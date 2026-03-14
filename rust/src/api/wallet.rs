use std::num::NonZeroU32;

use anyhow::Result;
use flutter_rust_bridge::frb;
use tokio::sync::RwLock;

use zcash_protocol::consensus::BlockHeight;
use zcash_protocol::value::Zatoshis;

use zingolib::config::{self, ZingoConfig};
use zingolib::lightclient::LightClient;
use zingolib::wallet::{LightWallet, WalletBase};

lazy_static::lazy_static! {
    static ref CLIENT: RwLock<Option<LightClient>> = RwLock::new(None);
}

fn zat_to_u64(z: Option<Zatoshis>) -> u64 {
    z.map(|v| u64::from(v)).unwrap_or(0)
}

// ---------------------------------------------------------------------------
// Initialization
// ---------------------------------------------------------------------------

/// Create a brand-new wallet from fresh entropy.
/// Returns the 24-word seed phrase.
pub async fn create_wallet(
    data_dir: String,
    server_url: String,
    chain_type: ChainType,
    chain_height: u32,
) -> Result<String> {
    let config = build_config(&data_dir, &server_url, chain_type)?;
    let height = BlockHeight::from_u32(chain_height);

    let client = LightClient::new(config, height, true)
        .map_err(|e| anyhow::anyhow!("{:?}", e))?;

    let phrase = {
        let wallet = client.wallet.read().await;
        wallet.mnemonic_phrase().unwrap_or_default()
    };

    *CLIENT.write().await = Some(client);
    Ok(phrase)
}

/// Restore a wallet from a seed phrase.
pub async fn restore_from_seed(
    data_dir: String,
    server_url: String,
    chain_type: ChainType,
    seed_phrase: String,
    birthday: u32,
) -> Result<()> {
    let config = build_config(&data_dir, &server_url, chain_type)?;
    let height = BlockHeight::from_u32(birthday);
    let network = config.network_type();

    let mnemonic = bip0039::Mnemonic::<bip0039::English>::from_phrase(&seed_phrase)
        .map_err(|e| anyhow::anyhow!("Invalid seed phrase: {:?}", e))?;

    let wallet = LightWallet::new(
        network,
        WalletBase::Mnemonic {
            mnemonic,
            no_of_accounts: NonZeroU32::new(1).unwrap(),
        },
        height,
        config.wallet_settings(),
    )
    .map_err(|e| anyhow::anyhow!("{:?}", e))?;

    let client = LightClient::create_from_wallet(wallet, config, true)
        .map_err(|e| anyhow::anyhow!("{:?}", e))?;

    *CLIENT.write().await = Some(client);
    Ok(())
}

/// Restore a wallet from a unified full viewing key (watch-only).
pub async fn restore_from_ufvk(
    data_dir: String,
    server_url: String,
    chain_type: ChainType,
    ufvk: String,
    birthday: u32,
) -> Result<()> {
    let config = build_config(&data_dir, &server_url, chain_type)?;
    let height = BlockHeight::from_u32(birthday);
    let network = config.network_type();

    let wallet = LightWallet::new(
        network,
        WalletBase::Ufvk(ufvk),
        height,
        config.wallet_settings(),
    )
    .map_err(|e| anyhow::anyhow!("{:?}", e))?;

    let client = LightClient::create_from_wallet(wallet, config, true)
        .map_err(|e| anyhow::anyhow!("{:?}", e))?;

    *CLIENT.write().await = Some(client);
    Ok(())
}

/// Open an existing wallet from disk.
pub async fn open_wallet(
    data_dir: String,
    server_url: String,
    chain_type: ChainType,
) -> Result<()> {
    let config = build_config(&data_dir, &server_url, chain_type)?;
    let client = LightClient::create_from_wallet_path(config)
        .map_err(|e| anyhow::anyhow!("{:?}", e))?;

    *CLIENT.write().await = Some(client);
    Ok(())
}

/// Save the wallet to disk and release resources.
pub async fn close_wallet() -> Result<()> {
    let mut guard = CLIENT.write().await;
    if let Some(mut client) = guard.take() {
        client.shutdown_save_task().await.ok();
    }
    Ok(())
}

// ---------------------------------------------------------------------------
// Sync (pepper-sync)
// ---------------------------------------------------------------------------

/// Start syncing and await completion.
pub async fn sync_wallet() -> Result<SyncResultInfo> {
    let mut guard = CLIENT.write().await;
    let client = guard
        .as_mut()
        .ok_or_else(|| anyhow::anyhow!("Wallet not initialized"))?;

    let result = client
        .sync_and_await()
        .await
        .map_err(|e| anyhow::anyhow!("{:?}", e))?;

    Ok(SyncResultInfo {
        start_height: u32::from(result.sync_start_height),
        end_height: u32::from(result.sync_end_height),
        blocks_scanned: result.blocks_scanned,
    })
}

/// Start syncing without awaiting (runs in background).
pub async fn start_sync() -> Result<()> {
    let mut guard = CLIENT.write().await;
    let client = guard
        .as_mut()
        .ok_or_else(|| anyhow::anyhow!("Wallet not initialized"))?;

    client
        .sync()
        .await
        .map_err(|e| anyhow::anyhow!("{:?}", e))?;
    Ok(())
}

/// Pause a running sync.
pub async fn pause_sync() -> Result<()> {
    let guard = CLIENT.read().await;
    let client = guard
        .as_ref()
        .ok_or_else(|| anyhow::anyhow!("Wallet not initialized"))?;

    client
        .pause_sync()
        .map_err(|e| anyhow::anyhow!("{:?}", e))?;
    Ok(())
}

/// Resume a paused sync.
pub async fn resume_sync() -> Result<()> {
    let guard = CLIENT.read().await;
    let client = guard
        .as_ref()
        .ok_or_else(|| anyhow::anyhow!("Wallet not initialized"))?;

    client
        .resume_sync()
        .map_err(|e| anyhow::anyhow!("{:?}", e))?;
    Ok(())
}

/// Stop a running sync.
pub async fn stop_sync() -> Result<()> {
    let guard = CLIENT.read().await;
    let client = guard
        .as_ref()
        .ok_or_else(|| anyhow::anyhow!("Wallet not initialized"))?;

    client
        .stop_sync()
        .map_err(|e| anyhow::anyhow!("{:?}", e))?;
    Ok(())
}

/// Full rescan from wallet birthday.
pub async fn rescan_wallet() -> Result<SyncResultInfo> {
    let mut guard = CLIENT.write().await;
    let client = guard
        .as_mut()
        .ok_or_else(|| anyhow::anyhow!("Wallet not initialized"))?;

    let result = client
        .rescan_and_await()
        .await
        .map_err(|e| anyhow::anyhow!("{:?}", e))?;

    Ok(SyncResultInfo {
        start_height: u32::from(result.sync_start_height),
        end_height: u32::from(result.sync_end_height),
        blocks_scanned: result.blocks_scanned,
    })
}

/// Get current sync status without blocking.
pub async fn get_sync_status() -> Result<SyncStatusInfo> {
    let guard = CLIENT.read().await;
    let client = guard
        .as_ref()
        .ok_or_else(|| anyhow::anyhow!("Wallet not initialized"))?;

    let mode = client.sync_mode();
    let mode_str = format!("{:?}", mode);

    Ok(SyncStatusInfo { mode: mode_str })
}

// ---------------------------------------------------------------------------
// Balance
// ---------------------------------------------------------------------------

/// Returns pool balances for the default account.
pub async fn get_wallet_balance() -> Result<WalletBalance> {
    let guard = CLIENT.read().await;
    let client = guard
        .as_ref()
        .ok_or_else(|| anyhow::anyhow!("Wallet not initialized"))?;

    let acct = zip32::AccountId::ZERO;
    let balance = client
        .account_balance(acct)
        .await
        .map_err(|e| anyhow::anyhow!("{:?}", e))?;

    Ok(WalletBalance {
        transparent: zat_to_u64(balance.confirmed_transparent_balance),
        sapling: zat_to_u64(balance.confirmed_sapling_balance),
        orchard: zat_to_u64(balance.confirmed_orchard_balance),
        unconfirmed_sapling: zat_to_u64(balance.unconfirmed_sapling_balance),
        unconfirmed_orchard: zat_to_u64(balance.unconfirmed_orchard_balance),
        unconfirmed_transparent: zat_to_u64(balance.unconfirmed_transparent_balance),
        total_transparent: zat_to_u64(balance.total_transparent_balance),
        total_sapling: zat_to_u64(balance.total_sapling_balance),
        total_orchard: zat_to_u64(balance.total_orchard_balance),
    })
}

// ---------------------------------------------------------------------------
// Addresses
// ---------------------------------------------------------------------------

/// Get the wallet's unified addresses.
pub async fn get_addresses() -> Result<Vec<AddressInfo>> {
    let guard = CLIENT.read().await;
    let client = guard
        .as_ref()
        .ok_or_else(|| anyhow::anyhow!("Wallet not initialized"))?;

    let addrs = client.unified_addresses_json().await;
    let mut result = vec![];
    for a in addrs.members() {
        result.push(AddressInfo {
            address: a["address"]
                .as_str()
                .or_else(|| a["encoded_address"].as_str())
                .unwrap_or("")
                .to_string(),
            has_transparent: a["receivers"]["transparent"].is_string()
                || a["receivers"]["p2pkh"].is_string(),
            has_sapling: a["receivers"]["sapling"].is_string(),
            has_orchard: a["receivers"]["orchard_exists"]
                .as_bool()
                .or_else(|| a["receivers"]["orchard"].as_bool())
                .unwrap_or(false),
        });
    }
    Ok(result)
}

/// Get the wallet's transparent addresses.
pub async fn get_transparent_addresses() -> Result<Vec<String>> {
    let guard = CLIENT.read().await;
    let client = guard
        .as_ref()
        .ok_or_else(|| anyhow::anyhow!("Wallet not initialized"))?;

    let addrs = client.transparent_addresses_json().await;
    let mut result = vec![];
    for a in addrs.members() {
        if let Some(addr) = a["encoded_address"].as_str() {
            result.push(addr.to_string());
        }
    }
    Ok(result)
}

// ---------------------------------------------------------------------------
// Transactions (rich value transfers with memos)
// ---------------------------------------------------------------------------

/// Get transaction summaries.
pub async fn get_transactions() -> Result<Vec<TransactionRecord>> {
    let guard = CLIENT.read().await;
    let client = guard
        .as_ref()
        .ok_or_else(|| anyhow::anyhow!("Wallet not initialized"))?;

    let summaries = client
        .transaction_summaries(true)
        .await
        .map_err(|e| anyhow::anyhow!("{:?}", e))?;

    let mut records = vec![];
    for tx in summaries.iter() {
        records.push(TransactionRecord {
            txid: tx.txid.to_string(),
            height: u32::from(tx.blockheight),
            timestamp: tx.datetime as u64,
            value: tx.balance_delta().unwrap_or(0),
            kind: format!("{}", tx.kind),
            fee: tx.fee,
            status: format!("{}", tx.status),
        });
    }
    Ok(records)
}

/// Get detailed value transfers (per-recipient breakdown with memos).
pub async fn get_value_transfers() -> Result<Vec<ValueTransferRecord>> {
    let guard = CLIENT.read().await;
    let client = guard
        .as_ref()
        .ok_or_else(|| anyhow::anyhow!("Wallet not initialized"))?;

    let transfers = client
        .value_transfers(true)
        .await
        .map_err(|e| anyhow::anyhow!("{:?}", e))?;

    let mut records = vec![];
    for vt in transfers.iter() {
        records.push(ValueTransferRecord {
            txid: vt.txid.to_string(),
            height: u32::from(vt.blockheight),
            timestamp: vt.datetime as u64,
            value: vt.value,
            kind: format!("{}", vt.kind),
            fee: vt.transaction_fee,
            recipient_address: vt.recipient_address.clone(),
            pool_received: vt.pool_received.clone(),
            memos: vt.memos.clone(),
            status: format!("{}", vt.status),
        });
    }
    Ok(records)
}

/// Search for messages (memo-bearing value transfers) optionally filtered by text.
pub async fn get_messages(filter: Option<String>) -> Result<Vec<ValueTransferRecord>> {
    let guard = CLIENT.read().await;
    let client = guard
        .as_ref()
        .ok_or_else(|| anyhow::anyhow!("Wallet not initialized"))?;

    let transfers = client
        .messages_containing(filter.as_deref())
        .await
        .map_err(|e| anyhow::anyhow!("{:?}", e))?;

    let mut records = vec![];
    for vt in transfers.iter() {
        records.push(ValueTransferRecord {
            txid: vt.txid.to_string(),
            height: u32::from(vt.blockheight),
            timestamp: vt.datetime as u64,
            value: vt.value,
            kind: format!("{}", vt.kind),
            fee: vt.transaction_fee,
            recipient_address: vt.recipient_address.clone(),
            pool_received: vt.pool_received.clone(),
            memos: vt.memos.clone(),
            status: format!("{}", vt.status),
        });
    }
    Ok(records)
}

// ---------------------------------------------------------------------------
// Send
// ---------------------------------------------------------------------------

/// Send ZEC to one or more recipients.
pub async fn send_payment(recipients: Vec<PaymentRecipient>) -> Result<String> {
    let mut guard = CLIENT.write().await;
    let client = guard
        .as_mut()
        .ok_or_else(|| anyhow::anyhow!("Wallet not initialized"))?;

    let request = build_transaction_request(&recipients)?;
    let acct = zip32::AccountId::ZERO;
    let txids = client
        .quick_send(request, acct, true)
        .await
        .map_err(|e| anyhow::anyhow!("{:?}", e))?;

    Ok(txids.head.to_string())
}

/// Shield transparent funds to the best shielded pool.
pub async fn shield_funds() -> Result<String> {
    let mut guard = CLIENT.write().await;
    let client = guard
        .as_mut()
        .ok_or_else(|| anyhow::anyhow!("Wallet not initialized"))?;

    let acct = zip32::AccountId::ZERO;
    let txids = client
        .quick_shield(acct)
        .await
        .map_err(|e| anyhow::anyhow!("{:?}", e))?;

    Ok(txids.head.to_string())
}

// ---------------------------------------------------------------------------
// Validation
// ---------------------------------------------------------------------------

/// Validate a Zcash address and return its type.
pub fn validate_address(address: String) -> AddressValidation {
    match zcash_address::ZcashAddress::try_from_encoded(&address) {
        Ok(addr) => {
            let addr_type = format!("{:?}", addr);
            AddressValidation {
                is_valid: true,
                address_type: Some(addr_type),
            }
        }
        Err(_) => AddressValidation {
            is_valid: false,
            address_type: None,
        },
    }
}

/// Validate a seed phrase.
pub fn validate_seed(seed: String) -> bool {
    bip0039::Mnemonic::<bip0039::English>::from_phrase(&seed).is_ok()
}

// ---------------------------------------------------------------------------
// Server
// ---------------------------------------------------------------------------

/// Get server info as JSON string.
pub async fn get_server_info() -> Result<String> {
    let guard = CLIENT.read().await;
    let client = guard
        .as_ref()
        .ok_or_else(|| anyhow::anyhow!("Wallet not initialized"))?;

    Ok(client.do_info().await)
}

/// Update the lightwalletd server URL.
pub async fn set_server(server_url: String) -> Result<()> {
    let mut guard = CLIENT.write().await;
    let client = guard
        .as_mut()
        .ok_or_else(|| anyhow::anyhow!("Wallet not initialized"))?;

    let uri: http::Uri = server_url
        .parse()
        .map_err(|e| anyhow::anyhow!("Invalid server URL: {:?}", e))?;
    client.set_indexer_uri(uri);
    Ok(())
}

// ---------------------------------------------------------------------------
// Backup / Export
// ---------------------------------------------------------------------------

/// Get the wallet's seed phrase.
/// Returns None for watch-only wallets.
pub async fn get_seed_phrase() -> Result<Option<String>> {
    let guard = CLIENT.read().await;
    let client = guard
        .as_ref()
        .ok_or_else(|| anyhow::anyhow!("Wallet not initialized"))?;

    let wallet = client.wallet.read().await;
    Ok(wallet.mnemonic_phrase())
}

/// Get the wallet's birthday height.
pub async fn get_birthday() -> Result<u32> {
    let guard = CLIENT.read().await;
    let client = guard
        .as_ref()
        .ok_or_else(|| anyhow::anyhow!("Wallet not initialized"))?;

    let wallet = client.wallet.read().await;
    Ok(u32::from(wallet.birthday))
}

/// Export the wallet's unified full viewing key (UFVK).
/// Safe to share -- allows watching the wallet but not spending.
pub async fn export_ufvk() -> Result<Option<String>> {
    use zcash_keys::keys::UnifiedFullViewingKey;

    let guard = CLIENT.read().await;
    let client = guard
        .as_ref()
        .ok_or_else(|| anyhow::anyhow!("Wallet not initialized"))?;

    let wallet = client.wallet.read().await;
    let network = wallet.network;

    let key_store = wallet
        .unified_key_store
        .get(&zip32::AccountId::ZERO);

    match key_store {
        Some(ks) => {
            let ufvk = UnifiedFullViewingKey::try_from(ks)
                .map_err(|e| anyhow::anyhow!("{:?}", e))?;
            let encoded = ufvk.encode(&network);
            Ok(Some(encoded))
        }
        None => Ok(None),
    }
}

/// Check whether this wallet has spending capability (vs watch-only).
pub async fn has_spending_key() -> Result<bool> {
    let guard = CLIENT.read().await;
    let client = guard
        .as_ref()
        .ok_or_else(|| anyhow::anyhow!("Wallet not initialized"))?;

    let wallet = client.wallet.read().await;
    Ok(wallet.mnemonic_phrase().is_some())
}

// ---------------------------------------------------------------------------
// Wallet management
// ---------------------------------------------------------------------------

/// Delete wallet data from disk. Must be called after close_wallet().
pub async fn delete_wallet_data(data_dir: String) -> Result<()> {
    let wallet_file = std::path::Path::new(&data_dir).join("zingo-wallet.dat");
    if wallet_file.exists() {
        std::fs::remove_file(&wallet_file)
            .map_err(|e| anyhow::anyhow!("Failed to delete wallet file: {:?}", e))?;
    }
    let tmp_file = std::path::Path::new(&data_dir).join("zingo-wallet.dat.tmp");
    if tmp_file.exists() {
        std::fs::remove_file(&tmp_file).ok();
    }
    Ok(())
}

/// Start the periodic save task (saves wallet state to disk at checkpoints).
pub async fn start_save_task() -> Result<()> {
    let mut guard = CLIENT.write().await;
    let client = guard
        .as_mut()
        .ok_or_else(|| anyhow::anyhow!("Wallet not initialized"))?;

    client.save_task().await;
    Ok(())
}

// ---------------------------------------------------------------------------
// Types exposed to Dart via flutter_rust_bridge
// ---------------------------------------------------------------------------

#[frb(dart_metadata=("freezed"))]
pub struct SyncResultInfo {
    pub start_height: u32,
    pub end_height: u32,
    pub blocks_scanned: u32,
}

#[frb(dart_metadata=("freezed"))]
pub struct SyncStatusInfo {
    pub mode: String,
}

#[frb(dart_metadata=("freezed"))]
pub struct WalletBalance {
    pub transparent: u64,
    pub sapling: u64,
    pub orchard: u64,
    pub unconfirmed_sapling: u64,
    pub unconfirmed_orchard: u64,
    pub unconfirmed_transparent: u64,
    pub total_transparent: u64,
    pub total_sapling: u64,
    pub total_orchard: u64,
}

#[frb(dart_metadata=("freezed"))]
pub struct AddressInfo {
    pub address: String,
    pub has_transparent: bool,
    pub has_sapling: bool,
    pub has_orchard: bool,
}

#[frb(dart_metadata=("freezed"))]
pub struct TransactionRecord {
    pub txid: String,
    pub height: u32,
    pub timestamp: u64,
    pub value: i64,
    pub kind: String,
    pub fee: Option<u64>,
    pub status: String,
}

#[frb(dart_metadata=("freezed"))]
pub struct ValueTransferRecord {
    pub txid: String,
    pub height: u32,
    pub timestamp: u64,
    pub value: u64,
    pub kind: String,
    pub fee: Option<u64>,
    pub recipient_address: Option<String>,
    pub pool_received: Option<String>,
    pub memos: Vec<String>,
    pub status: String,
}

#[frb(dart_metadata=("freezed"))]
pub struct PaymentRecipient {
    pub address: String,
    pub amount: u64,
    pub memo: Option<String>,
}

#[frb(dart_metadata=("freezed"))]
pub struct AddressValidation {
    pub is_valid: bool,
    pub address_type: Option<String>,
}

#[derive(Clone, Copy)]
pub enum ChainType {
    Mainnet,
    Testnet,
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

fn build_config(
    data_dir: &str,
    server_url: &str,
    chain_type: ChainType,
) -> Result<ZingoConfig> {
    let chain = match chain_type {
        ChainType::Mainnet => config::ChainType::Mainnet,
        ChainType::Testnet => config::ChainType::Testnet,
    };

    let uri: http::Uri = server_url
        .parse()
        .map_err(|e| anyhow::anyhow!("Invalid server URL: {:?}", e))?;

    let config = ZingoConfig::builder()
        .set_network_type(chain)
        .set_wallet_dir(data_dir.into())
        .set_indexer_uri(uri)
        .build();

    Ok(config)
}

fn build_transaction_request(
    recipients: &[PaymentRecipient],
) -> Result<zcash_client_backend::zip321::TransactionRequest> {
    use zcash_client_backend::zip321::{Payment, TransactionRequest};

    let payments: Vec<Payment> = recipients
        .iter()
        .map(|r| {
            let address: zcash_address::ZcashAddress =
                r.address.parse().map_err(|e| anyhow::anyhow!("{:?}", e))?;
            let amount =
                Zatoshis::try_from(r.amount).map_err(|_| anyhow::anyhow!("Invalid amount"))?;
            let memo = match &r.memo {
                Some(m) if !m.is_empty() => {
                    let memo: zcash_protocol::memo::Memo = m.parse()
                        .map_err(|e| anyhow::anyhow!("{:?}", e))?;
                    Some(memo.encode())
                }
                _ => None,
            };
            Ok(Payment::new(address, amount, memo, None, None, vec![])
                .ok_or_else(|| anyhow::anyhow!("Failed to create payment"))?)
        })
        .collect::<Result<Vec<_>>>()?;

    TransactionRequest::new(payments).map_err(|e| anyhow::anyhow!("{:?}", e))
}

#[flutter_rust_bridge::frb(init)]
pub fn init_app() {
    #[cfg(debug_assertions)]
    {
        let _ = tracing_subscriber::fmt()
            .with_max_level(tracing::Level::DEBUG)
            .try_init();
    }
    #[cfg(not(debug_assertions))]
    {
        let _ = tracing_subscriber::fmt()
            .with_max_level(tracing::Level::WARN)
            .try_init();
    }
    flutter_rust_bridge::setup_default_user_utils();
}
