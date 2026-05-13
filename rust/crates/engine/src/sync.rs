use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::time::{Duration, Instant};

use anyhow::Result;
use prost::Message;
use rusqlite::OptionalExtension;
use tokio::sync::{broadcast, mpsc, Mutex as TokioMutex};

use zcash_client_backend::data_api::chain::{
    error::Error as ChainError, scan_cached_blocks, BlockSource, CommitmentTreeRoot,
};
use zcash_client_backend::data_api::scanning::ScanPriority;
use zcash_client_backend::data_api::wallet::{decrypt_and_store_transaction, ConfirmationsPolicy};
use zcash_client_backend::data_api::{
    TransactionDataRequest, TransactionStatus, WalletCommitmentTrees, WalletRead, WalletWrite,
};
use zcash_client_backend::proto::compact_formats::CompactBlock;
use zcash_client_backend::proto::service::{
    compact_tx_streamer_client::CompactTxStreamerClient, BlockId, BlockRange, ChainSpec, Empty,
    GetAddressUtxosArg, GetSubtreeRootsArg, ShieldedProtocol, TxFilter,
};
use zcash_client_backend::wallet::WalletTransparentOutput;
use zcash_client_sqlite::error::SqliteClientError;
use zcash_client_sqlite::WalletDb;
use zcash_keys::encoding::AddressCodec as _;
use zcash_primitives::transaction::{Transaction, TxId};
use zcash_protocol::consensus::{BlockHeight, Network};
use zcash_protocol::consensus::{BranchId, Parameters};
use zcash_protocol::value::Zatoshis;
use zcash_transparent::address::Script;
use zcash_transparent::bundle::{OutPoint, TxOut};

use zcash_primitives::merkle_tree::HashSer;

use super::pending;
use super::wallet::connect_lwd;
use super::{open_cipher_conn, open_wallet_db, ENGINE};

// ---------------------------------------------------------------------------
// Sync state
// ---------------------------------------------------------------------------

static SYNC_RUNNING: AtomicBool = AtomicBool::new(false);
static SYNC_CANCEL: AtomicBool = AtomicBool::new(false);
static SYNC_PASS_COUNTER: AtomicU32 = AtomicU32::new(0);

lazy_static::lazy_static! {
    static ref SYNC_PROGRESS: TokioMutex<SyncProgressInfo> =
        TokioMutex::new(SyncProgressInfo::default());

    static ref SYNC_RUNTIME_CONFIG: TokioMutex<SyncRuntimeConfig> =
        TokioMutex::new(SyncRuntimeConfig::default());

    static ref SYNC_PERF: TokioMutex<SyncPerfSnapshot> =
        TokioMutex::new(SyncPerfSnapshot::default());

    static ref INACTIVE_WALLETS: TokioMutex<Vec<InactiveWallet>> =
        TokioMutex::new(Vec::new());

    static ref SYNC_EVENTS: broadcast::Sender<SyncEventInfo> = {
        let (tx, _) = broadcast::channel(256);
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
}

#[derive(Clone, Debug)]
pub struct SyncRuntimeConfig {
    pub prefetch_depth: usize,
    pub alternate_servers: Vec<String>,
}

impl Default for SyncRuntimeConfig {
    fn default() -> Self {
        Self {
            prefetch_depth: 3,
            alternate_servers: Vec::new(),
        }
    }
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
    pub multi_server_fallbacks: u64,
    pub multi_server_mismatches: u64,
}

#[derive(Clone, Debug, serde::Serialize)]
pub struct SyncEventInfo {
    pub event_type: String,
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
    pub db_cache_path: PathBuf,
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

pub async fn start() -> Result<()> {
    if SYNC_RUNNING.load(Ordering::SeqCst) {
        return Err(anyhow::anyhow!("Sync already running"));
    }

    let engine_guard = ENGINE.lock().await;
    let engine = engine_guard
        .as_ref()
        .ok_or_else(|| anyhow::anyhow!("Engine not initialized"))?;

    let db_data_path = engine.db_data_path.clone();
    let db_cache_path = engine.db_cache_path.clone();
    let params = engine.params;
    let server_url = engine.server_url.clone();
    let db_cipher_key = engine.db_cipher_key.clone();
    drop(engine_guard);

    SYNC_RUNNING.store(true, Ordering::SeqCst);
    SYNC_CANCEL.store(false, Ordering::SeqCst);
    {
        let runtime = SYNC_RUNTIME_CONFIG.lock().await.clone();
        let mut perf = SYNC_PERF.lock().await;
        *perf = SyncPerfSnapshot {
            adaptive_batch_size: SCAN_BATCH_SIZE,
            prefetch_depth: runtime.prefetch_depth,
            multi_server_enabled: !runtime.alternate_servers.is_empty(),
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
    }
    emit_progress_event("phase_changed", None, None).await;

    let mempool_db = db_data_path.clone();
    let mempool_server = server_url.clone();
    let mempool_key = db_cipher_key.clone();

    tokio::spawn(async move {
        match sync_forever(
            &db_data_path,
            &db_cache_path,
            params,
            &server_url,
            &db_cipher_key,
        )
        .await
        {
            Ok(()) => tracing::info!("[sync] stopped"),
            Err(e) => tracing::error!("[sync] error: {:?}", e),
        }
        SYNC_RUNNING.store(false, Ordering::SeqCst);
        {
            let mut p = SYNC_PROGRESS.lock().await;
            p.is_syncing = false;
            p.phase = SYNC_PHASE_IDLE.to_string();
        }
        emit_progress_event("phase_changed", None, None).await;
    });

    tokio::spawn(async move {
        mempool_forever(mempool_db, params, mempool_server, mempool_key).await;
    });

    Ok(())
}

pub async fn stop() {
    SYNC_CANCEL.store(true, Ordering::SeqCst);
    for _ in 0..100 {
        if !SYNC_RUNNING.load(Ordering::SeqCst) {
            return;
        }
        tokio::time::sleep(std::time::Duration::from_millis(100)).await;
    }
    SYNC_RUNNING.store(false, Ordering::SeqCst);
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

pub async fn configure_runtime(config: SyncRuntimeConfig) {
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
    });
}

pub fn emit_transaction_event(txid: String, status: &str) {
    emit_event(SyncEventInfo {
        event_type: "transaction_updated".to_string(),
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
    });
    emit_event(SyncEventInfo {
        event_type: "balance_maybe_changed".to_string(),
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
    });
}

/// Emit a log-level event so Dart can show Rust engine activity in the debug log.
pub fn emit_log(message: &str) {
    emit_event(SyncEventInfo {
        event_type: "engine_log".to_string(),
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
    let (db_data_path, db_cache_path) = super::db_paths(data_dir);
    let mut wallets = INACTIVE_WALLETS.lock().await;
    if !wallets.iter().any(|w| w.db_data_path == db_data_path) {
        wallets.push(InactiveWallet {
            db_data_path,
            db_cache_path,
        });
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
    let mut lwd = connect_lwd(&server_url).await?;
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
// Block cache — simple SQLite store implementing BlockSource
// ---------------------------------------------------------------------------

struct BlockCache {
    conn: rusqlite::Connection,
}

#[derive(Debug)]
pub struct BlockCacheError(String);

impl std::fmt::Display for BlockCacheError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "BlockCacheError: {}", self.0)
    }
}

impl std::error::Error for BlockCacheError {}

impl From<rusqlite::Error> for BlockCacheError {
    fn from(e: rusqlite::Error) -> Self {
        BlockCacheError(e.to_string())
    }
}

impl BlockCache {
    fn open(path: &Path, key: &Option<String>) -> Result<Self> {
        let conn = open_cipher_conn(path, key)?;
        conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS compactblocks (
                height INTEGER PRIMARY KEY,
                data BLOB NOT NULL
            )",
        )?;
        Ok(Self { conn })
    }

    fn insert_blocks(&self, blocks: &[CompactBlock]) -> Result<(), rusqlite::Error> {
        let tx = self.conn.unchecked_transaction()?;
        {
            let mut stmt = self.conn.prepare_cached(
                "INSERT OR REPLACE INTO compactblocks (height, data) VALUES (?, ?)",
            )?;
            for block in blocks {
                let data = block.encode_to_vec();
                stmt.execute(rusqlite::params![block.height as u32, data])?;
            }
        }
        tx.commit()?;
        Ok(())
    }

    fn truncate_from(&self, height: u32) -> Result<(), rusqlite::Error> {
        self.conn.execute(
            "DELETE FROM compactblocks WHERE height >= ?",
            rusqlite::params![height],
        )?;
        Ok(())
    }

    fn clear_range(&self, start: u32, end: u32) -> Result<(), rusqlite::Error> {
        self.conn.execute(
            "DELETE FROM compactblocks WHERE height >= ? AND height < ?",
            rusqlite::params![start, end],
        )?;
        Ok(())
    }
}

impl BlockSource for BlockCache {
    type Error = BlockCacheError;

    fn with_blocks<F, WalletErrT>(
        &self,
        from_height: Option<BlockHeight>,
        limit: Option<usize>,
        mut with_block: F,
    ) -> std::result::Result<
        (),
        zcash_client_backend::data_api::chain::error::Error<WalletErrT, Self::Error>,
    >
    where
        F: FnMut(
            CompactBlock,
        ) -> std::result::Result<
            (),
            zcash_client_backend::data_api::chain::error::Error<WalletErrT, Self::Error>,
        >,
    {
        use zcash_client_backend::data_api::chain::error::Error as CE;

        let from = from_height.map(u32::from).unwrap_or(0);
        let lim = limit.unwrap_or(u32::MAX as usize) as u32;

        let mut stmt = self
            .conn
            .prepare_cached(
                "SELECT height, data FROM compactblocks WHERE height >= ? ORDER BY height ASC LIMIT ?",
            )
            .map_err(|e| CE::BlockSource(BlockCacheError::from(e)))?;

        let rows = stmt
            .query_map(rusqlite::params![from, lim], |row| {
                let data: Vec<u8> = row.get(1)?;
                Ok(data)
            })
            .map_err(|e| CE::BlockSource(BlockCacheError::from(e)))?;

        for row in rows {
            let data = row.map_err(|e| CE::BlockSource(BlockCacheError::from(e)))?;
            let block = CompactBlock::decode(&data[..])
                .map_err(|e| CE::BlockSource(BlockCacheError(e.to_string())))?;
            with_block(block)?;
        }

        Ok(())
    }
}

// ---------------------------------------------------------------------------
// Continuous sync with exponential backoff retry
// ---------------------------------------------------------------------------

const MAX_CONSECUTIVE_FAILURES: u32 = 20;

async fn sync_forever(
    db_data_path: &Path,
    db_cache_path: &Path,
    params: Network,
    server_url: &str,
    db_cipher_key: &Option<String>,
) -> Result<()> {
    let mut backoff_ms: u64 = 3_000;
    const MAX_BACKOFF_MS: u64 = 30_000;
    let mut consecutive_failures: u32 = 0;

    loop {
        check_cancel()?;

        match sync_once(
            db_data_path,
            db_cache_path,
            params,
            server_url,
            db_cipher_key,
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
                let err_msg = format!("{:?}", e);
                tracing::warn!(
                    "[sync] error (attempt {}), retrying in {}ms: {}",
                    consecutive_failures,
                    backoff_ms,
                    err_msg
                );
                emit_log(&format!(
                    "pass failed (attempt {}): {}",
                    consecutive_failures,
                    if err_msg.len() > 120 {
                        &err_msg[..120]
                    } else {
                        &err_msg
                    }
                ));

                if consecutive_failures >= MAX_CONSECUTIVE_FAILURES {
                    let mut p = SYNC_PROGRESS.lock().await;
                    p.connection_error = Some(format!("{:?}", e));
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
                        "Sync stopped after {} consecutive failures: {:?}",
                        MAX_CONSECUTIVE_FAILURES,
                        e
                    ));
                }

                if consecutive_failures >= 3 {
                    let mut p = SYNC_PROGRESS.lock().await;
                    p.connection_error = Some(format!("{:?}", e));
                    p.phase = SYNC_PHASE_RECONNECTING.to_string();
                    drop(p);
                    emit_progress_event("connection_error", Some("scan"), Some(format!("{:?}", e)))
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
        if let Ok(mut lwd) = connect_lwd(&server_url).await {
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
// BlockCache holds rusqlite::Connection (not Send/Sync), so all logic that
// uses it must live in a single async function to avoid crossing await
// boundaries with a non-Send reference.
// ---------------------------------------------------------------------------

async fn sync_once(
    db_data_path: &Path,
    db_cache_path: &Path,
    params: Network,
    server_url: &str,
    db_cipher_key: &Option<String>,
) -> Result<()> {
    tracing::info!("[sync] starting pass, server={}", server_url);
    emit_log(&format!("sync pass start → {}", server_url));
    let runtime = SYNC_RUNTIME_CONFIG.lock().await.clone();
    let mut perf = PassPerf::default();

    let mut db_data = open_wallet_db(db_data_path, params, db_cipher_key)?;
    let db_cache = BlockCache::open(db_cache_path, db_cipher_key)?;
    {
        let mut p = SYNC_PROGRESS.lock().await;
        p.phase = SYNC_PHASE_CONNECTING.to_string();
    }
    emit_progress_event("phase_changed", None, None).await;
    let mut lwd = connect_lwd(server_url).await?;

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
        p.phase = SYNC_PHASE_UPDATING_ROOTS.to_string();
    }
    emit_progress_event("phase_changed", None, None).await;

    // 1) Always update subtree roots (idempotent with start_index=0)
    tracing::info!("[sync] updating subtree roots...");
    update_subtree_roots(&mut lwd, &mut db_data).await?;

    // 2) Sync until caught up (ECC pattern: `while running(...) {}`)
    let mut batch_size: u32 = SCAN_BATCH_SIZE;
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

        {
            let mut p = SYNC_PROGRESS.lock().await;
            p.phase = SYNC_PHASE_REFRESHING_UTXOS.to_string();
        }
        emit_progress_event("phase_changed", None, None).await;
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

        loop {
            let Some(verify_idx) = scan_ranges
                .iter()
                .position(|range| range.priority() == ScanPriority::Verify)
            else {
                break;
            };

            let range_clone = scan_ranges[verify_idx].clone();
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
                process_downloaded_range(&params, &db_cache, &mut db_data, &range_clone, downloaded)
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

        let batches: Vec<ScanRange> = scan_ranges
            .into_iter()
            .flat_map(|r| split_into_batches(r, batch_size))
            .filter(|r| r.priority() > ScanPriority::Scanned)
            .filter(|r| r.priority() != ScanPriority::Verify)
            .collect();

        tracing::debug!(
            "[sync] {} scan batches to process (batch_size={})",
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
                "scan batches: {} batch_size={} prefetch_depth={} multi_server={}",
                batches.len(),
                batch_size,
                runtime.prefetch_depth,
                !runtime.alternate_servers.is_empty()
            ));

            if runtime.prefetch_depth == 0 {
                let mut batch_idx: u32 = 0;
                let total_batches = batches.len() as u32;
                for current_range in batches {
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
                        "batch {}/{} [{:?}] {}..{}: downloaded in {} ms",
                        batch_idx,
                        total_batches,
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
                        &db_cache,
                        &mut db_data,
                        &mut batch_size,
                        &mut perf,
                        &current_range,
                        downloaded,
                        MultiServerCounters::default(),
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
                            "batch {}/{} restart: committed {} (no advance, +0)",
                            batch_idx, total_batches, committed_after
                        ));
                        break;
                    }
                    pass_batches_scanned += 1;
                    emit_log(&format!(
                        "batch {}/{} done: scanned in {} ms, committed {} → {} (+{} blocks)",
                        batch_idx,
                        total_batches,
                        scan_ms,
                        committed_before,
                        committed_after,
                        advance
                    ));
                }
            } else {
                let (tx, mut rx) = mpsc::channel::<Result<PrefetchedRange>>(runtime.prefetch_depth);
                let fetch_server_url = server_url.to_string();
                let fetch_batches = batches;
                let fetch_runtime = runtime.clone();
                let fetch_handle = tokio::spawn(async move {
                    fetch_prefetched_ranges(fetch_server_url, fetch_batches, fetch_runtime, tx)
                        .await
                });

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
                        multi_server_counters,
                    } = prefetched?;
                    let committed_before = wallet_fully_scanned_height(&mut db_data).unwrap_or(0);
                    emit_log(&format!(
                        "batch {} [{:?}] {}..{}: prefetched, scanning",
                        batch_idx,
                        current_range.priority(),
                        u32::from(current_range.block_range().start),
                        u32::from(current_range.block_range().end),
                    ));
                    {
                        let mut p = SYNC_PROGRESS.lock().await;
                        p.scanning_up_to = u32::from(current_range.block_range().end);
                    }
                    emit_progress_event("phase_changed", None, None).await;
                    let scan_started = Instant::now();
                    let outcome = process_prefetched_range(
                        &params,
                        &db_cache,
                        &mut db_data,
                        &mut batch_size,
                        &mut perf,
                        &current_range,
                        downloaded,
                        multi_server_counters,
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
                    emit_log(&format!(
                        "batch {} done: scanned in {} ms, committed {} → {} (+{} blocks)",
                        batch_idx, scan_ms, committed_before, committed_after, advance
                    ));
                }

                if did_restart {
                    fetch_handle.abort();
                } else {
                    match fetch_handle.await {
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
    match connect_lwd(server_url).await {
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
                p.maintenance_error = Some(format!("{:?}", e));
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
                    p.maintenance_error = Some(format!("{:?}", e));
                }
            }
        }
        Err(e) => {
            // Maintenance is intentionally not part of the critical scan path.
            // Memos and tx status will retry on the next pass without surfacing
            // as a wallet-wide connection failure.
            tracing::warn!("[sync] maintenance connection failed: {:?}", e);
            let mut p = SYNC_PROGRESS.lock().await;
            p.maintenance_error = Some(format!("{:?}", e));
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

fn describe_transaction_requests(requests: &[TransactionDataRequest]) -> String {
    let mut enhancement = 0usize;
    let mut status = 0usize;
    let mut other = 0usize;
    for req in requests {
        match req {
            TransactionDataRequest::Enhancement(_) => enhancement += 1,
            TransactionDataRequest::GetStatus(_) => status += 1,
            _ => other += 1,
        }
    }
    format!(
        "{} total ({} enhancement, {} status, {} other)",
        requests.len(),
        enhancement,
        status,
        other
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
    {
        let mut p = SYNC_PROGRESS.lock().await;
        p.phase = SYNC_PHASE_ENHANCING.to_string();
        p.maintenance_error = None;
        p.maintenance_queue_len = total as u32;
    }
    emit_progress_event("phase_changed", None, None).await;

    tracing::info!("[sync] enhancing: {} items in queue", total);
    emit_log(&format!(
        "enhancement queue: {}",
        describe_transaction_requests(&requests)
    ));

    let mut enhanced = 0usize;
    let mut status_checked = 0usize;
    let mut skipped = 0usize;
    let mut processed = 0usize;
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
            _ => {}
        }
    }

    let remaining = total.saturating_sub(processed);
    let remaining = db_data
        .transaction_data_requests()
        .map(|requests| requests.len())
        .unwrap_or(remaining);
    let msg = format!(
        "enhanced {}, status {}, skipped {}, remaining {}",
        enhanced, status_checked, skipped, remaining
    );
    tracing::info!("[sync] {}", msg);
    emit_log(&msg);

    let mut p = SYNC_PROGRESS.lock().await;
    p.maintenance_queue_len = remaining as u32;
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
            "enhance {}: server returned no transaction data",
            txid_short
        ));
        // Tx not (yet) on chain — mark as not-in-mempool so we don't keep
        // requesting it forever.
        db_data
            .set_transaction_status(txid, TransactionStatus::TxidNotRecognized)
            .map_err(|e| anyhow::anyhow!("set_transaction_status: {:?}", e))?;
        return Ok(());
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

fn short_txid(txid: TxId) -> String {
    let mut display = txid.as_ref().to_vec();
    display.reverse();
    let hex = hex::encode(display);
    hex[..hex.len().min(12)].to_string()
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
        TransactionStatus::TxidNotRecognized
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
    multi_server_counters: MultiServerCounters,
}

#[derive(Default)]
struct MultiServerCounters {
    fallbacks: u64,
    mismatches: u64,
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
struct PassPerf {
    batches: u64,
    blocks: u64,
    work_units: u64,
    download_ms: u64,
    scan_ms: u64,
    restarted_batches: u64,
    multi_server_fallbacks: u64,
    multi_server_mismatches: u64,
}

impl PassPerf {
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
            multi_server_enabled: !runtime.alternate_servers.is_empty(),
            multi_server_fallbacks: self.multi_server_fallbacks,
            multi_server_mismatches: self.multi_server_mismatches,
        };
    }

    fn record_multi_server(&mut self, counters: MultiServerCounters) {
        self.multi_server_fallbacks += counters.fallbacks;
        self.multi_server_mismatches += counters.mismatches;
    }

    fn log_summary(&self) {
        if self.batches == 0 {
            tracing::info!("[sync][perf] no scan batches in this pass");
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
            "[sync][perf][summary] batches={} blocks={} units={} avg_download_ms={} avg_scan_ms={} units_per_sec={:.1} restarted_batches={}",
            self.batches,
            self.blocks,
            self.work_units,
            avg_download_ms,
            avg_scan_ms,
            units_per_sec,
            self.restarted_batches
        );
        emit_log(&format!(
            "perf: batches={} blocks={} units={} avg_dl={}ms avg_scan={}ms units/s={:.1} restarts={} fallbacks={} mismatches={}",
            self.batches,
            self.blocks,
            self.work_units,
            avg_download_ms,
            avg_scan_ms,
            units_per_sec,
            self.restarted_batches,
            self.multi_server_fallbacks,
            self.multi_server_mismatches
        ));
    }
}

const SCAN_BATCH_SIZE: u32 = 250;
const MIN_BATCH_SIZE: u32 = 100;
const SLOW_SCAN_MS: u64 = 3_000;

fn adjust_batch_size(current: u32, scan_elapsed_ms: u64) -> u32 {
    if scan_elapsed_ms > SLOW_SCAN_MS {
        (current / 2).max(MIN_BATCH_SIZE)
    } else {
        current
    }
}

async fn fetch_prefetched_ranges(
    primary_server_url: String,
    batches: Vec<ScanRange>,
    runtime: SyncRuntimeConfig,
    tx: mpsc::Sender<Result<PrefetchedRange>>,
) -> Result<()> {
    let mut servers = vec![primary_server_url.clone()];
    for server in runtime.alternate_servers {
        if server != primary_server_url && !servers.iter().any(|s| s == &server) {
            servers.push(server);
        }
    }

    let mut primary_lwd = connect_lwd(&primary_server_url).await?;
    for (idx, scan_range) in batches.into_iter().enumerate() {
        check_cancel()?;
        let candidate_url = servers
            .get(idx % servers.len())
            .cloned()
            .unwrap_or_else(|| primary_server_url.clone());
        let (downloaded, multi_server_counters) = if candidate_url == primary_server_url {
            (
                download_range(&mut primary_lwd, &scan_range).await?,
                MultiServerCounters::default(),
            )
        } else {
            download_range_from_candidate(
                &primary_server_url,
                &mut primary_lwd,
                &candidate_url,
                &scan_range,
                idx,
            )
            .await?
        };

        if tx
            .send(Ok(PrefetchedRange {
                scan_range,
                downloaded,
                multi_server_counters,
            }))
            .await
            .is_err()
        {
            return Ok(());
        }
    }
    Ok(())
}

async fn download_range_from_candidate(
    primary_server_url: &str,
    primary_lwd: &mut CompactTxStreamerClient<tonic::transport::Channel>,
    candidate_url: &str,
    scan_range: &ScanRange,
    batch_index: usize,
) -> Result<(Option<DownloadedRange>, MultiServerCounters)> {
    let mut counters = MultiServerCounters::default();
    let mut candidate_lwd = match connect_lwd(candidate_url).await {
        Ok(lwd) => lwd,
        Err(e) => {
            counters.fallbacks += 1;
            tracing::warn!(
                "[sync] multi-server candidate failed to connect, falling back to primary: {}",
                e
            );
            emit_log("multi-server: candidate connect failed, using primary server");
            return Ok((download_range(primary_lwd, scan_range).await?, counters));
        }
    };

    let candidate = match download_range(&mut candidate_lwd, scan_range).await {
        Ok(downloaded) => downloaded,
        Err(e) => {
            counters.fallbacks += 1;
            tracing::warn!(
                "[sync] multi-server candidate download failed, falling back to primary: {}",
                e
            );
            emit_log("multi-server: candidate download failed, using primary server");
            return Ok((download_range(primary_lwd, scan_range).await?, counters));
        }
    };

    // Cross-check a small deterministic sample against the primary server. This
    // catches bad or divergent servers without doubling every download.
    if batch_index % 20 == 0 {
        let primary = download_range(primary_lwd, scan_range).await?;
        if !downloaded_ranges_match(&candidate, &primary) {
            counters.mismatches += 1;
            counters.fallbacks += 1;
            tracing::warn!(
                "[sync] multi-server mismatch for {}, using primary result",
                candidate_url
            );
            emit_log("multi-server: cross-check mismatch, using primary server");
            return Ok((primary, counters));
        }
    }

    tracing::debug!(
        "[sync] downloaded range {}..{} from {} (primary {})",
        u32::from(scan_range.block_range().start),
        u32::from(scan_range.block_range().end),
        candidate_url,
        primary_server_url
    );
    Ok((candidate, counters))
}

fn process_prefetched_range(
    params: &Network,
    db_cache: &BlockCache,
    db_data: &mut DbType,
    batch_size: &mut u32,
    perf: &mut PassPerf,
    current_range: &ScanRange,
    downloaded: Option<DownloadedRange>,
    multi_server_counters: MultiServerCounters,
) -> Result<ScanOutcome> {
    let batch_stats = downloaded.as_ref().map(|d| d.stats());
    let scan_started = Instant::now();
    let outcome = tokio::task::block_in_place(|| {
        process_downloaded_range(params, db_cache, db_data, current_range, downloaded)
    })?;
    let scan_elapsed_ms = scan_started.elapsed().as_millis() as u64;
    *batch_size = adjust_batch_size(*batch_size, scan_elapsed_ms);
    perf.record_multi_server(multi_server_counters);
    if let Some(stats) = batch_stats {
        perf.record(stats, scan_elapsed_ms, &outcome);
    }
    Ok(outcome)
}

async fn handle_scan_outcome(
    outcome: ScanOutcome,
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
            refresh_scan_progress(db_data).await;
            if notes_found > 0 {
                let _ =
                    enhance_transactions_inline(db_data, params, lwd, db_data_path, db_cipher_key)
                        .await;
            }
            emit_event(SyncEventInfo {
                event_type: "balance_maybe_changed".to_string(),
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
            });
            Ok(false)
        }
        ScanOutcome::NothingToScan => Ok(false),
    }
}

/// Async download phase — no `BlockCache` reference, fully Send-safe.
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
    let blocks = download_blocks(lwd, range_start, range_end).await?;
    if blocks.is_empty() {
        return Ok(None);
    }
    validate_blocks_for_range(&blocks, range_start, range_end)?;
    let chain_state = download_chain_state(lwd, range_start).await?;
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

/// Synchronous scan phase — inserts blocks, scans, handles reorgs.
/// Fully sync (no `.await`), so holding `&BlockCache` is safe.
fn process_downloaded_range(
    params: &Network,
    db_cache: &BlockCache,
    db_data: &mut DbType,
    scan_range: &zcash_client_backend::data_api::scanning::ScanRange,
    downloaded: Option<DownloadedRange>,
) -> Result<ScanOutcome> {
    let downloaded = match downloaded {
        Some(d) => d,
        None => return Ok(ScanOutcome::NothingToScan),
    };

    db_cache
        .insert_blocks(&downloaded.blocks)
        .map_err(|e| anyhow::anyhow!("insert_blocks: {:?}", e))?;

    let scan_len = scan_range.len();
    let priority = scan_range.priority();
    let scan_result = scan_cached_blocks(
        params,
        db_cache,
        db_data,
        downloaded.range_start,
        &downloaded.chain_state,
        scan_len,
    );

    db_cache
        .clear_range(
            u32::from(downloaded.range_start),
            u32::from(downloaded.range_end),
        )
        .map_err(|e| anyhow::anyhow!("clear_range: {:?}", e))?;

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
            let rewind_height = err.at_height().saturating_sub(10);
            tracing::info!(
                "[sync] reorg at {}, rewinding to {}",
                err.at_height(),
                u32::from(rewind_height)
            );
            emit_log(&format!(
                "scan continuity restart at {}, rewinding to {}",
                err.at_height(),
                u32::from(rewind_height)
            ));

            let actual_rewind = safe_truncate_to_height_sync(db_data, rewind_height)?;

            db_cache
                .truncate_from(u32::from(actual_rewind))
                .map_err(|e| anyhow::anyhow!("truncate cache: {:?}", e))?;

            Ok(ScanOutcome::Restarted)
        }
        Err(e) => Err(anyhow::anyhow!("scan error: {:?}", e)),
    }
}

/// Split a ScanRange into batch_size chunks (same algorithm as ECC reference).
fn split_into_batches(
    range: zcash_client_backend::data_api::scanning::ScanRange,
    batch_size: u32,
) -> Vec<zcash_client_backend::data_api::scanning::ScanRange> {
    let mut batches = Vec::new();
    let mut remaining = range;

    loop {
        if remaining.is_empty() {
            break;
        }
        match remaining.split_at(remaining.block_range().start + batch_size) {
            Some((current, next)) => {
                batches.push(current);
                remaining = next;
            }
            None => {
                batches.push(remaining);
                break;
            }
        }
    }

    batches
}

fn count_work_units(blocks: &[CompactBlock]) -> usize {
    blocks
        .iter()
        .map(|b| {
            b.vtx
                .iter()
                .map(|tx| tx.spends.len() + tx.outputs.len() + tx.actions.len())
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
        let height = block.height as u32;
        if height != expected {
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

fn downloaded_ranges_match(a: &Option<DownloadedRange>, b: &Option<DownloadedRange>) -> bool {
    match (a, b) {
        (None, None) => true,
        (Some(a), Some(b)) => {
            a.range_start == b.range_start
                && a.range_end == b.range_end
                && a.blocks.len() == b.blocks.len()
                && a.blocks
                    .iter()
                    .zip(b.blocks.iter())
                    .all(|(left, right)| left.height == right.height && left.hash == right.hash)
        }
        _ => false,
    }
}

// ---------------------------------------------------------------------------
// Subtree roots — always fetch from index 0 (idempotent, like ECC reference)
// ---------------------------------------------------------------------------

async fn update_subtree_roots(
    lwd: &mut CompactTxStreamerClient<tonic::transport::Channel>,
    db_data: &mut DbType,
) -> Result<()> {
    use futures_util::TryStreamExt;

    // Sapling
    let mut sapling_request = GetSubtreeRootsArg::default();
    sapling_request.set_shielded_protocol(ShieldedProtocol::Sapling);

    let sapling_roots: Vec<CommitmentTreeRoot<sapling_crypto::Node>> = lwd
        .get_subtree_roots(sapling_request)
        .await
        .map_err(|e| anyhow::anyhow!("get_subtree_roots(sapling): {:?}", e))?
        .into_inner()
        .and_then(|root| async move {
            let root_hash = sapling_crypto::Node::read(&root.root_hash[..])
                .map_err(|e| tonic::Status::internal(format!("{:?}", e)))?;
            Ok(CommitmentTreeRoot::from_parts(
                BlockHeight::from_u32(root.completing_block_height as u32),
                root_hash,
            ))
        })
        .try_collect()
        .await
        .map_err(|e| anyhow::anyhow!("sapling subtree roots: {:?}", e))?;

    tracing::info!("[sync] sapling: {} subtree roots", sapling_roots.len());
    db_data
        .put_sapling_subtree_roots(0, &sapling_roots)
        .map_err(|e| anyhow::anyhow!("put_sapling_subtree_roots: {:?}", e))?;

    // Orchard
    let mut orchard_request = GetSubtreeRootsArg::default();
    orchard_request.set_shielded_protocol(ShieldedProtocol::Orchard);

    let orchard_roots: Vec<CommitmentTreeRoot<orchard::tree::MerkleHashOrchard>> = lwd
        .get_subtree_roots(orchard_request)
        .await
        .map_err(|e| anyhow::anyhow!("get_subtree_roots(orchard): {:?}", e))?
        .into_inner()
        .and_then(|root| async move {
            let root_hash = orchard::tree::MerkleHashOrchard::read(&root.root_hash[..])
                .map_err(|e| tonic::Status::internal(format!("{:?}", e)))?;
            Ok(CommitmentTreeRoot::from_parts(
                BlockHeight::from_u32(root.completing_block_height as u32),
                root_hash,
            ))
        })
        .try_collect()
        .await
        .map_err(|e| anyhow::anyhow!("orchard subtree roots: {:?}", e))?;

    tracing::info!("[sync] orchard: {} subtree roots", orchard_roots.len());
    db_data
        .put_orchard_subtree_roots(0, &orchard_roots)
        .map_err(|e| anyhow::anyhow!("put_orchard_subtree_roots: {:?}", e))?;

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
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        db_data.get_wallet_summary(ConfirmationsPolicy::MIN)
    }))
    .ok()
    .and_then(|r| r.ok())
    .flatten()
    .map(|s| u32::from(s.fully_scanned_height()))
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
type ScanRange = zcash_client_backend::data_api::scanning::ScanRange;

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
    let prior_height = block_height - 1;
    let tree_state = lwd
        .get_tree_state(BlockId {
            height: u64::from(u32::from(prior_height)),
            hash: vec![],
        })
        .await
        .map_err(|e| anyhow::anyhow!("get_tree_state: {:?}", e))?;

    tree_state
        .into_inner()
        .to_chain_state()
        .map_err(|e| anyhow::anyhow!("to_chain_state: {:?}", e))
}

async fn download_blocks(
    lwd: &mut CompactTxStreamerClient<tonic::transport::Channel>,
    from: BlockHeight,
    to: BlockHeight,
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
    };

    let mut stream = lwd
        .get_block_range(range)
        .await
        .map_err(|e| anyhow::anyhow!("get_block_range: {:?}", e))?
        .into_inner();

    let mut blocks = Vec::new();
    while let Some(block) = stream
        .message()
        .await
        .map_err(|e| anyhow::anyhow!("stream block: {:?}", e))?
    {
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
            .map(|addr| addr.encode(params))
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

            if let Some(output) = WalletTransparentOutput::from_parts(outpoint, txout, Some(height))
            {
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
