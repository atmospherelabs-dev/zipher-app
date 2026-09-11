//! Official SDK-based Ironwood pool transfer using `zcash_pool_migration`.
//!
//! Uses the canonical librustzcash crate for ZIP 318 denomination decomposition,
//! preparation transaction building, PCZT signing, scheduled proving, and broadcast.

use anyhow::{anyhow, Result};
use rand::rngs::OsRng;
use tracing::info;

use zcash_client_backend::data_api::WalletRead;
use zcash_client_sqlite::{pool_migration::orchard_ironwood::PoolMigrations, util::SystemClock};
use zcash_pool_migration::satisfiability::{
    advance_migration, AdvanceConfig, DuenessTargets, ReorgSettleDepth, ReplanThreshold,
};

// Serialize migration mutation across UI, CLI and service calls in this process.
static REVIEWED_PLAN: std::sync::Mutex<Option<(std::path::PathBuf, std::time::Instant, MigrationPlan)>> = std::sync::Mutex::new(None);
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
    *REVIEWED_PLAN.lock().unwrap() = None;
    use secrecy::ExposeSecret;

    let (db_data_path, params, db_cipher_key) = engine_params().await?;
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

    let wallet_mig = WalletMigration::new(
        &db_data,
        account_id,
        usk.to_unified_full_viewing_key(),
        store,
    );

    let plan = mig_engine::plan_migration(&params, &wallet_mig, &mut OsRng)
        .map_err(|e| anyhow!("Plan failed: {}", e))?;

    let crossing_values: Vec<u64> = plan
        .crossing_values()
        .iter()
        .map(|z| u64::from(*z))
        .collect();
    let total_migrating: u64 = crossing_values.iter().sum();
    let estimated_total_fee =
        u64::from(plan.total_actions()) * zcash_primitives::transaction::fees::zip317::MARGINAL_FEE.into_u64();

    let summary = PlanSummary {
        crossing_values,
        total_migrating_zat: total_migrating,
        estimated_total_fee_zat: estimated_total_fee,
        prep_tx_count: plan.preparation_tx_count(),
        transfer_tx_count: plan.transfer_tx_count(),
        total_tx_count: plan.total_transactions(),
        prep_layers: plan.preparation_layer_count(),
    };
    *REVIEWED_PLAN.lock().unwrap() = Some((db_data_path.into(), std::time::Instant::now(), plan));
    Ok(summary)
}

/// Commit: plan + build + sign all PCZTs in one pass. Durable in the wallet DB.
pub async fn commit(seed_phrase: &secrecy::SecretString) -> Result<ProgressReport> {
    let _operation = MIGRATION_OPERATION.lock().await;
    use secrecy::ExposeSecret;

    let (db_data_path, params, db_cipher_key) = engine_params().await?;
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

    let mut wallet_mig = WalletMigration::new(
        &db_data,
        account_id,
        usk.to_unified_full_viewing_key(),
        store,
    );

    let (reviewed_path, reviewed_at, plan) = REVIEWED_PLAN.lock().unwrap().take()
        .ok_or_else(|| anyhow!("Review a migration plan before committing"))?;
    if reviewed_path != std::path::PathBuf::from(&db_data_path)
        || reviewed_at.elapsed() > std::time::Duration::from_secs(600) {
        return Err(anyhow!("Wallet changed or migration review expired; review again"));
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
    let target_height = chain_tip + 1;

    let state = mig_engine::commit_preparation(
        &params,
        target_height,
        &mut wallet_mig,
        usk.orchard(),
        &plan,
        &mut OsRng,
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
    let (db_data_path, params, db_cipher_key) = engine_params().await?;
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
    let targets = DuenessTargets::new(scanned_tip + 1, scanned_tip + 1);
    // Ten blocks is about 12.5 minutes at the current 75-second block spacing.
    let config = AdvanceConfig::new(ReorgSettleDepth::new(10));
    let usk = derive_usk(&params, seed_phrase.expose_secret())?;
    let ufvk = usk.to_unified_full_viewing_key();
    let fvk = orchard::keys::FullViewingKey::from(usk.orchard());

    // A bounded session prevents retries of not-yet-provable work from spinning.
    for _ in 0..=state.transactions().len() {
        let advance = advance_migration(&mut store, &mut state, targets, &config, &mut OsRng)
            .map_err(|e| anyhow!("Advance migration: {e:?}"))?;
        match advance.step() {
            AdvanceStep::Prove { transactions } => {
                let mut progressed = false;
                for target in transactions {
                    let mut prover =
                        WalletMigrationProver::new(&mut db_data, account_id, fvk.clone());
                    let outcome = match target.kind() {
                        MigrationTxKind::Transfer { .. } => mig_engine::prove_transfer(
                            &params,
                            &mut prover,
                            &mut state,
                            target.id(),
                            scanned_tip,
                            &mut OsRng,
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
                if current.db_data_path != db_data_path || current.params != params {
                    return Err(anyhow!("Wallet changed; transfer was not submitted"));
                }
                let transaction = store
                    .take_transaction_for_broadcast(&state, *id)
                    .map_err(|e| anyhow!("Prepare migration broadcast: {e:?}"))?;
                let mut raw = Vec::new();
                transaction.write(&mut raw)?;
                // Keep the engine identity pinned until the attempt completes. The SDK
                // already recorded this exact transaction for recovery after ambiguity.
                tokio::time::timeout(
                    std::time::Duration::from_secs(60),
                    super::send::broadcast_with_transport(
                        &server_url,
                        &params,
                        raw,
                        current.tor_transport()?,
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
                drop(guard);
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
                    &mut OsRng,
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
    let (path, params, key) = engine_params().await?;
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
        Some(state) => build_report(&state),
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
    let (path, params, key) = engine_params().await?;
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

async fn engine_params() -> Result<(PathBuf, Network, Option<String>)> {
    let guard = ENGINE.lock().await;
    let e = guard
        .as_ref()
        .ok_or_else(|| anyhow!("Engine not initialized"))?;
    Ok((e.db_data_path.clone(), e.params, e.db_cipher_key.clone()))
}

async fn engine_server_url() -> Result<String> {
    let guard = ENGINE.lock().await;
    let e = guard
        .as_ref()
        .ok_or_else(|| anyhow!("Engine not initialized"))?;
    Ok(e.server_url.clone())
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
