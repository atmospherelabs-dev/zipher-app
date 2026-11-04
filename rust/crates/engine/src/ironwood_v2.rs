//! Official SDK-based Ironwood pool transfer using `zcash_pool_migration`.
//!
//! Uses the canonical librustzcash crate for ZIP 318 denomination decomposition,
//! preparation transaction building, PCZT signing, scheduled proving, and broadcast.

use anyhow::{anyhow, Result};
use tracing::info;

use zcash_client_backend::data_api::WalletRead;
use zcash_client_sqlite::{pool_migration::orchard_ironwood::PoolMigrations, util::SystemClock};
use zcash_pool_migration::satisfiability::{
    advance_migration, AdvanceConfig, DuenessTargets, ReorgSettleDepth, ReplanThreshold,
};

// Serialize migration mutation across UI, CLI and service calls in this process.
static REVIEWED_PLAN: std::sync::Mutex<
    Option<(
        std::path::PathBuf,
        std::time::Instant,
        u32,
        u64,
        MigrationPlan,
    )>,
> = std::sync::Mutex::new(None);
static MIGRATION_OPERATION: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());
use zcash_keys::keys::UnifiedSpendingKey;
use zcash_pool_migration::engine::{
    self as mig_engine, MigrationPlan, MigrationState as SdkMigrationState, MigrationStatus,
    MigrationTxKind, MigrationTxState, PoolMigrationRead, PoolMigrationWrite,
};
use zcash_pool_migration::wallet::{WalletMigration, WalletMigrationProver};

use super::{open_wallet_db, ENGINE};

// ---------------------------------------------------------------------------
// Public result types for FFI
// ---------------------------------------------------------------------------

/// Summary of the planned denomination decomposition for user consent.
#[derive(Debug, Clone, serde::Serialize)]
pub struct PlanSummary {
    pub crossing_values: Vec<u64>,
    pub total_migrating_zat: u64,
    pub estimated_total_fee_zat: u64,
    pub prep_tx_count: usize,
    pub transfer_tx_count: usize,
    pub total_tx_count: usize,
    pub prep_layers: usize,
}

/// Current progress of the committed Ironwood transfer.
#[derive(Debug, Clone, serde::Serialize)]
pub struct ProgressReport {
    pub status: String,
    pub crossing_values: Vec<u64>,
    pub total_planned_zat: u64,
    pub total_confirmed_zat: u64,
    pub broadcast_count: u32,
    pub confirmed_count: u32,
    pub total_tx_count: u32,
    pub next_due_height: u32,
    pub fees_paid_zat: u64,
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Plan a transfer. Returns a summary for user consent (does NOT persist).
pub async fn plan(seed_phrase: &secrecy::SecretString) -> Result<PlanSummary> {
    let _operation = MIGRATION_OPERATION.lock().await;
    *REVIEWED_PLAN
        .lock()
        .map_err(|_| anyhow!("Migration review state is unavailable; reopen the wallet"))? = None;
    use secrecy::ExposeSecret;

    let (db_data_path, params, db_cipher_key, generation) = engine_params().await?;
    let db_data = open_wallet_db(&db_data_path, params, &db_cipher_key)?;
    let reviewed_target = u32::from(
        db_data
            .chain_height()
            .map_err(|e| anyhow!("Read migration planning height: {e:?}"))?
            .ok_or_else(|| anyhow!("Sync before reviewing a migration"))?,
    )
    .checked_add(1)
    .ok_or_else(|| anyhow!("Migration target height overflow"))?;
    super::network_upgrade::ensure_migration_can_start(&params, reviewed_target)?;

    let account_id = first_account_id(&db_data)?;

    let usk = derive_usk(&params, seed_phrase.expose_secret())?;

    let store = PoolMigrations::for_account(
        params,
        SystemClock,
        open_store_conn(&db_data_path, &db_cipher_key)?,
        account_id,
    )
    .map_err(|e| anyhow!("Store: {:?}", e))?;

    let wallet_mig = WalletMigration::new(
        &db_data,
        account_id,
        usk.to_unified_full_viewing_key(),
        store,
    );

    let mut rng = zipher_rng_compat::OS_RNG;
    let plan = mig_engine::plan_migration(&params, &wallet_mig, &mut rng)
        .map_err(|e| anyhow!("Plan failed: {}", e))?;

    let crossing_values: Vec<u64> = plan
        .crossing_values()
        .iter()
        .map(|z| u64::from(*z))
        .collect();
    let total_migrating: u64 = crossing_values.iter().sum();
    let estimated_total_fee = u64::from(plan.total_actions())
        * zcash_primitives::transaction::fees::zip317::MARGINAL_FEE.into_u64();

    let summary = PlanSummary {
        crossing_values,
        total_migrating_zat: total_migrating,
        estimated_total_fee_zat: estimated_total_fee,
        prep_tx_count: plan.preparation_tx_count(),
        transfer_tx_count: plan.transfer_tx_count(),
        total_tx_count: plan.total_transactions(),
        prep_layers: plan.preparation_layer_count(),
    };
    *REVIEWED_PLAN
        .lock()
        .map_err(|_| anyhow!("Migration review state is unavailable; reopen the wallet"))? =
        Some((
            db_data_path.into(),
            std::time::Instant::now(),
            reviewed_target,
            generation,
            plan,
        ));
    Ok(summary)
}

/// Commit: plan + build + sign all PCZTs in one pass. Durable in the wallet DB.
pub async fn commit(seed_phrase: &secrecy::SecretString) -> Result<ProgressReport> {
    let _operation = MIGRATION_OPERATION.lock().await;
    use secrecy::ExposeSecret;

    let (db_data_path, params, db_cipher_key, generation) = engine_params().await?;
    let db_data = open_wallet_db(&db_data_path, params, &db_cipher_key)?;

    let account_id = first_account_id(&db_data)?;
    let usk = derive_usk(&params, seed_phrase.expose_secret())?;

    let store = PoolMigrations::for_account(
        params,
        SystemClock,
        open_store_conn(&db_data_path, &db_cipher_key)?,
        account_id,
    )
    .map_err(|e| anyhow!("Store: {:?}", e))?;

    let (reviewed_path, reviewed_at, reviewed_target, reviewed_generation, plan) = REVIEWED_PLAN
        .lock()
        .map_err(|_| anyhow!("Migration review state is unavailable; reopen the wallet"))?
        .take()
        .ok_or_else(|| anyhow!("Review a migration plan before committing"))?;
    if reviewed_generation != generation
        || reviewed_path != std::path::PathBuf::from(&db_data_path)
        || reviewed_at.elapsed() > std::time::Duration::from_secs(600)
    {
        return Err(anyhow!(
            "Wallet changed or migration review expired; review again"
        ));
    }

    info!(
        "[Ironwood] Plan: {} crossings, {} prep txs ({} layers), {} total",
        plan.transfer_tx_count(),
        plan.preparation_tx_count(),
        plan.preparation_layer_count(),
        plan.total_transactions(),
    );

    let chain_tip = db_data
        .chain_height()
        .map_err(|e| anyhow!("{:?}", e))?
        .ok_or_else(|| anyhow!("Sync first"))?;
    let live_tip = live_migration_tip(&params, generation)
        .await?
        .max(u32::from(chain_tip));
    let target = live_tip
        .checked_add(1)
        .ok_or_else(|| anyhow!("Migration target height overflow"))?;
    super::network_upgrade::ensure_same_branch(&params, reviewed_target, target)?;
    super::network_upgrade::ensure_migration_can_start(&params, target)?;
    // Avoid paying preparation fees for a schedule whose first submission is
    // already in the upgrade hold. Do not silently redraw an approved plan.
    if let Some(first) = plan
        .planned_transactions()
        .iter()
        .filter_map(|t| t.scheduled_height().map(u32::from))
        .min()
    {
        if super::network_upgrade::migration_held(
            &params,
            super::network_upgrade::branch_at(&params, target),
            first.saturating_sub(1),
        ) {
            return Err(anyhow!(super::network_upgrade::MIGRATION_HOLD_MESSAGE));
        }
    }
    let target_height = zcash_protocol::consensus::BlockHeight::from_u32(target);
    // Keep the reviewed wallet identity pinned through the synchronous signing
    // and durable commit. A switch during the live-height request invalidates it.
    let identity = ENGINE.lock().await;
    let current = identity.as_ref().ok_or_else(|| anyhow!("Wallet closed"))?;
    if current.generation != generation
        || current.db_data_path != db_data_path
        || current.params != params
    {
        return Err(anyhow!("Wallet changed; review the migration again"));
    }

    // Borrow SQLite only after the final await. WalletMigration contains a
    // shared reference to the non-Sync connection and must never cross an
    // asynchronous FFI suspension point.
    let mut wallet_mig = WalletMigration::new(
        &db_data,
        account_id,
        usk.to_unified_full_viewing_key(),
        store,
    );
    let mut rng = zipher_rng_compat::OS_RNG;
    let state = mig_engine::commit_preparation(
        &params,
        target_height,
        &mut wallet_mig,
        usk.orchard(),
        &plan,
        &mut rng,
        ReplanThreshold::DEFAULT,
    )
    .map_err(|e| anyhow!("Commit failed: {}", e))?;

    info!("[Ironwood] Committed {} txs", state.transactions().len());
    build_report_from_plan(&state, &plan)
}

/// Advance the stable SDK's verified migration driver, broadcasting at most once.
pub async fn tick(seed_phrase: &secrecy::SecretString) -> Result<ProgressReport> {
    use secrecy::ExposeSecret;
    use zcash_pool_migration::{engine::ProveOutcome, state::AdvanceStep};

    let _operation = MIGRATION_OPERATION.lock().await;
    let (db_data_path, params, db_cipher_key, generation) = engine_params().await?;
    let server_url = engine_server_url().await?;
    let mut db_data = open_wallet_db(&db_data_path, params, &db_cipher_key)?;
    let account_id = first_account_id(&db_data)?;
    let mut store = PoolMigrations::for_account(
        params,
        SystemClock,
        open_store_conn(&db_data_path, &db_cipher_key)?,
        account_id,
    )
    .map_err(|e| anyhow!("Migration store: {e:?}"))?;
    let mut state = store
        .get_migration()
        .map_err(|e| anyhow!("Read migration: {e:?}"))?
        .ok_or_else(|| anyhow!("No transfer in progress"))?;
    let scanned_tip = db_data
        .block_fully_scanned()
        .map_err(|e| anyhow!("Read scanned height: {e:?}"))?
        .ok_or_else(|| anyhow!("Sync before advancing a transfer"))?
        .block_height();
    {
        let identity = ENGINE.lock().await;
        let current = identity.as_ref().ok_or_else(|| anyhow!("Wallet closed"))?;
        if current.generation != generation
            || current.db_data_path != db_data_path
            || current.params != params
        {
            return Err(anyhow!("Wallet changed; transfer was not advanced"));
        }
        let mut recovery = open_store_conn(&db_data_path, &db_cipher_key)?;
        if zcash_client_sqlite::pool_migration::orchard_ironwood::upgrade::stop_invalidated_migration(
            &mut recovery, &params, account_id,
        ).map_err(|e| anyhow!("Reconcile migration after network upgrade: {e}"))?.is_some() {
            let stopped = store.latest_migration().map_err(|e| anyhow!("Read stopped migration: {e}"))?
                .ok_or_else(|| anyhow!("Stopped migration receipt is unavailable"))?;
            let mut report = build_report(&stopped)?;
            report.status = "stopped_by_upgrade".into();
            return Ok(report);
        }
    }
    let live_tip = live_migration_tip(&params, generation)
        .await?
        .max(u32::from(scanned_tip));
    let targets = DuenessTargets::new(
        scanned_tip + 1,
        zcash_protocol::consensus::BlockHeight::from_u32(live_tip) + 1,
    );
    // This is a security depth, not a wall-clock duration. ZIP 318's privacy
    // delays and anchor/expiry grids are supplied by the spacing-aware SDK.
    let config = AdvanceConfig::new(
        ReorgSettleDepth::new(10),
        zcash_protocol::zip318::BlockSpacing::for_network(&params),
    );
    let usk = derive_usk(&params, seed_phrase.expose_secret())?;
    let ufvk = usk.to_unified_full_viewing_key();
    let fvk = orchard::keys::FullViewingKey::from(usk.orchard());

    let mut rng = zipher_rng_compat::OS_RNG;
    // A bounded session prevents retries of not-yet-provable work from spinning.
    for _ in 0..=state.transactions().len() {
        let advance = advance_migration(&mut store, &mut state, targets, &config, &mut rng)
            .map_err(|e| anyhow!("Advance migration: {e:?}"))?;
        // The SDK first reconciles every mined or ambiguously submitted part
        // against the scanned chain. Only then may an upgrade pause the rest;
        // never release inputs or rebuild from a server's missing tx response.
        if let Some(status) = migration_upgrade_status(&params, &state, live_tip)? {
            let mut report = build_report(&state)?;
            report.status = status.into();
            return Ok(report);
        }
        match advance.step() {
            AdvanceStep::Prove { transactions } => {
                let mut progressed = false;
                for target in transactions {
                    let mut prover = WalletMigrationProver::new(
                        &mut db_data,
                        zipher_rng_compat::OS_RNG,
                        account_id,
                        fvk.clone(),
                    );
                    let outcome = match target.kind() {
                        MigrationTxKind::Transfer { .. } => mig_engine::prove_transfer(
                            &params,
                            &mut prover,
                            &mut state,
                            target.id(),
                            scanned_tip,
                            &mut rng,
                        ),
                        MigrationTxKind::Preparation { .. } => mig_engine::prove_preparation(
                            &mut prover,
                            &mut state,
                            target.id(),
                            scanned_tip,
                        ),
                    }
                    .map_err(|e| anyhow!("Prove migration: {e}"))?;
                    match outcome {
                        ProveOutcome::Proved(proven) => {
                            store
                                .store_proved_transaction(&mut state, proven)
                                .map_err(|e| anyhow!("Store migration proof: {e:?}"))?;
                            progressed = true;
                        }
                        ProveOutcome::NotYetProvable => {
                            store
                                .replace_migration(&state)
                                .map_err(|e| anyhow!("Persist deferred proof: {e:?}"))?;
                        }
                        ProveOutcome::MarkedUnsatisfiable { .. } => {
                            store
                                .replace_migration(&state)
                                .map_err(|e| anyhow!("Persist migration state: {e:?}"))?;
                            progressed = true;
                        }
                    }
                }
                if !progressed {
                    break;
                }
            }
            AdvanceStep::Broadcast { id } => {
                // A wallet switch invalidates this session before any submission.
                let guard = ENGINE.lock().await;
                let current = guard.as_ref().ok_or_else(|| anyhow!("Wallet closed"))?;
                if current.generation != generation
                    || current.db_data_path != db_data_path
                    || current.params != params
                {
                    return Err(anyhow!("Wallet changed; transfer was not submitted"));
                }
                let transaction = store
                    .take_transaction_for_broadcast(&state, *id)
                    .map_err(|e| anyhow!("Prepare migration broadcast: {e:?}"))?;
                let mut raw = Vec::new();
                transaction.write(&mut raw)?;
                let tor = current.tor_transport()?;
                drop(guard);
                // The durable exact transaction already exists for ambiguity
                // recovery; recheck the session after proving before submission.
                tokio::time::timeout(
                    std::time::Duration::from_secs(60),
                    super::send::broadcast_for_generation(
                        &server_url,
                        &params,
                        raw,
                        tor,
                        generation,
                    ),
                )
                .await
                .map_err(|_| {
                    anyhow!(
                        "Broadcast timed out; the stored transaction will be reconciled after sync"
                    )
                })??;
                state.mark_broadcast(*id);
                store
                    .replace_migration(&state)
                    .map_err(|e| anyhow!("Persist broadcast: {e:?}"))?;
                break;
            }
            AdvanceStep::Rebuild { id } => {
                let rebuild_store = PoolMigrations::for_account(
                    params,
                    SystemClock,
                    open_store_conn(&db_data_path, &db_cipher_key)?,
                    account_id,
                )
                .map_err(|e| anyhow!("Migration store: {e:?}"))?;
                let wallet =
                    WalletMigration::new(&db_data, account_id, ufvk.clone(), rebuild_store);
                mig_engine::rebuild_expired_transfer(
                    &params,
                    &wallet,
                    usk.orchard(),
                    &mut state,
                    *id,
                    &mut rng,
                )
                .map_err(|e| anyhow!("Rebuild migration: {e}"))?;
                store
                    .replace_migration(&state)
                    .map_err(|e| anyhow!("Persist rebuilt migration: {e:?}"))?;
            }
            AdvanceStep::Replan => {
                return Err(anyhow!(
                    "Transfer needs a new plan. Review the remaining balance before restarting."
                ));
            }
            AdvanceStep::Reevaluate | AdvanceStep::Waiting | AdvanceStep::Complete => break,
        }
    }
    build_report(&state)
}

/// Read the most recent SDK record, including terminal history. No network calls.
pub async fn status() -> Result<ProgressReport> {
    let (path, params, key, _generation) = engine_params().await?;
    let db = open_wallet_db(&path, params, &key)?;
    let store = PoolMigrations::for_account(
        params,
        SystemClock,
        open_store_conn(&path, &key)?,
        first_account_id(&db)?,
    )
    .map_err(|e| anyhow!("Migration store: {e:?}"))?;
    match store
        .latest_migration()
        .map_err(|e| anyhow!("Read migration: {e:?}"))?
    {
        Some(state) => {
            let mut report = build_report(&state)?;
            let conn = open_store_conn(&path, &key)?;
            if zcash_client_sqlite::pool_migration::orchard_ironwood::upgrade::latest_upgrade_stop(
                &conn,
                first_account_id(&db)?,
            )
            .map_err(|e| anyhow!("Read migration upgrade receipt: {e}"))?
            .is_some()
            {
                report.status = "stopped_by_upgrade".into();
                return Ok(report);
            }
            if let Some(tip) = db
                .chain_height()
                .map_err(|e| anyhow!("Read migration status height: {e:?}"))?
            {
                if let Some(status) = migration_upgrade_status(&params, &state, u32::from(tip))? {
                    report.status = status.into();
                }
            }
            Ok(report)
        }
        None => Ok(ProgressReport {
            status: "idle".into(),
            crossing_values: vec![],
            total_planned_zat: 0,
            total_confirmed_zat: 0,
            broadcast_count: 0,
            confirmed_count: 0,
            total_tx_count: 0,
            next_due_height: 0,
            fees_paid_zat: 0,
        }),
    }
}

/// Cancel through the SDK: release reservations atomically and retain history.
/// Transactions already submitted can still be mined.
pub async fn cancel() -> Result<()> {
    let _operation = MIGRATION_OPERATION.lock().await;
    let (path, params, key, generation) = engine_params().await?;
    let identity = ENGINE.lock().await;
    let current = identity.as_ref().ok_or_else(|| anyhow!("Wallet closed"))?;
    if current.generation != generation || current.db_data_path != path || current.params != params
    {
        return Err(anyhow!("Wallet changed; review the cancellation again"));
    }
    let db = open_wallet_db(&path, params, &key)?;
    let mut store = PoolMigrations::for_account(
        params,
        SystemClock,
        open_store_conn(&path, &key)?,
        first_account_id(&db)?,
    )
    .map_err(|e| anyhow!("Migration store: {e:?}"))?;
    store
        .cancel_migration()
        .map_err(|e| anyhow!("Cancel migration: {e:?}"))?;
    Ok(())
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

use std::path::PathBuf;
use zcash_protocol::consensus::Network;

async fn engine_params() -> Result<(PathBuf, Network, Option<String>, u64)> {
    let guard = ENGINE.lock().await;
    let e = guard
        .as_ref()
        .ok_or_else(|| anyhow!("Engine not initialized"))?;
    Ok((
        e.db_data_path.clone(),
        e.params,
        e.db_cipher_key.clone(),
        e.generation,
    ))
}

async fn engine_server_url() -> Result<String> {
    let guard = ENGINE.lock().await;
    let e = guard
        .as_ref()
        .ok_or_else(|| anyhow!("Engine not initialized"))?;
    Ok(e.server_url.clone())
}

async fn live_migration_tip(params: &Network, generation: u64) -> Result<u32> {
    let (server_url, tor) = {
        let guard = ENGINE.lock().await;
        let engine = guard.as_ref().ok_or_else(|| anyhow!("Wallet closed"))?;
        if engine.generation != generation || engine.params != *params {
            return Err(anyhow!(
                "Wallet network changed; review the migration again"
            ));
        }
        (engine.server_url.clone(), engine.tor_transport()?)
    };
    let mut client = match tor {
        Some(client) => super::wallet::connect_lwd_tor(&client, &server_url).await?,
        None => super::wallet::connect_lwd(&server_url).await?,
    };
    super::network_upgrade::endpoint_tip(&mut client, params).await
}

/// Existing signatures are retained as evidence and may already have mined.
/// A policy pause never frees them or substitutes a newly signed transaction.
fn migration_upgrade_status(
    params: &Network,
    state: &SdkMigrationState,
    tip: u32,
) -> Result<Option<&'static str>> {
    if state.is_terminal() {
        return Ok(None);
    }
    let mut parts = Vec::new();
    for tx in state.transactions() {
        if matches!(tx.state(), MigrationTxState::Mined { .. }) {
            continue;
        }
        let pczt = pczt::Pczt::parse(tx.pczt())
            .map_err(|e| anyhow!("Read migration's signed consensus branch: {e:?}"))?;
        let branch =
            zcash_protocol::consensus::BranchId::try_from(*pczt.global().consensus_branch_id())
                .map_err(|e| anyhow!("Unsupported migration consensus branch: {e}"))?;
        parts.push(branch);
    }
    Ok(migration_parts_upgrade_status(params, &parts, tip))
}

fn migration_parts_upgrade_status<P: zcash_protocol::consensus::Parameters>(
    params: &P,
    unmined_branches: &[zcash_protocol::consensus::BranchId],
    tip: u32,
) -> Option<&'static str> {
    let target = tip.saturating_add(1);
    let current = super::network_upgrade::branch_at(params, target);
    let mut held = false;
    for branch in unmined_branches {
        if *branch != current
            && branch
                .height_bounds(params)
                .and_then(|(_, end)| end)
                .is_some_and(|end| u32::from(end) <= target)
        {
            return Some("upgrade_review_required");
        }
        held |= super::network_upgrade::migration_held(params, *branch, tip);
    }
    held.then_some("paused_by_upgrade")
}

type DbType = zcash_client_sqlite::WalletDb<
    rusqlite::Connection,
    Network,
    zcash_client_sqlite::util::SystemClock,
    rand::rngs::OsRng,
>;

fn open_store_conn(path: &PathBuf, key: &Option<String>) -> Result<rusqlite::Connection> {
    super::open_cipher_conn(path, key)
}
fn first_account_id(db: &DbType) -> Result<zcash_client_sqlite::AccountUuid> {
    db.get_account_ids()
        .map_err(|e| anyhow!("{:?}", e))?
        .into_iter()
        .next()
        .ok_or_else(|| anyhow!("No accounts"))
}

fn derive_usk(params: &Network, phrase: &str) -> Result<UnifiedSpendingKey> {
    let mnemonic = bip0039::Mnemonic::<bip0039::English>::from_phrase(phrase)
        .map_err(|_| anyhow!("Invalid seed phrase"))?;
    let seed = zeroize::Zeroizing::new(mnemonic.to_seed(""));
    let usk = UnifiedSpendingKey::from_seed(params, seed.as_ref(), zip32::AccountId::ZERO)
        .map_err(|e| anyhow!("USK: {:?}", e))?;
    Ok(usk)
}

fn build_report_from_plan(
    state: &SdkMigrationState,
    plan: &MigrationPlan,
) -> Result<ProgressReport> {
    let crossing_values: Vec<u64> = plan
        .crossing_values()
        .iter()
        .map(|z| u64::from(*z))
        .collect();
    let total_planned: u64 = crossing_values.iter().sum();
    let (bc, cc, fees, tc) = tally(state);
    let next = next_due_height(state);

    Ok(ProgressReport {
        status: status_str(state.status()),
        crossing_values,
        total_planned_zat: total_planned,
        total_confirmed_zat: tc,
        broadcast_count: bc,
        confirmed_count: cc,
        total_tx_count: state.transactions().len() as u32,
        next_due_height: next,
        fees_paid_zat: fees,
    })
}

fn build_report(state: &SdkMigrationState) -> Result<ProgressReport> {
    let crossing_values: Vec<u64> = state
        .crossing_values()
        .iter()
        .map(|z| u64::from(*z))
        .collect();
    let total_planned: u64 = crossing_values.iter().sum();
    let (bc, cc, fees, tc) = tally(state);
    let next = next_due_height(state);

    Ok(ProgressReport {
        status: status_str(state.status()),
        crossing_values,
        total_planned_zat: total_planned,
        total_confirmed_zat: tc,
        broadcast_count: bc,
        confirmed_count: cc,
        total_tx_count: state.transactions().len() as u32,
        next_due_height: next,
        fees_paid_zat: fees,
    })
}

fn status_str(s: MigrationStatus) -> String {
    match s {
        MigrationStatus::Planning => "planning".into(),
        MigrationStatus::Committed => "committed".into(),
        MigrationStatus::InProgress => "in_progress".into(),
        MigrationStatus::Complete => "complete".into(),
        MigrationStatus::Failed => "failed".into(),
        MigrationStatus::Superseded => "superseded".into(),
        MigrationStatus::Cancelled => "cancelled".into(),
    }
}

fn next_due_height(state: &SdkMigrationState) -> u32 {
    state
        .transactions()
        .iter()
        .filter(|tx| {
            matches!(
                tx.state(),
                MigrationTxState::Signed | MigrationTxState::Proved
            )
        })
        .map(|tx| u32::from(tx.scheduled_height()))
        .min()
        .unwrap_or(0)
}

fn tally(state: &SdkMigrationState) -> (u32, u32, u64, u64) {
    let mut broadcast = 0u32;
    let mut confirmed = 0u32;
    let mut fees = 0u64;
    let mut confirmed_zat = 0u64;

    for tx in state.transactions() {
        match tx.state() {
            MigrationTxState::Broadcast { .. } => broadcast += 1,
            MigrationTxState::Mined { .. } => {
                confirmed += 1;
                fees += migration_fee(tx.kind());
                if let MigrationTxKind::Transfer { crossing } = tx.kind() {
                    if let Some(val) = state.crossing_values().get(crossing) {
                        confirmed_zat += u64::from(*val);
                    }
                }
            }
            _ => {}
        }
    }
    (broadcast, confirmed, fees, confirmed_zat)
}

// ZIP 318 requires canonical fees for these fixed transaction shapes. Count
// only mined transactions; pending submissions have not yet paid a chain fee.
fn migration_fee(kind: MigrationTxKind) -> u64 {
    use zcash_protocol::zip318::{
        CROSSING_DESTINATION_ACTIONS, CROSSING_SOURCE_ACTIONS, PREP_TX_ACTIONS,
    };
    let actions = match kind {
        MigrationTxKind::Preparation { .. } => PREP_TX_ACTIONS,
        MigrationTxKind::Transfer { .. } => CROSSING_SOURCE_ACTIONS + CROSSING_DESTINATION_ACTIONS,
    };
    actions as u64 * zcash_primitives::transaction::fees::zip317::MARGINAL_FEE.into_u64()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn migration_bridge_futures_can_run_on_the_ffi_executor() {
        fn assert_send<T: Send>(_: T) {}
        // Construct futures without polling: no key access, database or network.
        let seed = secrecy::SecretString::new(String::new());
        assert_send(plan(&seed));
        assert_send(commit(&seed));
        assert_send(tick(&seed));
        assert_send(status());
        assert_send(cancel());
    }

    #[test]
    fn an_interrupted_migration_pauses_without_reclassifying_mined_steps() {
        use zcash_protocol::consensus::{BlockHeight, BranchId, NetworkUpgrade, Parameters};
        let params = Network::TestNetwork;
        let a = u32::from(params.activation_height(NetworkUpgrade::Nu7).unwrap());
        let old = BranchId::for_height(&params, BlockHeight::from_u32(a - 1));
        let new = BranchId::for_height(&params, BlockHeight::from_u32(a));
        assert_eq!(
            migration_parts_upgrade_status(&params, &[old], a - 12),
            None
        );
        assert_eq!(
            migration_parts_upgrade_status(&params, &[old], a - 11),
            Some("paused_by_upgrade")
        );
        assert_eq!(
            migration_parts_upgrade_status(&params, &[old], a - 1),
            Some("upgrade_review_required")
        );
        assert_eq!(
            migration_parts_upgrade_status(&params, &[old], a),
            Some("upgrade_review_required")
        );
        assert_eq!(migration_parts_upgrade_status(&params, &[new], a), None);
        // Mined parts are excluded before this policy is called: no remaining
        // signatures means an upgrade cannot turn a complete run into a pause.
        assert_eq!(migration_parts_upgrade_status(&params, &[], a), None);
    }

    #[test]
    fn reports_canonical_preparation_and_crossing_fees() {
        assert_eq!(
            migration_fee(MigrationTxKind::Preparation { layer: 0, index: 0 }),
            80_000
        );
        assert_eq!(
            migration_fee(MigrationTxKind::Transfer { crossing: 0 }),
            15_000
        );
    }
}
