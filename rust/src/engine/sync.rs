use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};

use anyhow::Result;
use prost::Message;
use tokio::sync::Mutex as TokioMutex;

use zcash_client_backend::data_api::chain::{scan_cached_blocks, BlockSource, CommitmentTreeRoot};
use zcash_client_backend::data_api::scanning::ScanPriority;
use zcash_client_backend::data_api::{WalletCommitmentTrees, WalletRead, WalletWrite};
use zcash_client_backend::proto::compact_formats::CompactBlock;
use zcash_client_backend::proto::service::{
    compact_tx_streamer_client::CompactTxStreamerClient, BlockId, BlockRange, ChainSpec,
    GetAddressUtxosArg, GetSubtreeRootsArg, ShieldedProtocol,
};
use zcash_client_backend::wallet::WalletTransparentOutput;
use zcash_client_sqlite::WalletDb;
use zcash_keys::encoding::AddressCodec as _;
use zcash_protocol::consensus::{BlockHeight, Network};
use zcash_protocol::value::Zatoshis;
use zcash_transparent::address::Script;
use zcash_transparent::bundle::{OutPoint, TxOut};

use zcash_primitives::merkle_tree::HashSer;

use super::wallet::connect_lwd;
use super::{open_wallet_db, open_cipher_conn, ENGINE};

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
}

#[derive(Default, Clone, Debug)]
pub struct SyncProgressInfo {
    pub synced_height: u32,
    pub latest_height: u32,
    pub is_syncing: bool,
    pub connection_error: Option<String>,
}

#[derive(Clone, Debug)]
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
    }

    tokio::spawn(async move {
        match sync_loop_with_retry(
            &db_data_path,
            &db_cache_path,
            params,
            &server_url,
            &db_cipher_key,
        )
        .await
        {
            Ok(()) => println!("[engine sync] completed successfully"),
            Err(e) => println!("[engine sync] error: {:?}", e),
        }
        SYNC_RUNNING.store(false, Ordering::SeqCst);
        {
            let mut p = SYNC_PROGRESS.lock().await;
            p.is_syncing = false;
        }
    });

    Ok(())
}

pub async fn stop() {
    SYNC_CANCEL.store(true, Ordering::SeqCst);
}

pub async fn get_progress() -> SyncProgressInfo {
    SYNC_PROGRESS.lock().await.clone()
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
            )"
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
        use zcash_client_backend::data_api::chain::error::Error as ChainError;

        let from = from_height.map(u32::from).unwrap_or(0);
        let lim = limit.unwrap_or(u32::MAX as usize) as u32;

        let mut stmt = self
            .conn
            .prepare_cached(
                "SELECT height, data FROM compactblocks WHERE height >= ? ORDER BY height ASC LIMIT ?",
            )
            .map_err(|e| ChainError::BlockSource(BlockCacheError::from(e)))?;

        let rows = stmt
            .query_map(rusqlite::params![from, lim], |row| {
                let data: Vec<u8> = row.get(1)?;
                Ok(data)
            })
            .map_err(|e| ChainError::BlockSource(BlockCacheError::from(e)))?;

        for row in rows {
            let data =
                row.map_err(|e| ChainError::BlockSource(BlockCacheError::from(e)))?;
            let block = CompactBlock::decode(&data[..])
                .map_err(|e| ChainError::BlockSource(BlockCacheError(e.to_string())))?;
            with_block(block)?;
        }

        Ok(())
    }
}

// ---------------------------------------------------------------------------
// Sync loop with exponential backoff retry
// ---------------------------------------------------------------------------

async fn sync_loop_with_retry(
    db_data_path: &Path,
    db_cache_path: &Path,
    params: Network,
    server_url: &str,
    db_cipher_key: &Option<String>,
) -> Result<()> {
    let mut backoff_ms: u64 = 5_000;
    const MAX_BACKOFF_MS: u64 = 60_000;

    loop {
        if SYNC_CANCEL.load(Ordering::SeqCst) {
            return Err(anyhow::anyhow!("Sync cancelled"));
        }

        match sync_loop(db_data_path, db_cache_path, params, server_url, db_cipher_key).await {
            Ok(()) => {
                // Active wallet is caught up — sync inactive wallets, then sleep
                {
                    let mut p = SYNC_PROGRESS.lock().await;
                    p.connection_error = None;
                }

                sync_inactive_wallets(params, server_url, db_cipher_key).await;

                // Sleep 30s then re-check for new blocks (respecting cancel)
                for _ in 0..30 {
                    if SYNC_CANCEL.load(Ordering::SeqCst) {
                        return Ok(());
                    }
                    tokio::time::sleep(std::time::Duration::from_secs(1)).await;
                }
                backoff_ms = 5_000;
            }
            Err(e) => {
                let msg = format!("{:?}", e);
                if msg.contains("Sync cancelled") {
                    return Err(e);
                }

                println!("[engine sync] error, retrying in {}ms: {}", backoff_ms, msg);
                {
                    let mut p = SYNC_PROGRESS.lock().await;
                    p.connection_error = Some(msg);
                }

                // Exponential backoff sleep with cancel check
                let sleep_chunks = backoff_ms / 1000;
                for _ in 0..sleep_chunks {
                    if SYNC_CANCEL.load(Ordering::SeqCst) {
                        return Err(anyhow::anyhow!("Sync cancelled"));
                    }
                    tokio::time::sleep(std::time::Duration::from_secs(1)).await;
                }

                backoff_ms = (backoff_ms * 2).min(MAX_BACKOFF_MS);
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Core sync loop (single pass)
// ---------------------------------------------------------------------------

async fn sync_loop(
    db_data_path: &Path,
    db_cache_path: &Path,
    params: Network,
    server_url: &str,
    db_cipher_key: &Option<String>,
) -> Result<()> {
    println!("[engine sync] starting sync loop");

    let mut db_data = open_wallet_db(db_data_path, params, db_cipher_key)?;
    let db_cache = BlockCache::open(db_cache_path, db_cipher_key)?;
    let mut lwd = connect_lwd(server_url).await?;

    update_subtree_roots(&mut lwd, &mut db_data).await?;

    let batch_size: u32 = 1000;

    loop {
        if SYNC_CANCEL.load(Ordering::SeqCst) {
            return Err(anyhow::anyhow!("Sync cancelled"));
        }

        let tip = lwd
            .get_latest_block(ChainSpec::default())
            .await
            .map_err(|e| anyhow::anyhow!("get_latest_block: {:?}", e))?;
        let tip_height = BlockHeight::from_u32(tip.into_inner().height as u32);

        db_data
            .update_chain_tip(tip_height)
            .map_err(|e| anyhow::anyhow!("update_chain_tip: {:?}", e))?;

        {
            let mut p = SYNC_PROGRESS.lock().await;
            p.latest_height = u32::from(tip_height);
            p.connection_error = None;
        }

        // Refresh transparent UTXOs before shielded scanning
        if let Err(e) = refresh_transparent_utxos(&mut lwd, &mut db_data, &params).await {
            println!("[engine sync] transparent UTXO refresh warning: {:?}", e);
        }

        let scan_ranges = db_data
            .suggest_scan_ranges()
            .map_err(|e| anyhow::anyhow!("suggest_scan_ranges: {:?}", e))?;

        if scan_ranges.is_empty() {
            println!("[engine sync] no more ranges to scan, done");
            break;
        }

        let mut any_scanned = false;

        for range in &scan_ranges {
            if range.priority() <= ScanPriority::Scanned {
                continue;
            }

            if SYNC_CANCEL.load(Ordering::SeqCst) {
                return Err(anyhow::anyhow!("Sync cancelled"));
            }

            let range_start = range.block_range().start;
            let range_end = range.block_range().end;
            println!(
                "[engine sync] scanning range {:?} priority={:?}",
                range.block_range(),
                range.priority()
            );

            let mut current = range_start;
            while current < range_end {
                if SYNC_CANCEL.load(Ordering::SeqCst) {
                    return Err(anyhow::anyhow!("Sync cancelled"));
                }

                let batch_end = std::cmp::min(
                    current + batch_size,
                    range_end,
                );

                let chain_state = download_chain_state(&mut lwd, current).await?;
                let blocks = download_blocks(&mut lwd, current, batch_end).await?;
                if blocks.is_empty() {
                    break;
                }

                db_cache
                    .insert_blocks(&blocks)
                    .map_err(|e| anyhow::anyhow!("insert_blocks: {:?}", e))?;

                let batch_len = u32::from(batch_end) - u32::from(current);
                let scan_result = scan_cached_blocks(
                    &params,
                    &db_cache,
                    &mut db_data,
                    current,
                    &chain_state,
                    batch_len as usize,
                );

                match scan_result {
                    Ok(summary) => {
                        let scanned = u32::from(summary.scanned_range().end)
                            - u32::from(summary.scanned_range().start);
                        println!(
                            "[engine sync] scanned {} blocks, {} notes found",
                            scanned,
                            summary.received_sapling_note_count()
                                + summary.received_orchard_note_count()
                        );
                    }
                    Err(e) => {
                        let err_str = format!("{:?}", e);
                        println!("[engine sync] scan error: {}", err_str);

                        db_cache
                            .clear_range(u32::from(current), u32::from(batch_end))
                            .ok();

                        // Reorg detection: if the error indicates chain
                        // continuity failure, truncate the wallet DB to before
                        // the bad range and let suggest_scan_ranges re-plan.
                        if err_str.contains("PrevHash")
                            || err_str.contains("Continuity")
                            || err_str.contains("ChainInvalid")
                            || err_str.contains("BlockConflict")
                        {
                            let reorg_height = current - 1;
                            println!(
                                "[engine sync] reorg detected, truncating to {}",
                                u32::from(reorg_height)
                            );
                            db_data
                                .truncate_to_height(reorg_height)
                                .map_err(|e| {
                                    anyhow::anyhow!("truncate_to_height: {:?}", e)
                                })?;
                            // Break inner loop; outer loop will re-fetch
                            // scan ranges from the corrected state.
                            any_scanned = true;
                        }
                        break;
                    }
                }

                db_cache
                    .clear_range(u32::from(current), u32::from(batch_end))
                    .ok();

                {
                    let mut p = SYNC_PROGRESS.lock().await;
                    p.synced_height = u32::from(batch_end);
                    p.latest_height = u32::from(tip_height);
                    p.is_syncing = true;
                }

                current = batch_end;
                any_scanned = true;
            }
        }

        if !any_scanned {
            break;
        }
    }

    println!("[engine sync] sync loop finished");
    Ok(())
}

// ---------------------------------------------------------------------------
// Background sync for inactive wallets
// ---------------------------------------------------------------------------

async fn sync_inactive_wallets(
    params: Network,
    server_url: &str,
    db_cipher_key: &Option<String>,
) {
    let wallets = INACTIVE_WALLETS.lock().await.clone();
    if wallets.is_empty() {
        return;
    }

    println!("[engine sync] syncing {} inactive wallet(s)", wallets.len());

    for wallet in &wallets {
        if SYNC_CANCEL.load(Ordering::SeqCst) {
            return;
        }

        if !wallet.db_data_path.exists() {
            continue;
        }

        if let Err(e) = sync_inactive_wallet_batch(
            &wallet.db_data_path,
            &wallet.db_cache_path,
            params,
            server_url,
            db_cipher_key,
        )
        .await
        {
            println!(
                "[engine sync] inactive wallet {:?} error: {:?}",
                wallet.db_data_path, e
            );
        }
    }
}

async fn sync_inactive_wallet_batch(
    db_data_path: &Path,
    db_cache_path: &Path,
    params: Network,
    server_url: &str,
    db_cipher_key: &Option<String>,
) -> Result<()> {
    let mut db_data = open_wallet_db(db_data_path, params, db_cipher_key)?;
    let db_cache = BlockCache::open(db_cache_path, db_cipher_key)?;
    let mut lwd = connect_lwd(server_url).await?;

    let tip = lwd
        .get_latest_block(ChainSpec::default())
        .await
        .map_err(|e| anyhow::anyhow!("get_latest_block: {:?}", e))?;
    let tip_height = BlockHeight::from_u32(tip.into_inner().height as u32);

    db_data
        .update_chain_tip(tip_height)
        .map_err(|e| anyhow::anyhow!("update_chain_tip: {:?}", e))?;

    let scan_ranges = db_data
        .suggest_scan_ranges()
        .map_err(|e| anyhow::anyhow!("suggest_scan_ranges: {:?}", e))?;

    let batch_size: u32 = 500;

    for range in &scan_ranges {
        if range.priority() <= ScanPriority::Scanned {
            continue;
        }

        if SYNC_CANCEL.load(Ordering::SeqCst) {
            return Ok(());
        }

        let range_start = range.block_range().start;
        let batch_end = std::cmp::min(range_start + batch_size, range.block_range().end);

        let chain_state = download_chain_state(&mut lwd, range_start).await?;
        let blocks = download_blocks(&mut lwd, range_start, batch_end).await?;
        if blocks.is_empty() {
            break;
        }

        db_cache
            .insert_blocks(&blocks)
            .map_err(|e| anyhow::anyhow!("insert_blocks: {:?}", e))?;

        let batch_len = u32::from(batch_end) - u32::from(range_start);
        let _ = scan_cached_blocks(
            &params,
            &db_cache,
            &mut db_data,
            range_start,
            &chain_state,
            batch_len as usize,
        );

        db_cache
            .clear_range(u32::from(range_start), u32::from(batch_end))
            .ok();

        // Only one batch per inactive wallet per cycle
        break;
    }

    Ok(())
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

async fn update_subtree_roots(
    lwd: &mut CompactTxStreamerClient<tonic::transport::Channel>,
    db_data: &mut WalletDb<rusqlite::Connection, Network, zcash_client_sqlite::util::SystemClock, rand::rngs::OsRng>,
) -> Result<()> {
    use futures_util::TryStreamExt;

    let mut sapling_request = GetSubtreeRootsArg::default();
    sapling_request.set_shielded_protocol(ShieldedProtocol::Sapling);

    let sapling_stream = lwd
        .get_subtree_roots(sapling_request)
        .await
        .map_err(|e| anyhow::anyhow!("get_subtree_roots(sapling): {:?}", e))?
        .into_inner();

    let sapling_roots: Vec<CommitmentTreeRoot<sapling_crypto::Node>> = sapling_stream
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

    println!(
        "[engine sync] {} sapling subtree roots",
        sapling_roots.len()
    );
    db_data
        .put_sapling_subtree_roots(0, &sapling_roots)
        .map_err(|e| anyhow::anyhow!("put_sapling_subtree_roots: {:?}", e))?;

    let mut orchard_request = GetSubtreeRootsArg::default();
    orchard_request.set_shielded_protocol(ShieldedProtocol::Orchard);

    let orchard_stream = lwd
        .get_subtree_roots(orchard_request)
        .await
        .map_err(|e| anyhow::anyhow!("get_subtree_roots(orchard): {:?}", e))?
        .into_inner();

    let orchard_roots: Vec<CommitmentTreeRoot<orchard::tree::MerkleHashOrchard>> = orchard_stream
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

    println!(
        "[engine sync] {} orchard subtree roots",
        orchard_roots.len()
    );
    db_data
        .put_orchard_subtree_roots(0, &orchard_roots)
        .map_err(|e| anyhow::anyhow!("put_orchard_subtree_roots: {:?}", e))?;

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

type DbType = WalletDb<rusqlite::Connection, Network, zcash_client_sqlite::util::SystemClock, rand::rngs::OsRng>;

async fn refresh_transparent_utxos(
    lwd: &mut CompactTxStreamerClient<tonic::transport::Channel>,
    db_data: &mut DbType,
    params: &Network,
) -> Result<()> {
    let account_ids = db_data
        .get_account_ids()
        .map_err(|e| anyhow::anyhow!("get_account_ids: {:?}", e))?;

    for account_id in account_ids {
        let start_height = db_data
            .utxo_query_height(account_id)
            .map_err(|e| anyhow::anyhow!("utxo_query_height: {:?}", e))?;

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

        println!(
            "[engine sync] refreshing transparent UTXOs for {:?} from height {} ({} addresses)",
            account_id, start_height, addresses.len()
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
            let Ok(txid_arr) = reply.txid[..].try_into() else { continue };
            let Ok(index) = reply.index.try_into() else { continue };
            let Ok(value) = Zatoshis::from_nonnegative_i64(reply.value_zat) else { continue };
            let Ok(height) = BlockHeight::try_from(reply.height) else { continue };

            let outpoint = OutPoint::new(txid_arr, index);
            let txout = TxOut::new(value, Script(zcash_script::script::Code(reply.script)));

            if let Some(output) = WalletTransparentOutput::from_parts(outpoint, txout, Some(height)) {
                db_data
                    .put_received_transparent_utxo(&output)
                    .map_err(|e| anyhow::anyhow!("put_received_transparent_utxo: {:?}", e))?;
                count += 1;
            }
        }

        if count > 0 {
            println!("[engine sync] stored {} transparent UTXOs for {:?}", count, account_id);
        }
    }

    Ok(())
}
