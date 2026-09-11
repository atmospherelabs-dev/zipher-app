use std::sync::Arc;

use anyhow::Result;
use rmcp::handler::server::wrapper::Parameters;
use rmcp::model::ServerInfo;
use rmcp::schemars;
use rmcp::{tool, tool_handler, tool_router, ServerHandler, ServiceExt};
use secrecy::{ExposeSecret, SecretString};
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use tokio::sync::RwLock;
use zcash_protocol::consensus::Network;

// ---------------------------------------------------------------------------
// Seed source tracking — used to re-decrypt on unlock
// ---------------------------------------------------------------------------

#[derive(Clone)]
enum SeedSource {
    OwsVault,
    None,
}

impl SeedSource {
    fn label(&self) -> &'static str {
        match self {
            SeedSource::OwsVault => "ows-vault",
            SeedSource::None => "none",
        }
    }


}

// ---------------------------------------------------------------------------
// Deterministic error codes (PRD Section 7)
// ---------------------------------------------------------------------------

const SUCCESS: &str = "SUCCESS";
const INSUFFICIENT_FUNDS: &str = "INSUFFICIENT_FUNDS";
const SYNC_REQUIRED: &str = "SYNC_REQUIRED";
const POLICY_EXCEEDED: &str = "POLICY_EXCEEDED";
const APPROVAL_REQUIRED: &str = "APPROVAL_REQUIRED";
const ADDRESS_NOT_ALLOWED: &str = "ADDRESS_NOT_ALLOWED";
const WALLET_LOCKED: &str = "WALLET_LOCKED";
const NETWORK_TIMEOUT: &str = "NETWORK_TIMEOUT";
const INVALID_PROPOSAL: &str = "INVALID_PROPOSAL";
const CONTEXT_REQUIRED: &str = "CONTEXT_REQUIRED";
const INTERNAL_ERROR: &str = "INTERNAL_ERROR";

fn classify_error(e: &anyhow::Error) -> &'static str {
    let msg = format!("{:#}", e);
    if msg.contains("APPROVAL_REQUIRED") {
        return APPROVAL_REQUIRED;
    }
    if msg.contains("POLICY_EXCEEDED") || msg.contains("RATE_LIMITED") {
        return POLICY_EXCEEDED;
    }
    if msg.contains("ADDRESS_NOT_ALLOWED") { return ADDRESS_NOT_ALLOWED; }
    if msg.contains("CONTEXT_REQUIRED") { return CONTEXT_REQUIRED; }
    if msg.contains("Insufficient") || msg.contains("insufficient") { return INSUFFICIENT_FUNDS; }
    if msg.contains("No pending proposal") || msg.contains("INVALID_PROPOSAL") { return INVALID_PROPOSAL; }
    if msg.contains("Engine not initialized") || msg.contains("not synced") { return SYNC_REQUIRED; }
    if msg.contains("transport") || msg.contains("timeout") || msg.contains("connection") { return NETWORK_TIMEOUT; }
    INTERNAL_ERROR
}

// ---------------------------------------------------------------------------
// Tool response wrapper
// ---------------------------------------------------------------------------

#[derive(Serialize)]
struct ToolResponse<T: Serialize> {
    error_code: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    message: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    data: Option<T>,
}

fn ok_response<T: Serialize>(data: T) -> String {
    serde_json::to_string_pretty(&ToolResponse {
        error_code: SUCCESS.to_string(),
        message: None,
        data: Some(data),
    })
    .unwrap_or_else(|_| r#"{"error_code":"INTERNAL_ERROR","message":"serialize failed"}"#.into())
}

fn err_response(e: &anyhow::Error) -> String {
    let code = classify_error(e);
    serde_json::to_string_pretty(&ToolResponse::<()> {
        error_code: code.to_string(),
        message: Some(format!("{:#}", e)),
        data: None,
    })
    .unwrap_or_else(|_| format!(r#"{{"error_code":"{}","message":"{}"}}"#, code, e))
}

fn err_code_response(code: &str, message: &str) -> String {
    serde_json::to_string_pretty(&ToolResponse::<()> {
        error_code: code.to_string(),
        message: Some(message.to_string()),
        data: None,
    })
    .unwrap()
}

// ---------------------------------------------------------------------------
// Parameter structs for tools
// ---------------------------------------------------------------------------

#[derive(Deserialize, JsonSchema)]
struct ProposeSendParams {
    /// Destination Zcash address
    address: String,
    /// Amount in zatoshis (1 ZEC = 100_000_000 zatoshis)
    amount: u64,
    /// Optional encrypted memo (shielded transactions only)
    memo: Option<String>,
    /// Context identifier for audit trail
    context_id: Option<String>,
}

#[derive(Deserialize, JsonSchema)]
struct ConfirmSendParams {
    /// Exact proposal_id returned by propose_send. Old or replaced IDs are rejected.
    proposal_id: String,
    /// Context identifier for audit trail
    context_id: Option<String>,
}

#[derive(Deserialize, JsonSchema)]
struct GetTransactionsParams {
    /// Maximum number of transactions to return (default 20)
    limit: Option<usize>,
}

#[derive(Deserialize, JsonSchema)]
struct ValidateAddressParams {
    /// Zcash address to validate
    address: String,
}

#[derive(Deserialize, JsonSchema)]
struct PayX402Params {
    /// The full HTTP 402 response body (JSON string from the x402 paywall)
    payment_body: String,
    /// Context identifier for audit trail
    context_id: Option<String>,
}

#[derive(Deserialize, JsonSchema)]
struct PayUrlParams {
    /// The URL to pay for (will auto-detect x402 or MPP protocol)
    url: String,
    /// HTTP method (GET, POST, PUT). Defaults to GET.
    method: Option<String>,
    /// Context identifier for audit trail
    context_id: Option<String>,
}

#[derive(Deserialize, JsonSchema)]
struct SwapQuoteParams {
    /// Destination asset symbol (e.g., "USDC", "ETH", "BTC")
    to_symbol: String,
    /// Destination blockchain (e.g., "eth", "sol", "arb"). Required if symbol exists on multiple chains.
    chain: Option<String>,
    /// Amount in zatoshis to swap
    amount: u64,
    /// Recipient address on the destination chain
    recipient: String,
    /// Slippage tolerance in basis points (default: 100 = 1%)
    slippage: Option<u32>,
}

#[derive(Deserialize, JsonSchema)]
struct SwapExecuteParams {
    /// Destination asset symbol (e.g., "USDC", "ETH", "BTC")
    to_symbol: String,
    /// Destination blockchain (e.g., "eth", "sol", "arb")
    chain: Option<String>,
    /// Amount in zatoshis to swap
    amount: u64,
    /// Recipient address on the destination chain
    recipient: String,
    /// Slippage tolerance in basis points (default: 100 = 1%)
    slippage: Option<u32>,
    /// Context identifier for audit trail
    context_id: Option<String>,
}

#[derive(Deserialize, JsonSchema)]
struct SwapStatusParams {
    /// The deposit address from the swap quote
    deposit_address: String,
}

#[derive(Deserialize, JsonSchema)]
struct MarketResearchParams {
    /// Search query — typically the market title or topic (e.g. "Bitcoin price above 100k by July 2026")
    query: String,
    /// Number of web results to fetch (default 5, max 10)
    limit: Option<usize>,
}

#[derive(Deserialize, JsonSchema)]
struct SessionOpenParams {
    /// Server URL to create a session for
    server_url: String,
    /// Amount in zatoshis to deposit as prepaid credit
    deposit: u64,
    /// Merchant ID on CipherPay
    merchant_id: String,
    /// Merchant's Zcash payment address
    pay_to: String,
    /// Context identifier for audit trail
    context_id: Option<String>,
}

#[derive(Deserialize, JsonSchema)]
struct SessionRequestParams {
    /// URL to request using session bearer token
    url: String,
    /// HTTP method (default: GET)
    method: Option<String>,
}

#[derive(Deserialize, JsonSchema)]
struct SessionCloseParams {
    /// Session ID to close
    session_id: String,
}

#[derive(Deserialize, JsonSchema)]
struct CipherpayInvoiceParams {
    /// Product or service name for the invoice
    product_name: String,
    /// Amount in the specified currency (e.g. 25.00 for $25)
    amount: f64,
    /// Currency code (default: USD). Supported: USD, EUR, GBP, BRL, etc.
    currency: Option<String>,
}

#[derive(Deserialize, JsonSchema)]
struct CipherpayCheckParams {
    /// CipherPay invoice ID to check
    invoice_id: String,
}

// --- Polymarket params ---

#[derive(Deserialize, JsonSchema)]
struct PolymarketDiscoverParams {
    /// Optional keyword to search for (e.g., "bitcoin", "election", "AI")
    keyword: Option<String>,
    /// Max number of events to return (default 10)
    limit: Option<u32>,
}

#[derive(Deserialize, JsonSchema)]
struct PolymarketPositionsParams {
    /// EVM address to check positions for. Omit to use the wallet's derived address.
    address: Option<String>,
}

#[derive(Deserialize, JsonSchema)]
struct EvmBalancesParams {
    /// Chain name: polygon, bsc, base, arb, eth, op
    chain: String,
}

#[derive(Deserialize, JsonSchema)]
struct SweepQuoteParams {
    /// Token symbol to sweep (e.g., USDC, USDT, POL, BNB)
    token: String,
    /// Chain to sweep from (e.g., polygon, bsc, base, arb)
    chain: String,
}

// --- Voting params ---

#[derive(Deserialize, JsonSchema)]
struct VoteEligibilityParams {
    /// Snapshot height for the vote round
    #[serde(rename = "snapshot_height")]
    _snapshot_height: u64,
}

// --- Ironwood pool transfer params ---

#[derive(Deserialize, JsonSchema)]
struct IronwoodPlanParams {}

#[derive(Deserialize, JsonSchema)]
struct IronwoodConfirmParams {
    /// Enable Tor for broadcasting
    tor: Option<bool>,
}

#[derive(Deserialize, JsonSchema)]
struct IronwoodStatusParams {}

#[derive(Deserialize, JsonSchema)]
struct IronwoodPauseParams {}

#[derive(Deserialize, JsonSchema)]
struct IronwoodResumeParams {}

// --- HITL params ---

#[derive(Deserialize, JsonSchema)]
struct HitlPairParams {
    /// Device name for the mobile wallet (e.g., "iPhone 15")
    device_name: String,
    /// Override relay URL (default: https://relay.atmospherelabs.dev)
    relay_url: Option<String>,
}

#[derive(Deserialize, JsonSchema)]
#[allow(dead_code)]
struct HitlDecideParams {
    /// The approval ID to decide on
    approval_id: String,
    /// Whether to approve (true) or reject (false)
    approved: bool,
    /// Optional rejection reason
    reason: Option<String>,
}

// ---------------------------------------------------------------------------
// MCP Server state
// ---------------------------------------------------------------------------

static PAYMENT_OPERATION: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

#[derive(Clone)]
struct ReviewedSend {
    id: String,
    address: String,
    amount: u64,
    fee: u64,
    context_id: Option<String>,
}

#[derive(Clone)]
struct ZipherMcpServer {
    data_dir: String,
    seed: Arc<RwLock<Option<SecretString>>>,
    locked: Arc<std::sync::atomic::AtomicBool>,
    network: Network,
    seed_source: Arc<SeedSource>,
    reviewed_send: Arc<tokio::sync::Mutex<Option<ReviewedSend>>>,
}

// ---------------------------------------------------------------------------
// Tool implementations
// ---------------------------------------------------------------------------

impl ZipherMcpServer {
    // Caller holds PAYMENT_OPERATION from proposal creation through broadcast.
    async fn confirm_accounted(&self, seed: &SecretString, address: &str,
        amount: u64, fee: u64, context_id: &Option<String>) -> Result<String> {
        if self.locked.load(std::sync::atomic::Ordering::SeqCst) {
            anyhow::bail!("WALLET_LOCKED");
        }
        let policy = zipher_engine::policy::load_policy_checked(&self.data_dir)?;
        zipher_engine::policy::check_rate_limit(&policy)
            .map_err(|e| anyhow::anyhow!("{e}"))?;
        let reservation = zipher_engine::audit::reserve_spend(
            &self.data_dir, address, amount, fee, context_id, &policy)?;
        // A failure may be an ambiguous broadcast. Never release its reserved
        // budget automatically, or retry the payment on behalf of the caller.
        let txid = zipher_engine::send::confirm_send(seed).await?;
        zipher_engine::audit::settle_spend(&self.data_dir, reservation, &txid)?;
        Ok(txid)
    }
}

#[tool_router]
impl ZipherMcpServer {
    #[tool(description = "Get wallet status: sync height, balance, primary address, policy summary, and seed source")]
    async fn wallet_status(&self) -> String {
        #[derive(Serialize)]
        struct WalletStatus {
            synced_height: u32,
            latest_height: u32,
            is_syncing: bool,
            balance: zipher_engine::types::WalletBalance,
            address: Option<String>,
            policy: zipher_engine::policy::SpendingPolicy,
            locked: bool,
            seed_source: String,
        }

        let progress = zipher_engine::sync::get_progress().await;
        let balance = match zipher_engine::query::get_wallet_balance().await {
            Ok(b) => b,
            Err(e) => return err_response(&e),
        };
        let address = zipher_engine::query::get_addresses()
            .await
            .ok()
            .and_then(|a| a.first().map(|info| info.address.clone()));
        let policy = match zipher_engine::policy::load_policy_checked(&self.data_dir) {
            Ok(p) => p, Err(e) => return err_response(&e),
        };

        ok_response(WalletStatus {
            synced_height: progress.synced_height,
            latest_height: progress.latest_height,
            is_syncing: progress.is_syncing,
            balance,
            address,
            policy,
            locked: self.locked.load(std::sync::atomic::Ordering::SeqCst),
            seed_source: self.seed_source.label().to_string(),
        })
    }

    #[tool(description = "Lock the wallet — clears the seed from memory. All signing operations will fail until unlocked. Read-only tools (balance, status, transactions) still work.")]
    async fn wallet_lock(&self) -> String {
        let _payment = PAYMENT_OPERATION.lock().await;
        self.reviewed_send.lock().await.take();
        if self.locked.load(std::sync::atomic::Ordering::SeqCst) {
            return err_code_response(WALLET_LOCKED, "Wallet is already locked.");
        }

        self.locked.store(true, std::sync::atomic::Ordering::SeqCst);
        {
            let mut seed_guard = self.seed.write().await;
            *seed_guard = None;
        }

        tracing::info!("Wallet locked — seed cleared from memory");
        ok_response(serde_json::json!({ "locked": true }))
    }

    #[tool(description = "Get pool-specific wallet balance (shielded orchard, shielded sapling, transparent, unconfirmed)")]
    async fn get_balance(&self) -> String {
        match zipher_engine::query::get_wallet_balance().await {
            Ok(balance) => ok_response(balance),
            Err(e) => err_response(&e),
        }
    }

    #[tool(description = "Create a send proposal. Returns fee and amount for review before signing. Call confirm_send to broadcast.")]
    async fn propose_send(&self, Parameters(params): Parameters<ProposeSendParams>) -> String {
        let _payment = PAYMENT_OPERATION.lock().await;
        self.reviewed_send.lock().await.take();
        let policy = match zipher_engine::policy::load_policy_checked(&self.data_dir) {
            Ok(p) => p, Err(e) => return err_response(&e),
        };
        let daily_spent = match zipher_engine::audit::daily_spent(&self.data_dir) {
            Ok(v) => v, Err(e) => return err_response(&e),
        };

        if let Err(violation) = zipher_engine::policy::check_proposal(
            &policy, &params.address, params.amount, &params.context_id, daily_spent,
        ) {


            zipher_engine::audit::log_event(
                &self.data_dir, "propose_send", Some(&params.address),
                Some(params.amount), None, params.context_id.as_deref(),
                None, Some(&violation.to_string()),
            ).ok();
            let code = match &violation {
                zipher_engine::policy::PolicyViolation::AddressNotAllowed { .. } => ADDRESS_NOT_ALLOWED,
                zipher_engine::policy::PolicyViolation::ContextRequired => CONTEXT_REQUIRED,
                zipher_engine::policy::PolicyViolation::ApprovalRequired { .. } => APPROVAL_REQUIRED,
                _ => POLICY_EXCEEDED,
            };
            return err_code_response(code, &violation.to_string());
        }

        match zipher_engine::send::propose_send(&params.address, params.amount, params.memo, false, false).await {
            Ok((send_amount, fee, _)) => {
                let proposal_id = uuid::Uuid::new_v4().to_string();
                *self.reviewed_send.lock().await = Some(ReviewedSend {
                    id: proposal_id.clone(),
                    address: params.address.clone(), amount: send_amount, fee,
                    context_id: params.context_id.clone(),
                });
                zipher_engine::audit::log_event(
                    &self.data_dir, "propose_send", Some(&params.address),
                    Some(send_amount), Some(fee), params.context_id.as_deref(),
                    None, None,
                ).ok();

                #[derive(Serialize)]
                struct ProposalResult {
                    proposal_id: String,
                    address: String,
                    send_amount: u64,
                    fee: u64,
                    total: u64,
                    send_amount_zec: f64,
                    fee_zec: f64,
                }

                ok_response(ProposalResult {
                    proposal_id,
                    address: params.address,
                    send_amount,
                    fee,
                    total: send_amount + fee,
                    send_amount_zec: send_amount as f64 / 1e8,
                    fee_zec: fee as f64 / 1e8,
                })
            }
            Err(e) => {
                zipher_engine::audit::log_event(
                    &self.data_dir, "propose_send", Some(&params.address),
                    Some(params.amount), None, params.context_id.as_deref(),
                    None, Some(&format!("{:#}", e)),
                ).ok();
                err_response(&e)
            }
        }
    }

    #[tool(description = "Sign and broadcast the pending send proposal. Uses seed from server memory — never pass seed as argument.")]
    async fn confirm_send(&self, Parameters(params): Parameters<ConfirmSendParams>) -> String {
        let _payment = PAYMENT_OPERATION.lock().await;
        if self.locked.load(std::sync::atomic::Ordering::SeqCst) {
            return err_code_response(WALLET_LOCKED, "Wallet is locked. Ask the operator to unlock.");
        }

        let seed_guard = self.seed.read().await;
        let seed_str = match seed_guard.as_ref() {
            Some(s) => s.clone(),
            None => {
                return err_code_response(WALLET_LOCKED, "No seed available. Run `zipher wallet init` to create an encrypted vault, then restart the server from the trusted operator terminal.");
            }
        };
        drop(seed_guard);

        let policy = match zipher_engine::policy::load_policy_checked(&self.data_dir) {
            Ok(p) => p, Err(e) => return err_response(&e),
        };
        if let Err(violation) = zipher_engine::policy::check_rate_limit(&policy) {
            zipher_engine::audit::log_event(
                &self.data_dir, "confirm_send", None,
                None, None, params.context_id.as_deref(),
                None, Some(&violation.to_string()),
            ).ok();
            return err_code_response(POLICY_EXCEEDED, &violation.to_string());
        }

        let reviewed = {
            let mut pending = self.reviewed_send.lock().await;
            match pending.as_ref() {
                Some(p) if p.id == params.proposal_id && p.context_id == params.context_id => {}
                _ => return err_code_response(INVALID_PROPOSAL, "Proposal replaced or context changed. Review again."),
            }
            pending.take().expect("matched pending proposal")
        };
        match self.confirm_accounted(&seed_str, &reviewed.address, reviewed.amount,
            reviewed.fee, &reviewed.context_id).await {
            Ok(txid) => {
                zipher_engine::policy::record_confirm();
                zipher_engine::audit::log_event(
                    &self.data_dir, "confirm_send", Some(&reviewed.address),
                    Some(reviewed.amount), Some(reviewed.fee), params.context_id.as_deref(),
                    Some(&txid), None,
                ).ok();

                #[derive(Serialize)]
                struct ConfirmResult { txid: String }
                ok_response(ConfirmResult { txid })
            }
            Err(e) => {
                zipher_engine::audit::log_event(
                    &self.data_dir, "confirm_send", None,
                    None, None, params.context_id.as_deref(),
                    None, Some(&format!("{:#}", e)),
                ).ok();
                err_response(&e)
            }
        }
    }

    #[tool(description = "Get the current pending approval awaiting operator review, if any. Returns approval details or null.")]
    async fn get_pending_approval(&self) -> String {
        match zipher_engine::policy::get_pending_approval() {
            Some(p) => ok_response(p),
            None => ok_response(serde_json::json!(null)),
        }
    }

    #[tool(description = "Shield transparent funds into the shielded pool. Uses seed from server memory.")]
    async fn shield_funds(&self) -> String {
        err_code_response(APPROVAL_REQUIRED, "Shield funds from the authenticated wallet UI or operator CLI.")
    }

    #[tool(description = "Get recent transaction history with memos")]
    async fn get_transactions(&self, Parameters(params): Parameters<GetTransactionsParams>) -> String {
        match zipher_engine::query::get_transactions().await {
            Ok(mut txs) => {
                txs.truncate(params.limit.unwrap_or(20));
                ok_response(txs)
            }
            Err(e) => err_response(&e),
        }
    }

    #[tool(description = "Get current sync status: synced height, latest height, whether syncing, any connection errors")]
    async fn sync_status(&self) -> String {
        let progress = zipher_engine::sync::get_progress().await;
        ok_response(progress)
    }

    #[tool(description = "Validate a Zcash address and return whether it is valid and its type")]
    async fn validate_address(&self, Parameters(params): Parameters<ValidateAddressParams>) -> String {
        #[derive(Serialize)]
        struct AddressValidation {
            valid: bool,
            address: String,
            address_type: Option<String>,
        }

        match params.address.parse::<zcash_address::ZcashAddress>() {
            Ok(_) => {
                let addr_type = if params.address.starts_with("zs") || params.address.starts_with("ztestsapling") {
                    "sapling"
                } else if params.address.starts_with("t1") || params.address.starts_with("t3") || params.address.starts_with("tm") {
                    "transparent"
                } else if params.address.starts_with("u1") || params.address.starts_with("utest") {
                    "unified"
                } else {
                    "unknown"
                };
                ok_response(AddressValidation {
                    valid: true,
                    address: params.address,
                    address_type: Some(addr_type.to_string()),
                })
            }
            Err(_) => {
                ok_response(AddressValidation {
                    valid: false,
                    address: params.address,
                    address_type: None,
                })
            }
        }
    }

    #[tool(description = "List available tokens for cross-chain swaps via Near Intents. Returns token symbols, blockchains, and prices.")]
    async fn swap_tokens(&self) -> String {
        match zipher_engine::swap::get_tokens().await {
            Ok(tokens) => {
                let swappable: Vec<_> = zipher_engine::swap::swappable_tokens(&tokens)
                    .into_iter()
                    .map(|t| serde_json::json!({
                        "asset_id": t.asset_id,
                        "symbol": t.symbol,
                        "blockchain": t.blockchain,
                        "decimals": t.decimals,
                        "price": t.price,
                    }))
                    .collect();
                let zec_id = zipher_engine::swap::find_zec_token(&tokens)
                    .map(|t| t.asset_id.clone());
                ok_response(serde_json::json!({
                    "zec_asset_id": zec_id,
                    "total": swappable.len(),
                    "tokens": swappable,
                }))
            }
            Err(e) => err_response(&e),
        }
    }

    #[tool(description = "Get a swap quote: ZEC to another asset via Near Intents. Shows expected output amount and deposit address. Does NOT execute the swap.")]
    async fn swap_quote(&self, Parameters(params): Parameters<SwapQuoteParams>) -> String {
        let tokens = match zipher_engine::swap::get_tokens().await {
            Ok(t) => t,
            Err(e) => return err_response(&e),
        };

        let zec = match zipher_engine::swap::find_zec_token(&tokens) {
            Some(t) => t,
            None => return err_code_response(INTERNAL_ERROR, "ZEC not found in token list"),
        };

        let dest = match find_dest_token(&tokens, &params.to_symbol, params.chain.as_deref()) {
            Ok(t) => t,
            Err(e) => return err_code_response(INVALID_PROPOSAL, &format!("{e}")),
        };

        let refund_addr = match zipher_engine::query::get_addresses().await {
            Ok(addrs) => addrs.first().map(|a| a.address.clone()).unwrap_or_default(),
            Err(e) => return err_response(&e),
        };

        match zipher_engine::swap::get_quote(
            &zec.asset_id,
            &dest.asset_id,
            &params.amount.to_string(),
            &params.recipient,
            &refund_addr,
            params.slippage.unwrap_or(100),
        ).await {
            Ok(quote) => ok_response(&quote),
            Err(e) => err_response(&e),
        }
    }

    #[tool(description = "Execute a cross-chain swap: send ZEC to Near Intents deposit address and receive another asset. Requires seed. Privacy note: ZEC side is shielded, destination is public.")]
    async fn swap_execute(&self, Parameters(params): Parameters<SwapExecuteParams>) -> String {
        let _payment = PAYMENT_OPERATION.lock().await;
        self.reviewed_send.lock().await.take();
        if self.locked.load(std::sync::atomic::Ordering::SeqCst) {
            return err_code_response(WALLET_LOCKED, "Wallet is locked.");
        }

        let seed_guard = self.seed.read().await;
        let seed_str = match seed_guard.as_ref() {
            Some(s) => s.clone(),
            None => return err_code_response(WALLET_LOCKED, "No seed available."),
        };
        drop(seed_guard);

        let tokens = match zipher_engine::swap::get_tokens().await {
            Ok(t) => t,
            Err(e) => return err_response(&e),
        };

        let zec = match zipher_engine::swap::find_zec_token(&tokens) {
            Some(t) => t,
            None => return err_code_response(INTERNAL_ERROR, "ZEC not found in token list"),
        };

        let dest = match find_dest_token(&tokens, &params.to_symbol, params.chain.as_deref()) {
            Ok(t) => t,
            Err(e) => return err_code_response(INVALID_PROPOSAL, &format!("{e}")),
        };

        let refund_addr = match zipher_engine::query::get_addresses().await {
            Ok(addrs) => addrs.first().map(|a| a.address.clone()).unwrap_or_default(),
            Err(e) => return err_response(&e),
        };

        let quote = match zipher_engine::swap::get_quote(
            &zec.asset_id,
            &dest.asset_id,
            &params.amount.to_string(),
            &params.recipient,
            &refund_addr,
            params.slippage.unwrap_or(100),
        ).await {
            Ok(q) => q,
            Err(e) => return err_response(&e),
        };

        if quote.deposit_address.is_empty() {
            return err_code_response(INTERNAL_ERROR, "No deposit address in quote");
        }

        let policy = match zipher_engine::policy::load_policy_checked(&self.data_dir) {
            Ok(p) => p, Err(e) => return err_response(&e),
        };
        let daily_spent = match zipher_engine::audit::daily_spent(&self.data_dir) {
            Ok(v) => v, Err(e) => return err_response(&e),
        };
        if let Err(violation) = zipher_engine::policy::check_proposal(
            &policy, &quote.deposit_address, params.amount, &params.context_id, daily_spent,
        ) {
            zipher_engine::audit::log_event(
                &self.data_dir, "swap_execute", Some(&quote.deposit_address),
                Some(params.amount), None, params.context_id.as_deref(),
                None, Some(&violation.to_string()),
            ).ok();
            let code = match &violation {
                zipher_engine::policy::PolicyViolation::AddressNotAllowed { .. } => ADDRESS_NOT_ALLOWED,
                zipher_engine::policy::PolicyViolation::ContextRequired => CONTEXT_REQUIRED,
                zipher_engine::policy::PolicyViolation::ApprovalRequired { .. } => APPROVAL_REQUIRED,
                _ => POLICY_EXCEEDED,
            };
            return err_code_response(code, &violation.to_string());
        }
        if let Err(violation) = zipher_engine::policy::check_rate_limit(&policy) {
            zipher_engine::audit::log_event(
                &self.data_dir, "swap_execute", Some(&quote.deposit_address),
                Some(params.amount), None, params.context_id.as_deref(),
                None, Some(&violation.to_string()),
            ).ok();
            return err_code_response(POLICY_EXCEEDED, &violation.to_string());
        }

        let (send_amount, fee, _) = match zipher_engine::send::propose_send(
            &quote.deposit_address, params.amount, None, false, false,
        ).await {
            Ok(r) => r,
            Err(e) => return err_response(&e),
        };

        if let Err(e) = quote.validate_for_funding(send_amount) {
            return err_response(&e);
        }
        let txid = match self.confirm_accounted(&seed_str, &quote.deposit_address, send_amount, fee, &params.context_id).await {
            Ok(txid) => {
                zipher_engine::policy::record_confirm();
                zipher_engine::audit::log_event(
                    &self.data_dir, "swap_execute", Some(&quote.deposit_address),
                    Some(send_amount), Some(fee), params.context_id.as_deref(),
                    Some(&txid), None,
                ).ok();
                txid
            }
            Err(e) => {
                zipher_engine::audit::log_event(
                    &self.data_dir, "swap_execute", Some(&quote.deposit_address),
                    Some(send_amount), Some(fee), params.context_id.as_deref(),
                    None, Some(&format!("{:#}", e)),
                ).ok();
                return err_response(&e);
            }
        };

        let _ = zipher_engine::swap::submit_deposit(&txid, &quote.deposit_address).await;

        ok_response(serde_json::json!({
            "txid": txid,
            "deposit_address": quote.deposit_address,
            "amount_in": quote.amount_in,
            "amount_out": quote.amount_out,
            "destination_symbol": params.to_symbol,
            "destination_chain": dest.blockchain,
            "recipient": params.recipient,
            "fee_zatoshis": fee,
        }))
    }

    #[tool(description = "Check the status of a cross-chain swap by its deposit address.")]
    async fn swap_status(&self, Parameters(params): Parameters<SwapStatusParams>) -> String {
        match zipher_engine::swap::get_status(&params.deposit_address).await {
            Ok(status) => ok_response(&status),
            Err(e) => err_response(&e),
        }
    }

    #[tool(description = "Open a prepaid session: send ZEC once, get a bearer token for many instant requests. Requires seed.")]
    async fn session_open(&self, Parameters(params): Parameters<SessionOpenParams>) -> String {
        let _payment = PAYMENT_OPERATION.lock().await;
        self.reviewed_send.lock().await.take();
        if self.locked.load(std::sync::atomic::Ordering::SeqCst) {
            return err_code_response(WALLET_LOCKED, "Wallet is locked.");
        }

        let seed_guard = self.seed.read().await;
        let seed_str = match seed_guard.as_ref() {
            Some(s) => s.clone(),
            None => return err_code_response(WALLET_LOCKED, "No seed available."),
        };
        drop(seed_guard);

        let memo = format!("zipher:session:{}", params.merchant_id);
        let policy = match zipher_engine::policy::load_policy_checked(&self.data_dir) {
            Ok(p) => p, Err(e) => return err_response(&e),
        };
        let daily_spent = match zipher_engine::audit::daily_spent(&self.data_dir) {
            Ok(v) => v, Err(e) => return err_response(&e),
        };
        if let Err(violation) = zipher_engine::policy::check_proposal(
            &policy, &params.pay_to, params.deposit, &params.context_id, daily_spent,
        ) {
            zipher_engine::audit::log_event(
                &self.data_dir, "session_open", Some(&params.pay_to),
                Some(params.deposit), None, params.context_id.as_deref(),
                None, Some(&violation.to_string()),
            ).ok();
            let code = match &violation {
                zipher_engine::policy::PolicyViolation::AddressNotAllowed { .. } => ADDRESS_NOT_ALLOWED,
                zipher_engine::policy::PolicyViolation::ContextRequired => CONTEXT_REQUIRED,
                zipher_engine::policy::PolicyViolation::ApprovalRequired { .. } => APPROVAL_REQUIRED,
                _ => POLICY_EXCEEDED,
            };
            return err_code_response(code, &violation.to_string());
        }
        if let Err(violation) = zipher_engine::policy::check_rate_limit(&policy) {
            zipher_engine::audit::log_event(
                &self.data_dir, "session_open", Some(&params.pay_to),
                Some(params.deposit), None, params.context_id.as_deref(),
                None, Some(&violation.to_string()),
            ).ok();
            return err_code_response(POLICY_EXCEEDED, &violation.to_string());
        }

        let (send_amount, fee, _) = match zipher_engine::send::propose_send(
            &params.pay_to, params.deposit, Some(memo), false, false,
        ).await {
            Ok(r) => r,
            Err(e) => return err_response(&e),
        };

        let txid = match self.confirm_accounted(&seed_str, &params.pay_to, send_amount, fee, &params.context_id).await {
            Ok(txid) => {
                zipher_engine::policy::record_confirm();
                zipher_engine::audit::log_event(
                    &self.data_dir, "session_open", Some(&params.pay_to),
                    Some(send_amount), Some(fee), params.context_id.as_deref(),
                    Some(&txid), None,
                ).ok();
                txid
            }
            Err(e) => {
                zipher_engine::audit::log_event(
                    &self.data_dir, "session_open", Some(&params.pay_to),
                    Some(send_amount), Some(fee), params.context_id.as_deref(),
                    None, Some(&format!("{:#}", e)),
                ).ok();
                return err_response(&e);
            }
        };

        match zipher_engine::session::open_session(
            None,
            &txid,
            &params.merchant_id,
            &params.server_url,
            &self.data_dir,
        ).await {
            Ok(session) => ok_response(&session),
            Err(e) => err_response(&e),
        }
    }

    #[tool(description = "Make a request using an active session's bearer token. No payment needed — uses prepaid credit.")]
    async fn session_request(&self, Parameters(params): Parameters<SessionRequestParams>) -> String {
        let host = params.url
            .split("//")
            .nth(1)
            .and_then(|s| s.split('/').next())
            .unwrap_or(&params.url);
        let server_url = format!(
            "{}//{}",
            params.url.split("//").next().unwrap_or("https:"),
            host
        );

        let session = match zipher_engine::session::find_session(&self.data_dir, &server_url) {
            Some(s) => s,
            None => return err_code_response(INVALID_PROPOSAL, &format!("No active session for {server_url}")),
        };

        let method = params.method.as_deref().unwrap_or("GET");
        match zipher_engine::session::session_request(&session, &params.url, method).await {
            Ok((status, body, remaining)) => {
                if let Some(rem) = remaining {
                    let mut store = zipher_engine::session::load_sessions(&self.data_dir);
                    if let Some(s) = store.sessions.iter_mut().find(|s| s.session_id == session.session_id) {
                        s.balance_remaining = rem;
                    }
                    zipher_engine::session::save_sessions(&self.data_dir, &store).ok();
                }
                ok_response(serde_json::json!({
                    "status": status,
                    "session_id": session.session_id,
                    "balance_remaining": remaining,
                    "response": body,
                }))
            }
            Err(e) => err_response(&e),
        }
    }

    #[tool(description = "List all active sessions with their balances.")]
    async fn session_list(&self) -> String {
        let sessions = zipher_engine::session::list_sessions(&self.data_dir);
        ok_response(serde_json::json!({
            "total": sessions.len(),
            "sessions": sessions,
        }))
    }

    #[tool(description = "Close a session and get final usage summary.")]
    async fn session_close(&self, Parameters(params): Parameters<SessionCloseParams>) -> String {
        match zipher_engine::session::close_session(None, &params.session_id, &self.data_dir).await {
            Ok(summary) => ok_response(&summary),
            Err(e) => err_response(&e),
        }
    }

    // --- CipherPay merchant tools ---

    #[tool(description = "Create a CipherPay invoice for accepting ZEC payments. Returns payment address, QR URI, and checkout URL. Requires CIPHERPAY_API_KEY.")]
    async fn cipherpay_create_invoice(&self, Parameters(params): Parameters<CipherpayInvoiceParams>) -> String {
        match zipher_engine::cipherpay::create_invoice(
            &params.product_name,
            params.amount,
            params.currency.as_deref().unwrap_or("USD"),
        ).await {
            Ok(invoice) => ok_response(&invoice),
            Err(e) => err_response(&e),
        }
    }

    #[tool(description = "Check the status of a CipherPay invoice by ID. Returns status (pending/detected/confirmed/expired), received amount, and transaction ID if paid.")]
    async fn cipherpay_check_invoice(&self, Parameters(params): Parameters<CipherpayCheckParams>) -> String {
        match zipher_engine::cipherpay::check_invoice(&params.invoice_id).await {
            Ok(status) => ok_response(&status),
            Err(e) => err_response(&e),
        }
    }

    #[tool(description = "Get your CipherPay merchant balance and stats. Returns total ZEC received, confirmed payment count, and merchant info. Requires CIPHERPAY_API_KEY.")]
    async fn cipherpay_balance(&self) -> String {
        match zipher_engine::cipherpay::merchant_balance().await {
            Ok(balance) => ok_response(&balance),
            Err(e) => err_response(&e),
        }
    }

    #[tool(description = "Pay any 402 paywall by URL. Automatically detects x402 or MPP protocol, pays, retries the request, and returns the response. This is the simplest way to access a paid API.")]
    async fn pay_url(&self, Parameters(params): Parameters<PayUrlParams>) -> String {
        let _payment = PAYMENT_OPERATION.lock().await;
        self.reviewed_send.lock().await.take();
        if self.locked.load(std::sync::atomic::Ordering::SeqCst) {
            return err_code_response(WALLET_LOCKED, "Wallet is locked.");
        }

        let seed_guard = self.seed.read().await;
        let seed_str = match seed_guard.as_ref() {
            Some(s) => s.clone(),
            None => return err_code_response(WALLET_LOCKED, "No seed available."),
        };
        drop(seed_guard);

        let expected_network = if self.network == Network::TestNetwork {
            "zcash:testnet"
        } else {
            "zcash:mainnet"
        };

        let client = reqwest::Client::new();
        let http_method = params.method.as_deref().unwrap_or("GET");
        let initial_resp = match http_method.to_uppercase().as_str() {
            "POST" => client.post(&params.url).send().await,
            "PUT" => client.put(&params.url).send().await,
            _ => client.get(&params.url).send().await,
        };
        let initial_resp = match initial_resp {
            Ok(r) => r,
            Err(e) => return err_code_response(NETWORK_TIMEOUT, &format!("HTTP request failed: {e}")),
        };

        if initial_resp.status() != reqwest::StatusCode::PAYMENT_REQUIRED {
            let status = initial_resp.status();
            let body = initial_resp.text().await.unwrap_or_default();
            if status.is_success() {
                return ok_response(serde_json::json!({ "status": status.as_u16(), "response": body }));
            }
            return err_code_response(INTERNAL_ERROR, &format!("Expected HTTP 402, got {status}"));
        }

        let mut headers = std::collections::HashMap::new();
        for (k, v) in initial_resp.headers() {
            if let Ok(val) = v.to_str() {
                headers.insert(k.as_str().to_lowercase(), val.to_string());
            }
        }
        let body = initial_resp.text().await.unwrap_or_default();

        let protocol = match zipher_engine::payment::detect_protocol(&headers, &body, expected_network) {
            Ok(p) => p,
            Err(zec_err) => {
                // Try cross-chain EVM x402 detection
                if let Ok(evm_info) = zipher_engine::evm_pay::parse_evm_x402(&body) {
                    let amount_human = evm_info.amount_raw.parse::<f64>().unwrap_or(0.0)
                        / 10f64.powi(evm_info.decimals as i32);
                    return ok_response(serde_json::json!({
                        "cross_chain_required": true,
                        "chain": evm_info.chain.name,
                        "network": evm_info.network,
                        "asset": evm_info.asset_symbol,
                        "asset_contract": evm_info.asset_contract,
                        "amount_raw": evm_info.amount_raw,
                        "amount_human": format!("{:.6}", amount_human),
                        "pay_to": evm_info.pay_to,
                        "action_required": format!(
                            "This API requires {} {} on {}. Use swap_execute to convert ZEC → {} on {}, \
                             then use the CLI 'pay_url' command which handles cross-chain x402 automatically.",
                            amount_human, evm_info.asset_symbol, evm_info.chain.name,
                            evm_info.asset_symbol, evm_info.chain.near_intents_blockchain
                        ),
                    }));
                }
                return err_code_response(INVALID_PROPOSAL, &format!("{zec_err}"));
            }
        };

        let address = match protocol.address() {
            Ok(a) => a,
            Err(e) => return err_code_response(INVALID_PROPOSAL, &format!("{e}")),
        };
        let amount = match protocol.amount_zatoshis() {
            Ok(a) => a,
            Err(e) => return err_code_response(INVALID_PROPOSAL, &format!("{e}")),
        };

        let policy = match zipher_engine::policy::load_policy_checked(&self.data_dir) {
            Ok(p) => p, Err(e) => return err_response(&e),
        };
        let daily_spent = match zipher_engine::audit::daily_spent(&self.data_dir) {
            Ok(v) => v, Err(e) => return err_response(&e),
        };
        if let Err(violation) = zipher_engine::policy::check_proposal(
            &policy, &address, amount, &params.context_id, daily_spent,
        ) {
            zipher_engine::audit::log_event(
                &self.data_dir, "pay_url", Some(&address),
                Some(amount), None, params.context_id.as_deref(),
                None, Some(&violation.to_string()),
            ).ok();
            return err_code_response(POLICY_EXCEEDED, &violation.to_string());
        }
        if let Err(violation) = zipher_engine::policy::check_rate_limit(&policy) {
            return err_code_response(POLICY_EXCEEDED, &violation.to_string());
        }

        let (send_amount, fee, _) = match zipher_engine::send::propose_send(&address, amount, None, false, false).await {
            Ok(r) => r,
            Err(e) => return err_response(&e),
        };

        let txid = match self.confirm_accounted(&seed_str, &address, send_amount, fee, &params.context_id).await {
            Ok(txid) => {
                zipher_engine::policy::record_confirm();
                zipher_engine::audit::log_event(
                    &self.data_dir, "pay_url", Some(&address),
                    Some(send_amount), Some(fee), params.context_id.as_deref(),
                    Some(&txid), None,
                ).ok();
                txid
            }
            Err(e) => {
                zipher_engine::audit::log_event(
                    &self.data_dir, "pay_url", Some(&address),
                    Some(send_amount), Some(fee), params.context_id.as_deref(),
                    None, Some(&format!("{:#}", e)),
                ).ok();
                return err_response(&e);
            }
        };

        let (cred_header, cred_value) = protocol.build_credential(&txid);

        let retry_resp = match http_method.to_uppercase().as_str() {
            "POST" => client.post(&params.url).header(&cred_header, &cred_value).send().await,
            "PUT" => client.put(&params.url).header(&cred_header, &cred_value).send().await,
            _ => client.get(&params.url).header(&cred_header, &cred_value).send().await,
        };
        let retry_resp = match retry_resp {
            Ok(r) => r,
            Err(e) => return err_code_response(NETWORK_TIMEOUT, &format!("Retry request failed: {e}")),
        };

        let retry_status = retry_resp.status().as_u16();
        let response_body = retry_resp.text().await.unwrap_or_default();

        let info = protocol.info().ok();

        ok_response(serde_json::json!({
            "txid": txid,
            "protocol": info.as_ref().map(|i| &i.protocol),
            "amount_zatoshis": send_amount,
            "fee_zatoshis": fee,
            "pay_to": address,
            "retry_status": retry_status,
            "response": response_body,
        }))
    }

    #[tool(description = "Research a prediction market topic using web search (Firecrawl). Returns news articles, snippets, and a summary the LLM can use to estimate probabilities. Set FIRECRAWL_API_KEY for web search; works without it but returns no external data.")]
    async fn market_research(&self, Parameters(params): Parameters<MarketResearchParams>) -> String {
        match zipher_engine::research::search_news(
            &params.query,
            params.limit.unwrap_or(5),
        ).await {
            Ok(report) => ok_response(serde_json::json!({
                "query": report.query,
                "source": report.source,
                "summary": report.summary,
                "items": report.items.iter().map(|item| serde_json::json!({
                    "title": item.title,
                    "url": item.url,
                    "snippet": item.snippet,
                    "content": item.content,
                })).collect::<Vec<_>>(),
            })),
            Err(e) => err_response(&e),
        }
    }

    // --- Polymarket tools ---

    #[tool(description = "Discover prediction markets on Polymarket. Returns active events with their markets, prices, and volume. Use to find betting opportunities.")]
    async fn polymarket_discover(&self, Parameters(params): Parameters<PolymarketDiscoverParams>) -> String {
        match zipher_engine::polymarket::polymarket_discover(
            params.keyword.as_deref(),
            params.limit.unwrap_or(10),
            false,
        ).await {
            Ok(summary) => ok_response(&summary),
            Err(e) => err_response(&e),
        }
    }

    #[tool(description = "Get your Polymarket positions (open bets). Shows condition IDs, outcomes, sizes, and current prices.")]
    async fn polymarket_positions(&self, Parameters(params): Parameters<PolymarketPositionsParams>) -> String {
        let address = if let Some(addr) = params.address {
            addr
        } else {
            let seed_guard = self.seed.read().await;
            match seed_guard.as_ref() {
                Some(s) => {
                    match zipher_engine::polymarket::derive_address(s.expose_secret()) {
                        Ok(a) => a,
                        Err(e) => return err_response(&e),
                    }
                }
                None => return err_code_response(WALLET_LOCKED, "No seed available — cannot derive EVM address."),
            }
        };

        match zipher_engine::polymarket::polymarket_get_positions(&address).await {
            Ok(positions) => ok_response(&positions),
            Err(e) => err_response(&e),
        }
    }

    #[tool(description = "Get EVM token balances on a specific chain. Shows native balance and known ERC-20 tokens (USDC, USDT, etc.). Uses wallet's derived EVM address.")]
    async fn evm_balances(&self, Parameters(params): Parameters<EvmBalancesParams>) -> String {
        let seed_guard = self.seed.read().await;
        let seed_str = match seed_guard.as_ref() {
            Some(s) => s.clone(),
            None => return err_code_response(WALLET_LOCKED, "No seed available."),
        };
        drop(seed_guard);

        let chain = match zipher_engine::evm::chain_by_name(&params.chain) {
            Some(c) => c,
            None => return err_code_response(INVALID_PROPOSAL, &format!("Unknown chain '{}'. Use: polygon, bsc, base, arb, eth, op", params.chain)),
        };

        let address = match zipher_engine::ows::derive_evm_address(seed_str.expose_secret()) {
            Ok(a) => a,
            Err(e) => return err_response(&e),
        };

        let native_bal = zipher_engine::evm::get_native_balance(chain.rpc_url, &address)
            .await
            .unwrap_or(0);

        let known = zipher_engine::evm::known_tokens(chain.chain_id);
        let mut token_balances = Vec::new();
        for tok in &known {
            let bal = zipher_engine::evm::get_erc20_balance(chain.rpc_url, &tok.address, &address)
                .await
                .unwrap_or(0);
            if bal > 0 {
                token_balances.push(serde_json::json!({
                    "symbol": tok.symbol,
                    "balance_raw": bal.to_string(),
                    "balance": zipher_engine::evm::format_token_amount(bal, tok.decimals),
                    "decimals": tok.decimals,
                    "contract": tok.address,
                }));
            }
        }

        ok_response(serde_json::json!({
            "chain": params.chain,
            "chain_id": chain.chain_id,
            "address": address,
            "native_balance_wei": native_bal.to_string(),
            "native_balance": zipher_engine::evm::format_token_amount(native_bal, 18),
            "native_symbol": chain.native_symbol,
            "tokens": token_balances,
        }))
    }

    #[tool(description = "Get a quote for sweeping an EVM token back to shielded ZEC via NEAR Intents. Shows expected ZEC output. Does NOT execute — use the sweep flow for that.")]
    async fn sweep_quote(&self, Parameters(params): Parameters<SweepQuoteParams>) -> String {
        let seed_guard = self.seed.read().await;
        let seed_str = match seed_guard.as_ref() {
            Some(s) => s.clone(),
            None => return err_code_response(WALLET_LOCKED, "No seed available."),
        };
        drop(seed_guard);

        let address = match zipher_engine::ows::derive_evm_address(seed_str.expose_secret()) {
            Ok(a) => a,
            Err(e) => return err_response(&e),
        };

        let tokens = match zipher_engine::swap::get_tokens().await {
            Ok(t) => t,
            Err(e) => return err_response(&e),
        };

        let zec = match zipher_engine::swap::find_zec_token(&tokens) {
            Some(t) => t,
            None => return err_code_response(INTERNAL_ERROR, "ZEC not found in token list"),
        };

        let chain_blockchain = params.chain.to_lowercase();
        let source_token = tokens.iter().find(|t| {
            t.symbol.eq_ignore_ascii_case(&params.token)
                && t.blockchain.eq_ignore_ascii_case(&chain_blockchain)
        });
        let source_token = match source_token {
            Some(t) => t,
            None => return err_code_response(INVALID_PROPOSAL, &format!("{} on {} not found in swap tokens", params.token, params.chain)),
        };

        let zec_address = match zipher_engine::query::get_addresses().await {
            Ok(addrs) => addrs.first().map(|a| a.address.clone()).unwrap_or_default(),
            Err(e) => return err_response(&e),
        };

        // Get balance to know how much to sweep
        let evm_chain = match zipher_engine::evm::chain_by_name(&params.chain) {
            Some(c) => c,
            None => return err_code_response(INVALID_PROPOSAL, &format!("Unknown chain '{}'", params.chain)),
        };

        let balance = if source_token.symbol.eq_ignore_ascii_case(&evm_chain.native_symbol) {
            zipher_engine::evm::get_native_balance(evm_chain.rpc_url, &address)
                .await
                .unwrap_or(0)
        } else {
            let contract = zipher_engine::evm_pay::token_contract(&params.token, evm_chain.chain_id)
                .unwrap_or("");
            if contract.is_empty() {
                return err_code_response(INVALID_PROPOSAL, &format!("No known contract for {} on {}", params.token, params.chain));
            }
            zipher_engine::evm::get_erc20_balance(evm_chain.rpc_url, contract, &address)
                .await
                .unwrap_or(0)
        };

        if balance == 0 {
            return ok_response(serde_json::json!({
                "token": params.token,
                "chain": params.chain,
                "balance": "0",
                "message": "Nothing to sweep — zero balance.",
            }));
        }

        match zipher_engine::swap::get_quote(
            &source_token.asset_id,
            &zec.asset_id,
            &balance.to_string(),
            &zec_address,
            &address,
            100,
        ).await {
            Ok(quote) => ok_response(serde_json::json!({
                "token": params.token,
                "chain": params.chain,
                "balance_raw": balance.to_string(),
                "balance": zipher_engine::evm::format_token_amount(balance, source_token.decimals as u8),
                "estimated_zec_out": quote.amount_out,
                "deposit_address": quote.deposit_address,
                "note": "To execute: approve + transfer tokens to deposit_address, then submit deposit to NEAR Intents.",
            })),
            Err(e) => err_response(&e),
        }
    }

    // --- Voting / governance tools ---

    #[tool(description = "Check voting eligibility for a governance round. Returns total eligible ZEC, number of notes, and number of bundles needed for delegation.")]
    async fn vote_eligibility(&self, Parameters(_params): Parameters<VoteEligibilityParams>) -> String {
        err_response(&anyhow::anyhow!("Voting is temporarily disabled during the Ironwood (NU6.3) upgrade. It will return once zcash_voting supports orchard 0.15."))
    }

    // --- Ironwood pool transfer tools (ZIP 318) ---

    #[tool(description = "Read an Ironwood transfer plan from the current SDK. Requires an unlocked wallet seed for derivation; does not sign, persist or broadcast a transfer.")]
    async fn ironwood_plan(&self, Parameters(_params): Parameters<IronwoodPlanParams>) -> String {
        if self.locked.load(std::sync::atomic::Ordering::SeqCst) {
            return err_code_response(WALLET_LOCKED, "Unlock the wallet to derive the SDK plan.");
        }
        let seed_guard = self.seed.read().await;
        let Some(seed) = seed_guard.as_ref() else {
            return err_code_response(WALLET_LOCKED, "No signing seed is available for plan derivation.");
        };
        match zipher_engine::ironwood_v2::plan(seed).await {
            Ok(plan) => ok_response(plan),
            Err(e) => err_response(&e),
        }
    }

    #[tool(description = "Unavailable legacy Ironwood execution entry point. Does not sign or create a schedule; use the wallet app's reviewed SDK migration flow.")]
    async fn ironwood_confirm(&self, Parameters(params): Parameters<IronwoodConfirmParams>) -> String {
        let _requested_tor = params.tor;
        err_response(&anyhow::anyhow!("Headless Ironwood execution is not connected to the SDK runner. Use the wallet app to review and execute the transfer. Nothing was signed or scheduled."))
    }

    #[tool(description = "Read the current Ironwood migration state from the wallet's SDK database, including confirmed transactions and next due height.")]
    async fn ironwood_status(&self, Parameters(_params): Parameters<IronwoodStatusParams>) -> String {
        match zipher_engine::ironwood_v2::status().await {
            Ok(report) => ok_response(report),
            Err(e) => err_response(&e),
        }
    }

    #[tool(description = "Unavailable legacy pause entry point. Cannot pause the SDK migration runner; use the wallet app managing the transfer.")]
    async fn ironwood_pause(&self, Parameters(_params): Parameters<IronwoodPauseParams>) -> String {
        err_response(&anyhow::anyhow!("Headless pause cannot control the SDK migration runner. Nothing was paused."))
    }

    #[tool(description = "Unavailable legacy resume entry point. Cannot resume the SDK migration runner; use the wallet app managing the transfer.")]
    async fn ironwood_resume(&self, Parameters(_params): Parameters<IronwoodResumeParams>) -> String {
        err_response(&anyhow::anyhow!("Headless resume is not connected to the SDK migration runner. Nothing was resumed."))
    }

    // --- HITL tools ---

    #[tool(description = "Generate a pairing code for connecting this agent to a Zipher mobile wallet. The mobile wallet scans this code to establish a secure approval channel.")]
    async fn hitl_pair(&self, Parameters(params): Parameters<HitlPairParams>) -> String {
        let (channel_id, pairing_code) = match zipher_engine::hitl::generate_pairing_code(&self.data_dir) {
            Ok(r) => r,
            Err(e) => return err_response(&e),
        };

        match zipher_engine::hitl::complete_pairing(
            &self.data_dir,
            &channel_id,
            &params.device_name,
            params.relay_url.as_deref(),
        ) {
            Ok(config) => ok_response(serde_json::json!({
                "channel_id": channel_id,
                "pairing_code": pairing_code,
                "relay_url": config.relay_url,
                "device_name": params.device_name,
                "instructions": "Show this pairing code to the Zipher mobile app. Scan it in Settings > Agent Pairing.",
            })),
            Err(e) => err_response(&e),
        }
    }

    #[tool(description = "Check HITL relay status: whether mobile pairing is active, and fetch any pending approval decisions.")]
    async fn hitl_status(&self) -> String {
        let config = zipher_engine::hitl::get_config(&self.data_dir);
        let pending = zipher_engine::policy::get_pending_approval();

        let mut decision = None;
        if let (Some(ref p), true) = (&pending, config.enabled) {
            decision = zipher_engine::hitl::poll_decision(&self.data_dir, &p.id)
                .await
                .ok()
                .flatten();
        }

        ok_response(serde_json::json!({
            "hitl_enabled": config.enabled,
            "paired_device": config.pairing.as_ref().map(|p| &p.device_name),
            "channel_id": config.pairing.as_ref().map(|p| &p.channel_id),
            "relay_url": config.relay_url,
            "pending_approval": pending.map(|p| serde_json::json!({
                "approval_id": p.id,
                "address": p.address,
                "amount": p.amount,
                "amount_zec": p.amount as f64 / 1e8,
                "expires_in_secs": p.remaining_secs(),
            })),
            "decision": decision,
        }))
    }

    #[tool(description = "Pay an HTTP 402 paywall. Pass the full 402 response body. Returns txid and a PAYMENT-SIGNATURE header value to include when retrying the original request.")]
    async fn pay_x402(&self, Parameters(params): Parameters<PayX402Params>) -> String {
        let _payment = PAYMENT_OPERATION.lock().await;
        self.reviewed_send.lock().await.take();
        if self.locked.load(std::sync::atomic::Ordering::SeqCst) {
            return err_code_response(WALLET_LOCKED, "Wallet is locked. Ask the operator to unlock.");
        }

        let seed_guard = self.seed.read().await;
        let seed_str = match seed_guard.as_ref() {
            Some(s) => s.clone(),
            None => {
                return err_code_response(WALLET_LOCKED, "No seed available. Run `zipher wallet init` to create an encrypted vault, then restart the server from the trusted operator terminal.");
            }
        };
        drop(seed_guard);

        let expected_network = if self.network == Network::TestNetwork {
            "zcash:testnet"
        } else {
            "zcash:mainnet"
        };

        let req = match zipher_engine::x402::parse_402_response(&params.payment_body, expected_network) {
            Ok(r) => r,
            Err(e) => return err_code_response(INVALID_PROPOSAL, &format!("Invalid x402 body: {e}")),
        };

        let amount = match zipher_engine::x402::amount_zatoshis(&req) {
            Ok(a) => a,
            Err(e) => return err_code_response(INVALID_PROPOSAL, &format!("{e}")),
        };

        let address = req.pay_to.clone();

        let policy = match zipher_engine::policy::load_policy_checked(&self.data_dir) {
            Ok(p) => p, Err(e) => return err_response(&e),
        };
        let daily_spent = match zipher_engine::audit::daily_spent(&self.data_dir) {
            Ok(v) => v, Err(e) => return err_response(&e),
        };

        if let Err(violation) = zipher_engine::policy::check_proposal(
            &policy, &address, amount, &params.context_id, daily_spent,
        ) {
            zipher_engine::audit::log_event(
                &self.data_dir, "x402_pay", Some(&address),
                Some(amount), None, params.context_id.as_deref(),
                None, Some(&violation.to_string()),
            ).ok();
            let code = match &violation {
                zipher_engine::policy::PolicyViolation::AddressNotAllowed { .. } => ADDRESS_NOT_ALLOWED,
                zipher_engine::policy::PolicyViolation::ContextRequired => CONTEXT_REQUIRED,
                zipher_engine::policy::PolicyViolation::ApprovalRequired { .. } => APPROVAL_REQUIRED,
                _ => POLICY_EXCEEDED,
            };
            return err_code_response(code, &violation.to_string());
        }

        if let Err(violation) = zipher_engine::policy::check_rate_limit(&policy) {
            zipher_engine::audit::log_event(
                &self.data_dir, "x402_pay", Some(&address),
                Some(amount), None, params.context_id.as_deref(),
                None, Some(&violation.to_string()),
            ).ok();
            return err_code_response(POLICY_EXCEEDED, &violation.to_string());
        }

        let (send_amount, fee, _) = match zipher_engine::send::propose_send(&address, amount, None, false, false).await {
            Ok(r) => r,
            Err(e) => {
                zipher_engine::audit::log_event(
                    &self.data_dir, "x402_pay", Some(&address),
                    Some(amount), None, params.context_id.as_deref(),
                    None, Some(&format!("{:#}", e)),
                ).ok();
                return err_response(&e);
            }
        };

        match self.confirm_accounted(&seed_str, &address, send_amount, fee, &params.context_id).await {
            Ok(txid) => {
                zipher_engine::policy::record_confirm();
                zipher_engine::audit::log_event(
                    &self.data_dir, "x402_pay", Some(&address),
                    Some(send_amount), Some(fee), params.context_id.as_deref(),
                    Some(&txid), None,
                ).ok();

                let payment_signature = zipher_engine::x402::build_payment_signature(&txid, &req);

                #[derive(Serialize)]
                struct X402Result {
                    txid: String,
                    payment_signature: String,
                    amount_zatoshis: u64,
                    fee_zatoshis: u64,
                    pay_to: String,
                }

                ok_response(X402Result {
                    txid,
                    payment_signature,
                    amount_zatoshis: send_amount,
                    fee_zatoshis: fee,
                    pay_to: address,
                })
            }
            Err(e) => {
                zipher_engine::audit::log_event(
                    &self.data_dir, "x402_pay", Some(&address),
                    Some(send_amount), Some(fee), params.context_id.as_deref(),
                    None, Some(&format!("{:#}", e)),
                ).ok();
                err_response(&e)
            }
        }
    }
}

#[tool_handler]
impl ServerHandler for ZipherMcpServer {
    fn get_info(&self) -> ServerInfo {
        let mut info = rmcp::model::Implementation::from_build_env();
        info.name = "zipher-mcp-server".into();
        info.version = env!("CARGO_PKG_VERSION").into();
        info.title = Some("Zipher — Shielded Wallet for AI Agents".into());
        info.description = Some("Headless Zcash wallet with encrypted vault, spending policies, and x402 paywall access".into());
        info.website_url = Some("https://zipher.app".into());

        ServerInfo::default()
            .with_server_info(info)
            .with_instructions(
                "Zipher: headless Zcash wallet + multi-chain agent toolkit for AI. \
                 Seed is secured in an encrypted vault (OWS or Zipher) — never pass it as a tool argument. \
                 wallet_lock clears access; only a trusted operator restart can unlock. Threshold payments require the operator CLI, not an MCP approval tool. \
                 Paid APIs: pay_url auto-detects x402/MPP, pays, returns response. \
                 Cross-chain: swap_execute converts ZEC to any asset via Near Intents. \
                 EVM: evm_balances shows token holdings; sweep_quote previews bridging back to ZEC. \
                 Prediction markets: polymarket_discover finds markets, polymarket_positions shows bets, order signing is unavailable until per-asset operator authorization is implemented. \
                 Governance voting is unavailable in this version."
            )
    }
}

// ---------------------------------------------------------------------------
// Swap helpers
// ---------------------------------------------------------------------------

fn find_dest_token<'a>(
    tokens: &'a [zipher_engine::swap::SwapToken],
    symbol: &str,
    chain: Option<&str>,
) -> anyhow::Result<&'a zipher_engine::swap::SwapToken> {
    let matches: Vec<&zipher_engine::swap::SwapToken> = tokens
        .iter()
        .filter(|t| t.symbol.eq_ignore_ascii_case(symbol))
        .filter(|t| chain.map_or(true, |c| t.blockchain.eq_ignore_ascii_case(c)))
        .collect();

    match matches.len() {
        0 => Err(anyhow::anyhow!(
            "Token '{}' not found{}",
            symbol,
            chain.map_or(String::new(), |c| format!(" on chain '{}'", c))
        )),
        1 => Ok(matches[0]),
        _ => {
            let chains: Vec<String> = matches.iter().map(|t| t.blockchain.clone()).collect();
            Err(anyhow::anyhow!(
                "'{}' exists on multiple chains: {}. Specify chain.",
                symbol,
                chains.join(", ")
            ))
        }
    }
}

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

const DEFAULT_MAINNET_SERVER: &str = "https://lightwalletd.mainnet.cipherscan.app:443";
const DEFAULT_TESTNET_SERVER: &str = "https://testnet.zec.rocks:443";

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

#[tokio::main]
async fn main() -> Result<()> {
    // Informational commands must not open a wallet, load keys, or start sync.
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.iter().map(String::as_str).collect::<Vec<_>>().as_slice() {
        [] => {}
        ["--version" | "-V"] => {
            println!("zipher-mcp-server {}", env!("CARGO_PKG_VERSION"));
            return Ok(());
        }
        ["--help" | "-h"] => {
            println!("Zipher MCP server {}\n\nUsage: zipher-mcp-server [--version|--help]\n\nWith no arguments, serves MCP over stdio. Configure ZIPHER_DATA_DIR,\nZIPHER_SERVER, ZIPHER_TESTNET, OWS_WALLET and OWS_PASSPHRASE through the environment.", env!("CARGO_PKG_VERSION"));
            return Ok(());
        }
        _ => anyhow::bail!("Unsupported arguments. Use --help for usage."),
    }
    tracing_subscriber::fmt()
        .with_writer(std::io::stderr)
        .with_max_level(tracing::Level::INFO)
        .with_target(false)
        .init();

    // Process hardening: disable core dumps, block ptrace (prevents memory scraping)
    let hardening = ows_signer::process_hardening::harden_process();
    if hardening.core_dumps_disabled {
        tracing::info!("Process hardened: core dumps disabled");
    }
    if hardening.ptrace_disabled {
        tracing::info!("Process hardened: ptrace blocked");
    }

    let testnet = std::env::var("ZIPHER_TESTNET").unwrap_or_default() == "1";
    let network = if testnet { Network::TestNetwork } else { Network::MainNetwork };
    let default_server = if testnet { DEFAULT_TESTNET_SERVER } else { DEFAULT_MAINNET_SERVER };
    let server_url = std::env::var("ZIPHER_SERVER").unwrap_or_else(|_| default_server.to_string());

    let net_suffix = if testnet { "testnet" } else { "mainnet" };
    let data_dir = std::env::var("ZIPHER_DATA_DIR").unwrap_or_else(|_| {
        let home = dirs::home_dir().expect("Cannot determine home directory");
        home.join(".zipher").join(net_suffix).to_string_lossy().to_string()
    });

    std::fs::create_dir_all(&data_dir)?;

    // Seed resolution priority: OWS vault only.
    let (seed, seed_source) = resolve_seed(&data_dir);

    tracing::info!("Seed source: {}", seed_source.label());

    let db_path = std::path::PathBuf::from(&data_dir).join("zipher-data.sqlite");
    if db_path.exists() {
        tracing::info!("Opening wallet from {}", data_dir);
        zipher_engine::wallet::open(&data_dir, &server_url, network, None).await?;

        tracing::info!("Starting background sync");
        zipher_engine::sync::start().await?;
    } else {
        tracing::warn!("No wallet found in {}. Read-only tools will return errors. Create a wallet first.", data_dir);
    }

    let server = ZipherMcpServer {
        data_dir: data_dir.clone(),
        seed: Arc::new(RwLock::new(seed)),
        locked: Arc::new(std::sync::atomic::AtomicBool::new(false)),
        network,
        seed_source: Arc::new(seed_source),
        reviewed_send: Arc::new(tokio::sync::Mutex::new(None)),
    };

    tracing::info!("Zipher MCP server starting on stdio (data_dir={})", data_dir);

    let transport = rmcp::transport::io::stdio();
    let server_handle = server.serve(transport).await?;
    server_handle.waiting().await?;

    zipher_engine::sync::stop().await;
    zipher_engine::wallet::close().await;

    tracing::info!("Zipher MCP server shut down");
    Ok(())
}

/// Resolve the seed phrase from the OWS encrypted vault (`~/.ows/wallets/`).
fn resolve_seed(_data_dir: &str) -> (Option<SecretString>, SeedSource) {
    let ows_wallet = std::env::var("OWS_WALLET").unwrap_or_else(|_| "default".to_string());
    let ows_passphrase = std::env::var("OWS_PASSPHRASE").unwrap_or_default();
    if let Ok(exported) = ows_lib::export_wallet(&ows_wallet, Some(&ows_passphrase), None) {
        if exported.contains(' ') && !exported.starts_with('{') {
            tracing::info!("Seed loaded from OWS vault (wallet: {})", ows_wallet);
            let source = SeedSource::OwsVault;
            return (Some(SecretString::new(exported)), source);
        }
    }

    tracing::warn!(
        "No OWS mnemonic wallet available. Signing tools will fail. \
         Run `zipher-cli wallet init`, or set OWS_WALLET / OWS_PASSPHRASE."
    );
    (None, SeedSource::None)
}

#[cfg(test)]
mod security_tests {
    use super::*;
    #[tokio::test]
    async fn replaced_proposal_cannot_be_confirmed_or_consumed() {
        let dir = std::env::temp_dir().join(format!("zipher-mcp-test-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        let server = ZipherMcpServer {
            data_dir: dir.to_str().unwrap().to_string(),
            seed: Arc::new(RwLock::new(Some(SecretString::new("dummy-test-secret".into())))),
            locked: Arc::new(std::sync::atomic::AtomicBool::new(false)),
            network: Network::MainNetwork,
            seed_source: Arc::new(SeedSource::None),
            reviewed_send: Arc::new(tokio::sync::Mutex::new(Some(ReviewedSend {
                id: "proposal-b".into(), address: "b".into(), amount: 10, fee: 1, context_id: None,
            }))),
        };
        let result = server.confirm_send(Parameters(ConfirmSendParams {
            proposal_id: "proposal-a".into(), context_id: None,
        })).await;
        assert!(result.contains(INVALID_PROPOSAL));
        assert_eq!(server.reviewed_send.lock().await.as_ref().unwrap().id, "proposal-b");
        server.wallet_lock().await;
        assert!(server.seed.read().await.is_none());
        assert!(server.reviewed_send.lock().await.is_none());
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn agent_cannot_invoke_operator_or_unbounded_signing_tools() {
        let tools = ZipherMcpServer::tool_router().list_all();
        for name in ["wallet_unlock", "approve_send", "polymarket_bet"] {
            assert!(!tools.iter().any(|t| t.name == name), "unsafe tool exposed: {name}");
        }
        assert!(serde_json::from_str::<ConfirmSendParams>(r#"{"context_id":null}"#).is_err());
    }
}
