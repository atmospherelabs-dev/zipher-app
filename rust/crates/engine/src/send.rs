use std::path::Path;
use std::sync::Mutex as StdMutex;

use anyhow::Result;
use secrecy::{ExposeSecret, SecretString};
use tracing::{debug, info, error};
use zeroize::Zeroize;

use zcash_address::ZcashAddress;
use zcash_client_backend::data_api::wallet::{
    create_pczt_from_proposal, create_proposed_transactions,
    extract_and_store_transaction_from_pczt,
    propose_send_max_transfer, propose_standard_transfer_to_address,
    propose_shielding, ConfirmationsPolicy, SpendingKeys,
};
use zcash_client_backend::data_api::{InputSource, MaxSpendMode, WalletRead};
use zcash_client_backend::fees::StandardFeeRule;
use zcash_client_backend::proposal::Proposal;
use zcash_client_backend::proto::service::RawTransaction;
use zcash_client_backend::wallet::OvkPolicy;
use zcash_client_sqlite::ReceivedNoteId;
use zcash_keys::address::Address;
use zcash_keys::keys::UnifiedSpendingKey;
use zcash_proofs::prover::LocalTxProver;
use zcash_protocol::consensus::{self, Network};
use zcash_protocol::value::Zatoshis;
use zcash_protocol::{PoolType, ShieldedProtocol};
use zcash_client_sqlite::WalletDb;
use super::wallet::connect_lwd;
use super::{open_wallet_db, ENGINE};

type DbType = WalletDb<rusqlite::Connection, Network, SystemClock, rand::rngs::OsRng>;
type ProposalType = Proposal<StandardFeeRule, ReceivedNoteId>;

use zcash_client_sqlite::util::SystemClock;

// ---------------------------------------------------------------------------
// Pending proposal state — always an SDK Proposal now
// ---------------------------------------------------------------------------

static PENDING_SEND: StdMutex<Option<ProposalType>> = StdMutex::new(None);

const PCZT_LOCK_EXPIRY_SECS: u64 = 600; // 10 minutes

fn pczt_lock_path(db_data_path: &Path) -> std::path::PathBuf {
    db_data_path
        .parent()
        .unwrap_or(db_data_path)
        .join("pending_pczt.lock")
}

fn check_pczt_lock(db_data_path: &Path) -> Result<()> {
    let lock = pczt_lock_path(db_data_path);
    if lock.exists() {
        if let Ok(meta) = std::fs::metadata(&lock) {
            if let Ok(modified) = meta.modified() {
                let age = modified.elapsed().unwrap_or_default();
                if age.as_secs() > PCZT_LOCK_EXPIRY_SECS {
                    info!("Stale PCZT lock ({}s old), removing", age.as_secs());
                    std::fs::remove_file(&lock).ok();
                    return Ok(());
                }
            }
        }
        return Err(anyhow::anyhow!(
            "A PCZT is already pending signing/broadcast. \
             Wait for it to confirm, or delete {} to cancel.",
            lock.display()
        ));
    }
    Ok(())
}

fn set_pczt_lock(db_data_path: &Path) {
    let lock = pczt_lock_path(db_data_path);
    std::fs::write(&lock, "").ok();
}

/// Clear the pending PCZT lock (call after successful broadcast or cancellation).
pub fn clear_pczt_lock(data_dir: &str) {
    let lock = std::path::Path::new(data_dir).join("pending_pczt.lock");
    std::fs::remove_file(&lock).ok();
}

// ---------------------------------------------------------------------------
// Propose / confirm (two-step send flow)
// ---------------------------------------------------------------------------

/// Step 1: Create a proposal, store it, return (send_amount, fee, is_exact).
///
/// Only shielded funds are spendable. Transparent funds must be shielded
/// first via the Shield button — they are never spent directly.
///
/// When `is_max` is true the SDK's `propose_send_max_transfer` is used and
/// `amount` is ignored — the returned `send_amount` is computed by the SDK.
pub async fn propose_send(
    address: &str,
    amount: u64,
    memo: Option<String>,
    is_max: bool,
) -> Result<(u64, u64, bool)> {
    let engine_guard = ENGINE.lock().await;
    let engine = engine_guard
        .as_ref()
        .ok_or_else(|| anyhow::anyhow!("Engine not initialized"))?;

    let db_data_path = engine.db_data_path.clone();
    let params = engine.params;
    let db_cipher_key = engine.db_cipher_key.clone();
    drop(engine_guard);

    let mut db_data = open_wallet_db(&db_data_path, params, &db_cipher_key)?;

    check_pczt_lock(&db_data_path)?;

    let account_id = db_data
        .get_account_ids()
        .map_err(|e| anyhow::anyhow!("{:?}", e))?
        .into_iter()
        .next()
        .ok_or_else(|| anyhow::anyhow!("No accounts"))?;

    let zaddr: ZcashAddress = address
        .parse()
        .map_err(|e| anyhow::anyhow!("Invalid address: {:?}", e))?;
    let to = Address::try_from_zcash_address(&params, zaddr.clone())
        .map_err(|e| anyhow::anyhow!("Address conversion: {:?}", e))?;

    let is_transparent_dest = matches!(to, Address::Transparent(_));

    let memo_bytes = match &memo {
        Some(m) if !m.is_empty() && !is_transparent_dest => {
            use std::str::FromStr;
            use zcash_protocol::memo::{Memo, MemoBytes};
            Some(MemoBytes::from(
                &Memo::from_str(m)
                    .map_err(|e| anyhow::anyhow!("Memo error: {:?}", e))?,
            ))
        }
        _ => None,
    };

    let confirmations = ConfirmationsPolicy::MIN;

    info!("Preparing send proposal to {}...", &address[..address.len().min(20)]);

    if is_max {
        let proposal = propose_send_max_transfer::<_, _, _, std::convert::Infallible>(
            &mut db_data,
            &params,
            account_id,
            &[ShieldedProtocol::Sapling, ShieldedProtocol::Orchard],
            &StandardFeeRule::Zip317,
            zaddr,
            memo_bytes,
            MaxSpendMode::MaxSpendable,
            confirmations,
        )
        .map_err(|e| anyhow::anyhow!("Proposal failed: {:?}", e))?;

        let fee = u64::from(proposal.steps().first().balance().fee_required());
        let send_amount: u64 = proposal
            .steps()
            .first()
            .transaction_request()
            .payments()
            .values()
            .map(|p| u64::from(p.amount()))
            .sum();

        info!("Proposal ready: {:.8} ZEC + {:.8} ZEC fee", send_amount as f64 / 1e8, fee as f64 / 1e8);
        *PENDING_SEND.lock().unwrap() = Some(proposal);
        Ok((send_amount, fee, true))
    } else {
        let send_zat = Zatoshis::from_u64(amount)
            .map_err(|_| anyhow::anyhow!("Invalid amount"))?;

        
        let proposal = propose_standard_transfer_to_address::<_, _, std::convert::Infallible>(
            &mut db_data,
            &params,
            StandardFeeRule::Zip317,
            account_id,
            confirmations,
            &to,
            send_zat,
            memo_bytes,
            None,
            ShieldedProtocol::Orchard,
        )
        .map_err(|e| anyhow::anyhow!("Proposal failed: {:?}", e))?;

        let fee = u64::from(proposal.steps().first().balance().fee_required());
        info!("Proposal ready: {:.8} ZEC + {:.8} ZEC fee", amount as f64 / 1e8, fee as f64 / 1e8);
        *PENDING_SEND.lock().unwrap() = Some(proposal);
        Ok((amount, fee, true))
    }
}

/// Step 2: Build + broadcast from the stored proposal.
pub async fn confirm_send(seed_phrase: &SecretString) -> Result<String> {
    info!("Signing and broadcasting transaction...");

    let proposal = {
        let mut lock = PENDING_SEND.lock().unwrap();
        lock.take()
            .ok_or_else(|| anyhow::anyhow!("No pending proposal — call propose_send first"))?
    };

    let step = proposal.steps().first();
    let fee = u64::from(step.balance().fee_required());
    let n_payments = step.transaction_request().payments().len();
    info!("Transaction: {} payment(s), {} zat fee", n_payments, fee);

    let engine_guard = ENGINE.lock().await;
    let engine = engine_guard
        .as_ref()
        .ok_or_else(|| anyhow::anyhow!("Engine not initialized"))?;

    let db_data_path = engine.db_data_path.clone();
    let params = engine.params;
    let server_url = engine.server_url.clone();
    let db_cipher_key = engine.db_cipher_key.clone();
    drop(engine_guard);

    let mnemonic =
        bip0039::Mnemonic::<bip0039::English>::from_phrase(seed_phrase.expose_secret())
            .map_err(|e| anyhow::anyhow!("Invalid seed phrase: {:?}", e))?;
    let mut seed = mnemonic.to_seed("");
    let usk_result = UnifiedSpendingKey::from_seed(&params, &seed, zip32::AccountId::ZERO);
    seed.zeroize();
    let usk = usk_result.map_err(|e| anyhow::anyhow!("USK derivation: {:?}", e))?;

    info!("Deriving keys and building ZK proofs...");
    let mut db_data = open_wallet_db(&db_data_path, params, &db_cipher_key)?;

    let prover = load_prover_from_path(&db_data_path)?;
    let spending_keys = SpendingKeys::from_unified_spending_key(usk);

    let txids = create_proposed_transactions::<
        _,
        _,
        std::convert::Infallible,
        _,
        std::convert::Infallible,
        _,
    >(
        &mut db_data,
        &params,
        &prover,
        &prover,
        &spending_keys,
        OvkPolicy::Sender,
        &proposal,
    )
    .map_err(|e| {
        error!("Transaction creation failed: {:?}", e);
        anyhow::anyhow!("Create tx failed: {:?}", e)
    })?;

    let txid = txids.first();
    info!("Transaction built: {}", txid);

    let tx = db_data
        .get_transaction(*txid)
        .map_err(|e| anyhow::anyhow!("{:?}", e))?
        .ok_or_else(|| anyhow::anyhow!("Transaction not found after creation"))?;
    let mut tx_bytes = Vec::new();
    tx.write(&mut tx_bytes)
        .map_err(|e| anyhow::anyhow!("Serialize tx: {:?}", e))?;

    debug!("[TX] {} bytes, header: {}", tx_bytes.len(),
        if tx_bytes.len() >= 20 { hex::encode(&tx_bytes[..20]) } else { hex::encode(&tx_bytes) });

    info!("Broadcasting to network...");
    let mut lwd = connect_lwd(&server_url).await?;
    let resp = lwd
        .send_transaction(RawTransaction {
            data: tx_bytes,
            height: 0,
        })
        .await
        .map_err(|e| {
            error!("Broadcast failed: {:?}", e);
            anyhow::anyhow!("Broadcast failed: {:?}", e)
        })?;

    let resp = resp.into_inner();

    if resp.error_code != 0 {
        error!("Broadcast rejected: {} (code {})", resp.error_message, resp.error_code);
        return Err(anyhow::anyhow!(
            "Broadcast rejected: {} (code {})",
            resp.error_message,
            resp.error_code
        ));
    }

    clear_pczt_lock(db_data_path.parent().unwrap_or(&db_data_path).to_str().unwrap_or(""));
    info!("Transaction confirmed! txid={}", txid);
    Ok(txid.to_string())
}


// ---------------------------------------------------------------------------
// PCZT creation (Creator + Prover — no signing key needed)
// ---------------------------------------------------------------------------

/// Create a PCZT from the pending proposal (Creator + Prover roles).
///
/// Returns serialized PCZT bytes ready for external signing via OWS.
/// The Signer role (spending key) is NOT needed here — only OWS needs the seed.
pub async fn create_pczt() -> Result<Vec<u8>> {
    let proposal = {
        let mut lock = PENDING_SEND.lock().unwrap();
        lock.take()
            .ok_or_else(|| anyhow::anyhow!("No pending proposal — call propose_send first"))?
    };

    let engine_guard = ENGINE.lock().await;
    let engine = engine_guard
        .as_ref()
        .ok_or_else(|| anyhow::anyhow!("Engine not initialized"))?;

    let db_data_path = engine.db_data_path.clone();
    let params = engine.params;
    let db_cipher_key = engine.db_cipher_key.clone();
    drop(engine_guard);

    let mut db_data = open_wallet_db(&db_data_path, params, &db_cipher_key)?;

    let account_id = db_data
        .get_account_ids()
        .map_err(|e| anyhow::anyhow!("{:?}", e))?
        .into_iter()
        .next()
        .ok_or_else(|| anyhow::anyhow!("No accounts"))?;

    info!("Building unsigned Zcash transaction (PCZT)...");
    let pczt = create_pczt_from_proposal::<
        _,
        _,
        std::convert::Infallible,
        _,
        std::convert::Infallible,
        _,
    >(
        &mut db_data,
        &params,
        account_id,
        OvkPolicy::Sender,
        &proposal,
    )
    .map_err(|e| anyhow::anyhow!("PCZT creation failed: {:?}", e))?;

    info!("Adding zero-knowledge proofs...");
    let tx_prover = load_prover_from_path(&db_data_path)?;

    let mut prover = pczt::roles::prover::Prover::new(pczt);

    if prover.requires_sapling_proofs() {
        info!("  Sapling proofs...");
        prover = prover
            .create_sapling_proofs(&tx_prover, &tx_prover)
            .map_err(|e| anyhow::anyhow!("Sapling proving failed: {:?}", e))?;
    }

    if prover.requires_orchard_proof() {
        info!("  Orchard proof...");
        let orchard_pk = orchard::circuit::ProvingKey::build();
        prover = prover
            .create_orchard_proof(&orchard_pk)
            .map_err(|e| anyhow::anyhow!("Orchard proving failed: {:?}", e))?;
    }

    let proved_pczt = prover.finish();
    let bytes = proved_pczt.serialize();
    set_pczt_lock(&db_data_path);
    info!("PCZT ready ({} bytes) — awaiting external signing", bytes.len());
    Ok(bytes)
}

// ---------------------------------------------------------------------------
// Store a signed PCZT back into the wallet DB (marks notes as spent)
// ---------------------------------------------------------------------------

/// After external signing (e.g. via OWS), feed the signed PCZT bytes back
/// so the wallet DB records the spent notes and prevents double-spends.
///
/// This is the SDK's intended workflow:
///   create_pczt_from_proposal → sign externally → extract_and_store
pub async fn store_signed_pczt(signed_pczt_bytes: &[u8]) -> Result<String> {
    let signed_pczt = pczt::Pczt::parse(signed_pczt_bytes)
        .map_err(|e| anyhow::anyhow!("Failed to parse signed PCZT: {:?}", e))?;

    let engine_guard = ENGINE.lock().await;
    let engine = engine_guard
        .as_ref()
        .ok_or_else(|| anyhow::anyhow!("Engine not initialized"))?;

    let db_data_path = engine.db_data_path.clone();
    let params = engine.params;
    let db_cipher_key = engine.db_cipher_key.clone();
    drop(engine_guard);

    let mut db_data = open_wallet_db(&db_data_path, params, &db_cipher_key)?;

    let tx_prover = load_prover_from_path(&db_data_path)?;
    let (spend_vk, output_vk) = tx_prover.verifying_keys();
    let orchard_vk = orchard::circuit::VerifyingKey::build();

    info!("Extracting and storing signed transaction in wallet DB...");
    let txid = extract_and_store_transaction_from_pczt::<DbType, Network>(
        &mut db_data,
        signed_pczt,
        Some((&spend_vk, &output_vk)),
        Some(&orchard_vk),
    )
    .map_err(|e| anyhow::anyhow!("Failed to extract/store PCZT: {:?}", e))?;

    let lock_dir = db_data_path.parent().unwrap_or(&db_data_path);
    std::fs::remove_file(lock_dir.join("pending_pczt.lock")).ok();

    info!("Transaction stored: {}", txid);
    Ok(txid.to_string())
}

// ---------------------------------------------------------------------------
// Max sendable (for the send page balance display)
// ---------------------------------------------------------------------------

/// Compute the maximum sendable amount to a given address.
/// Only considers shielded funds (transparent must be shielded first).
pub async fn get_max_sendable(address: &str) -> Result<u64> {
    let engine_guard = ENGINE.lock().await;
    let engine = engine_guard
        .as_ref()
        .ok_or_else(|| anyhow::anyhow!("Engine not initialized"))?;

    let db_data_path = engine.db_data_path.clone();
    let params = engine.params;
    let db_cipher_key = engine.db_cipher_key.clone();
    drop(engine_guard);

    let mut db_data = open_wallet_db(&db_data_path, params, &db_cipher_key)?;

    let account_id = db_data
        .get_account_ids()
        .map_err(|e| anyhow::anyhow!("{:?}", e))?
        .into_iter()
        .next()
        .ok_or_else(|| anyhow::anyhow!("No accounts"))?;

    let confirmations = ConfirmationsPolicy::MIN;

    let zaddr: ZcashAddress = address
        .parse()
        .map_err(|e| anyhow::anyhow!("Invalid address: {:?}", e))?;

    let proposal_result =
        propose_send_max_transfer::<_, _, _, std::convert::Infallible>(
            &mut db_data,
            &params,
            account_id,
            &[ShieldedProtocol::Sapling, ShieldedProtocol::Orchard],
            &StandardFeeRule::Zip317,
            zaddr,
            None,
            MaxSpendMode::MaxSpendable,
            confirmations,
        );

    match proposal_result {
        Ok(proposal) => {
            let send_amount: u64 = proposal
                .steps()
                .first()
                .transaction_request()
                .payments()
                .values()
                .map(|p| u64::from(p.amount()))
                .sum();
            Ok(send_amount)
        }
        Err(e) => {
            let err_str = format!("{:?}", e);
            if err_str.contains("InsufficientFunds") {
                Ok(0)
            } else {
                Err(anyhow::anyhow!("Proposal error: {}", err_str))
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Legacy single-step send (kept for compatibility)
// ---------------------------------------------------------------------------

fn propose_and_create_send(
    db_data: &mut DbType,
    params: &Network,
    account_id: <DbType as InputSource>::AccountId,
    to: &Address,
    amount: Zatoshis,
    memo: Option<zcash_protocol::memo::MemoBytes>,
    prover: &LocalTxProver,
    usk: UnifiedSpendingKey,
) -> Result<nonempty::NonEmpty<zcash_primitives::transaction::TxId>> {
    let proposal = propose_standard_transfer_to_address::<_, _, std::convert::Infallible>(
        db_data,
        params,
        StandardFeeRule::Zip317,
        account_id,
        ConfirmationsPolicy::MIN,
        to,
        amount,
        memo,
        None,
        ShieldedProtocol::Orchard,
    )
    .map_err(|e| anyhow::anyhow!("Proposal failed: {:?}", e))?;

    let spending_keys = SpendingKeys::from_unified_spending_key(usk);

    create_proposed_transactions::<_, _, std::convert::Infallible, _, std::convert::Infallible, _>(
        db_data,
        params,
        prover,
        prover,
        &spending_keys,
        OvkPolicy::Sender,
        &proposal,
    )
    .map_err(|e| anyhow::anyhow!("Create tx failed: {:?}", e))
}

fn propose_and_create_shielding(
    db_data: &mut DbType,
    params: &Network,
    from_addrs: &[zcash_transparent::address::TransparentAddress],
    to_account: <DbType as InputSource>::AccountId,
    prover: &LocalTxProver,
    usk: UnifiedSpendingKey,
) -> Result<nonempty::NonEmpty<zcash_primitives::transaction::TxId>> {
    let change_strategy =
        zcash_client_backend::fees::zip317::SingleOutputChangeStrategy::new(
            StandardFeeRule::Zip317,
            None,
            ShieldedProtocol::Orchard,
            zcash_client_backend::fees::DustOutputPolicy::default(),
        );
    let greedy =
        zcash_client_backend::data_api::wallet::input_selection::GreedyInputSelector::new();

    let proposal = propose_shielding::<_, _, _, _, std::convert::Infallible>(
        db_data,
        params,
        &greedy,
        &change_strategy,
        Zatoshis::from_u64(100_000).unwrap(),
        from_addrs,
        to_account,
        ConfirmationsPolicy::MIN,
    )
    .map_err(|e| anyhow::anyhow!("Shielding proposal failed: {:?}", e))?;

    let spending_keys = SpendingKeys::from_unified_spending_key(usk);

    create_proposed_transactions::<_, _, std::convert::Infallible, _, std::convert::Infallible, _>(
        db_data,
        params,
        prover,
        prover,
        &spending_keys,
        OvkPolicy::Sender,
        &proposal,
    )
    .map_err(|e| anyhow::anyhow!("Create shielding tx failed: {:?}", e))
}

fn load_prover_from_path(db_data_path: &Path) -> Result<LocalTxProver> {
    let wallet_dir = db_data_path
        .parent()
        .ok_or_else(|| anyhow::anyhow!("Cannot determine data directory"))?;

    let candidates = [
        wallet_dir.to_path_buf(),
        wallet_dir
            .parent()
            .map(|p| p.to_path_buf())
            .unwrap_or_default(),
    ];

    for dir in &candidates {
        let spend = dir.join("sapling-spend.params");
        let output = dir.join("sapling-output.params");
        if spend.exists() && output.exists() {
            return Ok(LocalTxProver::new(&spend, &output));
        }
    }

    Err(anyhow::anyhow!(
        "Sapling params not found. Searched {:?}.",
        candidates
    ))
}

/// Send a payment to one or more recipients (legacy single-step path).
pub async fn send_payment(
    seed_phrase: &SecretString,
    recipients: Vec<(String, u64, Option<String>)>,
) -> Result<String> {
    let engine_guard = ENGINE.lock().await;
    let engine = engine_guard
        .as_ref()
        .ok_or_else(|| anyhow::anyhow!("Engine not initialized"))?;

    let db_data_path = engine.db_data_path.clone();
    let params = engine.params;
    let server_url = engine.server_url.clone();
    let db_cipher_key = engine.db_cipher_key.clone();
    drop(engine_guard);

    let mnemonic =
        bip0039::Mnemonic::<bip0039::English>::from_phrase(seed_phrase.expose_secret())
            .map_err(|e| anyhow::anyhow!("Invalid seed phrase: {:?}", e))?;
    let mut seed = mnemonic.to_seed("");
    let usk_result = UnifiedSpendingKey::from_seed(&params, &seed, zip32::AccountId::ZERO);
    seed.zeroize();
    let usk = usk_result.map_err(|e| anyhow::anyhow!("USK derivation: {:?}", e))?;

    let mut db_data = open_wallet_db(&db_data_path, params, &db_cipher_key)?;

    let account_id = db_data
        .get_account_ids()
        .map_err(|e| anyhow::anyhow!("get_account_ids: {:?}", e))?
        .into_iter()
        .next()
        .ok_or_else(|| anyhow::anyhow!("No accounts in wallet"))?;

    if recipients.len() != 1 {
        return Err(anyhow::anyhow!(
            "Multi-recipient sends not yet implemented in the new engine"
        ));
    }

    let (addr_str, amount, memo_str) = &recipients[0];
    let zaddr: ZcashAddress = addr_str
        .parse()
        .map_err(|e| anyhow::anyhow!("Invalid address: {:?}", e))?;
    let to = Address::try_from_zcash_address(&params, zaddr)
        .map_err(|e| anyhow::anyhow!("Address conversion: {:?}", e))?;
    let amount = Zatoshis::from_u64(*amount).map_err(|_| anyhow::anyhow!("Invalid amount"))?;

    let is_transparent = matches!(to, Address::Transparent(_));
    let memo = match memo_str {
        Some(m) if !m.is_empty() && !is_transparent => {
            use std::str::FromStr;
            use zcash_protocol::memo::{Memo, MemoBytes};
            Some(MemoBytes::from(
                &Memo::from_str(m)
                    .map_err(|e| anyhow::anyhow!("Memo error: {:?}", e))?,
            ))
        }
        _ => None,
    };

    let prover = load_prover_from_path(&db_data_path)?;

    let txids = propose_and_create_send(
        &mut db_data, &params, account_id, &to, amount, memo, &prover, usk,
    )?;

    let txid = txids.first();
    let tx = db_data
        .get_transaction(*txid)
        .map_err(|e| anyhow::anyhow!("get_transaction: {:?}", e))?
        .ok_or_else(|| anyhow::anyhow!("Transaction not found after creation"))?;
    let mut tx_bytes = Vec::new();
    tx.write(&mut tx_bytes)
        .map_err(|e| anyhow::anyhow!("Serialize tx: {:?}", e))?;

    let mut lwd = connect_lwd(&server_url).await?;
    let resp = lwd
        .send_transaction(RawTransaction {
            data: tx_bytes,
            height: 0,
        })
        .await
        .map_err(|e| anyhow::anyhow!("Broadcast failed: {:?}", e))?;

    let resp = resp.into_inner();
    if resp.error_code != 0 {
        return Err(anyhow::anyhow!(
            "Broadcast rejected: {} (code {})",
            resp.error_message,
            resp.error_code
        ));
    }

    Ok(txid.to_string())
}

// ---------------------------------------------------------------------------
// Shield transparent funds
// ---------------------------------------------------------------------------

pub async fn shield_funds(seed_phrase: &SecretString) -> Result<String> {
    let engine_guard = ENGINE.lock().await;
    let engine = engine_guard
        .as_ref()
        .ok_or_else(|| anyhow::anyhow!("Engine not initialized"))?;

    let db_data_path = engine.db_data_path.clone();
    let params = engine.params;
    let server_url = engine.server_url.clone();
    let db_cipher_key = engine.db_cipher_key.clone();
    drop(engine_guard);

    let mnemonic =
        bip0039::Mnemonic::<bip0039::English>::from_phrase(seed_phrase.expose_secret())
            .map_err(|e| anyhow::anyhow!("Invalid seed phrase: {:?}", e))?;
    let mut seed = mnemonic.to_seed("");
    let usk_result = UnifiedSpendingKey::from_seed(&params, &seed, zip32::AccountId::ZERO);
    seed.zeroize();
    let usk = usk_result.map_err(|e| anyhow::anyhow!("USK derivation: {:?}", e))?;

    let mut db_data = open_wallet_db(&db_data_path, params, &db_cipher_key)?;

    let account_id = db_data
        .get_account_ids()
        .map_err(|e| anyhow::anyhow!("get_account_ids: {:?}", e))?
        .into_iter()
        .next()
        .ok_or_else(|| anyhow::anyhow!("No accounts in wallet"))?;

    let receivers = db_data
        .get_transparent_receivers(account_id, true, true)
        .map_err(|e| anyhow::anyhow!("get_transparent_receivers: {:?}", e))?;

    let from_addrs: Vec<zcash_transparent::address::TransparentAddress> =
        receivers.into_keys().collect();

    if from_addrs.is_empty() {
        return Err(anyhow::anyhow!("No transparent receivers found"));
    }

    let prover = load_prover_from_path(&db_data_path)?;

    let txids = propose_and_create_shielding(
        &mut db_data, &params, &from_addrs, account_id, &prover, usk,
    )?;

    let txid = txids.first();

    let tx = db_data
        .get_transaction(*txid)
        .map_err(|e| anyhow::anyhow!("get_transaction: {:?}", e))?
        .ok_or_else(|| anyhow::anyhow!("Transaction not found after creation"))?;

    let mut tx_bytes = Vec::new();
    tx.write(&mut tx_bytes)
        .map_err(|e| anyhow::anyhow!("Serialize tx: {:?}", e))?;

    let mut lwd = connect_lwd(&server_url).await?;
    let resp = lwd
        .send_transaction(RawTransaction {
            data: tx_bytes,
            height: 0,
        })
        .await
        .map_err(|e| anyhow::anyhow!("Broadcast failed: {:?}", e))?;

    let resp = resp.into_inner();
    if resp.error_code != 0 {
        return Err(anyhow::anyhow!(
            "Broadcast rejected: {} (code {})",
            resp.error_message,
            resp.error_code
        ));
    }

    Ok(txid.to_string())
}
