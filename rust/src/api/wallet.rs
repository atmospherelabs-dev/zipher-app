use flutter_rust_bridge::frb;

// ---------------------------------------------------------------------------
// Shared types used by both legacy and new engine FFI layers.
// These struct definitions generate the Dart classes via flutter_rust_bridge.
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

#[derive(Default)]
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
    pub raw_value: u64,
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
// Legacy stubs — these functions existed in the zingolib-based wallet.
// They are kept as stubs so that FRB-generated bindings continue to compile.
// At runtime, the Dart side calls engine_api.rs functions instead.
// ---------------------------------------------------------------------------

use anyhow::Result;

fn legacy_err<T>() -> Result<T> {
    Err(anyhow::anyhow!("Legacy zingolib engine has been removed. Use the new engine."))
}

#[allow(unused_variables)]
pub async fn create_wallet(
    data_dir: String, server_url: String, chain_type: ChainType, chain_height: u32,
) -> Result<String> { legacy_err() }
#[allow(unused_variables)]
pub async fn restore_from_seed(
    data_dir: String, server_url: String, chain_type: ChainType,
    seed_phrase: String, birthday: u32,
) -> Result<()> { legacy_err() }
#[allow(unused_variables)]
pub async fn restore_from_ufvk(
    data_dir: String, server_url: String, chain_type: ChainType,
    ufvk: String, birthday: u32,
) -> Result<()> { legacy_err() }
#[allow(unused_variables)]
pub async fn open_wallet(
    data_dir: String, server_url: String, chain_type: ChainType,
) -> Result<()> { legacy_err() }
pub async fn close_wallet() -> Result<()> { legacy_err() }
pub async fn sync_wallet() -> Result<SyncResultInfo> { legacy_err() }
pub async fn start_sync() -> Result<()> { legacy_err() }
pub async fn pause_sync() -> Result<()> { legacy_err() }
pub async fn resume_sync() -> Result<()> { legacy_err() }
pub async fn stop_sync() -> Result<()> { legacy_err() }
pub async fn rescan_wallet() -> Result<SyncResultInfo> { legacy_err() }
pub async fn get_sync_status() -> Result<SyncStatusInfo> { legacy_err() }
pub async fn get_wallet_balance() -> Result<WalletBalance> { legacy_err() }
pub async fn get_addresses() -> Result<Vec<AddressInfo>> { legacy_err() }
pub async fn get_transparent_addresses() -> Result<Vec<String>> { legacy_err() }
pub async fn get_transactions() -> Result<Vec<TransactionRecord>> { legacy_err() }
pub async fn get_value_transfers() -> Result<Vec<ValueTransferRecord>> { legacy_err() }
#[allow(unused_variables)]
pub async fn get_messages(filter: Option<String>) -> Result<Vec<ValueTransferRecord>> { legacy_err() }
#[allow(unused_variables)]
pub async fn send_payment(recipients: Vec<PaymentRecipient>) -> Result<String> { legacy_err() }
pub async fn shield_funds() -> Result<String> { legacy_err() }
#[allow(unused_variables)]
pub fn validate_address(address: String) -> AddressValidation {
    AddressValidation { is_valid: false, address_type: None }
}
#[allow(unused_variables)]
pub fn validate_seed(seed: String) -> bool { false }
#[allow(unused_variables)]
pub async fn get_server_info() -> Result<String> { legacy_err() }
#[allow(unused_variables)]
pub async fn set_server(server_url: String) -> Result<()> { legacy_err() }
pub async fn get_seed_phrase() -> Result<Option<String>> { legacy_err() }
pub async fn get_birthday() -> Result<u32> { legacy_err() }
pub async fn get_wallet_synced_height() -> Result<u32> { legacy_err() }
pub async fn export_ufvk() -> Result<Option<String>> { legacy_err() }
pub async fn has_spending_key() -> Result<bool> { legacy_err() }
pub async fn create_account() -> Result<u32> { legacy_err() }
pub async fn get_account_count() -> Result<u32> { legacy_err() }
#[allow(unused_variables)]
pub async fn get_account_balance(account_index: u32) -> Result<WalletBalance> { legacy_err() }
#[allow(unused_variables)]
pub async fn send_from_account(
    account_index: u32, recipients: Vec<PaymentRecipient>,
) -> Result<String> { legacy_err() }
#[allow(unused_variables)]
pub async fn shield_account(account_index: u32) -> Result<String> { legacy_err() }
#[allow(unused_variables)]
pub async fn generate_diversified_address(
    account_index: u32, include_orchard: bool, include_sapling: bool,
) -> Result<String> { legacy_err() }
#[allow(unused_variables)]
pub fn parse_payment_uri(uri: String) -> Result<Vec<PaymentRecipient>> { legacy_err() }
#[allow(unused_variables)]
pub fn build_payment_uri(address: String, amount: u64, memo: Option<String>) -> Result<String> { legacy_err() }
#[allow(unused_variables)]
pub async fn delete_wallet_data(data_dir: String) -> Result<()> { legacy_err() }
pub async fn start_save_task() -> Result<()> { Ok(()) }
#[allow(unused_variables)]
pub async fn get_latest_block_height(server_url: String, chain_type: ChainType) -> Result<u32> { legacy_err() }

// ---------------------------------------------------------------------------
// App initialization (kept here for FRB)
// ---------------------------------------------------------------------------

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
