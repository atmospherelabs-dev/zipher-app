use std::sync::Arc;

use anyhow::Result;
use rmcp::handler::server::wrapper::Parameters;
use rmcp::model::ServerInfo;
use rmcp::schemars;
use rmcp::{tool, tool_handler, tool_router, ServerHandler, ServiceExt};
use secrecy::SecretString;
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use tokio::sync::RwLock;
use zcash_protocol::consensus::Network;

// ---------------------------------------------------------------------------
// Seed source tracking — used to re-decrypt on unlock
// ---------------------------------------------------------------------------

#[derive(Clone)]
enum SeedSource {
    ZipherVault { data_dir: String, passphrase: String },
    OwsVault { wallet_name: String, passphrase: String },
    EnvVar(SecretString),
    None,
}

impl SeedSource {
    fn label(&self) -> &'static str {
        match self {
            SeedSource::ZipherVault { .. } => "zipher-vault",
            SeedSource::OwsVault { .. } => "ows-vault",
            SeedSource::EnvVar(_) => "env-var",
            SeedSource::None => "none",
        }
    }

    fn decrypt(&self) -> Option<SecretString> {
        match self {
            SeedSource::ZipherVault { data_dir, passphrase } => {
                zipher_engine::wallet::decrypt_vault(data_dir, passphrase).ok()
            }
            SeedSource::OwsVault { wallet_name, passphrase } => {
                let exported = ows_lib::export_wallet(wallet_name, Some(passphrase), None).ok()?;
                if exported.contains(' ') && !exported.starts_with('{') {
                    Some(SecretString::new(exported))
                } else {
                    None
                }
            }
            SeedSource::EnvVar(s) => Some(s.clone()),
            SeedSource::None => None,
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

fn err_with_data<T: Serialize>(code: &str, message: &str, data: T) -> String {
    serde_json::to_string_pretty(&ToolResponse {
        error_code: code.to_string(),
        message: Some(message.to_string()),
        data: Some(data),
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
struct ApproveSendParams {
    /// The approval ID returned by propose_send when APPROVAL_REQUIRED
    approval_id: String,
    /// Context identifier for audit trail
    context_id: Option<String>,
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
struct MarketScanParams {
    /// Optional keyword to filter markets (e.g. "bitcoin", "election", "AI")
    keyword: Option<String>,
    /// Maximum number of markets to return (default 30)
    limit: Option<u32>,
}

#[derive(Deserialize, JsonSchema)]
struct MarketResearchParams {
    /// Search query — typically the market title or topic (e.g. "Bitcoin price above 100k by July 2026")
    query: String,
    /// Number of web results to fetch (default 5, max 10)
    limit: Option<usize>,
}

#[derive(Deserialize, JsonSchema)]
struct MarketAnalyzeParams {
    /// Market ID to analyze
    market_id: u64,
    /// Which outcome index the agent believes is underpriced (0, 1, ...)
    outcome_index: usize,
    /// Agent's estimated probability for that outcome (0.0 to 1.0).
    /// This is the LLM's judgment after reading market data + research.
    estimated_prob: f64,
    /// How confident the agent is in its probability estimate (0.0 = very uncertain, 1.0 = very confident).
    /// Controls fractional Kelly: 0.0 → quarter Kelly, 1.0 → half Kelly.
    confidence: f64,
    /// Total available bankroll in USDT (used for Kelly position sizing)
    bankroll_usdt: f64,
    /// Maximum bet amount in USDT (hard risk cap)
    max_bet_usdt: Option<f64>,
}

#[derive(Deserialize, JsonSchema)]
struct MarketQuoteParams {
    /// Market ID on Myriad
    market_id: u64,
    /// Outcome index (0, 1, ...)
    outcome: u64,
    /// Amount in USDT to bet
    amount_usdt: f64,
    /// Slippage tolerance (0.0-1.0, default 0.01 = 1%)
    slippage: Option<f64>,
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

// ---------------------------------------------------------------------------
// MCP Server state
// ---------------------------------------------------------------------------

#[derive(Clone)]
struct ZipherMcpServer {
    data_dir: String,
    seed: Arc<RwLock<Option<SecretString>>>,
    locked: Arc<std::sync::atomic::AtomicBool>,
    network: Network,
    seed_source: Arc<SeedSource>,
    tool_router: rmcp::handler::server::tool::ToolRouter<Self>,
}

// ---------------------------------------------------------------------------
// Tool implementations
// ---------------------------------------------------------------------------

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
        let policy = zipher_engine::policy::load_policy(&self.data_dir);

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

    #[tool(description = "Unlock the wallet — re-decrypts the seed from its vault. Only the operator should call this.")]
    async fn wallet_unlock(&self) -> String {
        if !self.locked.load(std::sync::atomic::Ordering::SeqCst) {
            return err_code_response(SUCCESS, "Wallet is already unlocked.");
        }

        match self.seed_source.decrypt() {
            Some(seed) => {
                {
                    let mut seed_guard = self.seed.write().await;
                    *seed_guard = Some(seed);
                }
                self.locked.store(false, std::sync::atomic::Ordering::SeqCst);
                tracing::info!("Wallet unlocked — seed restored from {}", self.seed_source.label());
                ok_response(serde_json::json!({ "locked": false, "source": self.seed_source.label() }))
            }
            None => {
                err_code_response(
                    INTERNAL_ERROR,
                    "Failed to re-decrypt seed from vault. Check vault passphrase.",
                )
            }
        }
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
        let policy = zipher_engine::policy::load_policy(&self.data_dir);
        let daily_spent = zipher_engine::audit::daily_spent(&self.data_dir).unwrap_or(0);

        if let Err(violation) = zipher_engine::policy::check_proposal(
            &policy, &params.address, params.amount, &params.context_id, daily_spent,
        ) {
            // Approval threshold triggers HITL flow instead of hard deny
            if let zipher_engine::policy::PolicyViolation::ApprovalRequired { amount, threshold } = &violation {
                let approval_id = zipher_engine::policy::store_pending_approval(
                    &params.address,
                    params.amount,
                    params.memo.clone(),
                    params.context_id.clone(),
                );
                zipher_engine::audit::log_event(
                    &self.data_dir, "propose_send", Some(&params.address),
                    Some(params.amount), None, params.context_id.as_deref(),
                    None, Some(&format!("APPROVAL_REQUIRED: stored as {}", approval_id)),
                ).ok();

                #[derive(Serialize)]
                struct ApprovalInfo {
                    approval_id: String,
                    address: String,
                    amount: u64,
                    amount_zec: f64,
                    threshold: u64,
                    expires_in_secs: u64,
                }

                return err_with_data(
                    APPROVAL_REQUIRED,
                    &format!(
                        "Amount {} exceeds approval threshold {}. \
                         Operator must call approve_send with approval_id to proceed.",
                        amount, threshold,
                    ),
                    ApprovalInfo {
                        approval_id,
                        address: params.address,
                        amount: *amount,
                        amount_zec: *amount as f64 / 1e8,
                        threshold: *threshold,
                        expires_in_secs: 300,
                    },
                );
            }

            zipher_engine::audit::log_event(
                &self.data_dir, "propose_send", Some(&params.address),
                Some(params.amount), None, params.context_id.as_deref(),
                None, Some(&violation.to_string()),
            ).ok();
            let code = match &violation {
                zipher_engine::policy::PolicyViolation::AddressNotAllowed { .. } => ADDRESS_NOT_ALLOWED,
                zipher_engine::policy::PolicyViolation::ContextRequired => CONTEXT_REQUIRED,
                _ => POLICY_EXCEEDED,
            };
            return err_code_response(code, &violation.to_string());
        }

        match zipher_engine::send::propose_send(&params.address, params.amount, params.memo, false).await {
            Ok((send_amount, fee, _)) => {
                zipher_engine::audit::log_event(
                    &self.data_dir, "propose_send", Some(&params.address),
                    Some(send_amount), Some(fee), params.context_id.as_deref(),
                    None, None,
                ).ok();

                #[derive(Serialize)]
                struct ProposalResult {
                    address: String,
                    send_amount: u64,
                    fee: u64,
                    total: u64,
                    send_amount_zec: f64,
                    fee_zec: f64,
                }

                ok_response(ProposalResult {
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
        if self.locked.load(std::sync::atomic::Ordering::SeqCst) {
            return err_code_response(WALLET_LOCKED, "Wallet is locked. Ask the operator to unlock.");
        }

        let seed_guard = self.seed.read().await;
        let seed_str = match seed_guard.as_ref() {
            Some(s) => s.clone(),
            None => {
                return err_code_response(WALLET_LOCKED, "No seed available. Run `zipher wallet init` to create an encrypted vault, or unlock with wallet_unlock.");
            }
        };
        drop(seed_guard);

        let policy = zipher_engine::policy::load_policy(&self.data_dir);
        if let Err(violation) = zipher_engine::policy::check_rate_limit(&policy) {
            zipher_engine::audit::log_event(
                &self.data_dir, "confirm_send", None,
                None, None, params.context_id.as_deref(),
                None, Some(&violation.to_string()),
            ).ok();
            return err_code_response(POLICY_EXCEEDED, &violation.to_string());
        }

        match zipher_engine::send::confirm_send(&seed_str).await {
            Ok(txid) => {
                zipher_engine::policy::record_confirm();
                zipher_engine::audit::log_event(
                    &self.data_dir, "confirm_send", None,
                    None, None, params.context_id.as_deref(),
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

    #[tool(description = "Approve a pending send that exceeded the approval threshold (operator-only). Takes the approval_id from the APPROVAL_REQUIRED response, creates the proposal, signs, and broadcasts.")]
    async fn approve_send(&self, Parameters(params): Parameters<ApproveSendParams>) -> String {
        if self.locked.load(std::sync::atomic::Ordering::SeqCst) {
            return err_code_response(WALLET_LOCKED, "Wallet is locked. Ask the operator to unlock.");
        }

        let seed_guard = self.seed.read().await;
        let seed_str = match seed_guard.as_ref() {
            Some(s) => s.clone(),
            None => {
                return err_code_response(WALLET_LOCKED, "No seed available. Run `zipher wallet init` to create an encrypted vault, or unlock with wallet_unlock.");
            }
        };
        drop(seed_guard);

        let pending = match zipher_engine::policy::take_pending_approval(&params.approval_id) {
            Some(p) => p,
            None => {
                return err_code_response(
                    INVALID_PROPOSAL,
                    "No pending approval with that ID, or it has expired (5 min TTL).",
                );
            }
        };

        let context_id = params.context_id.or(pending.context_id);

        match zipher_engine::send::propose_send(
            &pending.address, pending.amount, pending.memo, false,
        ).await {
            Ok((send_amount, fee, _)) => {
                match zipher_engine::send::confirm_send(&seed_str).await {
                    Ok(txid) => {
                        zipher_engine::policy::record_confirm();
                        zipher_engine::audit::log_event(
                            &self.data_dir, "approve_send", Some(&pending.address),
                            Some(send_amount), Some(fee), context_id.as_deref(),
                            Some(&txid), None,
                        ).ok();

                        #[derive(Serialize)]
                        struct ApprovedResult {
                            txid: String,
                            address: String,
                            send_amount: u64,
                            fee: u64,
                            send_amount_zec: f64,
                            approval_id: String,
                        }

                        ok_response(ApprovedResult {
                            txid,
                            address: pending.address,
                            send_amount,
                            fee,
                            send_amount_zec: send_amount as f64 / 1e8,
                            approval_id: params.approval_id,
                        })
                    }
                    Err(e) => {
                        zipher_engine::audit::log_event(
                            &self.data_dir, "approve_send", Some(&pending.address),
                            Some(send_amount), Some(fee), context_id.as_deref(),
                            None, Some(&format!("{:#}", e)),
                        ).ok();
                        err_response(&e)
                    }
                }
            }
            Err(e) => {
                zipher_engine::audit::log_event(
                    &self.data_dir, "approve_send", Some(&pending.address),
                    Some(pending.amount), None, context_id.as_deref(),
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
        if self.locked.load(std::sync::atomic::Ordering::SeqCst) {
            return err_code_response(WALLET_LOCKED, "Wallet is locked.");
        }

        let seed_guard = self.seed.read().await;
        let seed_str = match seed_guard.as_ref() {
            Some(s) => s.clone(),
            None => {
                return err_code_response(WALLET_LOCKED, "No seed available.");
            }
        };
        drop(seed_guard);

        match zipher_engine::send::shield_funds(&seed_str).await {
            Ok(txid) => {
                zipher_engine::audit::log_event(
                    &self.data_dir, "shield_funds", None,
                    None, None, None, Some(&txid), None,
                ).ok();

                #[derive(Serialize)]
                struct ShieldResult { txid: String }
                ok_response(ShieldResult { txid })
            }
            Err(e) => err_response(&e),
        }
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

        let policy = zipher_engine::policy::load_policy(&self.data_dir);
        let daily_spent = zipher_engine::audit::daily_spent(&self.data_dir).unwrap_or(0);
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
            &quote.deposit_address, params.amount, None, false,
        ).await {
            Ok(r) => r,
            Err(e) => return err_response(&e),
        };

        let txid = match zipher_engine::send::confirm_send(&seed_str).await {
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
        let policy = zipher_engine::policy::load_policy(&self.data_dir);
        let daily_spent = zipher_engine::audit::daily_spent(&self.data_dir).unwrap_or(0);
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
            &params.pay_to, params.deposit, Some(memo), false,
        ).await {
            Ok(r) => r,
            Err(e) => return err_response(&e),
        };

        let txid = match zipher_engine::send::confirm_send(&seed_str).await {
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

        let policy = zipher_engine::policy::load_policy(&self.data_dir);
        let daily_spent = zipher_engine::audit::daily_spent(&self.data_dir).unwrap_or(0);
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

        let (send_amount, fee, _) = match zipher_engine::send::propose_send(&address, amount, None, false).await {
            Ok(r) => r,
            Err(e) => return err_response(&e),
        };

        let txid = match zipher_engine::send::confirm_send(&seed_str).await {
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

    #[tool(description = "Scan prediction markets on Myriad (BNB Chain). Returns open markets ranked by uncertainty — the most contested markets are where information edge is most valuable. Use market_research to gather news, then market_analyze to size a bet.")]
    async fn market_scan(&self, Parameters(params): Parameters<MarketScanParams>) -> String {
        match zipher_engine::myriad::get_markets(
            params.keyword.as_deref(),
            params.limit.unwrap_or(30),
        ).await {
            Ok(markets) => {
                let scanned = zipher_engine::myriad::rank_for_research(&markets);
                let items: Vec<_> = scanned.iter().map(|s| {
                    serde_json::json!({
                        "id": s.market.id,
                        "title": s.market.title,
                        "uncertainty": format!("{:.0}%", s.uncertainty * 100.0),
                        "book_sum": s.book_sum,
                        "outcomes": s.market.outcomes.iter().enumerate().map(|(i, o)| serde_json::json!({
                            "index": i,
                            "title": o.title,
                            "price": o.price,
                            "implied_prob": s.implied_probs.get(i).copied().unwrap_or(0.0),
                        })).collect::<Vec<_>>(),
                    })
                }).collect();
                ok_response(serde_json::json!({
                    "total_fetched": markets.len(),
                    "researchable": items.len(),
                    "markets": items,
                    "next_step": "Pick a market, call market_research with its title, then estimate a probability and call market_analyze.",
                }))
            }
            Err(e) => err_response(&e),
        }
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
                "next_step": "Read the research, form a probability estimate (0.0-1.0) for the outcome you think is underpriced, then call market_analyze with your estimate.",
            })),
            Err(e) => err_response(&e),
        }
    }

    #[tool(description = "Analyze a prediction market bet using Kelly Criterion. Pass your probability estimate (from research) and get a mathematically optimal bet size. Uses fractional Kelly (quarter to half Kelly) to prevent overbetting. This is the agent's decision engine.")]
    async fn market_analyze(&self, Parameters(params): Parameters<MarketAnalyzeParams>) -> String {
        let market = match zipher_engine::myriad::get_market(params.market_id).await {
            Ok(m) => m,
            Err(e) => return err_response(&e),
        };

        let max_bet = params.max_bet_usdt.unwrap_or(10.0);

        match zipher_engine::myriad::analyze_opportunity(
            &market,
            params.outcome_index,
            params.estimated_prob,
            params.confidence,
            params.bankroll_usdt,
            max_bet,
        ) {
            Some(signal) => ok_response(serde_json::json!({
                "action": "trade",
                "market_id": signal.market_id,
                "market_title": signal.market_title,
                "outcome_index": signal.outcome_index,
                "outcome_title": signal.outcome_title,
                "market_prob": signal.market_prob,
                "estimated_prob": signal.estimated_prob,
                "edge": format!("{:.1}%", signal.edge * 100.0),
                "expected_value": format!("${:.3} per $1", signal.expected_value),
                "kelly_fraction": format!("{:.1}%", signal.kelly_fraction * 100.0),
                "recommended_bet_usdt": signal.recommended_bet_usdt,
                "confidence": signal.confidence,
                "reason": signal.reason,
                "next_step": format!(
                    "To execute: call market_quote with market_id={}, outcome={}, amount_usdt={:.2}. Then use swap_execute for ZEC→USDT funding.",
                    signal.market_id, signal.outcome_index, signal.recommended_bet_usdt
                ),
            })),
            None => ok_response(serde_json::json!({
                "action": "no_trade",
                "market_id": params.market_id,
                "reason": "No positive edge. Your estimated probability is at or below the market price — no bet recommended.",
            })),
        }
    }

    #[tool(description = "Get a trade quote for a prediction market bet. Returns shares, price, and calldata. Use with swap_execute to fund the trade with ZEC.")]
    async fn market_quote(&self, Parameters(params): Parameters<MarketQuoteParams>) -> String {
        let slippage = params.slippage.unwrap_or(0.01);
        match zipher_engine::myriad::get_quote(
            params.market_id,
            params.outcome,
            "buy",
            params.amount_usdt,
            slippage,
        ).await {
            Ok(quote) => ok_response(serde_json::json!({
                "market_id": params.market_id,
                "outcome": params.outcome,
                "amount_usdt": params.amount_usdt,
                "shares": quote.shares,
                "price": quote.price,
                "price_per_share": if quote.shares > 0.0 { params.amount_usdt / quote.shares } else { 0.0 },
                "calldata": quote.calldata,
                "slippage": slippage,
                "next_step": "To execute: 1) swap_execute ZEC→USDT on BSC, 2) approve USDT for Myriad contract, 3) send calldata to Myriad PM contract. Use zipher-cli 'market bet' for the full automated flow.",
            })),
            Err(e) => err_response(&e),
        }
    }

    #[tool(description = "Pay an HTTP 402 paywall. Pass the full 402 response body. Returns txid and a PAYMENT-SIGNATURE header value to include when retrying the original request.")]
    async fn pay_x402(&self, Parameters(params): Parameters<PayX402Params>) -> String {
        if self.locked.load(std::sync::atomic::Ordering::SeqCst) {
            return err_code_response(WALLET_LOCKED, "Wallet is locked. Ask the operator to unlock.");
        }

        let seed_guard = self.seed.read().await;
        let seed_str = match seed_guard.as_ref() {
            Some(s) => s.clone(),
            None => {
                return err_code_response(WALLET_LOCKED, "No seed available. Run `zipher wallet init` to create an encrypted vault, or unlock with wallet_unlock.");
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

        let policy = zipher_engine::policy::load_policy(&self.data_dir);
        let daily_spent = zipher_engine::audit::daily_spent(&self.data_dir).unwrap_or(0);

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

        let (send_amount, fee, _) = match zipher_engine::send::propose_send(&address, amount, None, false).await {
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

        match zipher_engine::send::confirm_send(&seed_str).await {
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
                 The operator can lock/unlock the wallet remotely via wallet_lock/wallet_unlock. \
                 Paid APIs: pay_url auto-detects x402/MPP, pays, returns response. \
                 Cross-chain: swap_execute converts ZEC to any asset via Near Intents. \
                 Prediction markets: market_scan → market_research → market_analyze → market_quote → swap_execute."
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
const DEFAULT_TESTNET_SERVER: &str = "https://lightwalletd.testnet.cipherscan.app:443";

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

#[tokio::main]
async fn main() -> Result<()> {
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

    // Seed resolution priority: OWS vault → Zipher vault (legacy) → ZIPHER_SEED env (deprecated)
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
        tool_router: ZipherMcpServer::tool_router(),
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

/// Resolve the seed phrase from the best available source.
///
/// Priority:
/// 1. OWS encrypted vault (`~/.ows/wallets/`) — default for new installs
/// 2. Zipher vault (`~/.zipher/<net>/vault.enc`) — legacy, still supported
/// 3. `ZIPHER_SEED` env var — deprecated, cleared after read
fn resolve_seed(data_dir: &str) -> (Option<SecretString>, SeedSource) {
    // 1. OWS vault (primary — multi-chain ready)
    let ows_wallet = std::env::var("OWS_WALLET").unwrap_or_else(|_| "default".to_string());
    let ows_passphrase = std::env::var("OWS_PASSPHRASE").unwrap_or_default();
    if let Ok(exported) = ows_lib::export_wallet(&ows_wallet, Some(&ows_passphrase), None) {
        if exported.contains(' ') && !exported.starts_with('{') {
            tracing::info!("Seed loaded from OWS vault (wallet: {})", ows_wallet);
            let source = SeedSource::OwsVault {
                wallet_name: ows_wallet,
                passphrase: ows_passphrase,
            };
            return (Some(SecretString::new(exported)), source);
        }
    }

    // 2. Zipher vault (legacy fallback)
    if zipher_engine::vault::Vault::exists(data_dir) {
        let passphrase = std::env::var("ZIPHER_VAULT_PASS").unwrap_or_default();
        match zipher_engine::wallet::decrypt_vault(data_dir, &passphrase) {
            Ok(seed) => {
                tracing::info!("Seed loaded from zipher vault (legacy)");
                let source = SeedSource::ZipherVault {
                    data_dir: data_dir.to_string(),
                    passphrase,
                };
                return (Some(seed), source);
            }
            Err(e) => {
                tracing::warn!("Zipher vault exists but decryption failed: {}", e);
            }
        }
    }

    // 3. ZIPHER_SEED env var (deprecated)
    if let Ok(seed_val) = std::env::var("ZIPHER_SEED") {
        if !seed_val.is_empty() {
            tracing::warn!(
                "Using ZIPHER_SEED env var (DEPRECATED). \
                 Migrate to `zipher wallet init` for encrypted vault storage."
            );
            let secret = SecretString::new(seed_val);
            let source = SeedSource::EnvVar(secret.clone());
            ows_signer::process_hardening::clear_env_var("ZIPHER_SEED");
            return (Some(secret), source);
        }
    }

    tracing::warn!("No seed available. Signing tools will fail. Run `zipher wallet init` to create a vault.");
    (None, SeedSource::None)
}
