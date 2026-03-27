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
// Deterministic error codes (PRD Section 7)
// ---------------------------------------------------------------------------

const SUCCESS: &str = "SUCCESS";
const INSUFFICIENT_FUNDS: &str = "INSUFFICIENT_FUNDS";
const SYNC_REQUIRED: &str = "SYNC_REQUIRED";
const POLICY_EXCEEDED: &str = "POLICY_EXCEEDED";
const ADDRESS_NOT_ALLOWED: &str = "ADDRESS_NOT_ALLOWED";
const WALLET_LOCKED: &str = "WALLET_LOCKED";
const NETWORK_TIMEOUT: &str = "NETWORK_TIMEOUT";
const INVALID_PROPOSAL: &str = "INVALID_PROPOSAL";
const CONTEXT_REQUIRED: &str = "CONTEXT_REQUIRED";
const INTERNAL_ERROR: &str = "INTERNAL_ERROR";

fn classify_error(e: &anyhow::Error) -> &'static str {
    let msg = format!("{:#}", e);
    if msg.contains("POLICY_EXCEEDED") || msg.contains("APPROVAL_REQUIRED") || msg.contains("RATE_LIMITED") {
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

// ---------------------------------------------------------------------------
// MCP Server state
// ---------------------------------------------------------------------------

#[derive(Clone)]
struct ZipherMcpServer {
    data_dir: String,
    seed: Arc<RwLock<Option<SecretString>>>,
    locked: Arc<std::sync::atomic::AtomicBool>,
    network: Network,
    tool_router: rmcp::handler::server::tool::ToolRouter<Self>,
}

// ---------------------------------------------------------------------------
// Tool implementations
// ---------------------------------------------------------------------------

#[tool_router]
impl ZipherMcpServer {
    #[tool(description = "Get wallet status: sync height, balance, primary address, and policy summary")]
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
        })
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
                return err_code_response(WALLET_LOCKED, "No seed available. Set ZIPHER_SEED before starting the server.");
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
            Err(e) => return err_code_response(INVALID_PROPOSAL, &format!("{e}")),
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

    #[tool(description = "Pay an HTTP 402 paywall. Pass the full 402 response body. Returns txid and a PAYMENT-SIGNATURE header value to include when retrying the original request.")]
    async fn pay_x402(&self, Parameters(params): Parameters<PayX402Params>) -> String {
        if self.locked.load(std::sync::atomic::Ordering::SeqCst) {
            return err_code_response(WALLET_LOCKED, "Wallet is locked. Ask the operator to unlock.");
        }

        let seed_guard = self.seed.read().await;
        let seed_str = match seed_guard.as_ref() {
            Some(s) => s.clone(),
            None => {
                return err_code_response(WALLET_LOCKED, "No seed available. Set ZIPHER_SEED before starting the server.");
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
        ServerInfo::default()
            .with_instructions(
                "Zipher: headless Zcash light wallet for AI agents. \
                 Use pay_url to access any paid API — it auto-detects x402 or MPP protocol, \
                 pays, and returns the API response in one call. \
                 Use swap_execute to convert ZEC to other assets (USDC, ETH, etc.) via Near Intents. \
                 For manual two-step payments, use propose_send then confirm_send. \
                 Seed is held in server memory — never pass it as a tool argument."
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

    let seed = std::env::var("ZIPHER_SEED").ok().and_then(|s| {
        if s.is_empty() { None } else { Some(SecretString::new(s)) }
    });

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
