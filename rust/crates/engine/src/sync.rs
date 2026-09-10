use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::time::{Duration, Instant};

use anyhow::Result;
use rusqlite::OptionalExtension;
use tokio::sync::{broadcast, mpsc, Mutex as TokioMutex};

use zcash_client_backend::data_api::chain::{
    error::Error as ChainError, scan_cached_blocks, CommitmentTreeRoot,
};
use zcash_client_backend::data_api::scanning::ScanPriority;
use zcash_client_backend::data_api::wallet::{decrypt_and_store_transaction, ConfirmationsPolicy};
use zcash_client_backend::data_api::{
    TransactionDataRequest, TransactionStatus, TransactionsInvolvingAddress, WalletCommitmentTrees,
    WalletRead, WalletWrite,
};
use zcash_client_backend::proto::compact_formats::CompactBlock;
use zcash_client_backend::proto::service::{
    compact_tx_streamer_client::CompactTxStreamerClient, BlockId, BlockRange, ChainSpec, Empty,
    GetAddressUtxosArg, GetSubtreeRootsArg, ShieldedProtocol, TransparentAddressBlockFilter,
    TxFilter,
};
use zcash_client_backend::wallet::WalletTransparentOutput;
use zcash_client_sqlite::error::SqliteClientError;
use zcash_client_sqlite::WalletDb;
use zcash_primitives::transaction::{Transaction, TxId};
use zcash_protocol::consensus::{BlockHeight, Network};
use zcash_protocol::consensus::{BranchId, NetworkUpgrade, Parameters};
use zcash_protocol::value::Zatoshis;
use zcash_transparent::address::Script;
use zcash_transparent::bundle::{OutPoint, TxOut};

use zcash_primitives::merkle_tree::HashSer;

mod block_source;
use block_source::MemoryBlockSource;

use super::pending;
use super::wallet::{connect_lwd, connect_lwd_tor};
use super::{open_cipher_conn, open_wallet_db, ENGINE};

/// Connect to a lightwalletd server, routing through Tor if enabled.
async fn connect_lwd_maybe_tor(
    server_url: &str,
) -> Result<CompactTxStreamerClient<tonic::transport::Channel>> {
    let tor = {
        let guard = ENGINE.lock().await;
        guard.as_ref().map(|e| e.tor_transport()).transpose()?.flatten()
    };
    if let Some(ref client) = tor {
        connect_lwd_tor(client, server_url).await
    } else {
        connect_lwd(server_url).await
    }
}

// ---------------------------------------------------------------------------
// Sync state
// ---------------------------------------------------------------------------

static SYNC_RUNNING: AtomicBool = AtomicBool::new(false);
static SYNC_CANCEL: AtomicBool = AtomicBool::new(false);
// Survives reconnect passes; reset only when a wallet starts a new sync session.
static DOWNLOAD_BATCH_LIMIT: AtomicU32 = AtomicU32::new(u32::MAX);
static SYNC_PASS_COUNTER: AtomicU32 = AtomicU32::new(0);

// Stuck-reorg detection: if we see the same continuity error at the same
// height repeatedly across passes without making any committed progress,
// the wallet has a reorg that the SDK won't let us rewind past (typically
// because there are spendable notes at the affected height). Bail out of
// the auto-restart loop so the wallet doesn't burn battery, and surface a
// clear log telling the user to use "Recover Transactions".
const STUCK_REORG_THRESHOLD: u32 = 3;
static STUCK_REORG_HEIGHT: AtomicU32 = AtomicU32::new(0);
static STUCK_REORG_COUNT: AtomicU32 = AtomicU32::new(0);

lazy_static::lazy_static! {
    static ref SYNC_TASKS: TokioMutex<Option<SyncTasks>> = TokioMutex::new(None);

    static ref SYNC_PROGRESS: TokioMutex<SyncProgressInfo> =
        TokioMutex::new(SyncProgressInfo::default());

    static ref SYNC_RUNTIME_CONFIG: TokioMutex<SyncRuntimeConfig> =
        TokioMutex::new(SyncRuntimeConfig::default());

    static ref SYNC_PERF: TokioMutex<SyncPerfSnapshot> =
        TokioMutex::new(SyncPerfSnapshot::default());

    static ref INACTIVE_WALLETS: TokioMutex<Vec<InactiveWallet>> =
        TokioMutex::new(Vec::new());

    static ref SYNC_EVENTS: broadcast::Sender<SyncEventInfo> = {
        // 4096 keeps headroom for verbose diagnostic logs without dropping
        // events when the Dart consumer is briefly slow.
        let (tx, _) = broadcast::channel(4096);
        tx
    };
}

#[derive(Default, Clone, Debug, serde::Serialize)]
pub struct SyncProgressInfo {
    pub synced_height: u32,
    pub latest_height: u32,
    pub is_syncing: bool,
    pub connection_error: Option<String>,
    pub maintenance_error: Option<String>,
    pub phase: String,
    pub scanning_up_to: u32,
    pub adaptive_batch_size: u32,
    pub maintenance_queue_len: u32,
    /// Scan progress as numerator/denominator (notes scanned / total notes).
    /// 0..100 percentage can be computed as `scan_progress_num * 100 / scan_progress_den`
    /// (use checked division -- den may be 0).
    pub scan_progress_num: u64,
    pub scan_progress_den: u64,
    pub recovery_progress_num: u64,
    pub recovery_progress_den: u64,
    /// Blocks scanned in this sync session, summed across every priority
    /// (ChainTip, Historic, FoundNote, Verify). Drives the user-facing
    /// progress bar so it advances smoothly during ChainTip-first scanning,
    /// before `synced_height` (the fully-scanned committed height) catches up.
    pub blocks_scanned: u64,
    /// Total blocks to scan in this sync session. Recomputed at the start
    /// of each pass as `blocks_scanned + sum(remaining_ranges.len())`, so
    /// it stays correct when librustzcash adds new ranges mid-sync
    /// (e.g. FoundNote ranges after pass 1).
    pub blocks_total: u64,
}

#[derive(Clone, Debug)]
pub struct SyncRuntimeConfig {
    /// How many completed batches may wait ahead of the scanner. Additional
    /// lookahead trades memory for latency hiding; explicit values are capped at 8.
    pub prefetch_depth: usize,
    /// Optional lightwalletd peers. Automatic selection keeps them for failover;
    /// explicitly configured multi-server downloads rotate through them.
    pub alternate_servers: Vec<String>,
    /// Use known fallback peers without rotating healthy downloads across regions.
    pub auto_select_servers: bool,
}

impl Default for SyncRuntimeConfig {
    fn default() -> Self {
        Self {
            prefetch_depth: 3,
            alternate_servers: Vec::new(),
            auto_select_servers: true,
        }
    }
}

/// Known fallback peers for public-server users. Custom/self-hosted server
/// selections never silently add third-party peers.
pub fn known_lightwalletd_servers(params: &Network) -> Vec<String> {
    match params {
        Network::MainNetwork => vec![
            "https://lightwalletd.mainnet.cipherscan.app:443".to_string(),
            "https://zec.rocks:443".to_string(),
            "https://na.zec.rocks:443".to_string(),
            "https://sa.zec.rocks:443".to_string(),
            "https://eu.zec.rocks:443".to_string(),
            "https://ap.zec.rocks:443".to_string(),
        ],
        Network::TestNetwork => {
            vec!["https://testnet.zec.rocks:443".to_string()]
        }
    }
}

/// Build the default alternate-server list for a given primary. Returns an
/// empty list if the primary is not one of our known servers (we don't
/// silently steer custom-server users toward third-party nodes).
fn default_alternate_servers(params: &Network, primary: &str) -> Vec<String> {
    let known = known_lightwalletd_servers(params);
    if !known.iter().any(|s| s == primary) {
        return Vec::new();
    }
    known.into_iter().filter(|s| s != primary).collect()
}

#[derive(Default, Clone, Debug, serde::Serialize)]
pub struct SyncPerfSnapshot {
    pub batches: u64,
    pub blocks: u64,
    pub work_units: u64,
    pub download_ms: u64,
    pub scan_ms: u64,
    pub restarted_batches: u64,
    pub avg_download_ms: u64,
    pub avg_scan_ms: u64,
    pub work_units_per_second: f64,
    pub adaptive_batch_size: u32,
    pub prefetch_depth: usize,
    pub multi_server_enabled: bool,
    /// Number of times a batch failed on an alternate and fell back to
    /// the primary. High counts here mean an alternate is unhealthy.
    pub multi_server_fallbacks: u64,
}

#[derive(Clone, Debug, serde::Serialize)]
pub struct SyncEventInfo {
    pub event_type: String,
    pub scanning_up_to: u32,
    pub phase: Option<String>,
    pub synced_height: u32,
    pub latest_height: u32,
    pub maintenance_queue_len: u32,
    pub txid: Option<String>,
    pub status: Option<String>,
    pub scope: Option<String>,
    pub message: Option<String>,
    pub scan_progress_num: u64,
    pub scan_progress_den: u64,
    pub recovery_progress_num: u64,
    pub recovery_progress_den: u64,
    pub blocks_scanned: u64,
    pub blocks_total: u64,
}

const SYNC_PHASE_IDLE: &str = "idle";
const SYNC_PHASE_CONNECTING: &str = "connecting";
const SYNC_PHASE_UPDATING_ROOTS: &str = "updating_roots";
const SYNC_PHASE_REFRESHING_UTXOS: &str = "refreshing_utxos";
const SYNC_PHASE_SCANNING: &str = "scanning";
const SYNC_PHASE_VERIFYING: &str = "verifying";
const SYNC_PHASE_CAUGHT_UP: &str = "caught_up";
const SYNC_PHASE_ENHANCING: &str = "enhancing";
const SYNC_PHASE_RECONNECTING: &str = "reconnecting";

#[derive(Clone, Debug)]
#[allow(dead_code)]
pub(crate) struct InactiveWallet {
    pub db_data_path: PathBuf,
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

pub async fn start() -> Result<()> {
    // Serialize starts/stops. A previous session must release both workers
    // before resetting the shared cancellation flag or switching databases.
    let mut tasks = SYNC_TASKS.lock().await;
    if tasks
        .as_ref()
        .and_then(|tasks| tasks.scan.as_ref())
        .is_some_and(|task| !task.is_finished())
    {
        return Err(anyhow::anyhow!("Sync already running"));
    }
    if let Some(previous) = tasks.as_mut() {
        previous.abort_and_join().await;
    }
    *tasks = None;
    SYNC_RUNNING.store(false, Ordering::SeqCst);

    let engine_guard = ENGINE.lock().await;
    let engine = engine_guard
        .as_ref()
        .ok_or_else(|| anyhow::anyhow!("Engine not initialized"))?;

    let db_data_path = engine.db_data_path.clone();
    let params = engine.params;
    let server_url = engine.server_url.clone();
    let db_cipher_key = engine.db_cipher_key.clone();
    drop(engine_guard);

    SYNC_RUNNING.store(true, Ordering::SeqCst);
    SYNC_CANCEL.store(false, Ordering::SeqCst);
    DOWNLOAD_BATCH_LIMIT.store(u32::MAX, Ordering::Release);
    {
        let mut runtime = SYNC_RUNTIME_CONFIG.lock().await;
        if runtime.auto_select_servers {
            let defaults = default_alternate_servers(&params, &server_url);
            if !defaults.is_empty() {
                tracing::info!("[sync] configuring {} fallback peers", defaults.len());
                emit_log(&format!(
                    "server policy: selected peer with {} fallbacks ({})",
                    defaults.len(),
                    short_server_list(&defaults)
                ));
            }
            // Recompute after a wallet/server switch; never carry public peers
            // into a custom-server session.
            runtime.alternate_servers = defaults;
        }
        let runtime_snapshot = runtime.clone();
        drop(runtime);
        let mut perf = SYNC_PERF.lock().await;
        *perf = SyncPerfSnapshot {
            adaptive_batch_size: SCAN_BATCH_SIZE,
            prefetch_depth: runtime_snapshot.prefetch_depth,
            multi_server_enabled: !runtime_snapshot.auto_select_servers
                && runtime_snapshot.prefetch_depth > 0
                && !runtime_snapshot.alternate_servers.is_empty(),
            ..SyncPerfSnapshot::default()
        };
    }
    {
        let mut p = SYNC_PROGRESS.lock().await;
        p.is_syncing = true;
        p.synced_height = 0;
        p.latest_height = 0;
        p.connection_error = None;
        p.maintenance_error = None;
        p.phase = SYNC_PHASE_CONNECTING.to_string();
        p.scanning_up_to = 0;
        p.adaptive_batch_size = SCAN_BATCH_SIZE;
        p.maintenance_queue_len = 0;
        p.blocks_scanned = 0;
        p.blocks_total = 0;
    }
    emit_progress_event("phase_changed", None, None).await;

    let mempool_db = db_data_path.clone();
    let mempool_server = server_url.clone();
    let mempool_key = db_cipher_key.clone();

    let scan_task = tokio::spawn(async move {
        match sync_forever(&db_data_path, params, &server_url, &db_cipher_key).await {
            Ok(()) => tracing::info!("[sync] stopped"),
            Err(e) => tracing::error!("[sync] error: {:?}", e),
        }
        SYNC_CANCEL.store(true, Ordering::SeqCst);
        SYNC_RUNNING.store(false, Ordering::SeqCst);
        {
            let mut p = SYNC_PROGRESS.lock().await;
            p.is_syncing = false;
            p.phase = SYNC_PHASE_IDLE.to_string();
        }
        emit_progress_event("phase_changed", None, None).await;
    });

    let mempool_task = tokio::spawn(async move {
        mempool_forever(mempool_db, params, mempool_server, mempool_key).await;
    });
    *tasks = Some(SyncTasks {
        scan: Some(scan_task),
        mempool: Some(mempool_task),
    });

    Ok(())
}

pub async fn stop() {
    let mut tasks = SYNC_TASKS.lock().await;
    SYNC_CANCEL.store(true, Ordering::SeqCst);
    if let Some(active) = tasks.as_mut() {
        active.abort_and_join().await;
    }
    *tasks = None;
    SYNC_RUNNING.store(false, Ordering::SeqCst);
    {
        let mut progress = SYNC_PROGRESS.lock().await;
        progress.is_syncing = false;
        progress.phase = SYNC_PHASE_IDLE.to_string();
    }
    emit_progress_event("phase_changed", None, None).await;
}

struct SyncTasks {
    scan: Option<tokio::task::JoinHandle<()>>,
    mempool: Option<tokio::task::JoinHandle<()>>,
}

impl SyncTasks {
    async fn abort_and_join(&mut self) {
        // Abort both immediately, including stalled RPCs. A synchronous SDK
        // scan already in progress finishes before its JoinHandle completes.
        for task in [&self.scan, &self.mempool].into_iter().flatten() {
            task.abort();
        }
        for task in [&mut self.scan, &mut self.mempool] {
            if let Some(handle) = task.as_mut() {
                let _ = handle.await;
                // Leave unfinished handles owned here if the caller is cancelled.
                *task = None;
            }
        }
    }
}

pub fn is_running() -> bool {
    SYNC_RUNNING.load(Ordering::SeqCst)
}

pub async fn get_progress() -> SyncProgressInfo {
    SYNC_PROGRESS.lock().await.clone()
}

pub async fn get_perf_snapshot() -> SyncPerfSnapshot {
    SYNC_PERF.lock().await.clone()
}

pub async fn configure_runtime(mut config: SyncRuntimeConfig) {
    config.prefetch_depth = config.prefetch_depth.min(8);
    let mut runtime = SYNC_RUNTIME_CONFIG.lock().await;
    *runtime = config;
}

pub async fn reset_runtime_config() {
    configure_runtime(SyncRuntimeConfig::default()).await;
}

pub fn subscribe_events() -> broadcast::Receiver<SyncEventInfo> {
    SYNC_EVENTS.subscribe()
}

fn emit_event(event: SyncEventInfo) {
    let _ = SYNC_EVENTS.send(event);
}

async fn emit_progress_event(event_type: &str, scope: Option<&str>, message: Option<String>) {
    let p = SYNC_PROGRESS.lock().await.clone();
    emit_event(SyncEventInfo {
        event_type: event_type.to_string(),
        scanning_up_to: p.scanning_up_to,
        phase: Some(p.phase),
        synced_height: p.synced_height,
        latest_height: p.latest_height,
        maintenance_queue_len: p.maintenance_queue_len,
        txid: None,
        status: None,
        scope: scope.map(str::to_string),
        message,
        scan_progress_num: p.scan_progress_num,
        scan_progress_den: p.scan_progress_den,
        recovery_progress_num: p.recovery_progress_num,
        recovery_progress_den: p.recovery_progress_den,
        blocks_scanned: p.blocks_scanned,
        blocks_total: p.blocks_total,
    });
}

pub fn emit_transaction_event(txid: String, status: &str) {
    emit_event(SyncEventInfo {
        event_type: "transaction_updated".to_string(),
        scanning_up_to: 0,
        phase: None,
        synced_height: 0,
        latest_height: 0,
        maintenance_queue_len: 0,
        txid: Some(txid),
        status: Some(status.to_string()),
        scope: None,
        message: None,
        scan_progress_num: 0,
        scan_progress_den: 0,
        recovery_progress_num: 0,
        recovery_progress_den: 0,
        blocks_scanned: 0,
        blocks_total: 0,
    });
    emit_event(SyncEventInfo {
        event_type: "balance_maybe_changed".to_string(),
        scanning_up_to: 0,
        phase: None,
        synced_height: 0,
        latest_height: 0,
        maintenance_queue_len: 0,
        txid: None,
        status: None,
        scope: None,
        message: None,
        scan_progress_num: 0,
        scan_progress_den: 0,
        recovery_progress_num: 0,
        recovery_progress_den: 0,
        blocks_scanned: 0,
        blocks_total: 0,
    });
}

/// Emit a log-level event so Dart can show Rust engine activity in the debug log.
pub fn emit_log(message: &str) {
    emit_event(SyncEventInfo {
        event_type: "engine_log".to_string(),
        scanning_up_to: 0,
        phase: None,
        synced_height: 0,
        latest_height: 0,
        maintenance_queue_len: 0,
        txid: None,
        status: None,
        scope: None,
        message: Some(message.to_string()),
        scan_progress_num: 0,
        scan_progress_den: 0,
        recovery_progress_num: 0,
        recovery_progress_den: 0,
        blocks_scanned: 0,
        blocks_total: 0,
    });
}

/// Manually populate `SYNC_PROGRESS` from known DB / network values. Useful for
/// short-lived processes (CLI invocations) that did not run a sync pass in-process
/// but still need [`ensure_synced`] to pass when the underlying wallet DB is
/// already at the chain tip.
pub async fn set_progress(synced_height: u32, latest_height: u32) {
    let mut p = SYNC_PROGRESS.lock().await;
    if synced_height > p.synced_height {
        p.synced_height = synced_height;
    }
    if latest_height > p.latest_height {
        p.latest_height = latest_height;
    }
}

/// Maximum blocks behind tip before we consider the wallet "not synced enough to spend".
const SYNC_TOLERANCE_BLOCKS: u32 = 3;

/// Returns true if the wallet has completed at least one scan pass and is
/// within [`SYNC_TOLERANCE_BLOCKS`] of the chain tip.
pub async fn is_synced() -> bool {
    let p = SYNC_PROGRESS.lock().await;
    p.synced_height > 0
        && p.latest_height > 0
        && p.synced_height + SYNC_TOLERANCE_BLOCKS >= p.latest_height
}

/// Returns an error if the wallet is not synced close enough to the chain tip
/// for safe spending. Callers should surface this as a `SYNC_REQUIRED` error.
pub async fn ensure_synced() -> Result<()> {
    let p = SYNC_PROGRESS.lock().await;
    if p.synced_height == 0 || p.latest_height == 0 {
        return Err(anyhow::anyhow!(
            "Wallet not synced yet (synced: {}, tip: {}). Sync in progress.",
            p.synced_height,
            p.latest_height
        ));
    }
    if p.synced_height + SYNC_TOLERANCE_BLOCKS < p.latest_height {
        return Err(anyhow::anyhow!(
            "Wallet is {} blocks behind (synced: {}, tip: {}). Sync in progress.",
            p.latest_height - p.synced_height,
            p.synced_height,
            p.latest_height
        ));
    }
    Ok(())
}

pub async fn register_inactive_wallet(data_dir: &str) {
    let (db_data_path, _) = super::db_paths(data_dir);
    let mut wallets = INACTIVE_WALLETS.lock().await;
    if !wallets.iter().any(|w| w.db_data_path == db_data_path) {
        wallets.push(InactiveWallet { db_data_path });
    }
}

pub async fn unregister_inactive_wallet(data_dir: &str) {
    let (db_data_path, _) = super::db_paths(data_dir);
    let mut wallets = INACTIVE_WALLETS.lock().await;
    wallets.retain(|w| w.db_data_path != db_data_path);
}

pub async fn clear_inactive_wallets() {
    let mut wallets = INACTIVE_WALLETS.lock().await;
    wallets.clear();
}

pub async fn enhance_transaction(txid_hex: &str) -> Result<()> {
    let mut display_bytes =
        hex::decode(txid_hex).map_err(|e| anyhow::anyhow!("invalid txid hex: {:?}", e))?;
    if display_bytes.len() != 32 {
        return Err(anyhow::anyhow!("invalid txid length"));
    }
    display_bytes.reverse();
    let txid = TxId::from_bytes(
        display_bytes
            .try_into()
            .map_err(|_| anyhow::anyhow!("invalid txid length"))?,
    );

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
    let mut lwd = connect_lwd_maybe_tor(&server_url).await?;
    fetch_and_decrypt_tx(
        &mut db_data,
        &params,
        &mut lwd,
        &db_data_path,
        &db_cipher_key,
        txid,
    )
    .await?;
    emit_transaction_event(txid_hex.to_string(), "confirmed");
    Ok(())
}

/// Rescan from a given height by truncating the wallet DB and restarting sync.
pub async fn rescan_from(height: u32) -> Result<()> {
    stop().await;

    let engine_guard = ENGINE.lock().await;
    let engine = engine_guard
        .as_ref()
        .ok_or_else(|| anyhow::anyhow!("Engine not initialized"))?;

    let db_data_path = engine.db_data_path.clone();
    let params = engine.params;
    let db_cipher_key = engine.db_cipher_key.clone();
    drop(engine_guard);

    let mut db_data = open_wallet_db(&db_data_path, params, &db_cipher_key)?;
    let target = BlockHeight::from_u32(height);
    tracing::info!("[sync] rescan: truncating to height {}", height);
    safe_truncate_to_height_sync(&mut db_data, target)?;
    start().await
}

// ---------------------------------------------------------------------------
// Continuous sync with exponential backoff retry
// ---------------------------------------------------------------------------

const MAX_CONSECUTIVE_FAILURES: u32 = 20;

async fn sync_forever(
    db_data_path: &Path,
    params: Network,
    server_url: &str,
    db_cipher_key: &Option<String>,
) -> Result<()> {
    let mut backoff_ms: u64 = 3_000;
    const MAX_BACKOFF_MS: u64 = 30_000;
    let mut consecutive_failures: u32 = 0;
    let mut perf = SessionPerf::default();

    loop {
        check_cancel()?;

        let active_server = {
            let runtime = SYNC_RUNTIME_CONFIG.lock().await;
            let mut peers = vec![server_url.to_string()];
            for peer in &runtime.alternate_servers {
                if !peers.contains(peer) {
                    peers.push(peer.clone());
                }
            }
            peers[consecutive_failures as usize % peers.len()].clone()
        };
        match sync_once(
            db_data_path,
            params,
            &active_server,
            db_cipher_key,
            &mut perf,
        )
        .await
        {
            Ok(()) => {
                {
                    let mut p = SYNC_PROGRESS.lock().await;
                    p.connection_error = None;
                    p.phase = SYNC_PHASE_CAUGHT_UP.to_string();
                }
                emit_progress_event("phase_changed", None, None).await;
                backoff_ms = 3_000;
                consecutive_failures = 0;

                let has_queue = {
                    let p = SYNC_PROGRESS.lock().await;
                    p.maintenance_queue_len > 0
                };
                let idle_secs = if has_queue { 5 } else { 15 };

                for _ in 0..idle_secs {
                    if SYNC_CANCEL.load(Ordering::SeqCst) {
                        return Ok(());
                    }
                    tokio::time::sleep(std::time::Duration::from_secs(1)).await;
                }
            }
            Err(e) => {
                if is_cancel_error(&e) {
                    return Err(e);
                }

                consecutive_failures += 1;
                let err_msg = format!("{:#}", e);
                tracing::warn!(
                    "[sync] error (attempt {}), retrying in {}ms: {}",
                    consecutive_failures,
                    backoff_ms,
                    err_msg
                );
                emit_log(&format!(
                    "pass failed attempt={} retry_ms={} batch_limit={}: {}",
                    consecutive_failures,
                    backoff_ms,
                    DOWNLOAD_BATCH_LIMIT.load(Ordering::Acquire),
                    err_msg
                ));

                if consecutive_failures >= MAX_CONSECUTIVE_FAILURES {
                    let mut p = SYNC_PROGRESS.lock().await;
                    p.connection_error = Some(format!("{:#}", e));
                    p.phase = SYNC_PHASE_IDLE.to_string();
                    p.is_syncing = false;
                    drop(p);
                    emit_progress_event(
                        "sync_failed",
                        Some("scan"),
                        Some(format!(
                            "Sync stopped after {} consecutive failures",
                            MAX_CONSECUTIVE_FAILURES
                        )),
                    )
                    .await;
                    return Err(anyhow::anyhow!(
                        "Sync stopped after {} consecutive failures: {:#}",
                        MAX_CONSECUTIVE_FAILURES,
                        e
                    ));
                }

                {
                    let mut p = SYNC_PROGRESS.lock().await;
                    p.connection_error = Some(format!("{:#}", e));
                    p.phase = SYNC_PHASE_RECONNECTING.to_string();
                    drop(p);
                    emit_progress_event("connection_error", Some("scan"), Some(format!("{:#}", e)))
                        .await;
                }

                interruptible_sleep(backoff_ms).await?;
                backoff_ms = (backoff_ms * 2).min(MAX_BACKOFF_MS);
            }
        }
    }
}

/// Independent mempool monitoring task. Runs alongside sync_forever,
/// only active when the wallet is caught up.
async fn mempool_forever(
    db_data_path: PathBuf,
    params: Network,
    server_url: String,
    db_cipher_key: Option<String>,
) {
    loop {
        if SYNC_CANCEL.load(Ordering::SeqCst) {
            return;
        }

        let phase = { SYNC_PROGRESS.lock().await.phase.clone() };
        if phase != SYNC_PHASE_CAUGHT_UP {
            tokio::time::sleep(Duration::from_secs(5)).await;
            continue;
        }

        let latest = { SYNC_PROGRESS.lock().await.latest_height };
        if let Ok(mut lwd) = connect_lwd_maybe_tor(&server_url).await {
            if let Ok(mut db_data) = open_wallet_db(&db_data_path, params, &db_cipher_key) {
                if let Err(e) = scan_mempool_once(
                    &mut lwd,
                    &mut db_data,
                    &params,
                    &db_data_path,
                    &db_cipher_key,
                    latest,
                )
                .await
                {
                    tracing::debug!("[mempool] scan skipped: {:?}", e);
                }
            }
        }

        for _ in 0..30 {
            if SYNC_CANCEL.load(Ordering::SeqCst) {
                return;
            }
            tokio::time::sleep(Duration::from_secs(1)).await;
        }
    }
}

// ---------------------------------------------------------------------------
// Single sync pass — follows ECC reference (zcash_client_backend::sync::run)
//
// Each pass keeps the wallet database on one task; downloaded blocks stay in memory.
// ---------------------------------------------------------------------------

async fn sync_once(
    db_data_path: &Path,
    params: Network,
    server_url: &str,
    db_cipher_key: &Option<String>,
    perf: &mut SessionPerf,
) -> Result<()> {
    tracing::info!("[sync] starting pass, server={}", server_url);
    emit_log(&format!("sync pass start → {}", server_url));
    let runtime = SYNC_RUNTIME_CONFIG.lock().await.clone();
    // Snapshot whether we entered this pass already caught-up. If so, the
    // periodic maintenance work (subtree roots, UTXO refresh, tip check) is
    // background bookkeeping — we keep the phase as CAUGHT_UP for the whole
    // pass and only flip to a scanning phase if we actually discover work.
    let was_caught_up_on_entry = {
        let p = SYNC_PROGRESS.lock().await;
        p.phase == SYNC_PHASE_CAUGHT_UP
    };

    let mut db_data = open_wallet_db(db_data_path, params, db_cipher_key)?;
    {
        let mut p = SYNC_PROGRESS.lock().await;
        if !was_caught_up_on_entry {
            p.phase = SYNC_PHASE_CONNECTING.to_string();
        }
    }
    emit_progress_event("phase_changed", None, None).await;
    let mut lwd = connect_lwd_maybe_tor(server_url).await?;

    // Verify the lightwalletd server is on the correct network/consensus branch.
    {
        let info = lwd
            .get_lightd_info(Empty {})
            .await
            .map_err(|e| anyhow::anyhow!("get_lightd_info: {:?}", e))?
            .into_inner();

        let expected_chain = match params {
            Network::MainNetwork => "main",
            Network::TestNetwork => "test",
        };
        if !info.chain_name.is_empty() && info.chain_name != expected_chain {
            return Err(anyhow::anyhow!(
                "Network mismatch: wallet expects '{}' but server reports '{}'",
                expected_chain,
                info.chain_name
            ));
        }

        if !info.consensus_branch_id.is_empty() {
            let server_branch = info.consensus_branch_id.trim_start_matches("0x");
            let tip_height = BlockHeight::from_u32(info.block_height as u32);
            let expected_branch =
                format!("{:x}", u32::from(BranchId::for_height(&params, tip_height)));
            if server_branch != expected_branch {
                tracing::warn!(
                    "[sync] consensus branch mismatch: server={} expected={}",
                    server_branch,
                    expected_branch
                );
            }
        }
    }

    // Clear any stale error from a previous failed pass.
    {
        let mut p = SYNC_PROGRESS.lock().await;
        p.connection_error = None;
        p.maintenance_error = None;
        if !was_caught_up_on_entry {
            p.phase = SYNC_PHASE_UPDATING_ROOTS.to_string();
        }
    }
    if !was_caught_up_on_entry {
        emit_progress_event("phase_changed", None, None).await;
    }

    // 2) Sync until caught up (ECC pattern: `while running(...) {}`)
    let mut batch_size: u32 = SCAN_BATCH_SIZE.min(DOWNLOAD_BATCH_LIMIT.load(Ordering::Acquire));
    let mut keep_running = true;
    const SYNC_RESTART_TIMEOUT: Duration = Duration::from_secs(300);
    while keep_running {
        let pass_num = SYNC_PASS_COUNTER.fetch_add(1, Ordering::SeqCst) + 1;
        let pass_started = Instant::now();
        let pass_committed_start = wallet_fully_scanned_height(&mut db_data).unwrap_or(0);
        let mut pass_restarts: u32 = 0;
        let mut pass_batches_scanned: u32 = 0;
        check_cancel()?;

        // 3-4) Update chain tip
        let tip = lwd
            .get_latest_block(ChainSpec::default())
            .await
            .map_err(|e| anyhow::anyhow!("get_latest_block: {:?}", e))?;
        let tip_height = BlockHeight::from_u32(tip.into_inner().height as u32);
        tracing::info!("[sync] chain tip = {}", u32::from(tip_height));
        emit_log(&format!("chain tip = {}", u32::from(tip_height)));

        db_data
            .update_chain_tip(tip_height)
            .map_err(|e| anyhow::anyhow!("update_chain_tip: {:?}", e))?;

        {
            let mut p = SYNC_PROGRESS.lock().await;
            p.latest_height = u32::from(tip_height);
            p.connection_error = None;
        }
        emit_progress_event("phase_changed", None, None).await;

        update_subtree_roots(&mut lwd, &mut db_data, &params, tip_height).await?;

        if !was_caught_up_on_entry {
            let mut p = SYNC_PROGRESS.lock().await;
            p.phase = SYNC_PHASE_REFRESHING_UTXOS.to_string();
            drop(p);
            emit_progress_event("phase_changed", None, None).await;
        }
        if let Err(e) = refresh_transparent_utxos(&mut lwd, &mut db_data, &params).await {
            tracing::warn!("[sync] transparent UTXO refresh warning: {:?}", e);
        }

        // 5-6) Verify loop — handle Verify-priority ranges first
        let mut scan_ranges = db_data
            .suggest_scan_ranges()
            .map_err(|e| anyhow::anyhow!("suggest_scan_ranges: {:?}", e))?;

        emit_log(&format!(
            "pass #{} start: tip={} committed={} gap={} ranges={}",
            pass_num,
            u32::from(tip_height),
            pass_committed_start,
            u32::from(tip_height).saturating_sub(pass_committed_start),
            scan_ranges.len()
        ));
        emit_log(&format!(
            "pass #{} ranges: {}",
            pass_num,
            summarize_scan_ranges(&scan_ranges)
        ));

        // Seed the block-progress total. Sum the lengths of every
        // unscanned range (across all priorities) and add to whatever
        // we've already scanned in this session. The progress bar in
        // the UI is `blocks_scanned / blocks_total`.
        let remaining_blocks: u64 = scan_ranges.iter().map(|r| r.len() as u64).sum();
        refresh_blocks_total(remaining_blocks).await;

        loop {
            let Some(verify_idx) = scan_ranges
                .iter()
                .position(|range| range.priority() == ScanPriority::Verify)
            else {
                break;
            };

            check_cancel()?;
            let range = &scan_ranges[verify_idx];
            let range_clone = ScanRange::from_parts(
                range.block_range().start
                    ..batch_end(
                        batch_size,
                        range.block_range().start,
                        range.block_range().end,
                        &params,
                    ),
                ScanPriority::Verify,
            );
            tracing::info!("[sync] verifying range {:?}", range_clone.block_range());
            let verify_start = u32::from(range_clone.block_range().start);
            let verify_end = u32::from(range_clone.block_range().end);
            let verify_committed_before = wallet_fully_scanned_height(&mut db_data).unwrap_or(0);
            emit_log(&format!(
                "verify {}..{} ({} blocks): start, committed={}",
                verify_start,
                verify_end,
                range_clone.len(),
                verify_committed_before
            ));
            {
                let mut p = SYNC_PROGRESS.lock().await;
                p.phase = SYNC_PHASE_VERIFYING.to_string();
                p.scanning_up_to = verify_end;
            }
            emit_progress_event("phase_changed", None, None).await;

            let downloaded = download_range(&mut lwd, &range_clone).await?;
            let verify_stats = downloaded.as_ref().map(|d| d.stats());
            let scan_started = Instant::now();
            let outcome = tokio::task::block_in_place(|| {
                process_downloaded_range(&params, &mut db_data, &range_clone, downloaded)
            })?;
            let scan_elapsed_ms = scan_started.elapsed().as_millis() as u64;
            if let Some(stats) = verify_stats {
                perf.record(stats, scan_elapsed_ms, &outcome);
                perf.update_snapshot(batch_size, &runtime).await;
            }

            match outcome {
                ScanOutcome::Restarted => {
                    update_synced_progress_after_restart(&mut db_data).await;
                    let verify_committed_after = wallet_fully_scanned_height(&mut db_data)
                        .unwrap_or(verify_committed_before);
                    pass_restarts += 1;
                    emit_log(&format!(
                        "verify {}..{} restart: committed {} → {} (+{})",
                        verify_start,
                        verify_end,
                        verify_committed_before,
                        verify_committed_after,
                        verify_committed_after.saturating_sub(verify_committed_before)
                    ));
                }
                ScanOutcome::Scanned {
                    synced_height,
                    notes_found,
                } => {
                    update_synced_progress(&mut db_data, synced_height, false).await;
                    record_blocks_scanned(range_clone.len() as u64).await;
                    let verify_committed_after = wallet_fully_scanned_height(&mut db_data)
                        .unwrap_or(verify_committed_before);
                    emit_log(&format!(
                        "verify {}..{} done: committed {} → {} (+{}), notes_found={}",
                        verify_start,
                        verify_end,
                        verify_committed_before,
                        verify_committed_after,
                        verify_committed_after.saturating_sub(verify_committed_before),
                        notes_found
                    ));
                    if notes_found > 0 {
                        let _ = enhance_transactions_inline(
                            &mut db_data,
                            &params,
                            &mut lwd,
                            db_data_path,
                            db_cipher_key,
                        )
                        .await;
                    }
                }
                ScanOutcome::NothingToScan => break,
            }

            scan_ranges = db_data
                .suggest_scan_ranges()
                .map_err(|e| anyhow::anyhow!("suggest_scan_ranges: {:?}", e))?;
        }

        // 7) Process remaining scan ranges, split into fixed-size chunks.
        let scan_ranges = db_data
            .suggest_scan_ranges()
            .map_err(|e| anyhow::anyhow!("suggest_scan_ranges: {:?}", e))?;

        let batches: std::collections::VecDeque<ScanRange> = scan_ranges
            .into_iter()
            .filter(|r| r.priority() > ScanPriority::Scanned)
            .filter(|r| r.priority() != ScanPriority::Verify)
            .collect();

        tracing::debug!(
            "[sync] {} scan ranges to process (batch_size={})",
            batches.len(),
            batch_size
        );

        let mut did_restart = false;
        if !batches.is_empty() {
            {
                let mut p = SYNC_PROGRESS.lock().await;
                p.phase = SYNC_PHASE_SCANNING.to_string();
            }
            emit_progress_event("phase_changed", None, None).await;
            emit_log(&format!(
                "scan ranges: {} batch_size={} prefetch_depth={} multi_server={}",
                batches.len(),
                batch_size,
                runtime.prefetch_depth,
                !runtime.auto_select_servers && !runtime.alternate_servers.is_empty()
            ));

            let mut plan = BatchPlan {
                pending: batches,
                params,
            };
            if runtime.prefetch_depth == 0 {
                let mut batch_idx: u32 = 0;
                while let Some(current_range) = plan.next_batch(batch_size) {
                    check_cancel()?;
                    batch_idx += 1;
                    if pass_started.elapsed() > SYNC_RESTART_TIMEOUT {
                        tracing::info!(
                            "[sync] pass timeout ({}s), restarting to refresh chain tip",
                            SYNC_RESTART_TIMEOUT.as_secs()
                        );
                        emit_log("pass timeout, restarting to refresh chain tip");
                        pass_restarts += 1;
                        did_restart = true;
                        break;
                    }
                    let committed_before = wallet_fully_scanned_height(&mut db_data).unwrap_or(0);
                    let batch_started = Instant::now();
                    let downloaded = download_range(&mut lwd, &current_range).await?;
                    let download_ms = batch_started.elapsed().as_millis() as u64;
                    emit_log(&format!(
                        "batch {} [{:?}] {}..{}: downloaded in {} ms",
                        batch_idx,
                        current_range.priority(),
                        u32::from(current_range.block_range().start),
                        u32::from(current_range.block_range().end),
                        download_ms
                    ));
                    {
                        let mut p = SYNC_PROGRESS.lock().await;
                        p.scanning_up_to = u32::from(current_range.block_range().end);
                    }
                    emit_progress_event("phase_changed", None, None).await;
                    let scan_started = Instant::now();
                    let outcome = process_prefetched_range(
                        &params,
                        &mut db_data,
                        &mut batch_size,
                        perf,
                        &current_range,
                        downloaded,
                    )?;
                    let scan_ms = scan_started.elapsed().as_millis() as u64;
                    perf.update_snapshot(batch_size, &runtime).await;
                    {
                        let mut p = SYNC_PROGRESS.lock().await;
                        p.adaptive_batch_size = batch_size;
                    }
                    emit_progress_event("phase_changed", None, None).await;
                    did_restart = handle_scan_outcome(
                        outcome,
                        perf,
                        &mut db_data,
                        &params,
                        &mut lwd,
                        db_data_path,
                        db_cipher_key,
                    )
                    .await?;
                    let committed_after =
                        wallet_fully_scanned_height(&mut db_data).unwrap_or(committed_before);
                    let advance = committed_after.saturating_sub(committed_before);
                    if did_restart {
                        pass_restarts += 1;
                        emit_log(&format!(
                            "batch {} restart: committed {} (no advance, +0)",
                            batch_idx, committed_after
                        ));
                        break;
                    }
                    pass_batches_scanned += 1;
                    record_blocks_scanned(current_range.len() as u64).await;
                    emit_log(&format!(
                        "batch {} done: scanned in {} ms, committed {} → {} (+{} blocks)",
                        batch_idx, scan_ms, committed_before, committed_after, advance
                    ));
                }
            } else {
                let (tx, mut rx) = mpsc::channel::<Result<PrefetchedRange>>(runtime.prefetch_depth);
                let fetch_server_url = server_url.to_string();
                let fetch_client = lwd.clone();
                let next_batch_size = std::sync::Arc::new(AtomicU32::new(batch_size));
                let fetch_batch_size = next_batch_size.clone();
                let fetch_runtime = runtime.clone();
                // Wrap the prefetch task in an abort-on-drop guard.
                // Any non-normal exit from this scope (`?` propagating an
                // error, panic unwind, early `return`) drops the guard,
                // which aborts the spawned task. Without this, detached
                // download workers could keep streaming on alt servers
                // for up to 30 s after sync gave up on the pass.
                let fetch_handle = AbortOnDrop::new(tokio::spawn(async move {
                    fetch_prefetched_ranges(
                        fetch_server_url,
                        fetch_client,
                        plan,
                        fetch_runtime,
                        fetch_batch_size,
                        tx,
                    )
                    .await
                }));

                let mut batch_idx: u32 = 0;
                while let Some(prefetched) = rx.recv().await {
                    check_cancel()?;
                    batch_idx += 1;
                    if pass_started.elapsed() > SYNC_RESTART_TIMEOUT {
                        tracing::info!(
                            "[sync] pass timeout ({}s), restarting to refresh chain tip",
                            SYNC_RESTART_TIMEOUT.as_secs()
                        );
                        emit_log("pass timeout, restarting to refresh chain tip");
                        pass_restarts += 1;
                        did_restart = true;
                        break;
                    }
                    let PrefetchedRange {
                        scan_range: current_range,
                        downloaded,
                        fell_back_to_primary,
                    } = prefetched?;
                    if fell_back_to_primary {
                        perf.record_fallback();
                    }
                    let committed_before = wallet_fully_scanned_height(&mut db_data).unwrap_or(0);
                    emit_log(&format!(
                        "batch {} [{:?}] {}..{}: downloaded in {} ms, prefetched, scanning",
                        batch_idx,
                        current_range.priority(),
                        u32::from(current_range.block_range().start),
                        u32::from(current_range.block_range().end),
                        downloaded
                            .as_ref()
                            .map(|range| range.download_ms)
                            .unwrap_or(0),
                    ));
                    {
                        let mut p = SYNC_PROGRESS.lock().await;
                        p.scanning_up_to = u32::from(current_range.block_range().end);
                    }
                    emit_progress_event("phase_changed", None, None).await;
                    let scan_started = Instant::now();
                    let outcome = process_prefetched_range(
                        &params,
                        &mut db_data,
                        &mut batch_size,
                        perf,
                        &current_range,
                        downloaded,
                    )?;
                    let scan_ms = scan_started.elapsed().as_millis() as u64;
                    next_batch_size.store(batch_size, Ordering::Release);
                    perf.update_snapshot(batch_size, &runtime).await;
                    {
                        let mut p = SYNC_PROGRESS.lock().await;
                        p.adaptive_batch_size = batch_size;
                    }
                    emit_progress_event("phase_changed", None, None).await;
                    did_restart = handle_scan_outcome(
                        outcome,
                        perf,
                        &mut db_data,
                        &params,
                        &mut lwd,
                        db_data_path,
                        db_cipher_key,
                    )
                    .await?;
                    let committed_after =
                        wallet_fully_scanned_height(&mut db_data).unwrap_or(committed_before);
                    let advance = committed_after.saturating_sub(committed_before);
                    if did_restart {
                        pass_restarts += 1;
                        emit_log(&format!(
                            "batch {} restart: committed {} (no advance, +0)",
                            batch_idx, committed_after
                        ));
                        break;
                    }
                    pass_batches_scanned += 1;
                    record_blocks_scanned(current_range.len() as u64).await;
                    emit_log(&format!(
                        "batch {} done: scanned in {} ms, committed {} → {} (+{} blocks)",
                        batch_idx, scan_ms, committed_before, committed_after, advance
                    ));
                }

                if did_restart {
                    // AbortOnDrop drops at end of scope and aborts the
                    // task, no explicit call needed.
                    drop(fetch_handle);
                } else {
                    match fetch_handle.into_inner().await {
                        Ok(Ok(())) => {}
                        Ok(Err(e)) => return Err(e),
                        Err(e) if e.is_cancelled() => {}
                        Err(e) => {
                            return Err(anyhow::anyhow!("download prefetch task failed: {:?}", e))
                        }
                    }
                }
            }
        }

        let pass_committed_end =
            wallet_fully_scanned_height(&mut db_data).unwrap_or(pass_committed_start);
        let pass_advance = pass_committed_end.saturating_sub(pass_committed_start);
        emit_log(&format!(
            "pass #{} end: committed {} → {} (+{} blocks), batches_scanned={}, restarts={}, duration={}s, will_restart={}",
            pass_num,
            pass_committed_start,
            pass_committed_end,
            pass_advance,
            pass_batches_scanned,
            pass_restarts,
            pass_started.elapsed().as_secs(),
            did_restart
        ));

        // No-progress watchdog: if a pass completes without making progress
        // AND there were no restarts (i.e., nothing more to scan but committed
        // didn't move), break the outer loop so we don't spin forever.
        if pass_advance == 0 && !did_restart && pass_batches_scanned == 0 {
            emit_log(&format!(
                "pass #{} watchdog: no advance and no batches; treating as caught-up",
                pass_num
            ));
        }

        // Stuck-reorg watchdog: same continuity error several passes in a
        // row, all of which the SDK refused to rewind past. Stop the auto
        // restart loop so the wallet stops spinning, and tell the user.
        let stuck_count = STUCK_REORG_COUNT.load(Ordering::SeqCst);
        let stuck_height = STUCK_REORG_HEIGHT.load(Ordering::SeqCst);
        if stuck_count >= STUCK_REORG_THRESHOLD {
            let msg = format!(
                "wallet stuck on reorg at block {} ({} consecutive continuity errors, \
                 SDK refuses deeper rewind). Tap More → Recover Transactions to rescan from \
                 wallet birthday.",
                stuck_height, stuck_count
            );
            tracing::error!("[sync] {}", msg);
            emit_log(&msg);
            {
                let mut p = SYNC_PROGRESS.lock().await;
                p.connection_error = Some(format!(
                    "Wallet stuck on a chain reorg at block {}. Please use Recover \
                     Transactions in the More tab.",
                    stuck_height
                ));
                p.phase = SYNC_PHASE_CAUGHT_UP.to_string();
            }
            emit_progress_event("phase_changed", None, None).await;
            // Reset counter so a future manual rescan can start cleanly.
            STUCK_REORG_HEIGHT.store(0, Ordering::SeqCst);
            STUCK_REORG_COUNT.store(0, Ordering::SeqCst);
            break;
        }

        keep_running = did_restart;
    }

    let fsh = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        db_data.get_wallet_summary(ConfirmationsPolicy::default())
    }))
    .ok()
    .and_then(|r| r.ok())
    .flatten()
    .map(|s| u32::from(s.fully_scanned_height()))
    .unwrap_or(0);
    if fsh > 0 {
        emit_log(&format!("scan complete, fully_scanned_height = {}", fsh));
        let mut p = SYNC_PROGRESS.lock().await;
        p.synced_height = fsh;
        p.phase = SYNC_PHASE_CAUGHT_UP.to_string();
        drop(p);
        emit_progress_event("phase_changed", None, None).await;
    }

    // Run transaction enhancement: light-wallet sync via compact blocks does
    // not include the encrypted memo bytes (they're stripped from CompactTx
    // outputs/actions). To populate memos for received notes, we fetch the
    // full transaction via lightwalletd's `GetTransaction` RPC and then call
    // `decrypt_and_store_transaction`, which writes the decrypted memo into
    // `sapling_received_notes.memo` / `orchard_received_notes.memo`.
    //
    // Before enhancement, requeue any received notes that were scanned without
    // memo data (typical of wallets created before tx enhancement landed) so
    // we can retro-actively populate their memos.
    if let Err(e) = requeue_unenhanced_notes(db_data_path, db_cipher_key) {
        tracing::warn!("[sync] requeue unenhanced notes failed: {:?}", e);
    }
    let latest_for_pending = {
        let p = SYNC_PROGRESS.lock().await;
        p.latest_height.max(fsh)
    };
    match connect_lwd_maybe_tor(server_url).await {
        Ok(mut maintenance_lwd) => {
            if let Err(e) = enhance_transactions(
                &mut db_data,
                &params,
                &mut maintenance_lwd,
                db_data_path,
                db_cipher_key,
            )
            .await
            {
                tracing::warn!("[sync] maintenance failed (will retry next pass): {:?}", e);
                let mut p = SYNC_PROGRESS.lock().await;
                p.maintenance_error = Some(format!("{:#}", e));
            }
            match pending::resubmit_unmined(
                db_data_path,
                db_cipher_key,
                &mut maintenance_lwd,
                latest_for_pending,
            )
            .await
            {
                Ok(summary) => {
                    if summary.resubmitted > 0 || summary.confirmed > 0 || summary.expired > 0 {
                        tracing::info!(
                            "[sync] pending txs: resubmitted={} confirmed={} expired={}",
                            summary.resubmitted,
                            summary.confirmed,
                            summary.expired
                        );
                    }
                }
                Err(e) => {
                    tracing::warn!("[sync] pending tx resubmission failed: {:?}", e);
                    let mut p = SYNC_PROGRESS.lock().await;
                    p.maintenance_error = Some(format!("{:#}", e));
                }
            }
        }
        Err(e) => {
            // Maintenance is intentionally not part of the critical scan path.
            // Memos and tx status will retry on the next pass without surfacing
            // as a wallet-wide connection failure.
            tracing::warn!("[sync] maintenance connection failed: {:?}", e);
            let mut p = SYNC_PROGRESS.lock().await;
            p.maintenance_error = Some(format!("{:#}", e));
        }
    }

    perf.log_summary();
    perf.update_snapshot(batch_size, &runtime).await;
    tracing::info!("[sync] pass complete");
    Ok(())
}

/// Fetch full transaction data for any txs in the wallet's enhancement queue
/// and decrypt+store them so memos become available.
///
/// Capped at `MAX_MAINTENANCE_PER_PASS` to avoid holding the gRPC connection
/// open for too long on wallets with large transaction histories. Remaining
/// items stay in the queue and get processed on subsequent sync passes.
const MAX_MAINTENANCE_PER_PASS: usize = 100;

async fn enhance_transactions(
    db_data: &mut DbType,
    params: &Network,
    lwd: &mut CompactTxStreamerClient<tonic::transport::Channel>,
    db_data_path: &Path,
    db_cipher_key: &Option<String>,
) -> Result<()> {
    enhance_transactions_limited(
        db_data,
        params,
        lwd,
        db_data_path,
        db_cipher_key,
        MAX_MAINTENANCE_PER_PASS,
        true,
    )
    .await
}

async fn enhance_transactions_inline(
    db_data: &mut DbType,
    params: &Network,
    lwd: &mut CompactTxStreamerClient<tonic::transport::Channel>,
    db_data_path: &Path,
    db_cipher_key: &Option<String>,
) -> Result<()> {
    enhance_transactions_limited(db_data, params, lwd, db_data_path, db_cipher_key, 10, false).await
}

/// Per-txid failure counter. Txids that fail more than MAX_ENHANCE_RETRIES
/// across sync passes get marked as TxidNotRecognized to clear the queue.
const MAX_ENHANCE_RETRIES: u32 = 5;

lazy_static::lazy_static! {
    static ref ENHANCE_FAILURES: TokioMutex<std::collections::HashMap<TxId, u32>> =
        TokioMutex::new(std::collections::HashMap::new());
}

/// Classification used both for logging and for deciding what counts as
/// "real" work in the user-visible maintenance queue. Ephemeral t-address
/// checks are background hygiene that the SDK re-emits on every pass, so
/// they should not surface to users as "still recovering N items".
#[derive(Clone, Copy, PartialEq, Eq)]
enum RequestKind {
    Enhancement,
    Status,
    SpendSearch,
    EphemeralCheck,
}

fn classify_request(req: &TransactionDataRequest) -> RequestKind {
    match req {
        TransactionDataRequest::Enhancement(_) => RequestKind::Enhancement,
        TransactionDataRequest::GetStatus(_) => RequestKind::Status,
        TransactionDataRequest::TransactionsInvolvingAddress(r) => {
            // Spend-search has a bounded end height + Mined filter; ephemeral
            // checks have block_range_end = None and request_at = Some(time).
            if r.block_range_end().is_some() {
                RequestKind::SpendSearch
            } else {
                RequestKind::EphemeralCheck
            }
        }
    }
}

fn count_blocking_requests(requests: &[TransactionDataRequest]) -> usize {
    requests
        .iter()
        .filter(|r| classify_request(r) != RequestKind::EphemeralCheck)
        .count()
}

fn describe_transaction_requests(requests: &[TransactionDataRequest]) -> String {
    let mut enhancement = 0usize;
    let mut status = 0usize;
    let mut spend_search = 0usize;
    let mut ephemeral = 0usize;
    for req in requests {
        match classify_request(req) {
            RequestKind::Enhancement => enhancement += 1,
            RequestKind::Status => status += 1,
            RequestKind::SpendSearch => spend_search += 1,
            RequestKind::EphemeralCheck => ephemeral += 1,
        }
    }
    format!(
        "{} total ({} enhancement, {} status, {} spend-search, {} ephemeral)",
        requests.len(),
        enhancement,
        status,
        spend_search,
        ephemeral
    )
}

async fn enhance_transactions_limited(
    db_data: &mut DbType,
    params: &Network,
    lwd: &mut CompactTxStreamerClient<tonic::transport::Channel>,
    db_data_path: &Path,
    db_cipher_key: &Option<String>,
    max_items: usize,
    final_phase: bool,
) -> Result<()> {
    let requests = db_data
        .transaction_data_requests()
        .map_err(|e| anyhow::anyhow!("transaction_data_requests: {:?}", e))?;
    if requests.is_empty() {
        let mut p = SYNC_PROGRESS.lock().await;
        p.maintenance_queue_len = 0;
        return Ok(());
    }

    let total = requests.len();
    let blocking_total = count_blocking_requests(&requests);
    {
        let mut p = SYNC_PROGRESS.lock().await;
        // Surface only "real" work to the home screen. Ephemeral t-address
        // checks are re-emitted by the SDK on every pass as part of its
        // privacy schedule and would otherwise pin the UI at "N left"
        // forever.
        p.maintenance_queue_len = blocking_total as u32;
        if blocking_total > 0 {
            p.phase = SYNC_PHASE_ENHANCING.to_string();
        }
        p.maintenance_error = None;
    }
    if blocking_total > 0 {
        emit_progress_event("phase_changed", None, None).await;
    }

    tracing::info!(
        "[sync] enhancing: {} items in queue ({} blocking)",
        total,
        blocking_total
    );
    emit_log(&format!(
        "enhancement queue: {}",
        describe_transaction_requests(&requests)
    ));

    let mut enhanced = 0usize;
    let mut status_checked = 0usize;
    let mut skipped = 0usize;
    let mut processed = 0usize;
    let mut address_checks = 0usize;
    let mut address_txs_found = 0usize;
    let mut ephemeral_processed_this_pass = 0usize;
    let mut ephemeral_deferred = 0usize;
    const MAX_EPHEMERAL_CHECKS_PER_PASS: usize = 1;
    let now = std::time::SystemTime::now();
    let mut consecutive_rpc_errors = 0u32;

    for req in requests {
        if processed >= max_items {
            tracing::info!(
                "[sync] pausing maintenance at {} / {} (rest on next pass)",
                processed,
                total
            );
            break;
        }

        match req {
            TransactionDataRequest::Enhancement(txid) => {
                // Check if this txid has exceeded retry limit
                {
                    let failures = ENHANCE_FAILURES.lock().await;
                    if let Some(&count) = failures.get(&txid) {
                        if count >= MAX_ENHANCE_RETRIES {
                            tracing::info!(
                                "[sync] skipping txid {} after {} failures, clearing enhancement queue entry",
                                txid, count
                            );
                            let _ = clear_retrieval_queue_entry(db_data_path, db_cipher_key, txid);
                            emit_log(&format!(
                                "enhance {}: skipped after {} failures, cleared queue row",
                                short_txid(txid),
                                count
                            ));
                            skipped += 1;
                            processed += 1;
                            continue;
                        }
                    }
                }

                match fetch_and_decrypt_tx(db_data, params, lwd, db_data_path, db_cipher_key, txid)
                    .await
                {
                    Ok(()) => {
                        enhanced += 1;
                        processed += 1;
                        consecutive_rpc_errors = 0;
                        // Clear failure count on success
                        ENHANCE_FAILURES.lock().await.remove(&txid);
                        // Supplying the full transaction should satisfy the
                        // enhancement request. If the library leaves the row
                        // behind, clear it so memo recovery cannot keep the
                        // wallet in a permanent maintenance loop.
                        if clear_retrieval_queue_entry(db_data_path, db_cipher_key, txid)
                            .unwrap_or(false)
                        {
                            tracing::info!(
                                "[sync] cleared lingering enhancement queue entry {}",
                                txid
                            );
                        }
                        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
                    }
                    Err(e) => {
                        consecutive_rpc_errors += 1;
                        processed += 1;
                        let count = {
                            let mut failures = ENHANCE_FAILURES.lock().await;
                            let count = failures.entry(txid).or_insert(0);
                            *count += 1;
                            *count
                        };
                        tracing::info!(
                            "[sync] enhance {} failed (attempt {}): {:?}",
                            txid,
                            count,
                            e
                        );
                        emit_log(&format!(
                            "enhance {}: failed attempt {} ({})",
                            short_txid(txid),
                            count,
                            trim_log_error(&format!("{:?}", e))
                        ));
                        if consecutive_rpc_errors >= 3 {
                            tracing::warn!(
                                "[sync] 3 consecutive enhancement failures, \
                                 aborting enhancement (connection likely dropped)"
                            );
                            emit_log("enhancement: connection dropped, will retry next pass");
                            break;
                        }
                    }
                }
            }
            TransactionDataRequest::GetStatus(txid) => {
                match fetch_status(db_data, lwd, txid).await {
                    Ok(()) => {
                        status_checked += 1;
                        processed += 1;
                        consecutive_rpc_errors = 0;
                        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
                    }
                    Err(e) => {
                        consecutive_rpc_errors += 1;
                        processed += 1;
                        tracing::info!("[sync] get_status {}: {:?}", txid, e);
                        if consecutive_rpc_errors >= 3 {
                            tracing::warn!(
                                "[sync] 3 consecutive status failures, \
                                 aborting maintenance (connection likely dropped)"
                            );
                            emit_log("status check: connection dropped, will retry next pass");
                            break;
                        }
                    }
                }
            }
            TransactionDataRequest::TransactionsInvolvingAddress(req) => {
                let is_ephemeral = req.block_range_end().is_none();
                if is_ephemeral {
                    // Privacy schedule: skip if not yet due. Cap to 1 per
                    // pass so we don't decorrelate poorly by burst-checking.
                    if let Some(scheduled) = req.request_at() {
                        if scheduled > now {
                            ephemeral_deferred += 1;
                            continue;
                        }
                    }
                    if ephemeral_processed_this_pass >= MAX_EPHEMERAL_CHECKS_PER_PASS {
                        ephemeral_deferred += 1;
                        continue;
                    }
                    ephemeral_processed_this_pass += 1;
                }
                match scan_address_transactions(db_data, params, lwd, &req).await {
                    Ok(found) => {
                        address_checks += 1;
                        address_txs_found += found;
                        processed += 1;
                        consecutive_rpc_errors = 0;
                        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
                    }
                    Err(e) => {
                        consecutive_rpc_errors += 1;
                        processed += 1;
                        tracing::info!("[sync] t-addr scan failed: {:?}", e);
                        emit_log(&format!(
                            "t-addr check: failed ({})",
                            trim_log_error(&format!("{:?}", e))
                        ));
                        if consecutive_rpc_errors >= 3 {
                            tracing::warn!(
                                "[sync] 3 consecutive t-addr scan failures, \
                                 aborting maintenance (connection likely dropped)"
                            );
                            emit_log("t-addr check: connection dropped, will retry next pass");
                            break;
                        }
                    }
                }
            }
        }
    }

    // Re-read the queue so we can split "blocking work" (what we surface
    // to users) from "ephemeral hygiene" (forever-cycling background
    // checks). The fallback `total - processed` only kicks in if the DB
    // read fails.
    let remaining_total = match db_data.transaction_data_requests() {
        Ok(reqs) => Some(reqs),
        Err(_) => None,
    };
    let remaining_count = remaining_total
        .as_ref()
        .map(|r| r.len())
        .unwrap_or_else(|| total.saturating_sub(processed));
    let remaining_blocking = remaining_total
        .as_ref()
        .map(|r| count_blocking_requests(r))
        .unwrap_or(remaining_count);

    let msg = format!(
        "enhanced {}, status {}, t-addr_checks {} ({} txs), skipped {}, \
         remaining {} (blocking {}, ephemeral_deferred {})",
        enhanced,
        status_checked,
        address_checks,
        address_txs_found,
        skipped,
        remaining_count,
        remaining_blocking,
        ephemeral_deferred
    );
    tracing::info!("[sync] {}", msg);
    emit_log(&msg);

    let mut p = SYNC_PROGRESS.lock().await;
    p.maintenance_queue_len = remaining_blocking as u32;
    if final_phase {
        p.phase = SYNC_PHASE_CAUGHT_UP.to_string();
    } else {
        p.phase = SYNC_PHASE_SCANNING.to_string();
    }
    drop(p);
    emit_progress_event("phase_changed", None, None).await;
    Ok(())
}

async fn fetch_and_decrypt_tx(
    db_data: &mut DbType,
    params: &Network,
    lwd: &mut CompactTxStreamerClient<tonic::transport::Channel>,
    db_data_path: &Path,
    db_cipher_key: &Option<String>,
    txid: TxId,
) -> Result<()> {
    let txid_short = short_txid(txid);
    emit_log(&format!(
        "enhance {}: fetching full transaction",
        txid_short
    ));
    let resp = lwd
        .get_transaction(TxFilter {
            block: None,
            index: 0,
            hash: txid.as_ref().to_vec(),
        })
        .await
        .map_err(|e| anyhow::anyhow!("get_transaction: {:?}", e))?;
    let raw = resp.into_inner();

    if raw.data.is_empty() {
        emit_log(&format!(
            "enhance {}: server returned no transaction data (not yet on chain)",
            txid_short
        ));
        return Err(anyhow::anyhow!(
            "Transaction {} not yet available from server",
            txid_short
        ));
    }

    let mined_height = if raw.height == 0 {
        None
    } else {
        Some(BlockHeight::from_u32(raw.height as u32))
    };
    emit_log(&format!(
        "enhance {}: raw={} bytes height={}",
        txid_short,
        raw.data.len(),
        raw.height
    ));

    // BranchId is needed to deserialize the transaction with the correct
    // consensus rules. Use the mined height when known, otherwise fall back to
    // the current chain tip's branch.
    let branch_height = mined_height
        .or_else(|| db_data.chain_height().ok().flatten().map(|h| h))
        .unwrap_or_else(|| {
            params
                .activation_height(zcash_protocol::consensus::NetworkUpgrade::Nu5)
                .unwrap_or(BlockHeight::from_u32(0))
        });
    let branch_id = BranchId::for_height(params, branch_height);
    let tx = Transaction::read(&raw.data[..], branch_id)
        .map_err(|e| anyhow::anyhow!("Transaction::read: {:?}", e))?;

    decrypt_and_store_transaction(params, db_data, &tx, mined_height)
        .map_err(|e| anyhow::anyhow!("decrypt_and_store_transaction: {:?}", e))?;
    let memo_rows =
        count_text_or_binary_memos_for_tx(db_data_path, db_cipher_key, txid).unwrap_or_default();
    emit_log(&format!(
        "enhance {}: stored transaction, memo rows={}",
        txid_short, memo_rows
    ));
    Ok(())
}

/// Respond to a `TransactionsInvolvingAddress` request by querying
/// lightwalletd for transactions that touch the given t-address in the given
/// block range, ingesting any new transactions, then notifying the SDK that
/// the address has been checked up to the requested end height.
///
/// Returns the number of transactions stored from this request.
async fn scan_address_transactions(
    db_data: &mut DbType,
    params: &Network,
    lwd: &mut CompactTxStreamerClient<tonic::transport::Channel>,
    request: &TransactionsInvolvingAddress,
) -> Result<usize> {
    use zcash_client_backend::proto::service::RawTransaction;

    let address_encoded = request
        .address()
        .to_zcash_address(params.network_type())
        .encode();
    let start = u32::from(request.block_range_start());
    // `block_range_end` is end-exclusive per the SDK contract. lightwalletd
    // treats the gRPC range as inclusive of both endpoints, so we query up to
    // `end - 1` and notify the SDK with that same height.
    let (end_exclusive, end_inclusive) = match request.block_range_end() {
        Some(end) => {
            let end_u32 = u32::from(end);
            (end_u32, end_u32.saturating_sub(1))
        }
        None => {
            let tip = db_data
                .chain_height()
                .ok()
                .flatten()
                .map(u32::from)
                .unwrap_or(start);
            (tip + 1, tip)
        }
    };

    if end_inclusive < start {
        // Nothing to check; still notify so the SDK clears the request.
        if let Err(e) =
            db_data.notify_address_checked(request.clone(), BlockHeight::from_u32(end_inclusive))
        {
            tracing::warn!("[sync] notify_address_checked failed: {:?}", e);
        }
        return Ok(0);
    }

    emit_log(&format!(
        "t-addr check: {} blocks {}..{}",
        short_address(&address_encoded),
        start,
        end_exclusive
    ));

    let filter = TransparentAddressBlockFilter {
        address: address_encoded,
        range: Some(BlockRange {
            start: Some(BlockId {
                height: start as u64,
                hash: Vec::new(),
            }),
            end: Some(BlockId {
                height: end_inclusive as u64,
                hash: Vec::new(),
            }),
            pool_types: vec![],
        }),
    };

    let mut stream = lwd
        .get_taddress_txids(filter)
        .await
        .map_err(|e| anyhow::anyhow!("get_taddress_txids: {:?}", e))?
        .into_inner();

    let mut stored = 0usize;
    while let Some(raw) = next_stream_message(&mut stream, "get_taddress_txids stream").await? {
        let RawTransaction { data, height } = raw;
        if data.is_empty() {
            continue;
        }
        let mined_height = if height == 0 {
            None
        } else {
            Some(BlockHeight::from_u32(height as u32))
        };
        let branch_height = mined_height
            .or_else(|| db_data.chain_height().ok().flatten())
            .unwrap_or_else(|| {
                params
                    .activation_height(zcash_protocol::consensus::NetworkUpgrade::Nu5)
                    .unwrap_or(BlockHeight::from_u32(0))
            });
        let branch_id = BranchId::for_height(params, branch_height);
        let tx = Transaction::read(&data[..], branch_id)
            .map_err(|e| anyhow::anyhow!("Transaction::read (t-addr): {:?}", e))?;
        decrypt_and_store_transaction(params, db_data, &tx, mined_height)
            .map_err(|e| anyhow::anyhow!("decrypt_and_store_transaction (t-addr): {:?}", e))?;
        stored += 1;
    }

    // Mark the address as checked up to `end_inclusive`, even if zero txs
    // were returned. The sqlite backend will reject mismatched heights with
    // NotificationMismatch, so we mirror its expectation exactly.
    if let Err(e) =
        db_data.notify_address_checked(request.clone(), BlockHeight::from_u32(end_inclusive))
    {
        tracing::warn!("[sync] notify_address_checked failed: {:?}", e);
        emit_log(&format!(
            "t-addr check: notify failed ({})",
            trim_log_error(&format!("{:?}", e))
        ));
    }

    emit_log(&format!(
        "t-addr check done: {} new txs in {}..{}",
        stored, start, end_exclusive
    ));
    Ok(stored)
}

fn short_address(addr: &str) -> String {
    if addr.len() <= 14 {
        addr.to_string()
    } else {
        format!("{}…{}", &addr[..6], &addr[addr.len() - 4..])
    }
}

fn short_txid(txid: TxId) -> String {
    let mut display = txid.as_ref().to_vec();
    display.reverse();
    let hex = hex::encode(display);
    hex[..hex.len().min(12)].to_string()
}

fn short_server_list(servers: &[String]) -> String {
    fn host(url: &str) -> &str {
        url.trim_start_matches("https://")
            .trim_start_matches("http://")
            .split('/')
            .next()
            .unwrap_or(url)
    }
    let hosts: Vec<&str> = servers.iter().map(|s| host(s.as_str())).collect();
    hosts.join(", ")
}

fn trim_log_error(message: &str) -> String {
    const MAX_LEN: usize = 96;
    if message.len() <= MAX_LEN {
        message.to_string()
    } else {
        format!("{}...", &message[..MAX_LEN])
    }
}

fn count_text_or_binary_memos_for_tx(
    db_data_path: &Path,
    db_cipher_key: &Option<String>,
    txid: TxId,
) -> Result<u32> {
    let conn = open_cipher_conn(db_data_path, db_cipher_key)?;
    let count = conn.query_row(
        "SELECT COUNT(*)
         FROM v_tx_outputs
         WHERE txid = ?1
           AND memo IS NOT NULL
           AND memo != X'F6'",
        rusqlite::params![txid.as_ref()],
        |row| row.get(0),
    )?;
    Ok(count)
}

/// One-shot recovery: any received note (sapling or orchard) whose `memo`
/// column is NULL was scanned via compact blocks but never enhanced with the
/// full transaction memo. Re-add these txids to `tx_retrieval_queue` so the
/// enhancement pass below will fetch the full tx and populate their memos.
///
/// `0xF6` rows are intentionally skipped: librustzcash writes that single byte
/// only after a successful decryption confirmed the memo was empty, so there
/// is nothing to recover for those.
fn requeue_unenhanced_notes(db_data_path: &Path, db_cipher_key: &Option<String>) -> Result<()> {
    let conn = open_cipher_conn(db_data_path, db_cipher_key)?;

    // Count notes with NULL memo (need enhancement) vs 0xF6 (confirmed empty)
    let null_count: u32 = conn
        .query_row(
            "SELECT COUNT(*) FROM (
            SELECT transaction_id FROM sapling_received_notes WHERE memo IS NULL
            UNION
            SELECT transaction_id FROM orchard_received_notes WHERE memo IS NULL
        )",
            [],
            |row| row.get(0),
        )
        .unwrap_or(0);

    let total_notes: u32 = conn
        .query_row(
            "SELECT (SELECT COUNT(*) FROM sapling_received_notes) +
                (SELECT COUNT(*) FROM orchard_received_notes)",
            [],
            |row| row.get(0),
        )
        .unwrap_or(0);

    let queue_len: u32 = conn
        .query_row("SELECT COUNT(*) FROM tx_retrieval_queue", [], |row| {
            row.get(0)
        })
        .unwrap_or(0);

    tracing::info!(
        "[sync] memo stats: {} total notes, {} with NULL memo, {} already in queue",
        total_notes,
        null_count,
        queue_len
    );

    let added = conn.execute(
        "INSERT OR IGNORE INTO tx_retrieval_queue (txid, query_type)
         SELECT t.txid, 1
         FROM transactions t
         JOIN (
             SELECT transaction_id FROM sapling_received_notes WHERE memo IS NULL
             UNION
             SELECT transaction_id FROM orchard_received_notes WHERE memo IS NULL
         ) r ON r.transaction_id = t.id_tx
         WHERE t.mined_height IS NOT NULL",
        [],
    )?;
    if added > 0 {
        tracing::info!(
            "[sync] queued {} unenhanced received tx(s) for memo recovery",
            added
        );
        emit_log(&format!("queued {} txs for memo recovery", added));
    } else {
        tracing::info!("[sync] no unenhanced notes to queue");
    }
    Ok(())
}

fn clear_retrieval_queue_entry(
    db_data_path: &Path,
    db_cipher_key: &Option<String>,
    txid: TxId,
) -> Result<bool> {
    let conn = open_cipher_conn(db_data_path, db_cipher_key)?;
    let deleted = conn.execute(
        "DELETE FROM tx_retrieval_queue WHERE txid = ?1",
        rusqlite::params![txid.as_ref()],
    )?;
    Ok(deleted > 0)
}

async fn fetch_status(
    db_data: &mut DbType,
    lwd: &mut CompactTxStreamerClient<tonic::transport::Channel>,
    txid: TxId,
) -> Result<()> {
    let resp = lwd
        .get_transaction(TxFilter {
            block: None,
            index: 0,
            hash: txid.as_ref().to_vec(),
        })
        .await
        .map_err(|e| anyhow::anyhow!("get_transaction status: {:?}", e))?;

    let raw = resp.into_inner();
    let status = if raw.data.is_empty() {
        // Don't immediately mark as unrecognized -- server may be behind.
        // Return early without changing status; the SDK will re-request on next pass.
        tracing::debug!(
            "[sync] fetch_status {}: not yet available from server, deferring",
            txid
        );
        return Ok(());
    } else if raw.height == 0 {
        TransactionStatus::NotInMainChain
    } else {
        TransactionStatus::Mined(BlockHeight::from_u32(raw.height as u32))
    };
    db_data
        .set_transaction_status(txid, status)
        .map_err(|e| anyhow::anyhow!("set_transaction_status: {:?}", e))?;
    Ok(())
}

async fn scan_mempool_once(
    lwd: &mut CompactTxStreamerClient<tonic::transport::Channel>,
    db_data: &mut DbType,
    params: &Network,
    db_data_path: &Path,
    db_cipher_key: &Option<String>,
    latest_height: u32,
) -> Result<()> {
    let mempool_height = BlockHeight::from_u32(latest_height.saturating_add(1));
    let branch_id = BranchId::for_height(params, mempool_height);
    let mut stream = lwd
        .get_mempool_stream(Empty {})
        .await
        .map_err(|e| anyhow::anyhow!("get_mempool_stream: {:?}", e))?
        .into_inner();

    let mut processed = 0u32;
    const MAX_MEMPOOL_TXS_PER_PASS: u32 = 50;

    while processed < MAX_MEMPOOL_TXS_PER_PASS {
        let next = match tokio::time::timeout(Duration::from_millis(250), stream.message()).await {
            Ok(result) => result.map_err(|e| anyhow::anyhow!("mempool stream: {:?}", e))?,
            Err(_) => break,
        };
        let Some(raw) = next else {
            break;
        };
        if raw.data.is_empty() {
            continue;
        }
        processed += 1;

        let tx = match Transaction::read(&raw.data[..], branch_id) {
            Ok(tx) => tx,
            Err(e) => {
                tracing::debug!("[sync] mempool tx decode skipped: {:?}", e);
                continue;
            }
        };
        let txid = tx.txid();

        if let Err(e) = decrypt_and_store_transaction(params, db_data, &tx, Some(mempool_height)) {
            tracing::debug!("[sync] mempool decrypt skipped {}: {:?}", txid, e);
            continue;
        }

        if transaction_exists(db_data_path, db_cipher_key, txid)? {
            emit_transaction_event(txid.to_string(), "pending");
        }
    }

    if processed > 0 {
        tracing::debug!("[sync] processed {} mempool tx(s)", processed);
    }
    Ok(())
}

fn transaction_exists(
    db_data_path: &Path,
    db_cipher_key: &Option<String>,
    txid: TxId,
) -> Result<bool> {
    let conn = open_cipher_conn(db_data_path, db_cipher_key)?;
    let found = conn
        .query_row(
            "SELECT 1 FROM transactions WHERE txid = ? LIMIT 1",
            rusqlite::params![txid.as_ref().to_vec()],
            |_| Ok(()),
        )
        .optional()?
        .is_some();
    Ok(found)
}

struct DownloadedRange {
    blocks: Vec<CompactBlock>,
    chain_state: zcash_client_backend::data_api::chain::ChainState,
    range_start: BlockHeight,
    range_end: BlockHeight,
    download_ms: u64,
}

struct PrefetchedRange {
    scan_range: zcash_client_backend::data_api::scanning::ScanRange,
    downloaded: Option<DownloadedRange>,
    /// True if the producer had to fall back to the primary server after
    /// the assigned alternate failed for this batch. Surfaced into the
    /// `fallbacks` perf counter so we can see at a glance how often
    /// alternates are misbehaving.
    fell_back_to_primary: bool,
}

#[derive(Clone, Copy, Debug)]
struct BatchStats {
    blocks: u32,
    work_units: u32,
    download_ms: u64,
}

impl DownloadedRange {
    fn stats(&self) -> BatchStats {
        BatchStats {
            blocks: self.blocks.len() as u32,
            work_units: count_work_units(&self.blocks) as u32,
            download_ms: self.download_ms,
        }
    }
}

#[derive(Default, Debug)]
struct SessionPerf {
    batches: u64,
    blocks: u64,
    work_units: u64,
    download_ms: u64,
    scan_ms: u64,
    restarted_batches: u64,
    multi_server_fallbacks: u64,
    last_summary_refresh: Option<Instant>,
}

impl SessionPerf {
    fn record(&mut self, stats: BatchStats, scan_elapsed_ms: u64, outcome: &ScanOutcome) {
        self.batches += 1;
        self.blocks += stats.blocks as u64;
        self.work_units += stats.work_units as u64;
        self.download_ms += stats.download_ms;
        self.scan_ms += scan_elapsed_ms;
        if matches!(outcome, ScanOutcome::Restarted) {
            self.restarted_batches += 1;
        }

        if self.batches % 10 == 0 {
            tracing::info!(
                "[sync][perf] batches={} blocks={} units={} avg_download_ms={} avg_scan_ms={}",
                self.batches,
                self.blocks,
                self.work_units,
                self.download_ms / self.batches,
                self.scan_ms / self.batches
            );
        }
    }

    async fn update_snapshot(&self, adaptive_batch_size: u32, runtime: &SyncRuntimeConfig) {
        let avg_download_ms = if self.batches == 0 {
            0
        } else {
            self.download_ms / self.batches
        };
        let avg_scan_ms = if self.batches == 0 {
            0
        } else {
            self.scan_ms / self.batches
        };
        let work_units_per_second = if self.scan_ms == 0 {
            0.0
        } else {
            (self.work_units as f64) / (self.scan_ms as f64 / 1000.0)
        };
        let mut snapshot = SYNC_PERF.lock().await;
        *snapshot = SyncPerfSnapshot {
            batches: self.batches,
            blocks: self.blocks,
            work_units: self.work_units,
            download_ms: self.download_ms,
            scan_ms: self.scan_ms,
            restarted_batches: self.restarted_batches,
            avg_download_ms,
            avg_scan_ms,
            work_units_per_second,
            adaptive_batch_size,
            prefetch_depth: runtime.prefetch_depth,
            multi_server_enabled: !runtime.auto_select_servers
                && runtime.prefetch_depth > 0
                && !runtime.alternate_servers.is_empty(),
            multi_server_fallbacks: self.multi_server_fallbacks,
        };
    }

    fn record_fallback(&mut self) {
        self.multi_server_fallbacks += 1;
    }

    fn log_summary(&self) {
        if self.batches == 0 {
            tracing::info!("[sync][perf] no scan batches in this session");
            return;
        }
        let avg_download_ms = self.download_ms / self.batches;
        let avg_scan_ms = self.scan_ms / self.batches;
        let units_per_sec = if self.scan_ms == 0 {
            0.0
        } else {
            (self.work_units as f64) / (self.scan_ms as f64 / 1000.0)
        };
        tracing::info!(
            "[sync][perf][session] batches={} blocks={} units={} avg_download_ms={} avg_scan_ms={} units_per_sec={:.1} restarted_batches={}",
            self.batches,
            self.blocks,
            self.work_units,
            avg_download_ms,
            avg_scan_ms,
            units_per_sec,
            self.restarted_batches
        );
        emit_log(&format!(
            "perf: batches={} blocks={} units={} avg_dl={}ms avg_scan={}ms units/s={:.1} restarts={} fallbacks={}",
            self.batches,
            self.blocks,
            self.work_units,
            avg_download_ms,
            avg_scan_ms,
            units_per_sec,
            self.restarted_batches,
            self.multi_server_fallbacks,
        ));
    }
}

/// Default block-count limit. Actual memory depends on block density;
/// this is not a byte budget or a guarantee about mobile peak memory.
const SCAN_BATCH_SIZE: u32 = 1_000;
const MIN_BATCH_SIZE: u32 = 100;
const SLOW_SCAN_MS: u64 = 3_000;

/// Zcash mainnet "sandblasting" attack window. Blocks in this range
/// carry roughly an order of magnitude more shielded outputs than
/// surrounding blocks, so scanning them at the full batch size spikes
/// memory and stretches per-batch wall time past the slow-scan
/// threshold. We auto-drop to a much smaller batch when the current
/// scan range touches this window. Mirrors the constant in
/// zcash-android-wallet-sdk and Vizor.
const SANDBLASTING_START: u32 = 1_710_000;
const SANDBLASTING_END: u32 = 2_050_000;
const SANDBLASTING_BATCH_SIZE: u32 = 100;

/// Clamp at both density-window boundaries; small batches apply only inside it.
fn batch_end(base: u32, start: BlockHeight, end: BlockHeight, params: &Network) -> BlockHeight {
    let start = u32::from(start);
    let end = u32::from(end);
    let (size, boundary) = if *params == Network::MainNetwork && start < SANDBLASTING_START {
        (base, end.min(SANDBLASTING_START))
    } else if *params == Network::MainNetwork && start < SANDBLASTING_END {
        (base.min(SANDBLASTING_BATCH_SIZE), end.min(SANDBLASTING_END))
    } else {
        (base, end)
    };
    BlockHeight::from_u32(start.saturating_add(size.max(1)).min(boundary))
}

fn adjust_batch_size(current: u32, scan_elapsed_ms: u64) -> u32 {
    if scan_elapsed_ms > SLOW_SCAN_MS {
        (current / 2).max(MIN_BATCH_SIZE)
    } else {
        current
    }
}

/// Producer task for the prefetch pipeline. Downloads block ranges
/// sequentially on the selected peer (or rotates explicitly configured peers),
/// and emits each downloaded batch to the scan
/// consumer in order via `tx` (its capacity, `runtime.prefetch_depth`,
/// is the pipeline depth — we can stay that many batches ahead of the
/// scanner before blocking).
///
/// Downloads overlap SDK scanning. A bounded queue limits lookahead; both
/// stream idle and whole-batch deadlines prevent a stalled peer from blocking
/// progress indefinitely. Performance depends on block density and network.
///
/// Returns `Ok(())` early when the consumer drops `rx` (sync stopping
/// or pass restarting). One failed download on an alternate falls back
/// to the primary; if the primary also fails, the error propagates up
/// and `sync_forever` handles retry / backoff.
async fn fetch_prefetched_ranges(
    primary_server_url: String,
    primary_client: CompactTxStreamerClient<tonic::transport::Channel>,
    mut plan: BatchPlan,
    runtime: SyncRuntimeConfig,
    batch_size: std::sync::Arc<AtomicU32>,
    tx: mpsc::Sender<Result<PrefetchedRange>>,
) -> Result<()> {
    if plan.pending.is_empty() {
        return Ok(());
    }

    // Automatic mode keeps a healthy selected peer; sync_forever rotates on
    // failure. Explicit multi-server mode preserves round-robin downloads.
    let rotate_peers = !runtime.auto_select_servers;
    // Build the rotation: primary first, then unique alternates.
    let mut servers = vec![primary_server_url.clone()];
    for server in runtime.alternate_servers {
        if server != primary_server_url && !servers.iter().any(|s| s == &server) {
            servers.push(server);
        }
    }

    // Reuse the primary's established channel. Connect alternates only when
    // their slot is reached, so cold/failed peers never delay the first batch.
    let mut clients = std::collections::HashMap::new();
    clients.insert(primary_server_url.clone(), primary_client);

    let mut batch_idx = 0;
    while let Some(scan_range) = plan.next_batch(batch_size.load(Ordering::Acquire)) {
        check_cancel()?;
        let server_url = servers[if rotate_peers {
            batch_idx % servers.len()
        } else {
            0
        }]
        .clone();
        let first = async {
            if !clients.contains_key(&server_url) {
                let client = tokio::time::timeout(
                    Duration::from_secs(10),
                    connect_lwd_maybe_tor(&server_url),
                )
                .await
                .map_err(|_| anyhow::anyhow!("alternate connection timed out"))??;
                clients.insert(server_url.clone(), client);
            }
            let mut client = clients[&server_url].clone();
            download_range(&mut client, &scan_range).await
        }
        .await;

        let (downloaded, fell_back_to_primary) = match first {
            Ok(downloaded) => (downloaded, false),
            Err(error) if server_url != primary_server_url => {
                // Quarantine a failed peer for this pass instead of paying its
                // timeout repeatedly. The primary retains responsibility for retries.
                servers.retain(|server| server != &server_url);
                clients.remove(&server_url);
                tracing::warn!(
                    "[sync] alternate {} failed: {}; retrying on primary",
                    server_url,
                    error
                );
                emit_log(&format!(
                    "multi-server: batch {} fallback to primary ({})",
                    batch_idx, error
                ));
                let mut primary = clients[&primary_server_url].clone();
                (download_range(&mut primary, &scan_range).await?, true)
            }
            Err(error) => return Err(error),
        };

        let send_result = Ok(PrefetchedRange {
            scan_range,
            downloaded,
            fell_back_to_primary,
        });
        if tx.send(send_result).await.is_err() {
            // Consumer hung up (sync stopping or pass restarting).
            return Ok(());
        }
        batch_idx += 1;
    }

    Ok(())
}

fn process_prefetched_range(
    params: &Network,
    db_data: &mut DbType,
    batch_size: &mut u32,
    perf: &mut SessionPerf,
    current_range: &ScanRange,
    downloaded: Option<DownloadedRange>,
) -> Result<ScanOutcome> {
    let batch_stats = downloaded.as_ref().map(|d| d.stats());
    let scan_started = Instant::now();
    let outcome = tokio::task::block_in_place(|| {
        process_downloaded_range(params, db_data, current_range, downloaded)
    })?;
    let scan_elapsed_ms = scan_started.elapsed().as_millis() as u64;
    *batch_size = adjust_batch_size(*batch_size, scan_elapsed_ms)
        .min(DOWNLOAD_BATCH_LIMIT.load(Ordering::Acquire));
    if let Some(stats) = batch_stats {
        perf.record(stats, scan_elapsed_ms, &outcome);
    }
    Ok(outcome)
}

async fn handle_scan_outcome(
    outcome: ScanOutcome,
    perf: &mut SessionPerf,
    db_data: &mut DbType,
    params: &Network,
    lwd: &mut CompactTxStreamerClient<tonic::transport::Channel>,
    db_data_path: &Path,
    db_cipher_key: &Option<String>,
) -> Result<bool> {
    match outcome {
        ScanOutcome::Restarted => {
            update_synced_progress_after_restart(db_data).await;
            Ok(true)
        }
        ScanOutcome::Scanned {
            synced_height,
            notes_found,
        } => {
            update_synced_progress(db_data, synced_height, false).await;
            // WalletSummary computes all balances and subtree estimates. Keep it
            // off the per-batch hot path, especially the 100-block spam-era batches.
            // Committed heights and block counts still update after every batch.
            if perf.last_summary_refresh.is_none_or(|last| last.elapsed() >= Duration::from_secs(15)) {
                let started = Instant::now();
                refresh_scan_progress(db_data).await;
                perf.last_summary_refresh = Some(Instant::now());
                emit_log(&format!("progress summary refreshed in {} ms", started.elapsed().as_millis()));
            }
            if notes_found > 0 {
                let _ =
                    enhance_transactions_inline(db_data, params, lwd, db_data_path, db_cipher_key)
                        .await;
            }
            emit_event(SyncEventInfo {
                event_type: "balance_maybe_changed".to_string(),
                scanning_up_to: 0,
                phase: None,
                synced_height,
                latest_height: 0,
                maintenance_queue_len: 0,
                txid: None,
                status: None,
                scope: None,
                message: None,
                scan_progress_num: 0,
                scan_progress_den: 0,
                recovery_progress_num: 0,
                recovery_progress_den: 0,
                blocks_scanned: 0,
                blocks_total: 0,
            });
            Ok(false)
        }
        ScanOutcome::NothingToScan => Ok(false),
    }
}

// Use observed throughput when available, while always shrinking the failed range.
fn smaller_download_batch(requested: u32, received: u32) -> u32 {
    let half = (requested / 2).max(1);
    let throughput = if received == 0 {
        half
    } else {
        (received / 2).max(1)
    };
    half.min(throughput).max(16).min(requested.max(1))
}

/// Download independent block and tree-state requests on the same HTTP/2 channel.
async fn download_range(
    lwd: &mut CompactTxStreamerClient<tonic::transport::Channel>,
    scan_range: &zcash_client_backend::data_api::scanning::ScanRange,
) -> Result<Option<DownloadedRange>> {
    let range_start = scan_range.block_range().start;
    let range_end = scan_range.block_range().end;

    tracing::info!(
        "[sync] downloading {}..{} priority={:?}",
        u32::from(range_start),
        u32::from(range_end),
        scan_range.priority()
    );

    let download_started = Instant::now();
    if range_start == range_end {
        return Ok(None);
    }
    let mut tree_client = lwd.clone();
    let received = AtomicU32::new(0);
    let tree_ready = AtomicBool::new(false);
    emit_log(&format!(
        "download start range={}..{} blocks={} priority={:?}",
        u32::from(range_start),
        u32::from(range_end),
        scan_range.len(),
        scan_range.priority()
    ));
    let result = tokio::time::timeout(BATCH_DOWNLOAD_DEADLINE, async {
        tokio::try_join!(
            download_blocks(lwd, range_start, range_end, &received),
            async {
                let state = download_chain_state(&mut tree_client, range_start).await?;
                tree_ready.store(true, Ordering::Relaxed);
                Ok::<_, anyhow::Error>(state)
            },
        )
    })
    .await;
    let (blocks, chain_state) = match result {
        Ok(result) => result?,
        Err(_) => {
            let count = received.load(Ordering::Relaxed);
            let next = smaller_download_batch(scan_range.len() as u32, count);
            DOWNLOAD_BATCH_LIMIT.fetch_min(next, Ordering::AcqRel);
            return Err(anyhow::anyhow!(
                "download timeout: range={}..{} received={}/{} tree_ready={} elapsed_s={} next_batch={}",
                u32::from(range_start), u32::from(range_end), count, scan_range.len(),
                tree_ready.load(Ordering::Relaxed), BATCH_DOWNLOAD_DEADLINE.as_secs(),
                DOWNLOAD_BATCH_LIMIT.load(Ordering::Acquire)
            ));
        }
    };
    // Empty or truncated server responses must fail, never count as completed work.
    validate_blocks_for_range(&blocks, range_start, range_end)?;
    anyhow::ensure!(
        u32::from(chain_state.block_height()).checked_add(1) == Some(u32::from(range_start)),
        "tree state does not precede requested range"
    );
    let download_ms = download_started.elapsed().as_millis() as u64;

    Ok(Some(DownloadedRange {
        blocks,
        chain_state,
        range_start,
        range_end,
        download_ms,
    }))
}

enum ScanOutcome {
    NothingToScan,
    Scanned {
        synced_height: u32,
        notes_found: u32,
    },
    Restarted,
}

/// Attempt to truncate the wallet DB to `target`. If the library rejects the
/// height as too old (`RequestedRewindInvalid`), fall back to the
/// `safe_rewind_height` it provides. Uses both typed matching and string
/// matching as a safety net against version mismatches.
fn safe_truncate_to_height_sync(db_data: &mut DbType, target: BlockHeight) -> Result<BlockHeight> {
    match db_data.truncate_to_height(target) {
        Ok(_) => Ok(target),
        Err(SqliteClientError::RequestedRewindInvalid {
            safe_rewind_height,
            requested_height,
        }) => apply_safe_rewind(db_data, safe_rewind_height, requested_height, target),
        Err(e) => {
            let err_str = format!("{:?}", e);
            if let Some(safe) = parse_safe_rewind_height(&err_str) {
                tracing::warn!(
                    "[sync] rewind to {} rejected (string fallback), using safe height {}",
                    u32::from(target),
                    u32::from(safe)
                );
                db_data
                    .truncate_to_height(safe)
                    .map_err(|e2| anyhow::anyhow!("truncate_to_height (safe): {:?}", e2))?;
                Ok(safe)
            } else if err_str.contains("RequestedRewindInvalid") {
                tracing::warn!(
                    "[sync] rewind to {} rejected but couldn't parse safe height, skipping: {}",
                    u32::from(target),
                    err_str
                );
                Ok(target)
            } else {
                Err(anyhow::anyhow!("truncate_to_height: {:?}", e))
            }
        }
    }
}

fn apply_safe_rewind(
    db_data: &mut DbType,
    safe_rewind_height: Option<BlockHeight>,
    requested_height: BlockHeight,
    fallback: BlockHeight,
) -> Result<BlockHeight> {
    if let Some(safe) = safe_rewind_height {
        tracing::warn!(
            "[sync] rewind to {} rejected, using safe height {}",
            u32::from(requested_height),
            u32::from(safe)
        );
        db_data
            .truncate_to_height(safe)
            .map_err(|e| anyhow::anyhow!("truncate_to_height (safe): {:?}", e))?;
        Ok(safe)
    } else {
        tracing::warn!(
            "[sync] rewind to {} rejected, no safe height available",
            u32::from(requested_height)
        );
        Ok(fallback)
    }
}

/// Parse `safe_rewind_height` from the Debug representation of
/// `RequestedRewindInvalid` as a fallback when typed matching fails.
fn parse_safe_rewind_height(err_str: &str) -> Option<BlockHeight> {
    let marker = "safe_rewind_height: Some(BlockHeight(";
    let start = err_str.find(marker)? + marker.len();
    let end = start + err_str[start..].find(')')?;
    let height: u32 = err_str[start..end].parse().ok()?;
    Some(BlockHeight::from_u32(height))
}

/// Scan the bounded in-memory batch through the SDK and handle reorgs.
fn process_downloaded_range(
    params: &Network,
    db_data: &mut DbType,
    scan_range: &zcash_client_backend::data_api::scanning::ScanRange,
    downloaded: Option<DownloadedRange>,
) -> Result<ScanOutcome> {
    let downloaded = match downloaded {
        Some(d) => d,
        None => return Ok(ScanOutcome::NothingToScan),
    };

    validate_blocks_for_range(
        &downloaded.blocks,
        downloaded.range_start,
        downloaded.range_end,
    )?;
    anyhow::ensure!(
        downloaded.range_start == scan_range.block_range().start
            && downloaded.range_end == scan_range.block_range().end,
        "downloaded range does not match scheduled scan range"
    );
    anyhow::ensure!(
        u32::from(downloaded.chain_state.block_height()).checked_add(1)
            == Some(u32::from(downloaded.range_start)),
        "tree state does not precede downloaded range"
    );
    let block_source = MemoryBlockSource::new(downloaded.blocks);

    let scan_len = scan_range.len();
    let priority = scan_range.priority();
    let scan_result = scan_cached_blocks(
        params,
        &block_source,
        db_data,
        downloaded.range_start,
        &downloaded.chain_state,
        scan_len,
    );

    match scan_result {
        Ok(summary) => {
            let scanned_end = u32::from(summary.scanned_range().end);
            let notes =
                summary.received_sapling_note_count() + summary.received_orchard_note_count();
            tracing::info!(
                "[sync] scanned up to {}, {} notes found",
                scanned_end,
                notes
            );

            let latest_ranges = db_data
                .suggest_scan_ranges()
                .map_err(|e| anyhow::anyhow!("suggest_scan_ranges: {:?}", e))?;

            // Only restart when a Verify range appears (real reorg risk).
            // A new ChainTip just means the chain advanced while we were
            // scanning — that's normal, the next outer pass will pick it
            // up. Restarting on every ChainTip move starves the Historic
            // backlog and prevents fully_scanned_height from advancing.
            if priority != ScanPriority::Verify {
                if let Some(verify) = latest_ranges
                    .iter()
                    .find(|r| r.priority() == ScanPriority::Verify)
                {
                    tracing::info!(
                        "[sync] verify range appeared at {:?} while scanning {:?}, restarting",
                        verify.block_range(),
                        priority
                    );
                    emit_log(&format!(
                        "scan restart: new Verify range {}..{} appeared while scanning {:?}",
                        u32::from(verify.block_range().start),
                        u32::from(verify.block_range().end),
                        priority
                    ));
                    return Ok(ScanOutcome::Restarted);
                }
            }

            emit_log(&format!(
                "scanned range {}..{} priority={:?} committed_candidate={}",
                u32::from(scan_range.block_range().start),
                u32::from(scan_range.block_range().end),
                priority,
                scanned_end
            ));

            Ok(ScanOutcome::Scanned {
                synced_height: scanned_end,
                notes_found: notes as u32,
            })
        }
        Err(ChainError::Scan(err)) if err.is_continuity_error() => {
            let err_height = u32::from(err.at_height());
            let rewind_height = err.at_height().saturating_sub(10);
            let actual_rewind = safe_truncate_to_height_sync(db_data, rewind_height)?;

            // If the SDK can't rewind below the conflict point (typically
            // because there are spendable notes there), we will keep getting
            // the same continuity error forever. Track this so the outer
            // pass loop can break out and tell the user.
            let actual = u32::from(actual_rewind);
            let stuck = actual >= err_height.saturating_sub(1);

            tracing::info!(
                "[sync] reorg at {}, rewinding to {} (actual {})",
                err_height,
                u32::from(rewind_height),
                actual
            );
            emit_log(&format!(
                "scan continuity restart at {}, rewinding to {} (actual {}){}",
                err_height,
                u32::from(rewind_height),
                actual,
                if stuck {
                    " — wallet won't allow deeper rewind"
                } else {
                    ""
                }
            ));

            if stuck {
                let prev_height = STUCK_REORG_HEIGHT.load(Ordering::SeqCst);
                if prev_height == err_height {
                    STUCK_REORG_COUNT.fetch_add(1, Ordering::SeqCst);
                } else {
                    STUCK_REORG_HEIGHT.store(err_height, Ordering::SeqCst);
                    STUCK_REORG_COUNT.store(1, Ordering::SeqCst);
                }
            } else {
                STUCK_REORG_HEIGHT.store(0, Ordering::SeqCst);
                STUCK_REORG_COUNT.store(0, Ordering::SeqCst);
            }

            Ok(ScanOutcome::Restarted)
        }
        Err(e) => Err(anyhow::anyhow!("scan error: {:?}", e)),
    }
}

/// Plan only the next download, so scanner feedback applies within the current
/// pass. Already-prefetched batches remain valid and are consumed in order.
struct BatchPlan {
    pending: std::collections::VecDeque<ScanRange>,
    params: Network,
}

impl BatchPlan {
    fn next_batch(&mut self, batch_size: u32) -> Option<ScanRange> {
        let batch_size = batch_size.min(DOWNLOAD_BATCH_LIMIT.load(Ordering::Acquire));
        while let Some(range) = self.pending.pop_front() {
            if range.is_empty() {
                continue;
            }
            let end = batch_end(
                batch_size,
                range.block_range().start,
                range.block_range().end,
                &self.params,
            );
            if let Some((current, next)) = range.split_at(end) {
                self.pending.push_front(next);
                return Some(current);
            }
            return Some(range);
        }
        None
    }
}

#[cfg(test)]
fn split_into_batches(range: ScanRange, batch_size: u32, params: &Network) -> Vec<ScanRange> {
    let mut plan = BatchPlan {
        pending: [range].into(),
        params: *params,
    };
    std::iter::from_fn(|| plan.next_batch(batch_size)).collect()
}

fn count_work_units(blocks: &[CompactBlock]) -> usize {
    blocks
        .iter()
        .map(|b| {
            b.vtx
                .iter()
                .map(|tx| {
                    tx.spends.len()
                        + tx.outputs.len()
                        + tx.actions.len()
                        + tx.ironwood_actions.len()
                })
                .sum::<usize>()
        })
        .sum()
}

fn validate_blocks_for_range(
    blocks: &[CompactBlock],
    range_start: BlockHeight,
    range_end: BlockHeight,
) -> Result<()> {
    let mut expected = u32::from(range_start);
    let end = u32::from(range_end);
    for block in blocks {
        let height = u32::try_from(block.height)
            .map_err(|_| anyhow::anyhow!("compact block height exceeds u32: {}", block.height))?;
        if height != expected || height >= end {
            return Err(anyhow::anyhow!(
                "compact block height mismatch: expected {}, got {}",
                expected,
                height
            ));
        }
        expected += 1;
    }
    if expected != end {
        return Err(anyhow::anyhow!(
            "compact block range ended at {}, expected {}",
            expected,
            end
        ));
    }
    Ok(())
}

// ---------------------------------------------------------------------------
// Incremental subtree roots, retaining the overlap selected by the SDK.
// ---------------------------------------------------------------------------

async fn download_subtree_roots<H: HashSer>(
    mut lwd: CompactTxStreamerClient<tonic::transport::Channel>,
    protocol: ShieldedProtocol,
    start_index: u64,
) -> Result<Vec<CommitmentTreeRoot<H>>> {
    let request = GetSubtreeRootsArg {
        start_index: u32::try_from(start_index)?,
        shielded_protocol: protocol as i32,
        ..Default::default()
    };
    tokio::time::timeout(STREAM_IDLE_TIMEOUT, async {
        let mut stream = lwd.get_subtree_roots(request).await?.into_inner();
        let mut roots = Vec::new();
        while let Some(root) = next_stream_message(&mut stream, "subtree roots").await? {
            check_cancel()?;
            let height = u32::try_from(root.completing_block_height)?;
            roots.push(CommitmentTreeRoot::from_parts(
                BlockHeight::from_u32(height),
                H::read(&root.root_hash[..])?,
            ));
        }
        Ok(roots)
    })
    .await
    .map_err(|_| anyhow::anyhow!("subtree roots {:?}: timed out", protocol))?
}

async fn update_subtree_roots(
    lwd: &mut CompactTxStreamerClient<tonic::transport::Channel>,
    db_data: &mut DbType,
    params: &Network,
    tip: BlockHeight,
) -> Result<()> {
    // SDK indices overlap the most recent complete shard to detect divergence;
    // do not derive offsets by counting rows or skip the overlap on reorgs.
    let summary = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        db_data.get_wallet_summary(ConfirmationsPolicy::default())
    }))
    .ok()
    .and_then(|result| result.ok())
    .flatten();
    let (sapling_start, orchard_start, ironwood_start) = summary
        .as_ref()
        .map(|summary| {
            (
                summary.next_sapling_subtree_index(),
                summary.next_orchard_subtree_index(),
                summary.next_ironwood_subtree_index(),
            )
        })
        .unwrap_or((0, 0, 0));
    let (sapling, orchard, ironwood) = tokio::try_join!(
        download_subtree_roots::<sapling_crypto::Node>(
            lwd.clone(),
            ShieldedProtocol::Sapling,
            sapling_start
        ),
        download_subtree_roots::<orchard::tree::MerkleHashOrchard>(
            lwd.clone(),
            ShieldedProtocol::Orchard,
            orchard_start
        ),
        async {
            if params.is_nu_active(NetworkUpgrade::Nu6_3, tip) {
                download_subtree_roots::<orchard::tree::MerkleHashOrchard>(
                    lwd.clone(),
                    ShieldedProtocol::Ironwood,
                    ironwood_start,
                )
                .await
            } else {
                Ok(Vec::new())
            }
        },
    )?;
    check_cancel()?;
    if !sapling.is_empty() {
        db_data
            .put_sapling_subtree_roots(sapling_start, &sapling)
            .map_err(|e| anyhow::anyhow!("put sapling roots: {:?}", e))?;
    }
    if !orchard.is_empty() {
        db_data
            .put_orchard_subtree_roots(orchard_start, &orchard)
            .map_err(|e| anyhow::anyhow!("put orchard roots: {:?}", e))?;
    }
    if !ironwood.is_empty() {
        db_data
            .put_ironwood_subtree_roots(ironwood_start, &ironwood)
            .map_err(|e| anyhow::anyhow!("put ironwood roots: {:?}", e))?;
    }
    emit_log(&format!(
        "subtree roots: sapling={} from {}, orchard={} from {}, ironwood={} from {}",
        sapling.len(),
        sapling_start,
        orchard.len(),
        orchard_start,
        ironwood.len(),
        ironwood_start
    ));
    Ok(())
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

type DbType = WalletDb<
    rusqlite::Connection,
    Network,
    zcash_client_sqlite::util::SystemClock,
    rand::rngs::OsRng,
>;

/// Refresh scan/recovery progress ratios from the wallet summary.
async fn refresh_scan_progress(db_data: &mut DbType) {
    let summary = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        db_data.get_wallet_summary(ConfirmationsPolicy::default())
    }))
    .ok()
    .and_then(|r| r.ok())
    .flatten();

    if let Some(summary) = summary {
        let progress = summary.progress();
        let scan = progress.scan();
        let mut p = SYNC_PROGRESS.lock().await;
        p.scan_progress_num = *scan.numerator();
        p.scan_progress_den = *scan.denominator();
        if let Some(recovery) = progress.recovery() {
            p.recovery_progress_num = *recovery.numerator();
            p.recovery_progress_den = *recovery.denominator();
        }
    }
}

fn summarize_scan_ranges(ranges: &[ScanRange]) -> String {
    if ranges.is_empty() {
        return "[]".to_string();
    }
    let total = ranges.len();
    let parts: Vec<String> = ranges
        .iter()
        .take(8)
        .map(|r| {
            format!(
                "{:?} {}..{} ({} blocks)",
                r.priority(),
                u32::from(r.block_range().start),
                u32::from(r.block_range().end),
                r.len()
            )
        })
        .collect();
    if total > 8 {
        format!("[{}, ...({} total)]", parts.join(" | "), total)
    } else {
        format!("[{}]", parts.join(" | "))
    }
}

fn wallet_fully_scanned_height(db_data: &mut DbType) -> Option<u32> {
    // The SDK summary uses the same metadata, falling back to birthday - 1.
    // Asking for the full summary here recomputed balances several times per batch.
    match db_data.block_fully_scanned().ok()? {
        Some(block) => Some(u32::from(block.block_height())),
        None => db_data.get_wallet_birthday().ok()?.map(|h| u32::from(h).saturating_sub(1)),
    }
}

async fn update_synced_progress(db_data: &mut DbType, fallback_height: u32, allow_regress: bool) {
    let height = wallet_fully_scanned_height(db_data).unwrap_or(fallback_height);
    if height == 0 {
        return;
    }

    let mut p = SYNC_PROGRESS.lock().await;
    if allow_regress || height >= p.synced_height {
        p.synced_height = height;
    }
}

async fn update_synced_progress_after_restart(db_data: &mut DbType) {
    if let Some(height) = wallet_fully_scanned_height(db_data) {
        let mut p = SYNC_PROGRESS.lock().await;
        p.synced_height = height;
    }
}

/// Recompute the user-facing block-progress total at pass start. The total
/// is `blocks_scanned_so_far + remaining_blocks_across_all_ranges`. This
/// keeps the progress bar accurate when librustzcash adds new ranges
/// (Verify, FoundNote) between passes — the bar shifts slightly but never
/// jumps backward.
async fn refresh_blocks_total(remaining_blocks: u64) {
    let mut p = SYNC_PROGRESS.lock().await;
    let new_total = p.blocks_scanned.saturating_add(remaining_blocks);
    if new_total > p.blocks_total {
        p.blocks_total = new_total;
    }
}

/// Record blocks that just finished scanning. Called after a batch
/// successfully scans (regardless of priority — ChainTip, Historic,
/// FoundNote, Verify all count). This is what makes the progress bar
/// move during the priority-queue's "ChainTip-first" pre-pass, when
/// `synced_height` (the fully-scanned committed height) stays pinned at
/// the wallet birthday.
async fn record_blocks_scanned(blocks: u64) {
    if blocks == 0 {
        return;
    }
    let mut p = SYNC_PROGRESS.lock().await;
    p.blocks_scanned = p.blocks_scanned.saturating_add(blocks);
    // Self-correct if our running counter passes the previously recorded
    // total (can happen if librustzcash returns a slightly stale range
    // count between passes).
    if p.blocks_scanned > p.blocks_total {
        p.blocks_total = p.blocks_scanned;
    }
}
type ScanRange = zcash_client_backend::data_api::scanning::ScanRange;

/// Holds a `tokio::task::JoinHandle` and aborts it on drop. Use for
/// background tasks that must not outlive the scope they were spawned
/// from — without this, a detached spawn keeps running until its own
/// natural completion, which can mean an extra 30 s of network traffic
/// after sync gave up on a pass.
struct AbortOnDrop<T: Send + 'static> {
    handle: Option<tokio::task::JoinHandle<T>>,
}

impl<T: Send + 'static> AbortOnDrop<T> {
    fn new(handle: tokio::task::JoinHandle<T>) -> Self {
        Self {
            handle: Some(handle),
        }
    }
    /// Take ownership of the inner handle and skip the abort-on-drop.
    /// Use when you want to `.await` the task to natural completion.
    fn into_inner(mut self) -> tokio::task::JoinHandle<T> {
        self.handle.take().expect("AbortOnDrop already consumed")
    }
}

impl<T: Send + 'static> Drop for AbortOnDrop<T> {
    fn drop(&mut self) {
        if let Some(h) = self.handle.take() {
            h.abort();
        }
    }
}

fn check_cancel() -> Result<()> {
    if SYNC_CANCEL.load(Ordering::SeqCst) {
        Err(anyhow::anyhow!("Sync cancelled"))
    } else {
        Ok(())
    }
}

fn is_cancel_error(e: &anyhow::Error) -> bool {
    format!("{:?}", e).contains("Sync cancelled")
}

async fn interruptible_sleep(ms: u64) -> Result<()> {
    let chunks = ms / 1000;
    for _ in 0..chunks.max(1) {
        check_cancel()?;
        tokio::time::sleep(std::time::Duration::from_secs(1)).await;
    }
    Ok(())
}

async fn download_chain_state(
    lwd: &mut CompactTxStreamerClient<tonic::transport::Channel>,
    block_height: BlockHeight,
) -> Result<zcash_client_backend::data_api::chain::ChainState> {
    let prior_height = u32::from(block_height)
        .checked_sub(1)
        .ok_or_else(|| anyhow::anyhow!("cannot request tree state before genesis"))?;
    let tree_state = lwd
        .get_tree_state(BlockId {
            height: u64::from(prior_height),
            hash: vec![],
        })
        .await
        .map_err(|e| anyhow::anyhow!("get_tree_state: {:?}", e))?;

    tree_state
        .into_inner()
        .to_chain_state()
        .map_err(|e| anyhow::anyhow!("to_chain_state: {:?}", e))
}

/// Per-message idle timeout for any server-streaming lightwalletd RPC.
/// We bound how long we wait between consecutive stream messages, not
/// the total stream lifetime — a stream that's actively returning
/// blocks should be allowed to take however long it needs, but a
/// stream that accepts and then goes silent must surface as an error
/// promptly so the outer retry path can pick a different server.
const STREAM_IDLE_TIMEOUT: Duration = Duration::from_secs(30);

/// Wall-clock deadline for a single batch download. The per-message
/// idle timeout above catches "stream stopped emitting" but it can't
/// catch "stream emits a slow trickle of messages forever" — each
/// individual `stream.message().await` returns within 30 s so the idle
/// timeout never fires, yet the batch takes minutes. This deadline
/// bounds the total time we'll wait for one batch before surfacing the
/// error to the outer fallback / retry path. A healthy 1000-block batch
/// downloads in 1–15 s; 60 s is generous headroom for slow alternates.
const BATCH_DOWNLOAD_DEADLINE: Duration = Duration::from_secs(60);

/// Read the next message from a tonic server-streaming RPC, bounding
/// the wait so a silent stream can't wedge the sync loop.
async fn next_stream_message<T>(
    stream: &mut tonic::Streaming<T>,
    label: &str,
) -> Result<Option<T>> {
    match tokio::time::timeout(STREAM_IDLE_TIMEOUT, stream.message()).await {
        Ok(Ok(m)) => Ok(m),
        Ok(Err(e)) => Err(anyhow::anyhow!("{label}: {:?}", e)),
        Err(_) => Err(anyhow::anyhow!(
            "{label}: timed out after {}s waiting for next message",
            STREAM_IDLE_TIMEOUT.as_secs()
        )),
    }
}

async fn download_blocks(
    lwd: &mut CompactTxStreamerClient<tonic::transport::Channel>,
    from: BlockHeight,
    to: BlockHeight,
    received: &AtomicU32,
) -> Result<Vec<CompactBlock>> {
    let range = BlockRange {
        start: Some(BlockId {
            height: u64::from(u32::from(from)),
            hash: vec![],
        }),
        end: Some(BlockId {
            height: u64::from(u32::from(to) - 1),
            hash: vec![],
        }),
        pool_types: vec![],
    };

    let mut stream = lwd
        .get_block_range(range)
        .await
        .map_err(|e| anyhow::anyhow!("get_block_range: {:?}", e))?
        .into_inner();

    let mut blocks = Vec::new();
    let mut expected = u64::from(u32::from(from));
    let end = u64::from(u32::from(to));
    while let Some(block) = next_stream_message(&mut stream, "get_block_range stream").await? {
        check_cancel()?;
        anyhow::ensure!(
            block.height == expected && expected < end,
            "unexpected compact block height {}, expected {} before {}",
            block.height,
            expected,
            end
        );
        expected += 1;
        received.fetch_add(1, Ordering::Relaxed);
        blocks.push(block);
    }

    Ok(blocks)
}

// ---------------------------------------------------------------------------
// Transparent UTXO refresh
// ---------------------------------------------------------------------------

async fn refresh_transparent_utxos(
    lwd: &mut CompactTxStreamerClient<tonic::transport::Channel>,
    db_data: &mut DbType,
    params: &Network,
) -> Result<()> {
    let anchor_height = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        db_data.get_wallet_summary(ConfirmationsPolicy::default())
    }))
    .ok()
    .and_then(|r| r.ok())
    .flatten()
    .map(|summary| summary.fully_scanned_height())
    .or_else(|| db_data.get_wallet_birthday().ok().flatten());

    let account_ids = db_data
        .get_account_ids()
        .map_err(|e| anyhow::anyhow!("get_account_ids: {:?}", e))?;

    for account_id in account_ids {
        let previous_query_height = db_data
            .utxo_query_height(account_id)
            .map_err(|e| anyhow::anyhow!("utxo_query_height: {:?}", e))?;
        let start_height = anchor_height.unwrap_or(previous_query_height);

        let receivers = db_data
            .get_transparent_receivers(account_id, true, true)
            .map_err(|e| anyhow::anyhow!("get_transparent_receivers: {:?}", e))?;

        let addresses: Vec<String> = receivers
            .into_keys()
            .map(|addr| addr.to_zcash_address(params.network_type()).encode())
            .collect();

        if addresses.is_empty() {
            continue;
        }

        tracing::info!(
            "[sync] refreshing transparent UTXOs for {:?} from anchored height {} (previous query height {}, {} addrs)",
            account_id,
            start_height,
            previous_query_height,
            addresses.len()
        );

        let request = GetAddressUtxosArg {
            addresses,
            start_height: u64::from(u32::from(start_height)),
            max_entries: 0,
        };

        let reply_list = lwd
            .get_address_utxos(request)
            .await
            .map_err(|e| anyhow::anyhow!("get_address_utxos: {:?}", e))?;

        let utxos = reply_list.into_inner().address_utxos;
        let mut count = 0u32;

        for reply in utxos {
            let Ok(txid_arr) = reply.txid[..].try_into() else {
                continue;
            };
            let Ok(index) = reply.index.try_into() else {
                continue;
            };
            let Ok(value) = Zatoshis::from_nonnegative_i64(reply.value_zat) else {
                continue;
            };
            let Ok(height) = BlockHeight::try_from(reply.height) else {
                continue;
            };

            let outpoint = OutPoint::new(txid_arr, index);
            let txout = TxOut::new(value, Script(zcash_script::script::Code(reply.script)));

            if let Some(output) = WalletTransparentOutput::from_parts(
                outpoint,
                txout,
                Some(height),
                Some(account_id),
                None,
                None,
            ) {
                db_data
                    .put_received_transparent_utxo(&output)
                    .map_err(|e| anyhow::anyhow!("put_received_transparent_utxo: {:?}", e))?;
                count += 1;
            }
        }

        if count > 0 {
            tracing::info!(
                "[sync] stored {} transparent UTXOs for {:?}",
                count,
                account_id
            );
        }
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    #[ignore = "manual Tor network verification; no keys, wallet data, or transaction submission"]
    async fn verify_live_tor_transport() {
        let dir = tempfile::tempdir().unwrap();
        *ENGINE.lock().await = Some(crate::ZipherEngine {
            db_data_path: dir.path().join("unused.db"), params: Network::MainNetwork,
            server_url: "https://zec.rocks:443".into(), birthday: height(3_477_000),
            db_cipher_key: None, tor_required: false, tor_client: None,
        });
        let started = Instant::now();
        let result = super::super::wallet::enable_tor(dir.path().to_str().unwrap()).await;
        if result.is_ok() {
            assert!(super::super::wallet::is_tor_enabled().await);
            let tip = super::super::wallet::verify_tor_connection().await.unwrap();
            println!("Tor verified: tip={tip} elapsed_ms={}", started.elapsed().as_millis());
        }
        super::super::wallet::disable_tor().await;
        *ENGINE.lock().await = None;
        result.unwrap();
    }

    #[test]
    fn requested_tor_without_a_client_blocks_network_access() {
        let mut engine = crate::ZipherEngine {
            db_data_path: PathBuf::from("disposable.db"),
            params: Network::TestNetwork,
            server_url: "http://127.0.0.1:1".into(),
            birthday: height(2_000_000),
            db_cipher_key: None,
            tor_required: false,
            tor_client: None,
        };
        assert!(engine.tor_transport().unwrap().is_none());
        engine.tor_required = true;
        assert!(engine.tor_transport().is_err());
    }

    #[test]
    fn timeout_batches_shrink_to_observed_throughput_without_zero_ranges() {
        assert_eq!(smaller_download_batch(1000, 80), 40);
        assert_eq!(smaller_download_batch(1000, 0), 500);
        assert_eq!(smaller_download_batch(1000, 1000), 500);
        assert_eq!(smaller_download_batch(40, 0), 20);
        assert_eq!(smaller_download_batch(20, 0), 16);
        assert_eq!(smaller_download_batch(1, 0), 1);
        for n in 1..2000 {
            let next = smaller_download_batch(n, n / 4);
            assert!(next > 0 && next <= n);
        }
    }

    fn height(n: u32) -> BlockHeight {
        BlockHeight::from_u32(n)
    }

    #[test]
    fn dense_window_does_not_throttle_the_rest_of_history() {
        let range = ScanRange::from_parts(
            height(SANDBLASTING_START - 2_000)..height(SANDBLASTING_END + 2_000),
            ScanPriority::Historic,
        );
        let batches = split_into_batches(range.clone(), 1_000, &Network::MainNetwork);
        assert_eq!(batches.len(), 3_404); // Formerly 3,440 requests.
        assert_eq!(batches.first().unwrap().len(), 1_000);
        assert_eq!(batches.last().unwrap().len(), 1_000);
        assert_eq!(
            batches.iter().map(ScanRange::len).sum::<usize>(),
            range.len()
        );
        for pair in batches.windows(2) {
            assert_eq!(pair[0].block_range().end, pair[1].block_range().start);
        }
        for batch in batches {
            assert_eq!(batch.priority(), ScanPriority::Historic);
            let start = u32::from(batch.block_range().start);
            if (SANDBLASTING_START..SANDBLASTING_END).contains(&start) {
                assert!(batch.len() <= 100);
                assert!(u32::from(batch.block_range().end) <= SANDBLASTING_END);
            }
        }
    }

    #[test]
    fn batches_respect_boundaries_and_the_network() {
        assert_eq!(
            batch_end(
                1_000,
                height(SANDBLASTING_START - 50),
                height(SANDBLASTING_START + 2_000),
                &Network::MainNetwork
            ),
            height(SANDBLASTING_START)
        );
        assert_eq!(
            batch_end(
                1_000,
                height(SANDBLASTING_END - 50),
                height(SANDBLASTING_END + 2_000),
                &Network::MainNetwork
            ),
            height(SANDBLASTING_END)
        );
        assert_eq!(
            batch_end(
                1_000,
                height(SANDBLASTING_START),
                height(SANDBLASTING_START + 2_000),
                &Network::TestNetwork
            ),
            height(SANDBLASTING_START + 1_000)
        );
        assert_eq!(
            batch_end(
                1_000,
                height(u32::MAX - 2),
                height(u32::MAX),
                &Network::MainNetwork
            ),
            height(u32::MAX)
        );
        assert!(split_into_batches(
            ScanRange::from_parts(height(10)..height(10), ScanPriority::Verify),
            1_000,
            &Network::MainNetwork
        )
        .is_empty());
    }

    #[test]
    fn scanner_feedback_resizes_the_next_batch_without_skipping_work() {
        let mut plan = BatchPlan {
            pending: [ScanRange::from_parts(
                height(10)..height(2_010),
                ScanPriority::Historic,
            )]
            .into(),
            params: Network::MainNetwork,
        };
        assert_eq!(
            plan.next_batch(1_000).unwrap().block_range(),
            &(height(10)..height(1_010))
        );
        // A slow scan halves the next batch immediately, not next pass.
        assert_eq!(
            plan.next_batch(500).unwrap().block_range(),
            &(height(1_010)..height(1_510))
        );
        assert_eq!(
            plan.next_batch(100).unwrap().block_range(),
            &(height(1_510)..height(1_610))
        );
        assert_eq!(
            plan.next_batch(1_000).unwrap().block_range(),
            &(height(1_610)..height(2_010))
        );
        assert!(plan.next_batch(1_000).is_none());
    }

    #[test]
    fn reject_incomplete_duplicate_extra_and_wrapped_heights() {
        let blocks = |heights: &[u64]| {
            heights
                .iter()
                .map(|height| CompactBlock {
                    height: *height,
                    ..Default::default()
                })
                .collect::<Vec<_>>()
        };
        assert!(validate_blocks_for_range(&blocks(&[10, 11, 12]), height(10), height(13)).is_ok());
        for malformed in [
            vec![],
            vec![10, 11],
            vec![10, 10, 12],
            vec![10, 12, 11],
            vec![10, 11, 12, 13],
            vec![10 + (1u64 << 32), 11, 12],
        ] {
            assert!(
                validate_blocks_for_range(&blocks(&malformed), height(10), height(13)).is_err()
            );
        }
    }

    #[tokio::test]
    async fn benchmark_can_explicitly_disable_default_peers() {
        configure_runtime(SyncRuntimeConfig {
            prefetch_depth: usize::MAX,
            alternate_servers: vec![],
            auto_select_servers: false,
        })
        .await;
        let config = SYNC_RUNTIME_CONFIG.lock().await.clone();
        assert!(!config.auto_select_servers);
        assert!(config.alternate_servers.is_empty());
        assert_eq!(config.prefetch_depth, 8);
        reset_runtime_config().await;
    }

    #[tokio::test]
    async fn stopping_joins_both_workers_and_is_repeatable() {
        struct Dropped(std::sync::Arc<AtomicU32>);
        impl Drop for Dropped {
            fn drop(&mut self) {
                self.0.fetch_add(1, Ordering::SeqCst);
            }
        }
        let dropped = std::sync::Arc::new(AtomicU32::new(0));
        let spawn = || {
            let guard = Dropped(dropped.clone());
            let (started, ready) = tokio::sync::oneshot::channel();
            let task = tokio::spawn(async move {
                let _guard = guard;
                let _ = started.send(());
                std::future::pending::<()>().await;
            });
            (task, ready)
        };
        let (scan, scan_ready) = spawn();
        let (mempool, mempool_ready) = spawn();
        scan_ready.await.unwrap();
        mempool_ready.await.unwrap();
        let mut tasks = SyncTasks {
            scan: Some(scan),
            mempool: Some(mempool),
        };
        tasks.abort_and_join().await;
        assert_eq!(dropped.load(Ordering::SeqCst), 2);
        assert!(tasks.scan.is_none() && tasks.mempool.is_none());
        tasks.abort_and_join().await;
    }

    #[tokio::test]
    async fn engine_rejects_overlapping_starts_and_restarts_after_stop() {
        let dir = tempfile::tempdir().unwrap();
        *ENGINE.lock().await = Some(crate::ZipherEngine {
            db_data_path: dir.path().join("wallet.db"),
            params: Network::TestNetwork,
            server_url: "http://127.0.0.1:1".to_string(),
            birthday: height(2_000_000),
            db_cipher_key: None,
            tor_required: false,
        tor_client: None,
        });
        start().await.unwrap();
        assert!(is_running());
        assert!(start().await.is_err());
        stop().await;
        assert!(!is_running());
        assert!(SYNC_TASKS.lock().await.is_none());
        start().await.unwrap();
        stop().await;
        assert!(!get_progress().await.is_syncing);
        assert!(SYNC_TASKS.lock().await.is_none());
        *ENGINE.lock().await = None;
    }

    /// An empty, random wallet in a temporary directory; never uses an installed wallet.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    #[ignore = "manual live-network sync benchmark; no funds or transaction submission"]
    async fn benchmark_live_disposable_restore() {
        let server = "https://zec.rocks:443";
        let params = Network::MainNetwork;
        let tip = super::super::wallet::fetch_latest_height(server)
            .await
            .unwrap() as u32;
        let lookback = std::env::var("ZIPHER_SYNC_BENCH_BLOCKS")
            .map(|value| value.parse::<u32>().expect("invalid benchmark block count"))
            .unwrap_or(2_000);
        assert!((1..=100_000).contains(&lookback));
        let birthday = tip.saturating_sub(lookback);
        let entropy: [u8; 32] = rand::random();
        let mnemonic = bip0039::Mnemonic::<bip0039::English>::from_entropy(&entropy).unwrap();

        let compare_peers = std::env::var_os("ZIPHER_SYNC_BENCH_PEERS").is_some();
        let configurations: Vec<_> = if compare_peers {
            [false, true, true, false, false, true]
                .into_iter()
                .map(|automatic| (3, automatic))
                .collect()
        } else {
            [0, 3, 3, 0, 0, 3]
                .into_iter()
                .map(|depth| (depth, false))
                .collect()
        };
        for (sample, (prefetch_depth, automatic)) in configurations.into_iter().enumerate() {
            let dir = tempfile::tempdir().unwrap();
            let data_dir = dir.path().to_str().unwrap();
            let key = Some("disposable-sync-benchmark-key".to_string());
            super::super::wallet::restore(
                data_dir,
                server,
                params,
                mnemonic.phrase(),
                birthday,
                key.clone(),
                None,
            )
            .await
            .unwrap();
            configure_runtime(SyncRuntimeConfig {
                prefetch_depth,
                alternate_servers: if compare_peers {
                    default_alternate_servers(&params, server)
                } else {
                    vec![]
                },
                auto_select_servers: automatic,
            })
            .await;
            *SYNC_PROGRESS.lock().await = SyncProgressInfo::default();
            SYNC_CANCEL.store(false, Ordering::SeqCst);
            let mut perf = SessionPerf::default();
            let started = Instant::now();
            let (data_path, _) = super::super::db_paths(data_dir);
            let result = tokio::time::timeout(
                Duration::from_secs(180),
                sync_once(&data_path, params, server, &key, &mut perf),
            )
            .await;
            let elapsed_ms = started.elapsed().as_millis();
            let progress = get_progress().await;
            println!(
                "{}",
                serde_json::json!({
                    "benchmark": "disposable_restore", "sample": sample, "server": server, "birthday": birthday,
                    "prefetch_depth": prefetch_depth, "automatic_peer_policy": automatic, "compare_peers": compare_peers, "elapsed_ms": elapsed_ms,
                    "synced_height": progress.synced_height, "latest_height": progress.latest_height,
                    "blocks_scanned": progress.blocks_scanned, "perf": get_perf_snapshot().await,
                })
            );
            super::super::wallet::close().await;
            reset_runtime_config().await;
            result
                .expect("live sync exceeded 180s")
                .expect("live sync failed");
            assert!(
                progress.synced_height >= tip,
                "wallet did not catch up to the initial tip"
            );
            assert!(!dir.path().join("zipher-cache.sqlite").exists());
        }
    }
}
