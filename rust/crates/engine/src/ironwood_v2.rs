//! Official SDK-based Ironwood pool transfer using `zcash_pool_migration`.
//!
//! Uses the canonical librustzcash crate for ZIP 318 denomination decomposition,
//! preparation transaction building, PCZT signing, scheduled proving, and broadcast.

use anyhow::{anyhow, Result};
use rand::rngs::OsRng;
use tracing::info;

use zcash_client_backend::data_api::WalletRead;
use zcash_client_sqlite::pool_migration::orchard_ironwood::PoolMigrations;
use zcash_keys::keys::UnifiedSpendingKey;
use zcash_pool_migration::engine::{
    self as mig_engine, MigrationPlan, MigrationState as SdkMigrationState,
    MigrationStatus, MigrationTxKind, MigrationTxState,
    PoolMigrationRead, PoolMigrationWrite,
};
use zcash_pool_migration::wallet::{WalletMigration, WalletMigrationProver};


use super::{open_wallet_db, ENGINE};

// ---------------------------------------------------------------------------
// Public result types for FFI
// ---------------------------------------------------------------------------

/// Summary of the planned denomination decomposition for user consent.
#[derive(Debug, Clone)]
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
#[derive(Debug, Clone)]
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
    use secrecy::ExposeSecret;

    let (db_data_path, params, db_cipher_key) = engine_params().await?;
    let db_data = open_wallet_db(&db_data_path, params, &db_cipher_key)?;

    let account_id = first_account_id(&db_data)?;

    let usk = derive_usk(&params, seed_phrase.expose_secret())?;

    let store = PoolMigrations::for_account(open_store_conn(&db_data_path, &db_cipher_key)?, account_id)
        .map_err(|e| anyhow!("Store: {:?}", e))?;

    let wallet_mig = WalletMigration::new(&db_data, account_id, usk, store);

    let plan = mig_engine::plan_migration(&params, &wallet_mig, &mut OsRng)
        .map_err(|e| anyhow!("Plan failed: {}", e))?;

    let crossing_values: Vec<u64> = plan.crossing_values().iter().map(|z| u64::from(*z)).collect();
    let total_migrating: u64 = crossing_values.iter().sum();
    let estimated_total_fee = 15_000u64 * plan.total_transactions() as u64;

    Ok(PlanSummary {
        crossing_values,
        total_migrating_zat: total_migrating,
        estimated_total_fee_zat: estimated_total_fee,
        prep_tx_count: plan.preparation_tx_count(),
        transfer_tx_count: plan.transfer_tx_count(),
        total_tx_count: plan.total_transactions(),
        prep_layers: plan.preparation_layer_count(),
    })
}

/// Commit: plan + build + sign all PCZTs in one pass. Durable in the wallet DB.
pub async fn commit(seed_phrase: &secrecy::SecretString) -> Result<ProgressReport> {
    use secrecy::ExposeSecret;

    let (db_data_path, params, db_cipher_key) = engine_params().await?;
    let db_data = open_wallet_db(&db_data_path, params, &db_cipher_key)?;

    let account_id = first_account_id(&db_data)?;
    let usk = derive_usk(&params, seed_phrase.expose_secret())?;

    let store = PoolMigrations::for_account(open_store_conn(&db_data_path, &db_cipher_key)?, account_id)
        .map_err(|e| anyhow!("Store: {:?}", e))?;

    let mut wallet_mig = WalletMigration::new(&db_data, account_id, usk, store);

    let plan = mig_engine::plan_migration(&params, &wallet_mig, &mut OsRng)
        .map_err(|e| anyhow!("Plan failed: {}", e))?;

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
        &plan,
        &mut OsRng,
    )
    .map_err(|e| anyhow!("Commit failed: {}", e))?;

    info!("[Ironwood] Committed {} txs", state.transactions().len());
    build_report_from_plan(&state, &plan)
}

/// Tick: prove and broadcast the next due transaction. Call periodically.
pub async fn tick(seed_phrase: &secrecy::SecretString) -> Result<ProgressReport> {
    use secrecy::ExposeSecret;

    let (db_data_path, params, db_cipher_key) = engine_params().await?;
    let server_url = engine_server_url().await?;
    let mut db_data = open_wallet_db(&db_data_path, params, &db_cipher_key)?;

    let account_id = first_account_id(&db_data)?;

    let store = PoolMigrations::for_account(open_store_conn(&db_data_path, &db_cipher_key)?, account_id)
        .map_err(|e| anyhow!("Store: {:?}", e))?;

    let mut state = store
        .get_migration()
        .map_err(|e| anyhow!("{:?}", e))?
        .ok_or_else(|| anyhow!("No transfer in progress"))?;

    let chain_tip = db_data
        .chain_height()
        .map_err(|e| anyhow!("{:?}", e))?
        .ok_or_else(|| anyhow!("No chain data"))?;

    // Find next Signed tx whose scheduled height has been reached
    let next_due = state.transactions().iter().find(|tx| {
        matches!(tx.state(), MigrationTxState::Signed) && tx.scheduled_height() <= chain_tip
    });

    let Some(due_tx) = next_due else {
        info!("[Ironwood] tick: nothing due at h={}", u32::from(chain_tip));
        return build_report(&state);
    };

    let tx_id = due_tx.id();
    let tx_kind = due_tx.kind();

    info!("[Ironwood] Proving {:?} ({:?})", tx_id, tx_kind);

    let usk = derive_usk(&params, seed_phrase.expose_secret())?;
    let fvk = orchard::keys::FullViewingKey::from(usk.orchard());

    // Prove (mutates state: Signed -> Proved, updates stored PCZT with proven bytes)
    let mut prover = WalletMigrationProver::new(&mut db_data, account_id, fvk);
    match tx_kind {
        MigrationTxKind::Transfer { .. } => {
            mig_engine::prove_transfer(&mut prover, &mut state, tx_id)
                .map_err(|e| anyhow!("Prove transfer: {}", e))?;
        }
        MigrationTxKind::Preparation { .. } => {
            mig_engine::prove_preparation(&mut prover, &mut state, tx_id, chain_tip)
                .map_err(|e| anyhow!("Prove prep: {}", e))?;
        }
    }

    // Extract proven PCZT -> transaction bytes -> broadcast
    let proved_tx = state.transactions().iter().find(|t| t.id() == tx_id)
        .ok_or_else(|| anyhow!("Tx lost after proving"))?;

    let pczt = pczt::Pczt::parse(proved_tx.pczt())
        .map_err(|e| anyhow!("Parse proven PCZT: {:?}", e))?;
    let transaction = pczt::roles::tx_extractor::TransactionExtractor::new(pczt)
        .extract()
        .map_err(|e| anyhow!("Extract tx: {:?}", e))?;

    let mut raw_bytes = Vec::new();
    transaction.write(&mut raw_bytes)
        .map_err(|e| anyhow!("Serialize tx: {:?}", e))?;

    super::send::broadcast_multi(&server_url, &params, raw_bytes).await?;

    let txid = transaction.txid();
    info!("[Ironwood] Broadcast OK: {}", txid);

    // Mark broadcast in store
    let mut store_w = PoolMigrations::for_account(open_store_conn(&db_data_path, &db_cipher_key)?, account_id)
        .map_err(|e| anyhow!("Store: {:?}", e))?;
    store_w
        .update_transaction(tx_id, MigrationTxState::Broadcast { txid })
        .map_err(|e| anyhow!("Update state: {:?}", e))?;

    let fresh = store_w.get_migration().map_err(|e| anyhow!("{:?}", e))?
        .ok_or_else(|| anyhow!("Gone"))?;
    build_report(&fresh)
}

/// Read-only status check.
pub async fn status() -> Result<ProgressReport> {
    let (db_data_path, params, db_cipher_key) = engine_params().await?;
    let db_data = open_wallet_db(&db_data_path, params, &db_cipher_key)?;
    let account_id = first_account_id(&db_data)?;

    let store = PoolMigrations::for_account(open_store_conn(&db_data_path, &db_cipher_key)?, account_id)
        .map_err(|e| anyhow!("Store: {:?}", e))?;

    match store.get_migration().map_err(|e| anyhow!("{:?}", e))? {
        Some(s) => build_report(&s),
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

/// Cancel in-progress transfer (removes stored rows).
pub async fn cancel() -> Result<()> {
    let (db_data_path, _params, db_cipher_key) = engine_params().await?;

    open_store_conn(&db_data_path, &db_cipher_key)?.execute_batch(
        "DELETE FROM orchard_ironwood_migrations;"
    ).map_err(|e| anyhow!("Cancel: {:?}", e))?;

    info!("[Ironwood] Cancelled.");
    Ok(())
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

use zcash_protocol::consensus::Network;
use std::path::PathBuf;

async fn engine_params() -> Result<(PathBuf, Network, Option<String>)> {
    let guard = ENGINE.lock().await;
    let e = guard.as_ref().ok_or_else(|| anyhow!("Engine not initialized"))?;
    Ok((e.db_data_path.clone(), e.params, e.db_cipher_key.clone()))
}

async fn engine_server_url() -> Result<String> {
    let guard = ENGINE.lock().await;
    let e = guard.as_ref().ok_or_else(|| anyhow!("Engine not initialized"))?;
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
        .map_err(|e| anyhow!("Bad seed: {:?}", e))?;
    let mut seed = mnemonic.to_seed("");
    let usk = UnifiedSpendingKey::from_seed(params, &seed, zip32::AccountId::ZERO)
        .map_err(|e| anyhow!("USK: {:?}", e))?;
    seed.iter_mut().for_each(|b| *b = 0);
    Ok(usk)
}

fn build_report_from_plan(state: &SdkMigrationState, plan: &MigrationPlan) -> Result<ProgressReport> {
    let crossing_values: Vec<u64> = plan.crossing_values().iter().map(|z| u64::from(*z)).collect();
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
    let crossing_values: Vec<u64> = state.funding_notes().iter().map(|z| u64::from(*z)).collect();
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
    }
}

fn next_due_height(state: &SdkMigrationState) -> u32 {
    state.transactions().iter()
        .filter(|tx| matches!(tx.state(), MigrationTxState::Signed))
        .map(|tx| u32::from(tx.scheduled_height()))
        .min()
        .unwrap_or(0)
}

fn tally(state: &SdkMigrationState) -> (u32, u32, u64, u64) {
    let mut broadcast = 0u32;
    let mut confirmed = 0u32;
    let fees = 0u64;
    let mut confirmed_zat = 0u64;

    for tx in state.transactions() {
        match tx.state() {
            MigrationTxState::Broadcast { .. } => broadcast += 1,
            MigrationTxState::Mined { .. } => {
                confirmed += 1;
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
