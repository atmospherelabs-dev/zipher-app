use std::path::Path;
use std::sync::Mutex as StdMutex;

use anyhow::Result;
use secrecy::{ExposeSecret, SecretString};
use tracing::{debug, error, info, warn};
use zeroize::Zeroize;

use super::fees::{self, FeeSnapshot};
use super::sync::known_lightwalletd_servers;
use super::wallet::{connect_lwd, connect_lwd_tor};
use super::{open_wallet_db, ENGINE};

/// Connect with the wallet's captured transport policy; no global lock is needed.
async fn connect_lwd_with_tor(
    server_url: &str,
    tor: Option<&zcash_client_backend::tor::Client>,
) -> Result<CompactTxStreamerClient<tonic::transport::Channel>> {
    if let Some(client) = tor {
        connect_lwd_tor(client, server_url).await
    } else {
        connect_lwd(server_url).await
    }
}
use orchard::circuit::OrchardCircuitVersion;
use zcash_address::ZcashAddress;
use zcash_client_backend::data_api::wallet::input_selection::LockedInputPolicy;
use zcash_client_backend::data_api::wallet::{
    create_pczt_from_proposal, create_proposed_transactions,
    extract_and_store_transaction_from_pczt, propose_send_max_transfer, propose_shielding,
    ConfirmationsPolicy, SpendingKeys,
};
use zcash_client_backend::data_api::{
    CoinbaseFilter, InputSource, MaxSpendMode, OutputLockStore, WalletRead,
};
use zcash_client_backend::proposal::Proposal;
use zcash_client_backend::proto::service::compact_tx_streamer_client::CompactTxStreamerClient;
use zcash_client_backend::wallet::OvkPolicy;
use zcash_client_sqlite::ReceivedNoteId;
use zcash_client_sqlite::WalletDb;
use zcash_keys::address::Address;
use zcash_keys::keys::UnifiedSpendingKey;
use zcash_primitives::transaction::builder::BundlePadding;
use zcash_proofs::prover::LocalTxProver;
use zcash_protocol::consensus::Network;
use zcash_protocol::value::Zatoshis;
use zcash_protocol::ShieldedPool;

pub(crate) type DbType = WalletDb<rusqlite::Connection, Network, SystemClock, rand::rngs::OsRng>;
pub(crate) type ProposalType =
    Proposal<zcash_primitives::transaction::fees::zip317::FeeRule, ReceivedNoteId>;

use zcash_client_sqlite::util::SystemClock;

/// SDK selection, change and construction use the same reviewed fee rule.
fn propose_wallet_transfer(
    db: &mut DbType,
    params: &Network,
    fee_rule: zcash_primitives::transaction::fees::zip317::FeeRule,
    account: <DbType as InputSource>::AccountId,
    confirmations: ConfirmationsPolicy,
    to: &Address,
    amount: Zatoshis,
    memo: Option<zcash_protocol::memo::MemoBytes>,
) -> Result<ProposalType> {
    use zcash_client_backend::data_api::wallet::{
        input_selection::{GreedyInputSelector, SpendPolicy},
        propose_transfer,
    };
    let request = zip321::TransactionRequest::new(vec![zip321::Payment::new(
        to.to_zcash_address(params),
        Some(amount),
        memo,
        None,
        None,
        vec![],
    )
    .map_err(|e| anyhow::anyhow!("Invalid payment: {:?}", e))?])
    .map_err(|e| anyhow::anyhow!("Invalid request: {:?}", e))?;
    let selector = GreedyInputSelector::<DbType>::new();
    let change = zcash_client_backend::fees::zip317::SingleOutputChangeStrategy::<_, DbType>::new(
        fee_rule,
        None,
        ShieldedPool::Orchard,
        zcash_client_backend::fees::DustOutputPolicy::default(),
    );
    propose_transfer::<_, _, _, _, std::convert::Infallible>(
        db,
        params,
        account,
        &selector,
        &change,
        request,
        confirmations,
        &SpendPolicy::default(),
        None,
        None,
    )
    .map_err(|e| anyhow::anyhow!("Proposal failed: {:?}", e))
}

// ---------------------------------------------------------------------------
// Pending proposal state
// ---------------------------------------------------------------------------

pub(crate) struct PendingSend {
    proposal: ProposalType,
    fee_snapshot: FeeSnapshot,
    revision: u64,
}

pub(crate) static PENDING_SEND: StdMutex<Option<PendingSend>> = StdMutex::new(None);

/// Read the reviewed proposal's actual consensus branch for persisted approval
/// binding. This does not consume the proposal or access keys or the network.
pub fn pending_review_branch() -> Result<u32> {
    let guard = PENDING_SEND
        .lock()
        .map_err(|_| anyhow::anyhow!("Pending proposal unavailable"))?;
    let pending = guard
        .as_ref()
        .ok_or_else(|| anyhow::anyhow!("No pending proposal — review a payment first"))?;
    pending
        .fee_snapshot
        .review_branch(u32::from(pending.proposal.min_target_height()))
}

fn ensure_single_step(step_count: usize) -> Result<()> {
    if step_count != 1 {
        anyhow::bail!("Payments requiring multiple transactions, including TEX addresses, are not supported yet");
    }
    Ok(())
}

fn replace_single_step_pending<T>(slot: &mut Option<T>, step_count: usize, value: T) -> Result<()> {
    ensure_single_step(step_count)?;
    *slot = Some(value);
    Ok(())
}

async fn store_pending_send(proposal: ProposalType, fee_snapshot: FeeSnapshot) -> Result<()> {
    ensure_single_step(proposal.steps().len())?;
    let guard = ENGINE.lock().await;
    let engine = guard
        .as_ref()
        .ok_or_else(|| anyhow::anyhow!("Wallet closed during proposal creation"))?;
    fee_snapshot.validate_engine(engine)?;
    fee_snapshot.expiry_at_review(u32::from(proposal.min_target_height()))?;
    let steps = proposal.steps().len();
    static REVISION: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(1);
    let revision = REVISION.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    replace_single_step_pending(
        &mut *PENDING_SEND
            .lock()
            .map_err(|_| anyhow::anyhow!("Pending proposal unavailable"))?,
        steps,
        PendingSend {
            proposal,
            fee_snapshot,
            revision,
        },
    )
}

/// Validate a review before an interface reserves its spending budget. This
/// makes no keys, signatures or wallet writes, and never consumes the proposal.
pub async fn preflight_confirm_send() -> Result<()> {
    let (snapshot, target, revision) = {
        let guard = PENDING_SEND
            .lock()
            .map_err(|_| anyhow::anyhow!("Pending proposal unavailable"))?;
        let pending = guard
            .as_ref()
            .ok_or_else(|| anyhow::anyhow!("No pending proposal — review a payment first"))?;
        ensure_single_step(pending.proposal.steps().len())?;
        (
            pending.fee_snapshot.clone(),
            u32::from(pending.proposal.min_target_height()),
            pending.revision,
        )
    };
    snapshot.fresh_expiry(target).await?;
    let guard = PENDING_SEND
        .lock()
        .map_err(|_| anyhow::anyhow!("Pending proposal unavailable"))?;
    if guard.as_ref().map(|pending| pending.revision) != Some(revision) {
        anyhow::bail!(
            "Proposal replaced during validation; review the new payment before confirming"
        );
    }
    Ok(())
}

fn proposal_totals<F, N>(proposal: &Proposal<F, N>) -> Result<(u64, u64)> {
    let mut amount = 0u64;
    let mut fee = 0u64;
    for step in proposal.steps() {
        fee = fee
            .checked_add(u64::from(step.balance().fee_required()))
            .ok_or_else(|| anyhow::anyhow!("Proposal fee overflow"))?;
        for payment in step.transaction_request().payments().values() {
            amount = amount
                .checked_add(payment.amount().map(u64::from).unwrap_or(0))
                .ok_or_else(|| anyhow::anyhow!("Proposal amount overflow"))?;
        }
    }
    Ok((amount, fee))
}

// ---------------------------------------------------------------------------
// Multi-server broadcast
// ---------------------------------------------------------------------------

/// Broadcast through the captured private route and wallet session. Every peer
/// checks its own fresh tip; a custom primary is contacted on its own.
pub(crate) async fn broadcast_for_generation(
    primary_url: &str,
    params: &Network,
    tx_bytes: Vec<u8>,
    tor: Option<zcash_client_backend::tor::Client>,
    generation: u64,
) -> Result<()> {
    broadcast_scoped(primary_url, params, tx_bytes, tor, Some(generation)).await
}

async fn broadcast_scoped(
    primary_url: &str,
    params: &Network,
    tx_bytes: Vec<u8>,
    tor: Option<zcash_client_backend::tor::Client>,
    expected_generation: Option<u64>,
) -> Result<()> {
    let (wallet_path, cipher_key) = {
        let guard = ENGINE.lock().await;
        let engine = guard
            .as_ref()
            .ok_or_else(|| anyhow::anyhow!("Wallet closed before broadcast"))?;
        if expected_generation.is_some_and(|generation| generation != engine.generation) {
            anyhow::bail!("Wallet session changed before broadcast");
        }
        if &engine.params != params || engine.server_url != primary_url {
            anyhow::bail!("Wallet or server changed before broadcast");
        }
        if engine.tor_required && tor.is_none() {
            anyhow::bail!("Private route changed before broadcast; review again");
        }
        engine.tor_transport()?;
        (engine.db_data_path.clone(), engine.db_cipher_key.clone())
    };
    // Sync progress is process-global and can still describe a previous
    // network. Only this wallet's persisted chain height may bound a peer tip.
    let known_tip = u32::from(
        open_wallet_db(&wallet_path, *params, &cipher_key)?
            .chain_height()
            .map_err(|e| anyhow::anyhow!("Read wallet height before broadcast: {e:?}"))?
            .ok_or_else(|| anyhow::anyhow!("Sync before broadcasting a transaction"))?,
    );
    let known = known_lightwalletd_servers(params);
    let is_known_primary = known.iter().any(|s| s == primary_url);

    if !is_known_primary || known.len() <= 1 {
        let resp = tokio::time::timeout(std::time::Duration::from_secs(20), async {
            let mut lwd = connect_lwd_with_tor(primary_url, tor.as_ref()).await?;
            crate::network_upgrade::submit_transaction_with_generation(
                &mut lwd,
                params,
                tx_bytes,
                known_tip,
                expected_generation,
            )
            .await
        })
        .await
        .map_err(|_| {
            anyhow::anyhow!(
                "Broadcast timed out; check this transaction's status before another payment"
            )
        })??;
        if resp.error_code != 0 {
            return Err(anyhow::anyhow!(
                "Broadcast rejected: {} (code {})",
                resp.error_message,
                resp.error_code
            ));
        }
        return Ok(());
    }

    // Broadcast to all known servers concurrently.
    let mut handles = Vec::with_capacity(known.len());
    for server in &known {
        let url = server.clone();
        let data = tx_bytes.clone();
        let tor = tor.clone();
        let params = *params;
        handles.push(tokio::spawn(async move {
            let request = tokio::time::timeout(std::time::Duration::from_secs(20), async {
                let mut lwd = connect_lwd_with_tor(&url, tor.as_ref()).await?;
                crate::network_upgrade::submit_transaction_with_generation(
                    &mut lwd,
                    &params,
                    data,
                    known_tip,
                    expected_generation,
                )
                .await
            })
            .await;
            let client = match request {
                Ok(result) => result,
                Err(_) => {
                    return Err(format!(
                        "{}: broadcast timed out; outcome may be pending",
                        url
                    ))
                }
            };
            match client {
                Ok(resp) => {
                    let r = resp;
                    if r.error_code == 0 {
                        Ok(url)
                    } else {
                        Err(format!(
                            "{}: rejected code={} msg={}",
                            url, r.error_code, r.error_message
                        ))
                    }
                }
                Err(e) => Err(format!("{}: broadcast failed {:?}", url, e)),
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
        error!(
            "Multi-server broadcast: all {} servers rejected",
            failures.len()
        );
        let first_err = failures.into_iter().next().unwrap_or_default();
        return Err(anyhow::anyhow!(
            "Broadcast failed on all servers: {}",
            first_err
        ));
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

/// Release stale note locks in the wallet DB if no proposal is in-flight.
/// The SDK locks selected notes during `propose_transfer` to prevent double-spend.
/// If the app exits/crashes before confirm, those locks persist and block future proposals.
fn clear_stale_note_locks(db_data: &mut DbType, db_data_path: &Path) {
    let has_pending = PENDING_SEND.lock().unwrap().is_some();
    let pczt_exists = pczt_lock_path(db_data_path).exists();

    if has_pending || pczt_exists {
        return;
    }

    let account_id = match db_data.get_account_ids() {
        Ok(ids) => ids.into_iter().next(),
        Err(_) => None,
    };

    if let Some(id) = account_id {
        match db_data.clear_locked_outputs(id) {
            Ok(0) => {}
            Ok(n) => info!("Cleared {} stale note lock(s)", n),
            Err(e) => warn!("Failed to clear note locks: {:?}", e),
        }
    }
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
/// One relay fee snapshot is used for selection, change, review and construction.
/// Priority pays 10x that snapshot's marginal fee; it does not guarantee inclusion.
pub async fn propose_send(
    address: &str,
    amount: u64,
    memo: Option<String>,
    is_max: bool,
    priority: bool,
) -> Result<(u64, u64, bool)> {
    super::sync::ensure_synced().await?;
    let fee_snapshot = fees::snapshot(priority).await?;
    let fee_rule = fee_snapshot.fee_rule()?;

    let engine_guard = ENGINE.lock().await;
    let engine = engine_guard
        .as_ref()
        .ok_or_else(|| anyhow::anyhow!("Engine not initialized"))?;

    fee_snapshot.validate_engine(engine)?;
    let db_data_path = engine.db_data_path.clone();
    let params = engine.params;
    let db_cipher_key = engine.db_cipher_key.clone();
    drop(engine_guard);

    let mut db_data = open_wallet_db(&db_data_path, params, &db_cipher_key)?;

    check_pczt_lock(&db_data_path)?;
    clear_stale_note_locks(&mut db_data, &db_data_path);

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
        let proposal = propose_send_max_transfer::<_, _, _, std::convert::Infallible>(
            &mut db_data,
            &params,
            account_id,
            &[
                ShieldedPool::Sapling,
                ShieldedPool::Orchard,
                ShieldedPool::Ironwood,
            ],
            &fee_rule.clone(),
            zaddr,
            memo_bytes,
            MaxSpendMode::MaxSpendable,
            confirmations,
            &LockedInputPolicy::default(),
            None,
        )
        .map_err(|e| anyhow::anyhow!("Proposal failed: {:?}", e))?;

        let (send_amount, fee) = proposal_totals(&proposal)?;

        info!(
            "Proposal ready: {:.8} ZEC + {:.8} ZEC fee",
            send_amount as f64 / 1e8,
            fee as f64 / 1e8
        );
        store_pending_send(proposal, fee_snapshot).await?;
        Ok((send_amount, fee, true))
    } else {
        let send_zat = Zatoshis::from_u64(amount).map_err(|_| anyhow::anyhow!("Invalid amount"))?;

        let proposal = propose_wallet_transfer(
            &mut db_data,
            &params,
            fee_rule.clone(),
            account_id,
            confirmations,
            &to,
            send_zat,
            memo_bytes,
        )
        .map_err(|e| {
            if priority {
                anyhow::anyhow!("Priority proposal failed: {:?}", e)
            } else {
                anyhow::anyhow!("Proposal failed: {:?}", e)
            }
        })?;

        let (_, fee) = proposal_totals(&proposal)?;
        if priority {
            info!(
                "Priority proposal ready: {:.8} ZEC + {:.8} ZEC fee (10x marginal fee)",
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
        store_pending_send(proposal, fee_snapshot).await?;
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

    ensure_single_step(pending.proposal.steps().len())?;
    let engine_guard = ENGINE.lock().await;
    let engine = engine_guard
        .as_ref()
        .ok_or_else(|| anyhow::anyhow!("Engine not initialized"))?;

    pending.fee_snapshot.validate_engine(engine)?;
    let db_data_path = engine.db_data_path.clone();
    let params = engine.params;
    let server_url = engine.server_url.clone();
    let db_cipher_key = engine.db_cipher_key.clone();
    drop(engine_guard);
    let expiry = pending
        .fee_snapshot
        .fresh_expiry(u32::from(pending.proposal.min_target_height()))
        .await?;

    let mnemonic = bip0039::Mnemonic::<bip0039::English>::from_phrase(seed_phrase.expose_secret())
        .map_err(|_| anyhow::anyhow!("Invalid seed phrase"))?;
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
        &pending.proposal,
        Some(expiry),
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
    let tor = pending.fee_snapshot.broadcast_transport().await?;
    broadcast_for_generation(
        &server_url,
        &params,
        tx_bytes,
        tor,
        pending.fee_snapshot.generation(),
    )
    .await?;

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

    ensure_single_step(proposal.proposal.steps().len())?;
    let engine_guard = ENGINE.lock().await;
    let engine = engine_guard
        .as_ref()
        .ok_or_else(|| anyhow::anyhow!("Engine not initialized"))?;

    proposal.fee_snapshot.validate_engine(engine)?;
    let db_data_path = engine.db_data_path.clone();
    let params = engine.params;
    let db_cipher_key = engine.db_cipher_key.clone();
    drop(engine_guard);
    let expiry = proposal
        .fee_snapshot
        .fresh_expiry(u32::from(proposal.proposal.min_target_height()))
        .await?;

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
        &proposal.proposal,
        Some(expiry),
        BundlePadding::DEFAULT,
    )
    .map_err(|e| anyhow::anyhow!("PCZT creation failed: {:?}", e))?;

    let proved_pczt = prove_pczt(pczt, &db_data_path)?;
    let bytes = proved_pczt
        .serialize()
        .map_err(|e| anyhow::anyhow!("PCZT serialize failed: {:?}", e))?;
    proposal.fee_snapshot.validate_current().await?;
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

    let generation = engine.generation;
    let db_data_path = engine.db_data_path.clone();
    let params = engine.params;
    let server_url = engine.server_url.clone();
    let db_cipher_key = engine.db_cipher_key.clone();
    drop(engine_guard);

    let mut db_data = open_wallet_db(&db_data_path, params, &db_cipher_key)?;

    let sapling_keys = if !signed_pczt.sapling().spends().is_empty()
        || !signed_pczt.sapling().outputs().is_empty()
    {
        Some(load_prover_from_path(&db_data_path)?.verifying_keys())
    } else {
        None
    };

    info!("Extracting and storing signed transaction in wallet DB...");
    let txid = extract_and_store_transaction_from_pczt::<DbType, Network>(
        &mut db_data,
        signed_pczt,
        sapling_keys.as_ref().map(|(spend, output)| (spend, output)),
        None, // The SDK derives the verifying circuit from the PCZT branch ID.
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
        let tor = {
            let guard = ENGINE.lock().await;
            let engine = guard
                .as_ref()
                .ok_or_else(|| anyhow::anyhow!("Wallet closed during PCZT processing"))?;
            if engine.generation != generation {
                anyhow::bail!("Wallet session changed during PCZT processing");
            }
            engine.tor_transport()?
        };
        broadcast_for_generation(&server_url, &params, tx_bytes, tor, generation).await?;
        if let Err(e) =
            super::pending::record_broadcast(&db_data_path, &db_cipher_key, txid, &raw_tx)
        {
            debug!(
                "Failed to record pending PCZT transaction {}: {:?}",
                txid, e
            );
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
    get_max_sendable_with_priority(address, false).await
}

/// A priority-aware estimate for interfaces that already know the selected fee tier.
/// A subsequent send still makes its own fresh proposal and returns its exact amount.
pub async fn get_max_sendable_with_priority(address: &str, priority: bool) -> Result<u64> {
    let fee_snapshot = fees::snapshot(priority).await?;
    let fee_rule = fee_snapshot.fee_rule()?;
    let engine_guard = ENGINE.lock().await;
    let engine = engine_guard
        .as_ref()
        .ok_or_else(|| anyhow::anyhow!("Engine not initialized"))?;

    fee_snapshot.validate_engine(engine)?;
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
    let proposal_result = propose_send_max_transfer::<_, _, _, std::convert::Infallible>(
        &mut db_data,
        &params,
        account_id,
        &[
            ShieldedPool::Sapling,
            ShieldedPool::Orchard,
            ShieldedPool::Ironwood,
        ],
        &fee_rule,
        zaddr,
        None,
        MaxSpendMode::MaxSpendable,
        confirmations,
        &LockedInputPolicy::default(),
        None,
    );
    fee_snapshot.validate_current().await?;

    match proposal_result {
        Ok(proposal) => {
            ensure_single_step(proposal.steps().len())?;
            fee_snapshot.expiry_at_review(u32::from(proposal.min_target_height()))?;
            let (send_amount, _) = proposal_totals(&proposal)?;
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
    fee_snapshot: &FeeSnapshot,
    account_id: <DbType as InputSource>::AccountId,
    to: &Address,
    amount: Zatoshis,
    memo: Option<zcash_protocol::memo::MemoBytes>,
    prover: &LocalTxProver,
    usk: UnifiedSpendingKey,
) -> Result<nonempty::NonEmpty<zcash_primitives::transaction::TxId>> {
    let proposal = propose_wallet_transfer(
        db_data,
        params,
        fee_snapshot.fee_rule()?,
        account_id,
        ConfirmationsPolicy::MIN,
        to,
        amount,
        memo,
    )?;

    ensure_single_step(proposal.steps().len())?;
    let expiry = fee_snapshot.expiry_at_review(u32::from(proposal.min_target_height()))?;
    let spending_keys = SpendingKeys::from_unified_spending_key(usk);

    create_proposed_transactions::<_, _, std::convert::Infallible, _, std::convert::Infallible, _>(
        db_data,
        params,
        prover,
        prover,
        &spending_keys,
        OvkPolicy::Sender,
        &proposal,
        Some(expiry),
    )
    .map_err(|e| anyhow::anyhow!("Create tx failed: {:?}", e))
}

fn propose_and_create_shielding(
    db_data: &mut DbType,
    params: &Network,
    fee_snapshot: &FeeSnapshot,
    from_addrs: &[zcash_transparent::address::TransparentAddress],
    to_account: <DbType as InputSource>::AccountId,
    prover: &LocalTxProver,
    usk: UnifiedSpendingKey,
) -> Result<nonempty::NonEmpty<zcash_primitives::transaction::TxId>> {
    let change_strategy = zcash_client_backend::fees::zip317::SingleOutputChangeStrategy::new(
        fee_snapshot.fee_rule()?,
        None,
        ShieldedPool::Orchard,
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

    ensure_single_step(proposal.steps().len())?;
    let expiry = fee_snapshot.expiry_at_review(u32::from(proposal.min_target_height()))?;
    let spending_keys = SpendingKeys::from_unified_spending_key(usk);

    create_proposed_transactions::<_, _, std::convert::Infallible, _, std::convert::Infallible, _>(
        db_data,
        params,
        prover,
        prover,
        &spending_keys,
        OvkPolicy::Sender,
        &proposal,
        Some(expiry),
    )
    .map_err(|e| anyhow::anyhow!("Create shielding tx failed: {:?}", e))
}

/// Create a proved PCZT for transparent -> shielded funds.
///
/// This is the FROST/hardware-friendly shielding path: it builds the SDK
/// shielding proposal and then runs the same Creator + Prover PCZT roles used
/// by normal sends, without reading any seed material.
pub async fn create_shield_pczt() -> Result<Vec<u8>> {
    let fee_snapshot = fees::snapshot(false).await?;
    let fee_rule = fee_snapshot.fee_rule()?;
    let engine_guard = ENGINE.lock().await;
    let engine = engine_guard
        .as_ref()
        .ok_or_else(|| anyhow::anyhow!("Engine not initialized"))?;

    fee_snapshot.validate_engine(engine)?;
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
        fee_rule,
        None,
        ShieldedPool::Orchard,
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

    ensure_single_step(proposal.steps().len())?;
    let expiry = fee_snapshot.expiry_at_review(u32::from(proposal.min_target_height()))?;
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
        Some(expiry),
        BundlePadding::DEFAULT,
    )
    .map_err(|e| anyhow::anyhow!("Shield PCZT creation failed: {:?}", e))?;

    let proved_pczt = prove_pczt(pczt, &db_data_path)?;
    let bytes = proved_pczt
        .serialize()
        .map_err(|e| anyhow::anyhow!("PCZT serialize failed: {:?}", e))?;
    fee_snapshot.validate_current().await?;
    set_pczt_lock(&db_data_path);
    Ok(bytes)
}

fn orchard_circuit_version(branch: u32) -> Result<OrchardCircuitVersion> {
    use zcash_protocol::consensus::{BranchId, OrchardProtocolRevision};
    let revision = BranchId::try_from(branch)
        .ok()
        .and_then(|b| b.orchard_protocol_revision())
        .ok_or_else(|| anyhow::anyhow!("Unsupported Orchard consensus branch"))?;
    Ok(match revision {
        OrchardProtocolRevision::InsecureV1 => OrchardCircuitVersion::InsecurePreNu6_2,
        OrchardProtocolRevision::V2 => OrchardCircuitVersion::FixedPostNu6_2,
        OrchardProtocolRevision::V3 => OrchardCircuitVersion::PostNu6_3,
    })
}

#[cfg(test)]
mod circuit_tests {
    use super::*;
    use zcash_protocol::consensus::BranchId;

    #[test]
    fn selects_the_transaction_circuit_and_rejects_unknown_branches() {
        assert_eq!(
            orchard_circuit_version(u32::from(BranchId::Nu6_2)).unwrap(),
            OrchardCircuitVersion::FixedPostNu6_2
        );
        assert_eq!(
            orchard_circuit_version(u32::from(BranchId::Nu6_3)).unwrap(),
            OrchardCircuitVersion::PostNu6_3
        );
        assert!(orchard_circuit_version(u32::from(BranchId::Sapling)).is_err());
        assert!(orchard_circuit_version(0xffff_ffff).is_err());
    }
}

fn prove_pczt(pczt: pczt::Pczt, path: &Path) -> Result<pczt::Pczt> {
    use zcash_primitives::transaction::builder::cached_orchard_proving_key;
    let branch = *pczt.global().consensus_branch_id();
    let mut prover = pczt::roles::prover::Prover::new(pczt);
    if prover.requires_sapling_proofs() {
        let sapling = load_prover_from_path(path)?;
        prover = prover
            .create_sapling_proofs(&sapling, &sapling)
            .map_err(|e| anyhow::anyhow!("Sapling proving failed: {e:?}"))?;
    }
    if prover.requires_orchard_proof() {
        let key = cached_orchard_proving_key(orchard_circuit_version(branch)?)
            .map_err(|e| anyhow::anyhow!("Unsupported Orchard proving circuit: {e:?}"))?;
        prover = prover
            .create_orchard_proof(key)
            .map_err(|e| anyhow::anyhow!("Orchard proving failed: {e:?}"))?;
    }
    if prover.requires_ironwood_proof() {
        let key = cached_orchard_proving_key(OrchardCircuitVersion::PostNu6_3)
            .map_err(|e| anyhow::anyhow!("Unsupported Ironwood proving circuit: {e:?}"))?;
        prover = prover
            .create_ironwood_proof(key)
            .map_err(|e| anyhow::anyhow!("Ironwood proving failed: {e:?}"))?;
    }
    Ok(prover.finish())
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
    let fee_snapshot = fees::snapshot(false).await?;
    let engine_guard = ENGINE.lock().await;
    let engine = engine_guard
        .as_ref()
        .ok_or_else(|| anyhow::anyhow!("Engine not initialized"))?;

    fee_snapshot.validate_engine(engine)?;
    let db_data_path = engine.db_data_path.clone();
    let params = engine.params;
    let server_url = engine.server_url.clone();
    let db_cipher_key = engine.db_cipher_key.clone();
    drop(engine_guard);

    let mnemonic = bip0039::Mnemonic::<bip0039::English>::from_phrase(seed_phrase.expose_secret())
        .map_err(|_| anyhow::anyhow!("Invalid seed phrase"))?;
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
        &fee_snapshot,
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
    let tor = fee_snapshot.broadcast_transport().await?;
    broadcast_for_generation(
        &server_url,
        &params,
        tx_bytes,
        tor,
        fee_snapshot.generation(),
    )
    .await?;

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
    let fee_snapshot = fees::snapshot(false).await?;
    let engine_guard = ENGINE.lock().await;
    let engine = engine_guard
        .as_ref()
        .ok_or_else(|| anyhow::anyhow!("Engine not initialized"))?;

    fee_snapshot.validate_engine(engine)?;
    let db_data_path = engine.db_data_path.clone();
    let params = engine.params;
    let server_url = engine.server_url.clone();
    let db_cipher_key = engine.db_cipher_key.clone();
    drop(engine_guard);

    let mnemonic = bip0039::Mnemonic::<bip0039::English>::from_phrase(seed_phrase.expose_secret())
        .map_err(|_| anyhow::anyhow!("Invalid seed phrase"))?;
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
        &mut db_data,
        &params,
        &fee_snapshot,
        &from_addrs,
        account_id,
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
    let tor = fee_snapshot.broadcast_transport().await?;
    broadcast_for_generation(
        &server_url,
        &params,
        tx_bytes,
        tor,
        fee_snapshot.generation(),
    )
    .await?;

    if let Err(e) = super::pending::record_broadcast(&db_data_path, &db_cipher_key, *txid, &raw_tx)
    {
        debug!("Failed to record pending shielding tx {}: {:?}", txid, e);
    }
    super::sync::emit_transaction_event(txid.to_string(), "pending");
    Ok(txid.to_string())
}

// NOTE: The former `propose_pool_transfer` (manual Orchard → Ironwood path)
// was removed for ZIP-318 compliance. All migrations now go through
// `zcash_pool_migration` in ironwood_v2.rs, which handles canonical
// denominations, boundary-aligned anchors, and unpadded Ironwood bundles.

#[cfg(test)]
mod proposal_shape_tests {
    use super::*;

    #[test]
    fn unsupported_shapes_preserve_the_previously_reviewed_proposal() {
        let mut pending = Some("reviewed payment");
        for steps in [0, 2, 3] {
            let error = replace_single_step_pending(&mut pending, steps, "unsupported payment")
                .unwrap_err();
            assert!(error.to_string().contains("multiple transactions"));
            assert_eq!(pending, Some("reviewed payment"));
        }
        replace_single_step_pending(&mut pending, 1, "new reviewed payment").unwrap();
        assert_eq!(pending, Some("new reviewed payment"));
    }
}
