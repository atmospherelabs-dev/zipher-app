use std::path::Path;
use std::sync::Mutex as StdMutex;

use anyhow::Result;
use secrecy::{ExposeSecret, SecretString};
use tracing::{info, warn, error};
use zeroize::Zeroize;

use zcash_address::ZcashAddress;
use zcash_client_backend::data_api::wallet::{
    create_proposed_transactions, propose_send_max_transfer, propose_standard_transfer_to_address,
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

    info!("[PROPOSE] address={}, amount={}, is_max={}", address, amount, is_max);

    if is_max {
        info!("[PROPOSE] Using SDK propose_send_max_transfer");
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

        info!("[PROPOSE] MAX proposal OK. send_amount={}, fee={}", send_amount, fee);
        *PENDING_SEND.lock().unwrap() = Some(proposal);
        Ok((send_amount, fee, true))
    } else {
        let send_zat = Zatoshis::from_u64(amount)
            .map_err(|_| anyhow::anyhow!("Invalid amount"))?;

        info!("[PROPOSE] Using SDK propose_standard_transfer_to_address");
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
        info!("[PROPOSE] Proposal OK. fee={}", fee);
        *PENDING_SEND.lock().unwrap() = Some(proposal);
        Ok((amount, fee, true))
    }
}

/// Step 2: Build + broadcast from the stored proposal.
pub async fn confirm_send(seed_phrase: &SecretString) -> Result<String> {
    info!("[CONFIRM] ====== confirm_send START ======");

    let proposal = {
        let mut lock = PENDING_SEND.lock().unwrap();
        lock.take()
            .ok_or_else(|| anyhow::anyhow!("No pending proposal — call propose_send first"))?
    };

    let step = proposal.steps().first();
    info!("[CONFIRM] Proposal: target_height={}, fee_rule={:?}",
        u32::from(proposal.min_target_height()), proposal.fee_rule());
    info!("[CONFIRM] Proposal step: n_transparent_inputs={}, n_payments={}, fee_required={}, is_shielding={}",
        step.transparent_inputs().len(),
        step.transaction_request().payments().len(),
        u64::from(step.balance().fee_required()),
        step.is_shielding());
    for (idx, payment) in step.transaction_request().payments() {
        info!("[CONFIRM]   payment[{}]: addr={}, amount={}", idx,
            payment.recipient_address(), u64::from(payment.amount()));
    }
    for (i, utxo) in step.transparent_inputs().iter().enumerate() {
        info!("[CONFIRM]   t_input[{}]: outpoint={}:{}, value={}", i,
            hex::encode(utxo.outpoint().hash()), utxo.outpoint().n(),
            u64::from(utxo.txout().value()));
    }
    info!("[CONFIRM]   involves transparent={}, sapling={}, orchard={}",
        step.involves(PoolType::TRANSPARENT),
        step.involves(PoolType::Shielded(ShieldedProtocol::Sapling)),
        step.involves(PoolType::Shielded(ShieldedProtocol::Orchard)));

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

    {
        use zcash_transparent::keys::NonHardenedChildIndex;
        let t_key = usk.transparent();
        match t_key.derive_external_secret_key(NonHardenedChildIndex::ZERO) {
            Ok(sk) => {
                let sk_bytes = sk.secret_bytes();
                info!("[CONFIRM] USK external[0] secret key first 4 bytes: {}",
                    hex::encode(&sk_bytes[..4]));
            }
            Err(e) => {
                error!("[CONFIRM] Failed to derive external key[0]: {:?}", e);
            }
        }
        match t_key.derive_secret_key(
            zcash_transparent::keys::TransparentKeyScope::EXTERNAL,
            NonHardenedChildIndex::ZERO,
        ) {
            Ok(sk) => {
                let sk_bytes = sk.secret_bytes();
                info!("[CONFIRM] USK derive_secret_key(EXTERNAL, 0) first 4 bytes: {}",
                    hex::encode(&sk_bytes[..4]));
            }
            Err(e) => {
                error!("[CONFIRM] derive_secret_key(EXTERNAL, 0) failed: {:?}", e);
            }
        }
    }

    info!("[CONFIRM] USK derived OK, loading wallet DB...");
    let mut db_data = open_wallet_db(&db_data_path, params, &db_cipher_key)?;

    let prover = load_prover_from_path(&db_data_path)?;
    info!("[CONFIRM] Prover loaded OK. Calling create_proposed_transactions...");
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
        error!("[CONFIRM] create_proposed_transactions FAILED: {:?}", e);
        anyhow::anyhow!("Create tx failed: {:?}", e)
    })?;

    let txid = txids.first();
    info!("[CONFIRM] Transaction created OK. txid={}", txid);

    let tx = db_data
        .get_transaction(*txid)
        .map_err(|e| anyhow::anyhow!("{:?}", e))?
        .ok_or_else(|| anyhow::anyhow!("Transaction not found after creation"))?;
    let mut tx_bytes = Vec::new();
    tx.write(&mut tx_bytes)
        .map_err(|e| anyhow::anyhow!("Serialize tx: {:?}", e))?;
    info!("[CONFIRM] Serialized tx: {} bytes", tx_bytes.len());

    if tx_bytes.len() >= 20 {
        info!("[CONFIRM] tx header (first 20 bytes): {}", hex::encode(&tx_bytes[..20]));
    }
    if tx_bytes.len() >= 10 {
        let start = tx_bytes.len() - 10;
        info!("[CONFIRM] tx tail (last 10 bytes): {}", hex::encode(&tx_bytes[start..]));
    }

    if tx_bytes.len() >= 12 {
        let version = u32::from_le_bytes([tx_bytes[0], tx_bytes[1], tx_bytes[2], tx_bytes[3]]);
        let vg_id = u32::from_le_bytes([tx_bytes[4], tx_bytes[5], tx_bytes[6], tx_bytes[7]]);
        let branch = u32::from_le_bytes([tx_bytes[8], tx_bytes[9], tx_bytes[10], tx_bytes[11]]);
        info!("[CONFIRM] tx version=0x{:08x}, versionGroupId=0x{:08x}, consensusBranchId=0x{:08x}",
            version, vg_id, branch);

        let expected_branch = consensus::BranchId::for_height(
            &params,
            zcash_protocol::consensus::BlockHeight::from_u32(u32::from(proposal.min_target_height())),
        );
        info!("[CONFIRM] expected branch for target height: {:?}", expected_branch);
    }

    if tx_bytes.len() <= 2000 {
        info!("[CONFIRM] FULL TX HEX: {}", hex::encode(&tx_bytes));
    } else {
        info!("[CONFIRM] TX HEX (truncated, {} bytes total): {}...",
            tx_bytes.len(), hex::encode(&tx_bytes[..500]));
    }

    info!("[CONFIRM] Broadcasting to {}...", server_url);
    let mut lwd = connect_lwd(&server_url).await?;
    let resp = lwd
        .send_transaction(RawTransaction {
            data: tx_bytes,
            height: 0,
        })
        .await
        .map_err(|e| {
            error!("[CONFIRM] Broadcast gRPC call FAILED: {:?}", e);
            anyhow::anyhow!("Broadcast failed: {:?}", e)
        })?;

    let resp = resp.into_inner();
    info!("[CONFIRM] Broadcast response: error_code={}, error_message='{}'",
        resp.error_code, resp.error_message);

    if resp.error_code != 0 {
        error!("[CONFIRM] BROADCAST REJECTED: code={}, msg={}", resp.error_code, resp.error_message);
        return Err(anyhow::anyhow!(
            "Broadcast rejected: {} (code {})",
            resp.error_message,
            resp.error_code
        ));
    }

    info!("[CONFIRM] ====== confirm_send SUCCESS txid={} ======", txid);
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
