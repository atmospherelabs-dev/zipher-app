use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use anyhow::Result;
use prost::Message;
use rusqlite::OptionalExtension;
use tokio::sync::{broadcast, Mutex as TokioMutex};

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

lazy_static::lazy_static! {
    static ref SYNC_PROGRESS: TokioMutex<SyncProgressInfo> =
        TokioMutex::new(SyncProgressInfo::default());

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
}

const SYNC_PHASE_IDLE: &str = "idle";
const SYNC_PHASE_CONNECTING: &str = "connecting";
const SYNC_PHASE_UPDATING_ROOTS: &str = "updating_roots";
const SYNC_PHASE_REFRESHING_UTXOS: &str = "refreshing_utxos";
const SYNC_PHASE_MEMPOOL: &str = "mempool";
const SYNC_PHASE_SCANNING: &str = "scanning";
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
        let mut p = SYNC_PROGRESS.lock().await;
        p.is_syncing = true;
        p.synced_height = 0;
        p.latest_height = 0;
        p.connection_error = None;
        p.maintenance_error = None;
        p.phase = SYNC_PHASE_CONNECTING.to_string();
        p.scanning_up_to = 0;
        p.adaptive_batch_size = AdaptiveBatchTuner::DEFAULT_BATCH_SIZE;
        p.maintenance_queue_len = 0;
    }
    emit_progress_event("phase_changed", None, None).await;

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
    fetch_and_decrypt_tx(&mut db_data, &params, &mut lwd, txid).await?;
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
    db_data
        .truncate_to_height(target)
        .map_err(|e| anyhow::anyhow!("truncate_to_height: {:?}", e))?;

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

async fn sync_forever(
    db_data_path: &Path,
    db_cache_path: &Path,
    params: Network,
    server_url: &str,
    db_cipher_key: &Option<String>,
) -> Result<()> {
    let mut backoff_ms: u64 = 5_000;
    const MAX_BACKOFF_MS: u64 = 60_000;
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
                backoff_ms = 5_000;
                consecutive_failures = 0;

                for _ in 0..30 {
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
                tracing::warn!(
                    "[sync] error (attempt {}), retrying in {}ms: {:?}",
                    consecutive_failures,
                    backoff_ms,
                    e
                );

                // Only surface the error to UI after 2+ consecutive failures
                // to avoid flashing "connection lost" on transient hiccups
                if consecutive_failures >= 2 {
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
    let mut perf = PassPerf::default();

    let mut db_data = open_wallet_db(db_data_path, params, db_cipher_key)?;
    let db_cache = BlockCache::open(db_cache_path, db_cipher_key)?;
    {
        let mut p = SYNC_PROGRESS.lock().await;
        p.phase = SYNC_PHASE_CONNECTING.to_string();
    }
    emit_progress_event("phase_changed", None, None).await;
    let mut lwd = connect_lwd(server_url).await?;

    // We have a live gRPC connection to lightwalletd — clear any stale error
    // from a previous failed pass so UI/CLI stop showing "connection lost"
    // during the (potentially slow) subtree-roots update below.
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
    // Use adaptive height batches to avoid very dense ranges causing slow scans.
    let mut batch_tuner = AdaptiveBatchTuner::default();
    let mut keep_running = true;
    while keep_running {
        check_cancel()?;

        // 3-4) Update chain tip
        let tip = lwd
            .get_latest_block(ChainSpec::default())
            .await
            .map_err(|e| anyhow::anyhow!("get_latest_block: {:?}", e))?;
        let tip_height = BlockHeight::from_u32(tip.into_inner().height as u32);
        tracing::info!("[sync] chain tip = {}", u32::from(tip_height));

        db_data
            .update_chain_tip(tip_height)
            .map_err(|e| anyhow::anyhow!("update_chain_tip: {:?}", e))?;

        {
            let mut p = SYNC_PROGRESS.lock().await;
            p.latest_height = u32::from(tip_height);
            p.connection_error = None;
        }
        emit_progress_event("phase_changed", None, None).await;

        // Refresh transparent UTXOs from the wallet's fully-scanned height on
        // every pass. This matches the Rust SDK pattern and avoids missing
        // transparent inbound funds on wallets that have been inactive.
        {
            let mut p = SYNC_PROGRESS.lock().await;
            p.phase = SYNC_PHASE_REFRESHING_UTXOS.to_string();
        }
        emit_progress_event("phase_changed", None, None).await;
        if let Err(e) = refresh_transparent_utxos(&mut lwd, &mut db_data, &params).await {
            tracing::warn!("[sync] transparent UTXO refresh warning: {:?}", e);
        }

        {
            let mut p = SYNC_PROGRESS.lock().await;
            p.phase = SYNC_PHASE_MEMPOOL.to_string();
        }
        emit_progress_event("phase_changed", None, None).await;
        match connect_lwd(server_url).await {
            Ok(mut mempool_lwd) => {
                if let Err(e) = scan_mempool_once(
                    &mut mempool_lwd,
                    &mut db_data,
                    &params,
                    db_data_path,
                    db_cipher_key,
                    u32::from(tip_height),
                )
                .await
                {
                    tracing::debug!("[sync] mempool scan skipped: {:?}", e);
                }
            }
            Err(e) => tracing::debug!("[sync] mempool connection skipped: {:?}", e),
        }

        // 5-6) Verify loop — handle Verify-priority ranges first
        let mut scan_ranges = db_data
            .suggest_scan_ranges()
            .map_err(|e| anyhow::anyhow!("suggest_scan_ranges: {:?}", e))?;

        loop {
            match scan_ranges.first() {
                Some(range) if range.priority() == ScanPriority::Verify => {
                    tracing::info!("[sync] verifying range {:?}", range.block_range());
                    let range_clone = range.clone();
                    {
                        let mut p = SYNC_PROGRESS.lock().await;
                        p.phase = SYNC_PHASE_SCANNING.to_string();
                    }
                    emit_progress_event("phase_changed", None, None).await;
                    let downloaded = download_range(&mut lwd, &range_clone).await?;
                    let verify_stats = downloaded.as_ref().map(|d| d.stats());
                    {
                        let mut p = SYNC_PROGRESS.lock().await;
                        p.scanning_up_to = u32::from(range_clone.block_range().end);
                    }
                    emit_progress_event("phase_changed", None, None).await;
                    let scan_started = Instant::now();
                    let outcome = tokio::task::block_in_place(|| {
                        process_downloaded_range(
                            &params,
                            &db_cache,
                            &mut db_data,
                            &range_clone,
                            downloaded,
                        )
                    })?;
                    let scan_elapsed_ms = scan_started.elapsed().as_millis() as u64;
                    if let Some(stats) = verify_stats {
                        perf.record(stats, scan_elapsed_ms, &outcome);
                    }

                    match outcome {
                        ScanOutcome::Restarted => {
                            scan_ranges = db_data
                                .suggest_scan_ranges()
                                .map_err(|e| anyhow::anyhow!("suggest_scan_ranges: {:?}", e))?;
                        }
                        ScanOutcome::Scanned {
                            synced_height,
                            notes_found,
                        } => {
                            let mut p = SYNC_PROGRESS.lock().await;
                            p.synced_height = synced_height;
                            drop(p);
                            if notes_found > 0 {
                                let _ =
                                    enhance_transactions_inline(&mut db_data, &params, &mut lwd)
                                        .await;
                            }
                            break;
                        }
                        ScanOutcome::NothingToScan => break,
                    }
                }
                _ => break,
            }
        }

        // 7) Process remaining scan ranges, split into adaptive chunks.
        // Pipeline one prefetch batch ahead so network and scanning overlap.
        let scan_ranges = db_data
            .suggest_scan_ranges()
            .map_err(|e| anyhow::anyhow!("suggest_scan_ranges: {:?}", e))?;

        let batches: Vec<ScanRange> = scan_ranges
            .into_iter()
            .flat_map(|r| split_into_batches(r, batch_tuner.batch_size))
            .filter(|r| r.priority() > ScanPriority::Scanned)
            .collect();

        tracing::debug!(
            "[sync] {} scan batches to process (adaptive batch_size={})",
            batches.len(),
            batch_tuner.batch_size
        );

        let mut did_restart = false;
        let mut pipeline_iter = batches.into_iter();
        if let Some(first_range) = pipeline_iter.next() {
            {
                let mut p = SYNC_PROGRESS.lock().await;
                p.phase = SYNC_PHASE_SCANNING.to_string();
            }
            emit_progress_event("phase_changed", None, None).await;
            // Separate client for batch download prefetch (main client still handles
            // tip updates, verify loop, and transparent UTXO refresh).
            let mut downloader = connect_lwd(server_url).await?;
            let mut current_range = first_range;
            let mut current_downloaded = download_range(&mut downloader, &current_range).await?;
            let mut prefetch = pipeline_iter
                .next()
                .map(|next_range| spawn_download_prefetch(downloader, next_range));

            loop {
                check_cancel()?;
                let batch_stats = current_downloaded.as_ref().map(|d| d.stats());
                {
                    let mut p = SYNC_PROGRESS.lock().await;
                    p.scanning_up_to = u32::from(current_range.block_range().end);
                }
                emit_progress_event("phase_changed", None, None).await;
                let scan_started = Instant::now();
                let outcome = tokio::task::block_in_place(|| {
                    process_downloaded_range(
                        &params,
                        &db_cache,
                        &mut db_data,
                        &current_range,
                        current_downloaded,
                    )
                })?;
                let scan_elapsed_ms = scan_started.elapsed().as_millis() as u64;
                batch_tuner.observe(batch_stats, scan_elapsed_ms);
                if let Some(stats) = batch_stats {
                    perf.record(stats, scan_elapsed_ms, &outcome);
                }
                {
                    let mut p = SYNC_PROGRESS.lock().await;
                    p.adaptive_batch_size = batch_tuner.batch_size;
                }
                emit_progress_event("phase_changed", None, None).await;

                match outcome {
                    ScanOutcome::Restarted => {
                        did_restart = true;
                        if let Some(h) = prefetch.take() {
                            h.abort();
                        }
                        break;
                    }
                    ScanOutcome::Scanned {
                        synced_height,
                        notes_found,
                    } => {
                        let mut p = SYNC_PROGRESS.lock().await;
                        p.synced_height = synced_height;
                        drop(p);
                        if notes_found > 0 {
                            let _ =
                                enhance_transactions_inline(&mut db_data, &params, &mut lwd).await;
                        }
                    }
                    ScanOutcome::NothingToScan => {}
                }

                let Some(prefetch_handle) = prefetch.take() else {
                    break;
                };
                let (returned_downloader, next_range, next_downloaded) =
                    prefetch_handle
                        .await
                        .map_err(|e| anyhow::anyhow!("download prefetch join error: {:?}", e))??;
                downloader = returned_downloader;
                current_range = next_range;
                current_downloaded = next_downloaded;
                prefetch = pipeline_iter
                    .next()
                    .map(|next_range| spawn_download_prefetch(downloader, next_range));
            }
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
            if let Err(e) = enhance_transactions(&mut db_data, &params, &mut maintenance_lwd).await
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
    tracing::info!("[sync] pass complete");
    Ok(())
}

/// Fetch full transaction data for any txs in the wallet's enhancement queue
/// and decrypt+store them so memos become available.
///
/// Capped at `MAX_MAINTENANCE_PER_PASS` to avoid holding the gRPC connection
/// open for too long on wallets with large transaction histories. Remaining
/// items stay in the queue and get processed on subsequent sync passes.
const MAX_MAINTENANCE_PER_PASS: usize = 40;

async fn enhance_transactions(
    db_data: &mut DbType,
    params: &Network,
    lwd: &mut CompactTxStreamerClient<tonic::transport::Channel>,
) -> Result<()> {
    enhance_transactions_limited(db_data, params, lwd, MAX_MAINTENANCE_PER_PASS, true).await
}

async fn enhance_transactions_inline(
    db_data: &mut DbType,
    params: &Network,
    lwd: &mut CompactTxStreamerClient<tonic::transport::Channel>,
) -> Result<()> {
    enhance_transactions_limited(db_data, params, lwd, 5, false).await
}

async fn enhance_transactions_limited(
    db_data: &mut DbType,
    params: &Network,
    lwd: &mut CompactTxStreamerClient<tonic::transport::Channel>,
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

    let mut enhanced = 0usize;
    let mut status_checked = 0usize;
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
                match fetch_and_decrypt_tx(db_data, params, lwd, txid).await {
                    Ok(()) => {
                        enhanced += 1;
                        processed += 1;
                        consecutive_rpc_errors = 0;
                        // Small delay between RPCs to avoid hammering the server
                        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
                    }
                    Err(e) => {
                        consecutive_rpc_errors += 1;
                        tracing::debug!("[sync] enhance {}: {:?}", txid, e);
                        if consecutive_rpc_errors >= 3 {
                            tracing::warn!(
                                "[sync] 3 consecutive enhancement failures, \
                                 aborting enhancement (connection likely dropped)"
                            );
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
                        tracing::debug!("[sync] get_status {}: {:?}", txid, e);
                        if consecutive_rpc_errors >= 3 {
                            tracing::warn!(
                                "[sync] 3 consecutive status/enhancement failures, \
                                 aborting maintenance (connection likely dropped)"
                            );
                            break;
                        }
                    }
                }
            }
            _ => {}
        }
    }

    if enhanced > 0 {
        tracing::info!(
            "[sync] enhanced {} transaction(s), checked {} status request(s)",
            enhanced,
            status_checked
        );
    } else {
        tracing::debug!(
            "[sync] no transactions needing enhancement; checked {} status request(s)",
            status_checked
        );
    }

    let mut p = SYNC_PROGRESS.lock().await;
    p.maintenance_queue_len = total.saturating_sub(processed) as u32;
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
    txid: TxId,
) -> Result<()> {
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
    Ok(())
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
    // Use INSERT OR IGNORE because (txid) has a UNIQUE constraint; a tx that
    // already has an enhancement request queued will simply be left as-is.
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
    }
    Ok(())
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
    }
}

#[derive(Clone, Copy, Debug)]
struct AdaptiveBatchTuner {
    batch_size: u32,
}

impl Default for AdaptiveBatchTuner {
    fn default() -> Self {
        Self {
            batch_size: Self::DEFAULT_BATCH_SIZE,
        }
    }
}

impl AdaptiveBatchTuner {
    const MIN_BATCH_SIZE: u32 = 150;
    const MAX_BATCH_SIZE: u32 = 2_000;
    const DEFAULT_BATCH_SIZE: u32 = 1_000;
    const TARGET_WORK_UNITS: u32 = 12_000;
    const SLOW_SCAN_MS: u64 = 4_000;
    const FAST_SCAN_MS: u64 = 1_200;

    fn observe(&mut self, stats: Option<BatchStats>, scan_elapsed_ms: u64) {
        let Some(stats) = stats else {
            return;
        };
        if stats.blocks == 0 || stats.work_units == 0 {
            return;
        }

        // Estimate density (work units per block) and choose the next height batch
        // to keep CPU load and memory stable across sparse/dense regions.
        let density = stats.work_units as f64 / stats.blocks as f64;
        let target_by_density = (Self::TARGET_WORK_UNITS as f64 / density)
            .round()
            .clamp(Self::MIN_BATCH_SIZE as f64, Self::MAX_BATCH_SIZE as f64)
            as u32;

        // Blend current value with target to avoid oscillation.
        let blended = ((self.batch_size as u64 * 7) + (target_by_density as u64 * 3)) / 10;
        self.batch_size = blended as u32;

        // Time-based safety adjustment.
        if scan_elapsed_ms > Self::SLOW_SCAN_MS {
            self.batch_size = (self.batch_size / 2).max(Self::MIN_BATCH_SIZE);
        } else if scan_elapsed_ms < Self::FAST_SCAN_MS {
            self.batch_size = (self.batch_size + self.batch_size / 5).min(Self::MAX_BATCH_SIZE);
        }
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

            if let Some(first) = latest_ranges.first() {
                if first.priority() > priority {
                    tracing::info!(
                        "[sync] higher priority range appeared ({:?} > {:?}), restarting",
                        first.priority(),
                        priority
                    );
                    return Ok(ScanOutcome::Restarted);
                }
            }

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

            db_data
                .truncate_to_height(rewind_height)
                .map_err(|e| anyhow::anyhow!("truncate_to_height: {:?}", e))?;

            db_cache
                .truncate_from(u32::from(rewind_height))
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

fn spawn_download_prefetch(
    mut downloader: CompactTxStreamerClient<tonic::transport::Channel>,
    scan_range: ScanRange,
) -> tokio::task::JoinHandle<
    Result<(
        CompactTxStreamerClient<tonic::transport::Channel>,
        ScanRange,
        Option<DownloadedRange>,
    )>,
> {
    tokio::spawn(async move {
        let downloaded = download_range(&mut downloader, &scan_range).await?;
        Ok((downloader, scan_range, downloaded))
    })
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
