use anyhow::Result;
use secrecy::SecretVec;

use zcash_client_backend::data_api::{AccountBirthday, WalletRead, WalletWrite};
use zcash_client_backend::proto::service::{
    compact_tx_streamer_client::CompactTxStreamerClient, BlockId, ChainSpec,
};
use zcash_client_sqlite::wallet::init::init_wallet_db;
use zcash_protocol::consensus::{BlockHeight, Network};

use super::{db_paths, open_wallet_db, migrate_to_encrypted, ZipherEngine, ENGINE};

// ---------------------------------------------------------------------------
// lightwalletd gRPC helpers
// ---------------------------------------------------------------------------

pub(crate) async fn connect_lwd(
    server_url: &str,
) -> Result<CompactTxStreamerClient<tonic::transport::Channel>> {
    let tls = tonic::transport::ClientTlsConfig::new()
        .with_webpki_roots();
    let endpoint = tonic::transport::Channel::from_shared(server_url.to_string())?
        .tls_config(tls)?;
    let channel = endpoint.connect().await?;
    Ok(CompactTxStreamerClient::new(channel))
}

async fn fetch_tree_state(
    server_url: &str,
    height: u64,
) -> Result<zcash_client_backend::proto::service::TreeState> {
    let mut client = connect_lwd(server_url).await?;
    let resp = client
        .get_tree_state(BlockId {
            height,
            hash: vec![],
        })
        .await
        .map_err(|e| anyhow::anyhow!("get_tree_state failed: {:?}", e))?;
    Ok(resp.into_inner())
}

pub async fn fetch_latest_height(server_url: &str) -> Result<u64> {
    let mut client = connect_lwd(server_url).await?;
    let resp = client
        .get_latest_block(ChainSpec {})
        .await
        .map_err(|e| anyhow::anyhow!("get_latest_block failed: {:?}", e))?;
    Ok(resp.into_inner().height)
}

// ---------------------------------------------------------------------------
// Wallet lifecycle
// ---------------------------------------------------------------------------

/// Create a brand-new wallet. Returns the 24-word BIP39 seed phrase.
pub async fn create(
    data_dir: &str,
    server_url: &str,
    params: Network,
    chain_height: u32,
    db_cipher_key: Option<String>,
) -> Result<String> {
    println!("[engine] create wallet dir={} height={}", data_dir, chain_height);

    let (db_data_path, db_cache_path) = db_paths(data_dir);

    let tree_state = fetch_tree_state(server_url, chain_height as u64).await?;
    let birthday = AccountBirthday::from_treestate(tree_state, None)
        .map_err(|_| anyhow::anyhow!("Failed to create account birthday from tree state"))?;

    let entropy: [u8; 32] = rand::random();
    let mnemonic = bip0039::Mnemonic::<bip0039::English>::from_entropy(&entropy)
        .map_err(|e| anyhow::anyhow!("Mnemonic error: {:?}", e))?;
    let phrase = mnemonic.phrase().to_string();
    let seed_bytes = mnemonic.to_seed("");
    let seed = SecretVec::new(seed_bytes.to_vec());

    let mut db = open_wallet_db(&db_data_path, params, &db_cipher_key)?;
    init_wallet_db(&mut db, None)
        .map_err(|e| anyhow::anyhow!("init_wallet_db error: {:?}", e))?;

    let (account_id, _usk) = db
        .create_account("Main", &seed, &birthday, None)
        .map_err(|e| anyhow::anyhow!("create_account error: {:?}", e))?;
    println!("[engine] created account {:?}", account_id);

    *ENGINE.lock().await = Some(ZipherEngine {
        db_data_path,
        db_cache_path,
        params,
        server_url: server_url.to_string(),
        birthday: BlockHeight::from_u32(chain_height),
        db_cipher_key,
    });

    Ok(phrase)
}

/// Restore a wallet from an existing BIP39 seed phrase.
pub async fn restore(
    data_dir: &str,
    server_url: &str,
    params: Network,
    seed_phrase: &str,
    birthday_height: u32,
    db_cipher_key: Option<String>,
) -> Result<()> {
    println!(
        "[engine] restore wallet dir={} birthday={}",
        data_dir, birthday_height
    );

    let (db_data_path, db_cache_path) = db_paths(data_dir);

    let mnemonic = bip0039::Mnemonic::<bip0039::English>::from_phrase(seed_phrase)
        .map_err(|e| anyhow::anyhow!("Invalid seed phrase: {:?}", e))?;
    let seed_bytes = mnemonic.to_seed("");
    let seed = SecretVec::new(seed_bytes.to_vec());

    let tree_state = fetch_tree_state(server_url, birthday_height as u64).await?;
    let chain_tip = fetch_latest_height(server_url).await?;
    let recover_until = Some(BlockHeight::from_u32(chain_tip as u32));

    let birthday = AccountBirthday::from_treestate(tree_state, recover_until)
        .map_err(|_| anyhow::anyhow!("Failed to create account birthday from tree state"))?;

    let mut db = open_wallet_db(&db_data_path, params, &db_cipher_key)?;
    init_wallet_db(&mut db, None)
        .map_err(|e| anyhow::anyhow!("init_wallet_db error: {:?}", e))?;

    let (account_id, _usk) = db
        .create_account("Restored", &seed, &birthday, None)
        .map_err(|e| anyhow::anyhow!("create_account error: {:?}", e))?;
    println!("[engine] restored account {:?}", account_id);

    *ENGINE.lock().await = Some(ZipherEngine {
        db_data_path,
        db_cache_path,
        params,
        server_url: server_url.to_string(),
        birthday: BlockHeight::from_u32(birthday_height),
        db_cipher_key,
    });

    Ok(())
}

/// Restore a watch-only wallet from a UFVK (no spending capability).
pub async fn restore_from_ufvk(
    data_dir: &str,
    server_url: &str,
    params: Network,
    ufvk_str: &str,
    birthday_height: u32,
    db_cipher_key: Option<String>,
) -> Result<()> {
    println!(
        "[engine] restore from UFVK dir={} birthday={}",
        data_dir, birthday_height
    );

    let (db_data_path, db_cache_path) = db_paths(data_dir);

    let tree_state = fetch_tree_state(server_url, birthday_height as u64).await?;
    let chain_tip = fetch_latest_height(server_url).await?;
    let recover_until = Some(BlockHeight::from_u32(chain_tip as u32));

    let birthday = AccountBirthday::from_treestate(tree_state, recover_until)
        .map_err(|_| anyhow::anyhow!("Failed to create account birthday from tree state"))?;

    let ufvk = zcash_keys::keys::UnifiedFullViewingKey::decode(&params, ufvk_str)
        .map_err(|e| anyhow::anyhow!("Invalid UFVK: {:?}", e))?;

    let mut db = open_wallet_db(&db_data_path, params, &db_cipher_key)?;
    init_wallet_db(&mut db, None)
        .map_err(|e| anyhow::anyhow!("init_wallet_db error: {:?}", e))?;

    let _account = db
        .import_account_ufvk(
            "Watch-only",
            &ufvk,
            &birthday,
            zcash_client_backend::data_api::AccountPurpose::ViewOnly,
            None,
        )
        .map_err(|e| anyhow::anyhow!("import_account_ufvk error: {:?}", e))?;
    println!("[engine] imported watch-only account");

    *ENGINE.lock().await = Some(ZipherEngine {
        db_data_path,
        db_cache_path,
        params,
        server_url: server_url.to_string(),
        birthday: BlockHeight::from_u32(birthday_height),
        db_cipher_key,
    });

    Ok(())
}

/// Open an existing wallet database.
pub async fn open(
    data_dir: &str,
    server_url: &str,
    params: Network,
    db_cipher_key: Option<String>,
) -> Result<()> {
    let (db_data_path, db_cache_path) = db_paths(data_dir);

    if !db_data_path.exists() {
        return Err(anyhow::anyhow!(
            "Wallet database not found at {:?}",
            db_data_path
        ));
    }

    println!("[engine] open wallet at {:?}", db_data_path);

    if let Some(ref key) = db_cipher_key {
        migrate_to_encrypted(&db_data_path, key).ok();
        migrate_to_encrypted(&db_cache_path, key).ok();
    }

    let mut db = open_wallet_db(&db_data_path, params, &db_cipher_key)?;
    init_wallet_db(&mut db, None)
        .map_err(|e| anyhow::anyhow!("init_wallet_db error: {:?}", e))?;

    let account_ids = db
        .get_account_ids()
        .map_err(|e| anyhow::anyhow!("get_account_ids error: {:?}", e))?;
    let account_id = account_ids
        .first()
        .ok_or_else(|| anyhow::anyhow!("No accounts in wallet"))?;

    let birthday = db
        .get_account_birthday(*account_id)
        .map_err(|e| anyhow::anyhow!("get_account_birthday error: {:?}", e))?;
    println!("[engine] opened wallet, birthday={}", u32::from(birthday));

    *ENGINE.lock().await = Some(ZipherEngine {
        db_data_path,
        db_cache_path,
        params,
        server_url: server_url.to_string(),
        birthday,
        db_cipher_key,
    });

    Ok(())
}

/// Close the wallet: stop sync, wait for it, then drop the engine.
pub async fn close() {
    tracing::info!("[engine] close wallet — stopping sync first");
    super::sync::stop().await;

    for _ in 0..50 {
        if !super::sync::is_running() {
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(100)).await;
    }
    if super::sync::is_running() {
        tracing::warn!("[engine] sync still running after 5s, proceeding with close");
    }

    *ENGINE.lock().await = None;
    tracing::info!("[engine] wallet closed");
}

/// Delete wallet database files from disk.
pub fn delete(data_dir: &str) -> Result<()> {
    let (db_data_path, db_cache_path) = db_paths(data_dir);

    for path in &[
        db_data_path.clone(),
        db_cache_path.clone(),
        db_data_path.with_extension("sqlite-wal"),
        db_data_path.with_extension("sqlite-shm"),
        db_cache_path.with_extension("sqlite-wal"),
        db_cache_path.with_extension("sqlite-shm"),
    ] {
        if path.exists() {
            std::fs::remove_file(path).ok();
        }
    }
    Ok(())
}
