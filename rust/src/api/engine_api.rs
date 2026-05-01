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
        None,
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
        None,
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

// ---------------------------------------------------------------------------
// EVM queries (all via reqwest — bypasses Dart HTTP issues on iOS)
// ---------------------------------------------------------------------------

/// Native balance in raw wei as decimal string.
pub async fn engine_get_native_balance(rpc_url: String, address: String) -> Result<String> {
    let raw = engine::evm::get_native_balance(&rpc_url, &address).await?;
    Ok(raw.to_string())
}

/// ERC-20 balance in raw token units as decimal string.
pub async fn engine_get_erc20_balance(
    rpc_url: String,
    token_contract: String,
    owner_address: String,
) -> Result<String> {
    let raw = engine::evm::get_erc20_balance(&rpc_url, &token_contract, &owner_address).await?;
    Ok(raw.to_string())
}

/// Pending nonce for an address.
pub async fn engine_get_nonce(rpc_url: String, address: String) -> Result<u64> {
    engine::evm::get_nonce(&rpc_url, &address).await
}

/// Suggested EIP-1559 gas fees. Returns (maxPriorityFeePerGas, maxFeePerGas) in wei.
pub async fn engine_suggest_eip1559_fees(
    rpc_url: String,
    chain_id: u64,
) -> Result<EvmFees> {
    let fees = engine::evm::suggest_eip1559_fees(&rpc_url, chain_id).await?;
    Ok(EvmFees {
        max_priority_fee_per_gas: fees.max_priority_fee_per_gas,
        max_fee_per_gas: fees.max_fee_per_gas,
    })
}

/// ERC-20 approve: sign + broadcast + wait. Returns tx hash.
pub async fn engine_approve_erc20(
    rpc_url: String,
    seed_phrase: String,
    owner_address: String,
    token_address: String,
    spender_address: String,
    amount_raw: String,
    chain_id: u64,
) -> Result<String> {
    let amount: u128 = amount_raw
        .parse()
        .map_err(|e| anyhow::anyhow!("Invalid amount: {e}"))?;
    let fees = engine::evm::suggest_eip1559_fees(&rpc_url, chain_id).await?;
    engine::evm::approve_erc20(
        &rpc_url, &seed_phrase, &owner_address, &token_address,
        &spender_address, amount, chain_id, &fees,
    ).await
}

/// Wait for a tx receipt. Returns (success, block_number).
pub async fn engine_wait_for_receipt(
    rpc_url: String,
    tx_hash: String,
) -> Result<EvmReceipt> {
    let r = engine::evm::wait_for_receipt(&rpc_url, &tx_hash, 90).await?;
    Ok(EvmReceipt {
        success: r.status,
        block_number: r.block_number,
        gas_used: r.gas_used,
        tx_hash: r.tx_hash,
    })
}

/// ERC-1155 isApprovedForAll check.
pub async fn engine_erc1155_is_approved_for_all(
    rpc_url: String,
    owner: String,
    token_contract: String,
    operator: String,
) -> Result<bool> {
    engine::evm::erc1155_is_approved_for_all(&rpc_url, &owner, &token_contract, &operator).await
}

/// ERC-1155 setApprovalForAll: sign + broadcast + wait. Returns tx hash.
pub async fn engine_erc1155_set_approval_for_all(
    rpc_url: String,
    seed_phrase: String,
    owner_address: String,
    token_contract: String,
    operator: String,
    approved: bool,
    chain_id: u64,
) -> Result<String> {
    let fees = engine::evm::suggest_eip1559_fees(&rpc_url, chain_id).await?;
    engine::evm::erc1155_set_approval_for_all(
        &rpc_url, &seed_phrase, &owner_address, &token_contract,
        &operator, approved, chain_id, &fees,
    ).await
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

/// Rescan the wallet from its birthday height by truncating and restarting sync.
pub async fn engine_rescan_from_birthday() -> Result<()> {
    let birthday = engine::query::get_birthday().await?;
    engine::sync::rescan_from(birthday).await
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

// ---------------------------------------------------------------------------
// Market / Prediction Markets
// ---------------------------------------------------------------------------

pub struct MarketInfo {
    pub id: u64,
    pub title: String,
    pub description: Option<String>,
    pub state: Option<String>,
    pub outcomes: Vec<MarketOutcome>,
}

pub struct MarketOutcome {
    pub title: String,
    pub price: f64,
    pub outcome_id: Option<u64>,
}

pub async fn engine_get_markets(keyword: Option<String>, limit: u32) -> Result<Vec<MarketInfo>> {
    let markets = zipher_engine::myriad::get_markets(keyword.as_deref(), limit).await?;
    Ok(markets.into_iter().map(|m| MarketInfo {
        id: m.id,
        title: m.title,
        description: m.description,
        state: m.state,
        outcomes: m.outcomes.into_iter().map(|o| MarketOutcome {
            title: o.title,
            price: o.price,
            outcome_id: o.outcome_id,
        }).collect(),
    }).collect())
}

pub struct TradeSignalInfo {
    pub market_id: u64,
    pub market_title: String,
    pub outcome_index: u32,
    pub outcome_title: String,
    pub market_prob: f64,
    pub estimated_prob: f64,
    pub edge: f64,
    pub kelly_fraction: f64,
    pub recommended_bet_usdt: f64,
    pub expected_value: f64,
    pub confidence: f64,
    pub reason: String,
}

pub fn engine_analyze_opportunity(
    market_id: u64,
    outcome_index: u32,
    estimated_prob: f64,
    confidence: f64,
    bankroll: f64,
    max_bet: f64,
) -> Result<Option<TradeSignalInfo>> {
    let rt = tokio::runtime::Handle::try_current()
        .map_err(|_| anyhow::anyhow!("No tokio runtime"))?;

    let markets = rt.block_on(zipher_engine::myriad::get_market(market_id))?;

    let signal = zipher_engine::myriad::analyze_opportunity(
        &markets,
        outcome_index as usize,
        estimated_prob,
        confidence,
        bankroll,
        max_bet,
    );

    Ok(signal.map(|s| TradeSignalInfo {
        market_id: s.market_id,
        market_title: s.market_title,
        outcome_index: s.outcome_index as u32,
        outcome_title: s.outcome_title,
        market_prob: s.market_prob,
        estimated_prob: s.estimated_prob,
        edge: s.edge,
        kelly_fraction: s.kelly_fraction,
        recommended_bet_usdt: s.recommended_bet_usdt,
        expected_value: s.expected_value,
        confidence: s.confidence,
        reason: s.reason,
    }))
}

// ---------------------------------------------------------------------------
// EVM / OWS — On-device EVM signing via ows-signer
// ---------------------------------------------------------------------------

/// Derive the EVM (BSC/ETH) address from the wallet's BIP-39 seed phrase.
/// Uses the standard BIP-44 path m/44'/60'/0'/0/0.
pub fn engine_derive_evm_address(seed_phrase: String) -> Result<String> {
    zipher_engine::ows::derive_evm_address(&seed_phrase)
}

/// Derive addresses for EVM, Solana, and Bitcoin from a single seed phrase.
/// All derivation is CPU-only (no network calls).
pub fn engine_derive_multi_chain_addresses(seed_phrase: String) -> Result<EngineMultiChainAddresses> {
    let addrs = zipher_engine::ows::derive_all_addresses(&seed_phrase)?;
    Ok(EngineMultiChainAddresses {
        evm: addrs.evm,
        solana: addrs.solana,
        bitcoin: addrs.bitcoin,
    })
}

/// Multi-chain addresses returned to Dart.
pub struct EngineMultiChainAddresses {
    pub evm: String,
    pub solana: String,
    pub bitcoin: String,
}

/// Sign an unsigned EVM transaction and return the broadcast-ready signed bytes.
pub fn engine_sign_evm_tx(seed_phrase: String, unsigned_tx_hex: String) -> Result<String> {
    let unsigned_bytes = hex::decode(&unsigned_tx_hex)
        .map_err(|e| anyhow::anyhow!("Invalid hex: {}", e))?;
    let signed_bytes = zipher_engine::ows::sign_evm_tx(&seed_phrase, &unsigned_bytes)?;
    Ok(hex::encode(signed_bytes))
}

/// Sign an unsigned EVM transaction, broadcast it via JSON-RPC, and return the tx hash.
pub async fn engine_sign_and_broadcast_evm_tx(
    seed_phrase: String,
    unsigned_tx_hex: String,
    rpc_url: String,
) -> Result<String> {
    let unsigned_bytes = hex::decode(&unsigned_tx_hex)
        .map_err(|e| anyhow::anyhow!("Invalid hex: {}", e))?;
    zipher_engine::ows::sign_and_broadcast_evm_tx(&seed_phrase, &unsigned_bytes, &rpc_url).await
}

// ---------------------------------------------------------------------------
// On-device LLM — candle-based GGUF inference
// ---------------------------------------------------------------------------

/// Load a GGUF model and tokenizer from the given file paths.
/// Must be called before `engine_llm_infer`. Blocks while loading (~1-5s).
pub fn engine_llm_load(model_path: String, tokenizer_path: String) -> Result<()> {
    zipher_engine::llm::load_model(&model_path, &tokenizer_path)
}

/// Unload the LLM from memory.
pub fn engine_llm_unload() -> Result<()> {
    zipher_engine::llm::unload_model()
}

/// Check if an LLM model is currently loaded.
pub fn engine_llm_is_loaded() -> bool {
    zipher_engine::llm::is_model_loaded()
}

/// Run LLM inference on a raw prompt. Returns the generated text.
pub fn engine_llm_infer(prompt: String, max_tokens: u32, temperature: f64) -> Result<String> {
    zipher_engine::llm::infer(&prompt, max_tokens, temperature)
}

/// Build an intent-classification prompt from the user's natural language input.
/// The returned prompt is ready to pass to `engine_llm_infer`.
pub fn engine_llm_build_intent_prompt(user_input: String) -> String {
    zipher_engine::llm::build_intent_prompt(&user_input)
}

/// Get the recommended model filename, display name, and expected size in bytes.
pub fn engine_llm_recommended_model() -> EngineLlmModelInfo {
    let (filename, name, size) = zipher_engine::llm::recommended_model();
    EngineLlmModelInfo {
        filename: filename.to_string(),
        display_name: name.to_string(),
        size_bytes: size,
    }
}

/// Info about the recommended LLM model.
pub struct EngineLlmModelInfo {
    pub filename: String,
    pub display_name: String,
    pub size_bytes: u64,
}

// ---------------------------------------------------------------------------
// Polymarket — EIP-712 signing for CLOB orders and auth
// ---------------------------------------------------------------------------

/// Sign the CLOB L1 auth message to derive API credentials.
/// Returns (polygon_address, eip712_signature_hex).
pub fn engine_polymarket_sign_auth(
    seed_phrase: String,
    timestamp: u64,
    nonce: u64,
) -> Result<PolymarketAuthResult> {
    let (address, signature) =
        zipher_engine::polymarket::sign_clob_auth(&seed_phrase, timestamp, nonce)?;
    Ok(PolymarketAuthResult { address, signature })
}

pub struct PolymarketAuthResult {
    pub address: String,
    pub signature: String,
}

/// Sign a Polymarket CLOB V2 order with EIP-712.
/// Returns the hex-encoded signature.
pub fn engine_polymarket_sign_order(
    seed_phrase: String,
    salt: String,
    maker: String,
    signer: String,
    token_id: String,
    maker_amount: String,
    taker_amount: String,
    side: u8,
    signature_type: u8,
    timestamp: String,
    metadata: String,
    builder: String,
    neg_risk: bool,
) -> Result<String> {
    let order = zipher_engine::polymarket::PolymarketOrder {
        salt,
        maker,
        signer,
        token_id,
        maker_amount,
        taker_amount,
        side,
        signature_type,
        timestamp,
        metadata,
        builder,
    };
    zipher_engine::polymarket::sign_order(&seed_phrase, &order, neg_risk)
}

/// Whether one Gamma `/markets` or nested event market object passes the default
/// tradability filter (same rules as `zipher-cli polymarket list`). Pure JSON — no wallet.
pub fn engine_polymarket_gamma_market_passes_quality_filter(
    market_json: String,
    relaxed: bool,
) -> bool {
    match serde_json::from_str::<zipher_engine::polymarket::PolymarketMarket>(&market_json) {
        Ok(m) => zipher_engine::polymarket::polymarket_market_passes_quality(&m, relaxed),
        Err(_) => false,
    }
}

/// Polymarket discovery: Gamma events + Rust grouping/quality (same as CLI `polymarket list`).
/// Returns JSON `PolymarketDiscoverySummary`.
pub async fn engine_polymarket_discover(
    keyword: Option<String>,
    limit: u32,
) -> Result<String> {
    let summary =
        zipher_engine::polymarket::polymarket_discover(keyword.as_deref(), limit, false).await?;
    Ok(serde_json::to_string(&summary)?)
}

/// Polymarket open positions for `user` (0x + 40 hex) via public Data API.
/// Returns JSON array of `PolymarketPosition`.
pub async fn engine_polymarket_get_positions(address: String) -> Result<String> {
    let positions = zipher_engine::polymarket::polymarket_get_positions(&address).await?;
    Ok(serde_json::to_string(&positions)?)
}

// ---------------------------------------------------------------------------
// EVM shared types
// ---------------------------------------------------------------------------

pub struct EvmFees {
    pub max_priority_fee_per_gas: u64,
    pub max_fee_per_gas: u64,
}

pub struct EvmReceipt {
    pub success: bool,
    pub block_number: u64,
    pub gas_used: u64,
    pub tx_hash: String,
}

// ---------------------------------------------------------------------------
// EVM Swap — same-chain token swaps via ParaSwap (DEX aggregator)
// ---------------------------------------------------------------------------

/// Quote result returned to Dart.
pub struct EvmSwapQuoteResult {
    pub src_token: String,
    pub src_amount: String,
    pub src_decimals: u32,
    pub dest_token: String,
    pub dest_amount: String,
    pub dest_decimals: u32,
    /// Serialized JSON of the priceRoute (opaque to Dart, passed back to execute).
    pub price_route_json: String,
    pub token_transfer_proxy: String,
}

/// Get a ParaSwap quote for a same-chain EVM swap.
pub async fn engine_evm_swap_quote(
    chain_id: u64,
    src_token: String,
    src_decimals: u32,
    dest_token: String,
    dest_decimals: u32,
    amount_raw: String,
    user_address: String,
) -> Result<EvmSwapQuoteResult> {
    let quote = zipher_engine::evm_swap::get_quote(
        chain_id,
        &src_token,
        src_decimals,
        &dest_token,
        dest_decimals,
        &amount_raw,
        &user_address,
    ).await?;

    Ok(EvmSwapQuoteResult {
        src_token: quote.src_token,
        src_amount: quote.src_amount,
        src_decimals: quote.src_decimals,
        dest_token: quote.dest_token,
        dest_amount: quote.dest_amount,
        dest_decimals: quote.dest_decimals,
        price_route_json: serde_json::to_string(&quote.price_route_json)?,
        token_transfer_proxy: quote.token_transfer_proxy,
    })
}

/// Swap execution result returned to Dart.
pub struct EvmSwapExecuteResult {
    pub tx_hash: String,
    pub success: bool,
    pub block_number: u64,
    pub gas_used: u64,
    pub src_amount: String,
    pub dest_amount_expected: String,
}

/// Execute a full same-chain EVM swap: quote -> approve (if ERC-20) -> build -> sign -> broadcast -> wait.
/// All RLP encoding, signing, and broadcasting happens in Rust.
pub async fn engine_evm_swap_execute(
    rpc_url: String,
    seed_phrase: String,
    chain_id: u64,
    user_address: String,
    src_token: String,
    src_decimals: u32,
    dest_token: String,
    dest_decimals: u32,
    amount_raw: String,
    slippage_bps: u32,
) -> Result<EvmSwapExecuteResult> {
    let params = zipher_engine::evm_swap::SwapParams {
        rpc_url,
        seed_phrase,
        chain_id,
        user_address,
        src_token,
        src_decimals,
        dest_token,
        dest_decimals,
        amount_raw,
        slippage_bps,
    };

    let result = zipher_engine::evm_swap::execute_swap(&params).await?;

    Ok(EvmSwapExecuteResult {
        tx_hash: result.tx_hash,
        success: result.receipt.status,
        block_number: result.receipt.block_number,
        gas_used: result.receipt.gas_used,
        src_amount: result.src_amount,
        dest_amount_expected: result.dest_amount_expected,
    })
}
