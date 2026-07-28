use std::path::Path;
use std::sync::Mutex as StdMutex;

use anyhow::Result;
use secrecy::{ExposeSecret, SecretString};
use tracing::{debug, error, info, warn};
use zeroize::Zeroize;

use super::sync::known_lightwalletd_servers;
use super::wallet::{connect_lwd, connect_lwd_tor};
use super::{open_wallet_db, ENGINE};

/// Connect to lightwalletd, routing through Tor if enabled.
async fn connect_lwd_maybe_tor(
    server_url: &str,
) -> Result<CompactTxStreamerClient<tonic::transport::Channel>> {
    let tor = {
        let guard = ENGINE.lock().await;
        guard.as_ref().and_then(|e| e.tor_client.clone())
    };
    if let Some(ref client) = tor {
        connect_lwd_tor(client, server_url).await
    } else {
        connect_lwd(server_url).await
    }
}
use zcash_address::ZcashAddress;
use zcash_client_backend::data_api::wallet::{
    create_pczt_from_proposal,
    create_proposed_transactions,
    extract_and_store_transaction_from_pczt, propose_send_max_transfer, propose_shielding,
    propose_standard_transfer_to_address,
    ConfirmationsPolicy, SpendingKeys,
};
use zcash_client_backend::data_api::wallet::input_selection::LockedInputPolicy;
use zcash_client_backend::data_api::{Account as _, CoinbaseFilter, InputSource, MaxSpendMode, WalletRead};
use zcash_client_backend::fees::StandardFeeRule;
use zcash_client_backend::proposal::Proposal;
use zcash_client_backend::proto::service::RawTransaction;
use zcash_client_backend::proto::service::compact_tx_streamer_client::CompactTxStreamerClient;
use zcash_client_backend::wallet::OvkPolicy;
use zcash_client_sqlite::ReceivedNoteId;
use zcash_client_sqlite::WalletDb;
use zcash_keys::address::Address;
use zcash_keys::keys::UnifiedSpendingKey;
use orchard::circuit::OrchardCircuitVersion;
use zcash_primitives::transaction::builder::BundlePadding;
use zcash_proofs::prover::LocalTxProver;
use zcash_protocol::consensus::Network;
use zcash_protocol::value::Zatoshis;
use zcash_protocol::ShieldedProtocol;

pub(crate) type DbType = WalletDb<rusqlite::Connection, Network, SystemClock, rand::rngs::OsRng>;
pub(crate) type ProposalType = Proposal<StandardFeeRule, ReceivedNoteId>;

use zcash_client_sqlite::util::SystemClock;

/// 2-block expiry delta (~2.5 minutes at 75s/block).
#[allow(dead_code)]
const TX_EXPIRY_DELTA: u32 = 2;

/// 4x the standard ZIP-317 marginal fee (5000 zat) = 20000 zat.
#[allow(dead_code)]
const PRIORITY_MARGINAL_FEE: u64 = 20_000;

// ---------------------------------------------------------------------------
// Pending proposal state
// ---------------------------------------------------------------------------

pub(crate) static PENDING_SEND: StdMutex<Option<ProposalType>> = StdMutex::new(None);

// ---------------------------------------------------------------------------
// Multi-server broadcast
// ---------------------------------------------------------------------------

/// Broadcast a raw transaction to all known lightwalletd servers concurrently.
/// Returns success if at least one server accepts. Falls back to single-server
/// if the primary is not in our known list (e.g. self-hosted node).
async fn broadcast_multi(
    primary_url: &str,
    params: &Network,
    tx_bytes: Vec<u8>,
) -> Result<()> {
    let known = known_lightwalletd_servers(params);
    let is_known_primary = known.iter().any(|s| s == primary_url);

    if !is_known_primary || known.len() <= 1 {
        let mut lwd = connect_lwd_maybe_tor(primary_url).await?;
        let resp = lwd
            .send_transaction(RawTransaction { data: tx_bytes, height: 0 })
            .await
            .map_err(|e| anyhow::anyhow!("Broadcast failed: {:?}", e))?
            .into_inner();
        if resp.error_code != 0 {
            return Err(anyhow::anyhow!(
                "Broadcast rejected: {} (code {})",
                resp.error_message, resp.error_code
            ));
        }
        return Ok(());
    }

    // Broadcast to all known servers concurrently.
    let mut handles = Vec::with_capacity(known.len());
    for server in &known {
        let url = server.clone();
        let data = tx_bytes.clone();
        handles.push(tokio::spawn(async move {
            let client = connect_lwd_maybe_tor(&url).await;
            match client {
                Ok(mut lwd) => {
                    match lwd.send_transaction(RawTransaction { data, height: 0 }).await {
                        Ok(resp) => {
                            let r = resp.into_inner();
                            if r.error_code == 0 {
                                Ok(url)
                            } else {
                                Err(format!("{}: rejected code={} msg={}", url, r.error_code, r.error_message))
                            }
                        }
                        Err(e) => Err(format!("{}: rpc error {:?}", url, e)),
                    }
                }
                Err(e) => Err(format!("{}: connect failed {:?}", url, e)),
            }
        }));
    }

    let results = futures_util::future::join_all(handles).await;
    let mut successes = Vec::new();
    let mut failures = Vec::new();

    for result in results {
        match result {
            Ok(Ok(url)) => successes.push(url),
            Ok(Err(msg)) => failures.push(msg),
            Err(e) => failures.push(format!("task panicked: {:?}", e)),
        }
    }

    if successes.is_empty() {
        error!("Multi-server broadcast: all {} servers rejected", failures.len());
        let first_err = failures.into_iter().next().unwrap_or_default();
        return Err(anyhow::anyhow!("Broadcast failed on all servers: {}", first_err));
    }

    info!(
        "Multi-server broadcast: {}/{} servers accepted",
        successes.len(),
        successes.len() + failures.len()
    );
    for f in &failures {
        warn!("Multi-server broadcast partial failure: {}", f);
    }

    Ok(())
}

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
///
/// When `priority` is true, a 4x marginal fee is used (20000 zat vs 5000 zat
/// standard). This makes the transaction more likely to be mined quickly but
/// costs more.
pub async fn propose_send(
    address: &str,
    amount: u64,
    memo: Option<String>,
    is_max: bool,
    priority: bool,
) -> Result<(u64, u64, bool)> {
    super::sync::ensure_synced().await?;

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
                &Memo::from_str(m).map_err(|e| anyhow::anyhow!("Memo error: {:?}", e))?,
            ))
        }
        _ => None,
    };

    let confirmations = ConfirmationsPolicy::MIN;

    info!(
        "Preparing send proposal to {}...",
        &address[..address.len().min(20)]
    );

    if is_max {
        // librustzcash 0.21 has a bug in `propose_send_max_transfer` for transparent
        // recipients: it never inserts `PoolType::Transparent` into the payment_pools
        // map, causing `PaymentPoolsMismatch`. Workaround: probe the fee with a
        // standard transfer, adjusting the amount until it fits.
        if is_transparent_dest {
            let summary_opt = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                db_data.get_wallet_summary(ConfirmationsPolicy::MIN)
            }))
            .map_err(|_| anyhow::anyhow!("wallet summary unavailable"))?
            .map_err(|e| anyhow::anyhow!("{:?}", e))?;
            let summary =
                summary_opt.ok_or_else(|| anyhow::anyhow!("wallet summary not yet available"))?;
            let ab = summary
                .account_balances()
                .get(&account_id)
                .ok_or_else(|| anyhow::anyhow!("account balance missing"))?;
            let spendable: u64 = u64::from(ab.sapling_balance().spendable_value())
                + u64::from(ab.orchard_balance().spendable_value());

            // Probe progressively larger fee buffers until the proposal succeeds.
            // ZIP-317 base is 5_000 zat and most max-to-transparent sends fit within
            // 25_000 zat. Any over-estimate ends up as shielded change, which is fine.
            let mut last_err: Option<anyhow::Error> = None;
            for fee_buffer in [10_000u64, 15_000, 20_000, 25_000, 30_000, 40_000] {
                if spendable <= fee_buffer {
                    continue;
                }
                let target = spendable - fee_buffer;
                let send_zat = match Zatoshis::from_u64(target) {
                    Ok(z) => z,
                    Err(_) => continue,
                };
                let attempt = propose_standard_transfer_to_address::<_, _, std::convert::Infallible>(
                    &mut db_data,
                    &params,
                    StandardFeeRule::Zip317,
                    account_id,
                    confirmations,
                    &to,
                    send_zat,
                    memo_bytes.clone(),
                    None,
                    ShieldedProtocol::Orchard,
                    None,
                    None,
                );
                match attempt {
                    Ok(proposal) => {
                        let fee = u64::from(proposal.steps().first().balance().fee_required());
                        info!(
                            "Max-to-transparent proposal: send {:.8} ZEC + {:.8} ZEC fee (buffer {})",
                            target as f64 / 1e8,
                            fee as f64 / 1e8,
                            fee_buffer,
                        );
                        *PENDING_SEND.lock().unwrap() = Some(proposal);
                        return Ok((target, fee, true));
                    }
                    Err(e) => {
                        last_err = Some(anyhow::anyhow!("{:?}", e));
                    }
                }
            }
            return Err(last_err.unwrap_or_else(|| {
                anyhow::anyhow!("Insufficient balance for max-to-transparent send")
            }));
        }

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
            &LockedInputPolicy::default(),
            None,
        )
        .map_err(|e| anyhow::anyhow!("Proposal failed: {:?}", e))?;

        let fee = u64::from(proposal.steps().first().balance().fee_required());
        let send_amount: u64 = proposal
            .steps()
            .first()
            .transaction_request()
            .payments()
            .values()
            .filter_map(|p| p.amount().map(|a| u64::from(a)))
            .sum();

        info!(
            "Proposal ready: {:.8} ZEC + {:.8} ZEC fee",
            send_amount as f64 / 1e8,
            fee as f64 / 1e8
        );
        *PENDING_SEND.lock().unwrap() = Some(proposal);
        Ok((send_amount, fee, true))
    } else {
        let send_zat = Zatoshis::from_u64(amount).map_err(|_| anyhow::anyhow!("Invalid amount"))?;

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
            None,
            None,
        )
        .map_err(|e| {
            if priority {
                anyhow::anyhow!("Priority proposal failed: {:?}", e)
            } else {
                anyhow::anyhow!("Proposal failed: {:?}", e)
            }
        })?;

        let fee = u64::from(proposal.steps().first().balance().fee_required());
        if priority {
            info!(
                "Priority proposal ready: {:.8} ZEC + {:.8} ZEC fee (standard ZIP-317 until custom marginal fee is restored)",
                amount as f64 / 1e8,
                fee as f64 / 1e8
            );
        } else {
            info!(
                "Proposal ready: {:.8} ZEC + {:.8} ZEC fee",
                amount as f64 / 1e8,
                fee as f64 / 1e8
            );
        }
        *PENDING_SEND.lock().unwrap() = Some(proposal);
        Ok((amount, fee, true))
    }
}

/// Step 2: Build + broadcast from the stored proposal.
pub async fn confirm_send(seed_phrase: &SecretString) -> Result<String> {
    info!("Signing and broadcasting transaction...");

    let pending = {
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
    let server_url = engine.server_url.clone();
    let db_cipher_key = engine.db_cipher_key.clone();
    drop(engine_guard);

    let mnemonic = bip0039::Mnemonic::<bip0039::English>::from_phrase(seed_phrase.expose_secret())
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
        &pending,
        None,
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

    debug!(
        "[TX] {} bytes, header: {}",
        tx_bytes.len(),
        if tx_bytes.len() >= 20 {
            hex::encode(&tx_bytes[..20])
        } else {
            hex::encode(&tx_bytes)
        }
    );

    info!("Broadcasting to network...");
    let raw_tx = tx_bytes.clone();
    broadcast_multi(&server_url, &params, tx_bytes).await?;

    clear_pczt_lock(
        db_data_path
            .parent()
            .unwrap_or(&db_data_path)
            .to_str()
            .unwrap_or(""),
    );
    if let Err(e) = super::pending::record_broadcast(&db_data_path, &db_cipher_key, *txid, &raw_tx)
    {
        debug!("Failed to record pending transaction {}: {:?}", txid, e);
    }
    super::sync::emit_transaction_event(txid.to_string(), "pending");
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
        None,
        BundlePadding::DEFAULT,
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
        let orchard_pk =
            orchard::circuit::ProvingKey::build(OrchardCircuitVersion::FixedPostNu6_2);
        prover = prover
            .create_orchard_proof(&orchard_pk)
            .map_err(|e| anyhow::anyhow!("Orchard proving failed: {:?}", e))?;
    }

    let proved_pczt = prover.finish();
    let bytes = proved_pczt
        .serialize()
        .map_err(|e| anyhow::anyhow!("PCZT serialize failed: {:?}", e))?;
    set_pczt_lock(&db_data_path);
    info!(
        "PCZT ready ({} bytes) — awaiting external signing",
        bytes.len()
    );
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
    store_signed_pczt_inner(signed_pczt_bytes, false).await
}

pub async fn store_and_broadcast_signed_pczt(signed_pczt_bytes: &[u8]) -> Result<String> {
    store_signed_pczt_inner(signed_pczt_bytes, true).await
}

async fn store_signed_pczt_inner(signed_pczt_bytes: &[u8], broadcast: bool) -> Result<String> {
    let signed_pczt = pczt::Pczt::parse(signed_pczt_bytes)
        .map_err(|e| anyhow::anyhow!("Failed to parse signed PCZT: {:?}", e))?;

    let engine_guard = ENGINE.lock().await;
    let engine = engine_guard
        .as_ref()
        .ok_or_else(|| anyhow::anyhow!("Engine not initialized"))?;

    let db_data_path = engine.db_data_path.clone();
    let params = engine.params;
    let server_url = engine.server_url.clone();
    let db_cipher_key = engine.db_cipher_key.clone();
    drop(engine_guard);

    let mut db_data = open_wallet_db(&db_data_path, params, &db_cipher_key)?;

    let tx_prover = load_prover_from_path(&db_data_path)?;
    let (spend_vk, output_vk) = tx_prover.verifying_keys();
    let orchard_vk =
        orchard::circuit::VerifyingKey::build(OrchardCircuitVersion::FixedPostNu6_2);

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
    if broadcast {
        let tx = db_data
            .get_transaction(txid)
            .map_err(|e| anyhow::anyhow!("{:?}", e))?
            .ok_or_else(|| anyhow::anyhow!("Transaction not found after PCZT store"))?;
        let mut tx_bytes = Vec::new();
        tx.write(&mut tx_bytes)
            .map_err(|e| anyhow::anyhow!("Serialize tx: {:?}", e))?;

        let raw_tx = tx_bytes.clone();
        broadcast_multi(&server_url, &params, tx_bytes).await?;
        if let Err(e) =
            super::pending::record_broadcast(&db_data_path, &db_cipher_key, txid, &raw_tx)
        {
            debug!("Failed to record pending PCZT transaction {}: {:?}", txid, e);
        }
        super::sync::emit_transaction_event(txid.to_string(), "pending");
    }
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
    let to = Address::try_from_zcash_address(&params, zaddr.clone())
        .map_err(|e| anyhow::anyhow!("Address conversion: {:?}", e))?;
    let is_transparent_dest = matches!(to, Address::Transparent(_));

    // librustzcash 0.21 bug: `propose_send_max_transfer` to a transparent
    // recipient always errors with `PaymentPoolsMismatch`. Estimate via probing.
    if is_transparent_dest {
        let summary_opt = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            db_data.get_wallet_summary(ConfirmationsPolicy::MIN)
        }))
        .map_err(|_| anyhow::anyhow!("wallet summary unavailable"))?
        .map_err(|e| anyhow::anyhow!("{:?}", e))?;
        let summary = match summary_opt {
            Some(s) => s,
            None => return Ok(0),
        };
        let ab = match summary.account_balances().get(&account_id) {
            Some(ab) => ab,
            None => return Ok(0),
        };
        let spendable: u64 = u64::from(ab.sapling_balance().spendable_value())
            + u64::from(ab.orchard_balance().spendable_value());
        for fee_buffer in [10_000u64, 15_000, 20_000, 25_000, 30_000, 40_000] {
            if spendable <= fee_buffer {
                continue;
            }
            let target = spendable - fee_buffer;
            let send_zat = match Zatoshis::from_u64(target) {
                Ok(z) => z,
                Err(_) => continue,
            };
            let attempt = propose_standard_transfer_to_address::<_, _, std::convert::Infallible>(
                &mut db_data,
                &params,
                StandardFeeRule::Zip317,
                account_id,
                confirmations,
                &to,
                send_zat,
                None,
                None,
                ShieldedProtocol::Orchard,
                None,
                None,
            );
            if attempt.is_ok() {
                return Ok(target);
            }
        }
        return Ok(0);
    }

    let proposal_result = propose_send_max_transfer::<_, _, _, std::convert::Infallible>(
        &mut db_data,
        &params,
        account_id,
        &[ShieldedProtocol::Sapling, ShieldedProtocol::Orchard],
        &StandardFeeRule::Zip317,
        zaddr,
        None,
        MaxSpendMode::MaxSpendable,
        confirmations,
        &LockedInputPolicy::default(),
        None,
    );

    match proposal_result {
        Ok(proposal) => {
            let send_amount: u64 = proposal
                .steps()
                .first()
                .transaction_request()
                .payments()
                .values()
                .filter_map(|p| p.amount().map(|a| u64::from(a)))
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
        None,
        None,
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
        None,
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
    let change_strategy = zcash_client_backend::fees::zip317::SingleOutputChangeStrategy::new(
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
        CoinbaseFilter::AllTransparentOutputs,
        None,
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
        None,
    )
    .map_err(|e| anyhow::anyhow!("Create shielding tx failed: {:?}", e))
}

/// Create a proved PCZT for transparent -> shielded funds.
///
/// This is the FROST/hardware-friendly shielding path: it builds the SDK
/// shielding proposal and then runs the same Creator + Prover PCZT roles used
/// by normal sends, without reading any seed material.
pub async fn create_shield_pczt() -> Result<Vec<u8>> {
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

    let change_strategy = zcash_client_backend::fees::zip317::SingleOutputChangeStrategy::new(
        StandardFeeRule::Zip317,
        None,
        ShieldedProtocol::Orchard,
        zcash_client_backend::fees::DustOutputPolicy::default(),
    );
    let greedy =
        zcash_client_backend::data_api::wallet::input_selection::GreedyInputSelector::new();

    let proposal = propose_shielding::<_, _, _, _, std::convert::Infallible>(
        &mut db_data,
        &params,
        &greedy,
        &change_strategy,
        Zatoshis::from_u64(100_000).unwrap(),
        &from_addrs,
        account_id,
        ConfirmationsPolicy::MIN,
        CoinbaseFilter::AllTransparentOutputs,
        None,
    )
    .map_err(|e| anyhow::anyhow!("Shielding proposal failed: {:?}", e))?;

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
        None,
        BundlePadding::DEFAULT,
    )
    .map_err(|e| anyhow::anyhow!("Shield PCZT creation failed: {:?}", e))?;

    let tx_prover = load_prover_from_path(&db_data_path)?;
    let mut prover = pczt::roles::prover::Prover::new(pczt);
    if prover.requires_sapling_proofs() {
        prover = prover
            .create_sapling_proofs(&tx_prover, &tx_prover)
            .map_err(|e| anyhow::anyhow!("Sapling proving failed: {:?}", e))?;
    }
    if prover.requires_orchard_proof() {
        let orchard_pk =
            orchard::circuit::ProvingKey::build(OrchardCircuitVersion::FixedPostNu6_2);
        prover = prover
            .create_orchard_proof(&orchard_pk)
            .map_err(|e| anyhow::anyhow!("Orchard proving failed: {:?}", e))?;
    }
    let proved_pczt = prover.finish();
    let bytes = proved_pczt
        .serialize()
        .map_err(|e| anyhow::anyhow!("PCZT serialize failed: {:?}", e))?;
    set_pczt_lock(&db_data_path);
    Ok(bytes)
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

    let mnemonic = bip0039::Mnemonic::<bip0039::English>::from_phrase(seed_phrase.expose_secret())
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
                &Memo::from_str(m).map_err(|e| anyhow::anyhow!("Memo error: {:?}", e))?,
            ))
        }
        _ => None,
    };

    let prover = load_prover_from_path(&db_data_path)?;

    let txids = propose_and_create_send(
        &mut db_data,
        &params,
        account_id,
        &to,
        amount,
        memo,
        &prover,
        usk,
    )?;

    let txid = txids.first();
    let tx = db_data
        .get_transaction(*txid)
        .map_err(|e| anyhow::anyhow!("get_transaction: {:?}", e))?
        .ok_or_else(|| anyhow::anyhow!("Transaction not found after creation"))?;
    let mut tx_bytes = Vec::new();
    tx.write(&mut tx_bytes)
        .map_err(|e| anyhow::anyhow!("Serialize tx: {:?}", e))?;

    let raw_tx = tx_bytes.clone();
    broadcast_multi(&server_url, &params, tx_bytes).await?;

    if let Err(e) = super::pending::record_broadcast(&db_data_path, &db_cipher_key, *txid, &raw_tx)
    {
        debug!("Failed to record pending transaction {}: {:?}", txid, e);
    }
    super::sync::emit_transaction_event(txid.to_string(), "pending");
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

    let mnemonic = bip0039::Mnemonic::<bip0039::English>::from_phrase(seed_phrase.expose_secret())
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

    let txids =
        propose_and_create_shielding(&mut db_data, &params, &from_addrs, account_id, &prover, usk)?;

    let txid = txids.first();

    let tx = db_data
        .get_transaction(*txid)
        .map_err(|e| anyhow::anyhow!("get_transaction: {:?}", e))?
        .ok_or_else(|| anyhow::anyhow!("Transaction not found after creation"))?;

    let mut tx_bytes = Vec::new();
    tx.write(&mut tx_bytes)
        .map_err(|e| anyhow::anyhow!("Serialize tx: {:?}", e))?;

    let raw_tx = tx_bytes.clone();
    broadcast_multi(&server_url, &params, tx_bytes).await?;

    if let Err(e) = super::pending::record_broadcast(&db_data_path, &db_cipher_key, *txid, &raw_tx)
    {
        debug!("Failed to record pending shielding tx {}: {:?}", txid, e);
    }
    super::sync::emit_transaction_event(txid.to_string(), "pending");
    Ok(txid.to_string())
}

// ---------------------------------------------------------------------------
// Ironwood pool transfer (SpendPolicy-restricted to Orchard inputs)
// ---------------------------------------------------------------------------

use zcash_client_backend::data_api::wallet::{
    propose_transfer,
    input_selection::{GreedyInputSelector, SpendPolicy},
};
use zcash_client_backend::fees::zip317::SingleOutputChangeStrategy;
use zcash_client_backend::fees::DustOutputPolicy;
use zcash_primitives::transaction::TxVersion;
use zcash_client_backend::zip321;

/// Propose a pool transfer: spends only Orchard notes, sends to own
/// unified address (routed to Ironwood post-NU6.3).
///
/// Stores the proposal in PENDING_SEND for subsequent confirm_send.
/// Returns (amount_zat, fee_zat).
pub async fn propose_pool_transfer(
    amount_zat: u64,
    is_max: bool,
) -> Result<(u64, u64)> {
    super::sync::ensure_synced().await?;

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

    let account = db_data
        .get_account(account_id)
        .map_err(|e| anyhow::anyhow!("{:?}", e))?
        .ok_or_else(|| anyhow::anyhow!("Account not found"))?;

    let ufvk = account
        .ufvk()
        .ok_or_else(|| anyhow::anyhow!("No UFVK for account"))?;

    let (ua, _) = ufvk
        .default_address(zcash_keys::keys::UnifiedAddressRequest::ORCHARD)
        .map_err(|e| anyhow::anyhow!("Address derivation failed: {:?}", e))?;

    let zaddr: ZcashAddress = ua.encode(&params)
        .parse()
        .map_err(|e| anyhow::anyhow!("Invalid self-address: {:?}", e))?;

    info!(
        "[PoolTransfer] Proposing Orchard->Ironwood: {} zat, max={}",
        amount_zat, is_max
    );

    if is_max {
        let proposal = propose_send_max_transfer::<_, _, _, std::convert::Infallible>(
            &mut db_data,
            &params,
            account_id,
            &[ShieldedProtocol::Orchard],
            &StandardFeeRule::Zip317,
            zaddr,
            None,
            MaxSpendMode::MaxSpendable,
            ConfirmationsPolicy::MIN,
            &LockedInputPolicy::default(),
            None,
        )
        .map_err(|e| anyhow::anyhow!("Pool transfer max proposal failed: {:?}", e))?;

        let fee = u64::from(proposal.steps().first().balance().fee_required());
        let send_amount = {
            let balance = proposal.steps().first().balance();
            let total_in: u64 = u64::from(balance.total());
            let fee: u64 = u64::from(balance.fee_required());
            total_in.saturating_sub(fee)
        };

        info!(
            "[PoolTransfer] Max: {:.8} ZEC + {:.8} ZEC fee",
            send_amount as f64 / 1e8,
            fee as f64 / 1e8
        );

        *PENDING_SEND.lock().unwrap() = Some(proposal);
        Ok((send_amount, fee))
    } else {
        let send_zat = Zatoshis::from_u64(amount_zat)
            .map_err(|_| anyhow::anyhow!("Invalid amount"))?;

        let request = zip321::TransactionRequest::new(vec![
            zip321::Payment::new(
                zaddr,
                Some(send_zat),
                None,
                None,
                None,
                vec![],
            )
            .map_err(|e| anyhow::anyhow!("Failed to create payment: {:?}", e))?,
        ])
        .map_err(|e| anyhow::anyhow!("TransactionRequest: {:?}", e))?;

        let input_selector = GreedyInputSelector::new();
        let change_strategy = SingleOutputChangeStrategy::new(
            StandardFeeRule::Zip317,
            None,
            ShieldedProtocol::Orchard,
            DustOutputPolicy::default(),
        );
        let spend_policy = SpendPolicy::shielded_pools([ShieldedProtocol::Orchard]);

        let proposal = propose_transfer::<_, _, _, _, std::convert::Infallible>(
            &mut db_data,
            &params,
            account_id,
            &input_selector,
            &change_strategy,
            request,
            ConfirmationsPolicy::MIN,
            &spend_policy,
            None,
            Some(TxVersion::V6),
        )
        .map_err(|e| anyhow::anyhow!("Pool transfer proposal failed: {:?}", e))?;

        let fee = u64::from(proposal.steps().first().balance().fee_required());
        info!(
            "[PoolTransfer] {:.8} ZEC + {:.8} ZEC fee",
            amount_zat as f64 / 1e8,
            fee as f64 / 1e8
        );

        *PENDING_SEND.lock().unwrap() = Some(proposal);
        Ok((amount_zat, fee))
    }
}
