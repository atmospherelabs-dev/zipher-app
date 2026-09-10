use anyhow::Result;
use secrecy::{SecretString, SecretVec};

use zcash_client_backend::data_api::{AccountBirthday, WalletRead, WalletWrite};
use zcash_client_backend::proto::service::{
    compact_tx_streamer_client::CompactTxStreamerClient, BlockId, ChainSpec,
};
use zcash_client_sqlite::wallet::init::init_wallet_db;
use zcash_protocol::consensus::{BlockHeight, Network};

use super::vault::Vault;
use super::{db_paths, migrate_to_encrypted, open_wallet_db, ZipherEngine, ENGINE};

// ---------------------------------------------------------------------------
// lightwalletd gRPC helpers
// ---------------------------------------------------------------------------

pub(crate) async fn connect_lwd(
    server_url: &str,
) -> Result<CompactTxStreamerClient<tonic::transport::Channel>> {
    let tls = tonic::transport::ClientTlsConfig::new().with_webpki_roots();
    let endpoint = tonic::transport::Channel::from_shared(server_url.to_string())?
        .tls_config(tls)?
        .connect_timeout(std::time::Duration::from_secs(15))
        .timeout(std::time::Duration::from_secs(120))
        .keep_alive_timeout(std::time::Duration::from_secs(20))
        .http2_keep_alive_interval(std::time::Duration::from_secs(30));
    let channel = endpoint.connect().await?;
    Ok(CompactTxStreamerClient::new(channel))
}

/// Connect to lightwalletd through the Tor network.
/// Requires `tor_client` to be initialized via `enable_tor`.
pub(crate) async fn connect_lwd_tor(
    tor_client: &zcash_client_backend::tor::Client,
    server_url: &str,
) -> Result<CompactTxStreamerClient<tonic::transport::Channel>> {
    let uri: tonic::transport::Uri = server_url
        .parse()
        .map_err(|e| anyhow::anyhow!("invalid server URL: {}", e))?;
    let is_onion = uri.host().map_or(false, |h| h.ends_with(".onion"));
    let client = tor_client
        .connect_to_lightwalletd(uri, is_onion)
        .await
        .map_err(|e| anyhow::anyhow!("Tor connection failed: {}", e))?;
    Ok(client)
}

pub(crate) async fn fetch_tree_state(
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
// Tor lifecycle
// ---------------------------------------------------------------------------

/// Bootstrap the Tor client and store it in the engine state.
/// `data_dir` is the app's data directory — a `tor/` subdirectory will be
/// created inside it for Arti's persistent data and cache.
static TOR_TRANSITION: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

pub async fn enable_tor(data_dir: &str) -> Result<()> {
    let _transition = TOR_TRANSITION.lock().await;
    let identity = {
        let mut guard = ENGINE.lock().await;
        let engine = guard.as_mut().ok_or_else(|| anyhow::anyhow!("Wallet is not open"))?;
        engine.tor_required = true;
        engine.tor_client = None;
        engine.db_data_path.clone()
    };
    let was_running = super::sync::is_running();
    // Existing HTTP/2 channels retain their route. Join both workers before
    // bootstrapping so a successful toggle also replaces those channels.
    super::sync::stop().await;
    let tor_dir = std::path::PathBuf::from(data_dir).join("tor");
    tokio::fs::create_dir_all(&tor_dir).await?;
    tracing::info!("Bootstrapping Tor for Zcash connections");
    let client = tokio::time::timeout(std::time::Duration::from_secs(120),
        zcash_client_backend::tor::Client::create(&tor_dir, |perms| {
            perms.ignore_prefix(&tor_dir);
        })
    ).await.map_err(|_| anyhow::anyhow!("Tor bootstrap timed out"))?
        .map_err(|e| anyhow::anyhow!("Tor bootstrap failed: {e}"))?;
    {
        let mut guard = ENGINE.lock().await;
        let engine = guard.as_mut().ok_or_else(|| anyhow::anyhow!("Wallet closed"))?;
        if engine.db_data_path != identity {
            anyhow::bail!("Wallet changed while connecting to Tor");
        }
        engine.tor_client = Some(client);
    }
    // Failure leaves Tor required; callers cannot retry over a direct route.
    let verification = tokio::time::timeout(std::time::Duration::from_secs(30), verify_tor_connection())
        .await.map_err(|_| anyhow::anyhow!("Tor verification timed out"))
        .and_then(|result| result);
    if let Err(error) = verification {
        let mut guard = ENGINE.lock().await;
        if let Some(engine) = guard.as_mut().filter(|e| e.db_data_path == identity) {
            engine.tor_client = None;
        }
        return Err(error);
    }
    if was_running { super::sync::start().await?; }
    tracing::info!("Tor verified; Zcash connections use Tor");
    Ok(())
}

/// Explicitly opt back into direct Zcash connections, replacing live channels.
pub async fn disable_tor() {
    let _transition = TOR_TRANSITION.lock().await;
    let was_running = super::sync::is_running();
    super::sync::stop().await;
    {
        let mut guard = ENGINE.lock().await;
        if let Some(ref mut engine) = *guard {
            if let Some(ref client) = engine.tor_client {
                client.set_dormant(zcash_client_backend::tor::DormantMode::Soft);
            }
            engine.tor_client = None;
            engine.tor_required = false;
        }
    }
    if was_running {
        if let Err(error) = super::sync::start().await {
            tracing::warn!("Sync restart after disabling Tor failed: {error}");
        }
    }
}

/// Returns whether Tor is currently active.
pub async fn is_tor_enabled() -> bool {
    let guard = ENGINE.lock().await;
    guard
        .as_ref()
        .map_or(false, |e| e.tor_client.is_some())
}

/// Verify Tor is working by fetching the chain tip through the Tor circuit.
/// Returns the block height if successful, proving traffic actually routes through Tor.
pub async fn verify_tor_connection() -> Result<u64> {
    use zcash_client_backend::proto::service::ChainSpec;

    let (tor, server_url) = {
        let guard = ENGINE.lock().await;
        let engine = guard
            .as_ref()
            .ok_or_else(|| anyhow::anyhow!("engine not initialized"))?;
        let tor = engine
            .tor_client
            .clone()
            .ok_or_else(|| anyhow::anyhow!("Tor is not enabled"))?;
        (tor, engine.server_url.clone())
    };

    tracing::info!("Verifying Tor connection to {}", server_url);
    let mut client = connect_lwd_tor(&tor, &server_url).await?;
    let resp = client
        .get_latest_block(ChainSpec {})
        .await
        .map_err(|e| anyhow::anyhow!("Tor verification failed: {:?}", e))?;
    let height = resp.into_inner().height;
    tracing::info!("Tor verified — fetched block {} via Tor", height);
    Ok(height)
}

/// Resolve a caller-supplied height: 0 means "use chain tip".
async fn resolve_height(server_url: &str, height: u32) -> Result<u64> {
    if height == 0 {
        let tip = fetch_latest_height(server_url).await?;
        tracing::debug!(chain_tip = tip, "Resolved wallet birthday to chain tip");
        Ok(tip)
    } else {
        Ok(height as u64)
    }
}

/// Fetch tree state and build an AccountBirthday.
/// `recover_until`: if `true`, also fetches the chain tip for recover-until
/// (used by restore flows that need to scan from birthday to tip).
async fn build_birthday(
    server_url: &str,
    height: u64,
    with_recover_until: bool,
) -> Result<(AccountBirthday, u64)> {
    let tree_state = fetch_tree_state(server_url, height).await?;
    let recover_until = if with_recover_until {
        let tip = fetch_latest_height(server_url).await?;
        Some(BlockHeight::from_u32(tip as u32))
    } else {
        None
    };
    let birthday = AccountBirthday::from_treestate(tree_state, recover_until)
        .map_err(|_| anyhow::anyhow!("Failed to create account birthday from tree state"))?;
    Ok((birthday, height))
}

/// Store the engine singleton after wallet init.
async fn activate_engine(
    db_data_path: std::path::PathBuf,
    params: Network,
    server_url: &str,
    birthday_height: u64,
    db_cipher_key: Option<String>,
) {
    *ENGINE.lock().await = Some(ZipherEngine {
        db_data_path,
        params,
        server_url: server_url.to_string(),
        birthday: BlockHeight::from_u32(birthday_height as u32),
        db_cipher_key,
        tor_required: false,
        tor_client: None,
    });
}

// ---------------------------------------------------------------------------
// Wallet lifecycle
// ---------------------------------------------------------------------------

/// Create a brand-new wallet. Returns the 24-word BIP39 seed phrase.
///
/// If `vault_passphrase` is `Some`, the seed is encrypted and stored in a
/// vault file alongside the wallet database. Pass `Some("")` for headless /
/// agent mode (no passphrase protection, still encrypted at rest).
pub async fn create(
    data_dir: &str,
    server_url: &str,
    params: Network,
    chain_height: u32,
    db_cipher_key: Option<String>,
    vault_passphrase: Option<&str>,
) -> Result<String> {
    let (db_data_path, _) = db_paths(data_dir);

    let height = resolve_height(server_url, chain_height).await?;
    let (birthday, _) = build_birthday(server_url, height, false).await?;

    let entropy: [u8; 32] = rand::random();
    let mnemonic = bip0039::Mnemonic::<bip0039::English>::from_entropy(&entropy)
        .map_err(|e| anyhow::anyhow!("Mnemonic error: {:?}", e))?;
    let phrase = mnemonic.phrase().to_string();
    let seed = SecretVec::new(mnemonic.to_seed("").to_vec());

    let mut db = open_wallet_db(&db_data_path, params, &db_cipher_key)?;
    init_wallet_db(&mut db, None).map_err(|e| anyhow::anyhow!("init_wallet_db: {:?}", e))?;

    let (_account_id, _usk) = db
        .create_account("Main", &seed, &birthday, None)
        .map_err(|e| anyhow::anyhow!("create_account: {:?}", e))?;

    if let Some(passphrase) = vault_passphrase {
        Vault::create(data_dir, &SecretString::new(phrase.clone()), passphrase)?;
    }

    activate_engine(db_data_path, params, server_url, height, db_cipher_key).await;
    Ok(phrase)
}

/// Restore a wallet from an existing BIP39 seed phrase.
///
/// If `vault_passphrase` is `Some`, the seed is encrypted and stored in a
/// vault file alongside the wallet database.
pub async fn restore(
    data_dir: &str,
    server_url: &str,
    params: Network,
    seed_phrase: &str,
    birthday_height: u32,
    db_cipher_key: Option<String>,
    vault_passphrase: Option<&str>,
) -> Result<()> {
    let (db_data_path, _) = db_paths(data_dir);

    let mnemonic = bip0039::Mnemonic::<bip0039::English>::from_phrase(seed_phrase)
        .map_err(|_| anyhow::anyhow!("Invalid seed phrase"))?;
    let seed = SecretVec::new(mnemonic.to_seed("").to_vec());

    let height = resolve_height(server_url, birthday_height).await?;
    let (birthday, _) = build_birthday(server_url, height, true).await?;

    let mut db = open_wallet_db(&db_data_path, params, &db_cipher_key)?;
    init_wallet_db(&mut db, None).map_err(|e| anyhow::anyhow!("init_wallet_db: {:?}", e))?;

    let (_account_id, _usk) = db
        .create_account("Restored", &seed, &birthday, None)
        .map_err(|e| anyhow::anyhow!("create_account: {:?}", e))?;

    if let Some(passphrase) = vault_passphrase {
        Vault::create(data_dir, &SecretString::new(seed_phrase.to_string()), passphrase)?;
    }

    activate_engine(db_data_path, params, server_url, height, db_cipher_key).await;
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
    let (db_data_path, _) = db_paths(data_dir);

    let height = resolve_height(server_url, birthday_height).await?;
    let (birthday, _) = build_birthday(server_url, height, true).await?;

    let ufvk = zcash_keys::keys::UnifiedFullViewingKey::decode(&params, ufvk_str)
        .map_err(|e| anyhow::anyhow!("Invalid UFVK: {:?}", e))?;

    let mut db = open_wallet_db(&db_data_path, params, &db_cipher_key)?;
    init_wallet_db(&mut db, None).map_err(|e| anyhow::anyhow!("init_wallet_db: {:?}", e))?;

    let _account = db
        .import_account_ufvk(
            "Watch-only",
            &ufvk,
            &birthday,
            zcash_client_backend::data_api::AccountPurpose::ViewOnly,
            None,
        )
        .map_err(|e| anyhow::anyhow!("import_account_ufvk: {:?}", e))?;

    activate_engine(db_data_path, params, server_url, height, db_cipher_key).await;
    Ok(())
}

/// Open an existing wallet database.
pub async fn open(
    data_dir: &str,
    server_url: &str,
    params: Network,
    db_cipher_key: Option<String>,
) -> Result<()> {
    let (db_data_path, _) = db_paths(data_dir);

    if !db_data_path.exists() {
        return Err(anyhow::anyhow!(
            "Wallet database not found at {:?}",
            db_data_path
        ));
    }

    tracing::debug!("open wallet at {:?}", db_data_path);

    if let Some(ref key) = db_cipher_key {
        migrate_to_encrypted(&db_data_path, key).ok();
    }

    let mut db = open_wallet_db(&db_data_path, params, &db_cipher_key)?;

    // Catch panics from init_wallet_db (schema migrations can panic on
    // incompatible old databases). Return a clean error instead of aborting.
    let init_result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        init_wallet_db(&mut db, None)
    }));

    match init_result {
        Ok(Ok(_)) => {},
        Ok(Err(e)) => {
            return Err(anyhow::anyhow!("database schema migration failed: {:?}", e));
        },
        Err(_panic) => {
            return Err(anyhow::anyhow!(
                "database schema migration panicked — the wallet database is incompatible with this version. \
                 Delete and restore from seed to fix."
            ));
        },
    }

    let account_ids = db
        .get_account_ids()
        .map_err(|e| anyhow::anyhow!("get_account_ids error: {:?}", e))?;
    let account_id = account_ids
        .first()
        .ok_or_else(|| anyhow::anyhow!("No accounts in wallet"))?;

    let birthday = db
        .get_account_birthday(*account_id)
        .map_err(|e| anyhow::anyhow!("get_account_birthday error: {:?}", e))?;
    tracing::debug!("opened wallet, birthday={}", u32::from(birthday));

    *ENGINE.lock().await = Some(ZipherEngine {
        db_data_path,
        params,
        server_url: server_url.to_string(),
        birthday,
        db_cipher_key,
        tor_required: false,
        tor_client: None,
    });

    Ok(())
}

/// Close the wallet: stop sync, wait for it, then drop the engine.
pub async fn close() {
    tracing::info!("[engine] close wallet — stopping sync first");
    super::sync::stop().await;

    *ENGINE.lock().await = None;
    tracing::info!("[engine] wallet closed");
}

/// Update the active lightwalletd server. Sync is stopped first so the next
/// sync start uses the new URL instead of a stale in-flight client.
pub async fn set_server(server_url: &str) -> Result<()> {
    super::sync::stop().await;
    let mut engine = ENGINE.lock().await;
    let engine = engine
        .as_mut()
        .ok_or_else(|| anyhow::anyhow!("Engine not initialized"))?;
    engine.server_url = server_url.to_string();
    tracing::info!("[engine] lightwalletd server updated");
    Ok(())
}

/// Decrypt the seed phrase from the vault.
/// Returns the seed as a SecretString; zeroized on drop.
pub fn decrypt_vault(data_dir: &str, passphrase: &str) -> Result<SecretString> {
    let vault = Vault::open(data_dir)?;
    vault.decrypt_seed(passphrase)
}

/// Delete wallet database files and vault from disk.
pub fn delete(data_dir: &str) -> Result<()> {
    let (db_data_path, db_cache_path) = db_paths(data_dir);

    let vault_path = Vault::vault_path(data_dir);

    for path in &[
        db_data_path.clone(),
        db_cache_path.clone(),
        db_data_path.with_extension("sqlite-wal"),
        db_data_path.with_extension("sqlite-shm"),
        db_cache_path.with_extension("sqlite-wal"),
        db_cache_path.with_extension("sqlite-shm"),
        vault_path,
    ] {
        if path.exists() {
            std::fs::remove_file(path).ok();
        }
    }
    Ok(())
}
