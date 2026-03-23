//! FFI bindings for the Zipher wallet engine built on zcash_client_backend.

use anyhow::Result;
use zcash_protocol::consensus::Network;

use super::wallet::{AddressInfo, AddressValidation, ChainType, WalletBalance};
use crate::engine;

fn to_network(ct: ChainType) -> Network {
    match ct {
        ChainType::Mainnet => Network::MainNetwork,
        ChainType::Testnet => Network::TestNetwork,
    }
}

// ---------------------------------------------------------------------------
// Wallet lifecycle
// ---------------------------------------------------------------------------

/// Create a new wallet. Returns the 24-word seed phrase.
pub async fn engine_create_wallet(
    data_dir: String,
    server_url: String,
    chain_type: ChainType,
    chain_height: u32,
    db_cipher_key: Option<String>,
) -> Result<String> {
    engine::wallet::create(
        &data_dir,
        &server_url,
        to_network(chain_type),
        chain_height,
        db_cipher_key,
    )
    .await
}

/// Restore a wallet from a BIP39 seed phrase.
pub async fn engine_restore_from_seed(
    data_dir: String,
    server_url: String,
    chain_type: ChainType,
    seed_phrase: String,
    birthday: u32,
    db_cipher_key: Option<String>,
) -> Result<()> {
    engine::wallet::restore(
        &data_dir,
        &server_url,
        to_network(chain_type),
        &seed_phrase,
        birthday,
        db_cipher_key,
    )
    .await
}

/// Restore a watch-only wallet from a UFVK.
pub async fn engine_restore_from_ufvk(
    data_dir: String,
    server_url: String,
    chain_type: ChainType,
    ufvk: String,
    birthday: u32,
    db_cipher_key: Option<String>,
) -> Result<()> {
    engine::wallet::restore_from_ufvk(
        &data_dir,
        &server_url,
        to_network(chain_type),
        &ufvk,
        birthday,
        db_cipher_key,
    )
    .await
}

/// Open an existing wallet from disk.
pub async fn engine_open_wallet(
    data_dir: String,
    server_url: String,
    chain_type: ChainType,
    db_cipher_key: Option<String>,
) -> Result<()> {
    engine::wallet::open(
        &data_dir,
        &server_url,
        to_network(chain_type),
        db_cipher_key,
    )
    .await
}

/// Close the current wallet.
pub async fn engine_close_wallet() -> Result<()> {
    engine::wallet::close().await;
    Ok(())
}

/// Delete wallet database files from disk.
pub async fn engine_delete_wallet_data(data_dir: String) -> Result<()> {
    engine::wallet::delete(&data_dir)
}

// ---------------------------------------------------------------------------
// Addresses
// ---------------------------------------------------------------------------

pub async fn engine_get_addresses() -> Result<Vec<AddressInfo>> {
    let addrs = engine::query::get_addresses().await?;
    Ok(addrs.into_iter().map(|a| a.into()).collect())
}

pub async fn engine_get_transparent_addresses() -> Result<Vec<String>> {
    engine::query::get_transparent_addresses().await
}

// ---------------------------------------------------------------------------
// Balance
// ---------------------------------------------------------------------------

pub async fn engine_get_wallet_balance() -> Result<WalletBalance> {
    let balance = engine::query::get_wallet_balance().await?;
    Ok(balance.into())
}

/// Returns the maximum amount (in zatoshis) that can be sent to the given
/// address after accounting for the exact ZIP-317 fee.
pub async fn engine_get_max_sendable(address: String) -> Result<u64> {
    engine::send::get_max_sendable(&address).await
}

// ---------------------------------------------------------------------------
// Misc
// ---------------------------------------------------------------------------

pub async fn engine_get_birthday() -> Result<u32> {
    engine::query::get_birthday().await
}

pub async fn engine_get_wallet_synced_height() -> Result<u32> {
    engine::query::get_synced_height().await
}

pub async fn engine_has_spending_key() -> Result<bool> {
    engine::query::has_spending_key().await
}

pub async fn engine_export_ufvk() -> Result<Option<String>> {
    engine::query::export_ufvk().await
}

pub fn engine_validate_address(address: String) -> AddressValidation {
    match address.parse::<zcash_address::ZcashAddress>() {
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

pub fn engine_validate_seed(seed: String) -> bool {
    bip0039::Mnemonic::<bip0039::English>::from_phrase(&seed).is_ok()
}

pub async fn engine_get_latest_block_height(server_url: String) -> Result<u32> {
    let height = engine::wallet::fetch_latest_height(&server_url).await?;
    Ok(height as u32)
}

// ---------------------------------------------------------------------------
// Sync
// ---------------------------------------------------------------------------

pub async fn engine_start_sync() -> Result<()> {
    engine::sync::start().await
}

pub async fn engine_stop_sync() -> Result<()> {
    engine::sync::stop().await;
    Ok(())
}

pub async fn engine_get_sync_progress() -> Result<EngineSyncProgress> {
    let p = engine::sync::get_progress().await;
    Ok(EngineSyncProgress {
        synced_height: p.synced_height,
        latest_height: p.latest_height,
        is_syncing: p.is_syncing,
        connection_error: p.connection_error,
        scanning_up_to: p.scanning_up_to,
    })
}

/// Sync progress reported to Dart.
pub struct EngineSyncProgress {
    pub synced_height: u32,
    pub latest_height: u32,
    pub is_syncing: bool,
    pub connection_error: Option<String>,
    pub scanning_up_to: u32,
}

// ---------------------------------------------------------------------------
// Background sync for inactive wallets
// ---------------------------------------------------------------------------

pub async fn engine_register_inactive_wallet(data_dir: String) -> Result<()> {
    engine::sync::register_inactive_wallet(&data_dir).await;
    Ok(())
}

pub async fn engine_unregister_inactive_wallet(data_dir: String) -> Result<()> {
    engine::sync::unregister_inactive_wallet(&data_dir).await;
    Ok(())
}

pub async fn engine_clear_inactive_wallets() -> Result<()> {
    engine::sync::clear_inactive_wallets().await;
    Ok(())
}

// ---------------------------------------------------------------------------
// Send
// ---------------------------------------------------------------------------

/// Step 1: Create a proposal and return exact fee info.
/// When `is_max` is true, `amount` is ignored and the SDK computes the max sendable.
pub async fn engine_propose_send(
    address: String,
    amount: u64,
    memo: Option<String>,
    is_max: bool,
) -> Result<ProposalResult> {
    let (send_amount, fee, is_exact) =
        engine::send::propose_send(&address, amount, memo, is_max).await?;
    Ok(ProposalResult {
        send_amount,
        fee,
        is_exact,
    })
}

/// Proposal result returned to Dart.
pub struct ProposalResult {
    pub send_amount: u64,
    pub fee: u64,
    pub is_exact: bool,
}

/// Step 2: Confirm and broadcast the previously proposed transaction.
pub async fn engine_confirm_send(seed_phrase: String) -> Result<String> {
    use secrecy::SecretString;
    let secret_seed = SecretString::new(seed_phrase);
    engine::send::confirm_send(&secret_seed).await
}

/// Legacy single-step send (still used for multi-recipient or fallback).
pub async fn engine_send_payment(
    seed_phrase: String,
    address: String,
    amount: u64,
    memo: Option<String>,
) -> Result<String> {
    use secrecy::SecretString;
    let secret_seed = SecretString::new(seed_phrase);
    engine::send::send_payment(
        &secret_seed,
        vec![(address, amount, memo)],
    )
    .await
}

/// Shield transparent funds into the shielded pool.
pub async fn engine_shield_funds(seed_phrase: String) -> Result<String> {
    use secrecy::SecretString;
    let secret_seed = SecretString::new(seed_phrase);
    engine::send::shield_funds(&secret_seed).await
}

// ---------------------------------------------------------------------------
// Transaction history
// ---------------------------------------------------------------------------

pub async fn engine_get_transactions() -> Result<Vec<EngineTransactionRecord>> {
    let txs = engine::query::get_transactions().await?;
    Ok(txs.into_iter().map(|t| t.into()).collect())
}

pub struct EngineTransactionRecord {
    pub txid: String,
    pub height: u32,
    pub timestamp: u32,
    pub value: i64,
    pub kind: String,
    pub fee: Option<u64>,
    pub memo: Option<String>,
    pub expired_unmined: bool,
}

impl From<zipher_engine::types::EngineTransactionRecord> for EngineTransactionRecord {
    fn from(t: zipher_engine::types::EngineTransactionRecord) -> Self {
        Self {
            txid: t.txid,
            height: t.height,
            timestamp: t.timestamp,
            value: t.value,
            kind: t.kind,
            fee: t.fee,
            memo: t.memo,
            expired_unmined: t.expired_unmined,
        }
    }
}
