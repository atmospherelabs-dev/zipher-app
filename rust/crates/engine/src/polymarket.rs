//! Polymarket integration — Gamma market discovery, EIP-712 order signing, CLOB auth.
//!
//! CLOB HTTP calls and HMAC auth are handled on the Dart side. This module provides
//! cryptographic operations that require access to the private key, plus a small
//! Gamma API client for CLI discovery and quality filtering.

use anyhow::Result;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use tracing::info;

use ows_signer::chains::evm::EvmSigner;
use ows_signer::curve::Curve;
use ows_signer::hd::HdDeriver;
use ows_signer::mnemonic::Mnemonic;
use ows_signer::traits::ChainSigner;

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

pub const POLYGON_CHAIN_ID: u64 = 137;

/// Polymarket CTF Exchange contract on Polygon.
pub const CTF_EXCHANGE: &str = "0x4bFb41d5B3570DeFd03C39a9A4D8dE6Bd8B8982E";

/// Polymarket Neg Risk CTF Exchange (for multi-outcome markets).
pub const NEG_RISK_CTF_EXCHANGE: &str = "0xC5d563A36AE78145C45a50134d48A1215220f80a";

/// USDC.e on Polygon (Polymarket's collateral token).
pub const USDC_POLYGON: &str = "0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174";

/// Polygon RPC endpoint.
pub const POLYGON_RPC: &str = "https://polygon-rpc.com/";

/// Polymarket Gamma REST API (public market metadata).
pub const GAMMA_API: &str = "https://gamma-api.polymarket.com";

/// Polymarket Data API (public positions, activity, etc.).
pub const DATA_API: &str = "https://data-api.polymarket.com";

/// Conditional Tokens (ERC-1155) on Polygon — outcome tokens live here.
pub const CTF_CONTRACT: &str = "0x4D97DCd97eC945f40cF65F87097ACe5EA0476045";

/// Neg-risk adapter (ERC-1155) — approve this contract for neg-risk sells.
pub const NEG_RISK_ADAPTER: &str = "0xd91E80cF2E7be2e162c6513ceD06f1dD0dA35296";

// ---------------------------------------------------------------------------
// Gamma API — types and HTTP client
// ---------------------------------------------------------------------------

fn json_f64(v: &Value) -> Option<f64> {
    match v {
        Value::Number(n) => n.as_f64(),
        Value::String(s) => s.parse().ok(),
        _ => None,
    }
}

/// Percent-encode a query component (UTF-8 byte safe).
fn percent_encode_component(s: &str) -> String {
    let mut out = String::new();
    for b in s.as_bytes() {
        match *b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(*b as char);
            }
            _ => out.push_str(&format!("%{:02X}", b)),
        }
    }
    out
}

/// Parse Gamma's `outcomes` / `outcomePrices` / `clobTokenIds` (JSON array or stringified JSON).
fn parse_json_string_list(v: &Value) -> Vec<String> {
    let slice = match v {
        Value::String(s) => serde_json::from_str::<Vec<Value>>(s).unwrap_or_default(),
        Value::Array(a) => a.clone(),
        _ => return vec![],
    };
    slice
        .into_iter()
        .map(|x| match x {
            Value::String(s) => s,
            _ => x.to_string().trim_matches('"').to_string(),
        })
        .collect()
}

fn parse_json_f64_list(v: &Value) -> Vec<f64> {
    let slice = match v {
        Value::String(s) => serde_json::from_str::<Vec<Value>>(s).unwrap_or_default(),
        Value::Array(a) => a.clone(),
        _ => return vec![],
    };
    slice
        .into_iter()
        .filter_map(|x| match x {
            Value::Number(n) => n.as_f64(),
            Value::String(s) => s.parse().ok(),
            _ => None,
        })
        .collect()
}

/// One Polymarket tradable market as returned by Gamma (`/events` nested or `/markets`).
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PolymarketMarket {
    #[serde(default)]
    pub id: Option<String>,
    #[serde(default)]
    pub question: Option<String>,
    #[serde(default)]
    pub title: Option<String>,
    #[serde(default)]
    pub condition_id: Option<String>,
    #[serde(default)]
    outcomes: Value,
    #[serde(default)]
    outcome_prices: Value,
    #[serde(default)]
    clob_token_ids: Value,
    #[serde(default)]
    volume: Value,
    #[serde(default)]
    volume24hr: Value,
    #[serde(default)]
    liquidity_num: Value,
    #[serde(default)]
    best_bid: Value,
    #[serde(default)]
    best_ask: Value,
    #[serde(default)]
    spread: Value,
    #[serde(default)]
    accepting_orders: Option<bool>,
    #[serde(default)]
    neg_risk: Option<bool>,
    #[serde(default)]
    pub group_item_title: Option<String>,
    #[serde(default)]
    pub active: Option<bool>,
    #[serde(default)]
    pub closed: Option<bool>,
}

impl PolymarketMarket {
    pub fn display_title(&self) -> String {
        self.question
            .clone()
            .or_else(|| self.title.clone())
            .unwrap_or_default()
    }

    pub fn condition_id_str(&self) -> String {
        self.condition_id.clone().unwrap_or_default()
    }

    pub fn volume_f(&self) -> f64 {
        json_f64(&self.volume).unwrap_or(0.0)
    }

    pub fn volume_24hr(&self) -> f64 {
        json_f64(&self.volume24hr).unwrap_or(0.0)
    }

    pub fn liquidity_num_f(&self) -> f64 {
        json_f64(&self.liquidity_num).unwrap_or(0.0)
    }

    pub fn best_bid_f(&self) -> Option<f64> {
        json_f64(&self.best_bid)
    }

    pub fn best_ask_f(&self) -> Option<f64> {
        json_f64(&self.best_ask)
    }

    pub fn spread_f(&self) -> Option<f64> {
        json_f64(&self.spread)
    }

    pub fn accepting_orders_effective(&self) -> bool {
        self.accepting_orders.unwrap_or(false)
    }

    pub fn neg_risk_effective(&self) -> bool {
        self.neg_risk.unwrap_or(false)
    }

    pub fn outcome_labels(&self) -> Vec<String> {
        parse_json_string_list(&self.outcomes)
    }

    pub fn outcome_prices_vec(&self) -> Vec<f64> {
        parse_json_f64_list(&self.outcome_prices)
    }

    pub fn clob_token_ids_vec(&self) -> Vec<String> {
        parse_json_string_list(&self.clob_token_ids)
    }

    /// Primary "Yes" / first-outcome price for display (binary and multi-outcome sub-markets).
    pub fn primary_yes_price(&self) -> Option<f64> {
        self.outcome_prices_vec().first().copied()
    }
}

/// Event container from Gamma `/events` (holds one or many `markets`).
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PolymarketEvent {
    #[serde(default)]
    pub id: String,
    #[serde(default)]
    pub title: String,
    #[serde(default)]
    neg_risk: Option<bool>,
    #[serde(default)]
    pub markets: Vec<PolymarketMarket>,
    #[serde(default)]
    volume: Value,
    #[serde(default)]
    volume24hr: Value,
}

impl PolymarketEvent {
    pub fn neg_risk_effective(&self) -> bool {
        self.neg_risk.unwrap_or(false)
    }

    pub fn event_volume_24hr(&self) -> f64 {
        json_f64(&self.volume24hr)
            .or_else(|| json_f64(&self.volume))
            .unwrap_or(0.0)
    }
}

/// Quality gate for tradable, non-degenerate CLOB markets (`--all` disables).
///
/// Criteria: accepting orders, positive 24h volume, non-zero best bid, neither side
/// at ~0% or ~100%, spread under 10% when known.
pub fn polymarket_market_passes_quality(m: &PolymarketMarket, relaxed: bool) -> bool {
    if relaxed {
        return true;
    }
    if !m.accepting_orders_effective() {
        return false;
    }
    if m.volume_24hr() <= 0.0 {
        return false;
    }
    match m.best_bid_f() {
        Some(b) if b > 0.0 => {}
        _ => return false,
    }
    let prices = m.outcome_prices_vec();
    if prices.is_empty() {
        return false;
    }
    const EPS: f64 = 0.001;
    for p in &prices {
        if *p <= EPS || *p >= 1.0 - EPS {
            return false;
        }
    }
    if let Some(sp) = m.spread_f() {
        if sp > 0.10 {
            return false;
        }
    }
    true
}

/// One runner line for grouped events or outcome summary for a single market.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PolymarketRunnerSummary {
    pub label: String,
    /// Implied probability on the first outcome (e.g. "Yes" for team sub-markets).
    pub price: f64,
    pub volume_24hr: f64,
    pub condition_id: String,
}

/// Display row for `polymarket list` (JSON or human formatting in CLI).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PolymarketListRow {
    /// `grouped` when the event has multiple sub-markets; `single` for one market.
    pub kind: String,
    pub title: String,
    pub market_count: usize,
    pub volume_24hr: f64,
    pub neg_risk: bool,
    pub top_runners: Vec<PolymarketRunnerSummary>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PolymarketDiscoverySummary {
    pub events_fetched: usize,
    pub total_submarkets: usize,
    pub submarkets_after_filter: usize,
    pub rows: Vec<PolymarketListRow>,
}

const RUNNER_PREVIEW: usize = 5;

/// Build list rows from raw Gamma events (filtering + neg-risk style grouping).
pub fn polymarket_build_discovery_rows(events: &[PolymarketEvent], relaxed: bool) -> PolymarketDiscoverySummary {
    let mut total_submarkets = 0usize;
    let mut submarkets_after_filter = 0usize;
    let mut rows = Vec::new();

    for ev in events {
        let n = ev.markets.len();
        total_submarkets += n;

        let mut filtered: Vec<&PolymarketMarket> = ev
            .markets
            .iter()
            .filter(|m| polymarket_market_passes_quality(m, relaxed))
            .collect();
        submarkets_after_filter += filtered.len();

        if n == 0 {
            continue;
        }

        if n == 1 {
            let m = &ev.markets[0];
            if !polymarket_market_passes_quality(m, relaxed) {
                continue;
            }
            let labels = m.outcome_labels();
            let prices = m.outcome_prices_vec();
            let mut top_runners = Vec::new();
            for (i, lab) in labels.iter().enumerate() {
                let price = prices.get(i).copied().unwrap_or(0.0);
                top_runners.push(PolymarketRunnerSummary {
                    label: lab.clone(),
                    price,
                    volume_24hr: m.volume_24hr(),
                    condition_id: m.condition_id_str(),
                });
            }
            rows.push(PolymarketListRow {
                kind: "single".into(),
                title: m.display_title(),
                market_count: 1,
                volume_24hr: m.volume_24hr(),
                neg_risk: m.neg_risk_effective(),
                top_runners,
            });
            continue;
        }

        // Multiple sub-markets: show event title + top runners by 24h volume.
        filtered.sort_by(|a, b| {
            b.volume_24hr()
                .partial_cmp(&a.volume_24hr())
                .unwrap_or(std::cmp::Ordering::Equal)
        });

        let top: Vec<&PolymarketMarket> = filtered.into_iter().take(RUNNER_PREVIEW).collect();

        let top_runners: Vec<PolymarketRunnerSummary> = top
            .iter()
            .filter_map(|m| {
                let label = m
                    .group_item_title
                    .clone()
                    .filter(|s| !s.is_empty())
                    .unwrap_or_else(|| m.display_title());
                let price = m.primary_yes_price()?;
                Some(PolymarketRunnerSummary {
                    label,
                    price,
                    volume_24hr: m.volume_24hr(),
                    condition_id: m.condition_id_str(),
                })
            })
            .collect();

        if top_runners.is_empty() && !relaxed {
            continue;
        }

        rows.push(PolymarketListRow {
            kind: "grouped".into(),
            title: ev.title.clone(),
            market_count: n,
            volume_24hr: ev.event_volume_24hr(),
            neg_risk: ev.neg_risk_effective(),
            top_runners,
        });
    }

    PolymarketDiscoverySummary {
        events_fetched: events.len(),
        total_submarkets,
        submarkets_after_filter,
        rows,
    }
}

/// Fetch active events from Gamma (ordered by 24h volume).
pub async fn polymarket_gamma_get_events(
    keyword: Option<&str>,
    limit: u32,
) -> Result<Vec<PolymarketEvent>> {
    let client = reqwest::Client::new();
    let mut url = format!(
        "{}/events?active=true&closed=false&order=volume24hr&ascending=false&limit={}",
        GAMMA_API, limit
    );
        if let Some(kw) = keyword {
        if !kw.is_empty() {
            let enc = percent_encode_component(kw);
            url.push_str("&tag=");
            url.push_str(&enc);
        }
    }

    info!("Gamma GET {}", url);
    let resp = client
        .get(&url)
        .send()
        .await
        .map_err(|e| anyhow::anyhow!("Gamma API request failed: {}", e))?;

    let status = resp.status();
    let text = resp
        .text()
        .await
        .map_err(|e| anyhow::anyhow!("Gamma API body read failed: {}", e))?;

    if !status.is_success() {
        return Err(anyhow::anyhow!(
            "Gamma API returned {}: {}",
            status,
            &text[..text.len().min(200)]
        ));
    }

    let events: Vec<PolymarketEvent> = serde_json::from_str(&text)
        .map_err(|e| anyhow::anyhow!("Gamma events parse failed: {} — {}", e, &text[..text.len().min(200)]))?;

    Ok(events)
}

/// Fetch a single market by `condition_id` (uses `condition_ids` query param).
pub async fn polymarket_gamma_get_market_by_condition(condition_id: &str) -> Result<PolymarketMarket> {
    let id = condition_id.trim().trim_start_matches("0x");
    let hex_id = if condition_id.starts_with("0x") {
        condition_id.to_string()
    } else {
        format!("0x{}", id)
    };

    let client = reqwest::Client::new();
    let url = format!("{}/markets?condition_ids={}", GAMMA_API, hex_id);

    info!("Gamma GET {}", url);
    let resp = client
        .get(&url)
        .send()
        .await
        .map_err(|e| anyhow::anyhow!("Gamma API request failed: {}", e))?;

    let status = resp.status();
    let text = resp
        .text()
        .await
        .map_err(|e| anyhow::anyhow!("Gamma API body read failed: {}", e))?;

    if !status.is_success() {
        return Err(anyhow::anyhow!(
            "Gamma API returned {}: {}",
            status,
            &text[..text.len().min(200)]
        ));
    }

    let list: Vec<PolymarketMarket> = serde_json::from_str(&text).map_err(|e| {
        anyhow::anyhow!(
            "Gamma markets parse failed: {} — {}",
            e,
            &text[..text.len().min(200)]
        )
    })?;

    list.into_iter()
        .next()
        .ok_or_else(|| anyhow::anyhow!("No market found for condition_id {}", hex_id))
}

/// Convenience: fetch events and build discovery summary.
pub async fn polymarket_discover(
    keyword: Option<&str>,
    limit: u32,
    relaxed: bool,
) -> Result<PolymarketDiscoverySummary> {
    let events = polymarket_gamma_get_events(keyword, limit).await?;
    Ok(polymarket_build_discovery_rows(&events, relaxed))
}

// ---------------------------------------------------------------------------
// Data API — user positions (read-only, no auth)
// ---------------------------------------------------------------------------

/// Open position row from Polymarket Data API `GET /positions`.
///
/// Schema: [Get current positions](https://docs.polymarket.com/api-reference/core/get-current-positions-for-a-user)
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PolymarketPosition {
    #[serde(default)]
    pub proxy_wallet: Option<String>,
    #[serde(default)]
    pub asset: String,
    #[serde(default)]
    pub condition_id: String,
    #[serde(default)]
    pub size: f64,
    #[serde(default)]
    pub avg_price: f64,
    #[serde(default)]
    pub initial_value: f64,
    #[serde(default)]
    pub current_value: f64,
    #[serde(default)]
    pub cash_pnl: f64,
    #[serde(default)]
    pub percent_pnl: f64,
    #[serde(default)]
    pub cur_price: f64,
    #[serde(default)]
    pub title: Option<String>,
    #[serde(default)]
    pub outcome: Option<String>,
    #[serde(default)]
    pub outcome_index: Option<i32>,
    #[serde(default)]
    pub negative_risk: Option<bool>,
    #[serde(default)]
    pub redeemable: Option<bool>,
    #[serde(default)]
    pub slug: Option<String>,
    #[serde(default)]
    pub event_slug: Option<String>,
}

/// Fetch open positions for a wallet (`user` = 0x + 40 hex).
pub async fn polymarket_get_positions(user_address: &str) -> Result<Vec<PolymarketPosition>> {
    let addr = user_address.trim();
    if !addr.starts_with("0x") || addr.len() != 42 {
        anyhow::bail!("user address must be 0x-prefixed 40 hex characters");
    }
    let client = reqwest::Client::new();
    let url = format!(
        "{}/positions?user={}&sizeThreshold=0&limit=500&sortBy=TOKENS&sortDirection=DESC",
        DATA_API, addr
    );
    info!("Data API GET {}", url);
    let resp = client
        .get(&url)
        .send()
        .await
        .map_err(|e| anyhow::anyhow!("Data API request failed: {}", e))?;
    let status = resp.status();
    let text = resp
        .text()
        .await
        .map_err(|e| anyhow::anyhow!("Data API body read failed: {}", e))?;
    if !status.is_success() {
        anyhow::bail!(
            "Data API returned {}: {}",
            status,
            &text[..text.len().min(200)]
        );
    }
    let positions: Vec<PolymarketPosition> = serde_json::from_str(&text).map_err(|e| {
        anyhow::anyhow!(
            "Data API positions parse failed: {} — {}",
            e,
            &text[..text.len().min(200)]
        )
    })?;
    Ok(positions)
}

// ---------------------------------------------------------------------------
// Order signing types
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PolymarketOrder {
    pub salt: String,
    pub maker: String,
    pub signer: String,
    pub taker: String,
    pub token_id: String,
    pub maker_amount: String,
    pub taker_amount: String,
    pub expiration: String,
    pub nonce: String,
    pub fee_rate_bps: String,
    pub side: u8,
    pub signature_type: u8,
}

// ---------------------------------------------------------------------------
// Key derivation
// ---------------------------------------------------------------------------

fn derive_evm_privkey(seed_phrase: &str) -> Result<Vec<u8>> {
    let mnemonic = Mnemonic::from_phrase(seed_phrase)
        .map_err(|e| anyhow::anyhow!("Invalid seed phrase: {}", e))?;

    let path = EvmSigner.default_derivation_path(0);
    let secret_key = HdDeriver::derive_from_mnemonic(&mnemonic, "", &path, Curve::Secp256k1)
        .map_err(|e| anyhow::anyhow!("HD derivation failed: {}", e))?;

    Ok(secret_key.expose().to_vec())
}

/// Derive the Polygon address from a seed phrase (same as EVM address).
pub fn derive_address(seed_phrase: &str) -> Result<String> {
    let privkey = derive_evm_privkey(seed_phrase)?;
    EvmSigner
        .derive_address(&privkey)
        .map_err(|e| anyhow::anyhow!("Address derivation failed: {}", e))
}

// ---------------------------------------------------------------------------
// L1 Auth — Derive API credentials via EIP-712 signature
// ---------------------------------------------------------------------------

/// Sign a CLOB L1 auth message and return (address, signature_hex).
/// The caller POSTs the signature to `/auth/derive-api-key` to get API credentials.
pub fn sign_clob_auth(seed_phrase: &str, timestamp: u64, nonce: u64) -> Result<(String, String)> {
    let privkey = derive_evm_privkey(seed_phrase)?;
    let address = EvmSigner
        .derive_address(&privkey)
        .map_err(|e| anyhow::anyhow!("Address derivation failed: {}", e))?;

    let typed_data_json = serde_json::json!({
        "types": {
            "EIP712Domain": [
                {"name": "name", "type": "string"},
                {"name": "version", "type": "string"},
                {"name": "chainId", "type": "uint256"}
            ],
            "ClobAuth": [
                {"name": "address", "type": "address"},
                {"name": "timestamp", "type": "string"},
                {"name": "nonce", "type": "uint256"},
                {"name": "message", "type": "string"}
            ]
        },
        "primaryType": "ClobAuth",
        "domain": {
            "name": "ClobAuthDomain",
            "version": "1",
            "chainId": POLYGON_CHAIN_ID
        },
        "message": {
            "address": address,
            "timestamp": timestamp.to_string(),
            "nonce": nonce,
            "message": "This message attests that I control the given wallet"
        }
    }).to_string();

    let output = EvmSigner
        .sign_typed_data(&privkey, &typed_data_json)
        .map_err(|e| anyhow::anyhow!("EIP-712 signing failed: {}", e))?;

    let sig_hex = format!("0x{}", hex::encode(&output.signature));
    Ok((address, sig_hex))
}

// ---------------------------------------------------------------------------
// Order Signing — EIP-712 for CTF Exchange orders
// ---------------------------------------------------------------------------

/// Sign a Polymarket order. Returns the hex-encoded EIP-712 signature.
///
/// `neg_risk`: if true, uses the Neg Risk CTF Exchange contract.
pub fn sign_order(seed_phrase: &str, order: &PolymarketOrder, neg_risk: bool) -> Result<String> {
    let privkey = derive_evm_privkey(seed_phrase)?;
    let exchange = if neg_risk { NEG_RISK_CTF_EXCHANGE } else { CTF_EXCHANGE };

    let typed_data_json = serde_json::json!({
        "types": {
            "EIP712Domain": [
                {"name": "name", "type": "string"},
                {"name": "version", "type": "string"},
                {"name": "chainId", "type": "uint256"},
                {"name": "verifyingContract", "type": "address"}
            ],
            "Order": [
                {"name": "salt", "type": "uint256"},
                {"name": "maker", "type": "address"},
                {"name": "signer", "type": "address"},
                {"name": "taker", "type": "address"},
                {"name": "tokenId", "type": "uint256"},
                {"name": "makerAmount", "type": "uint256"},
                {"name": "takerAmount", "type": "uint256"},
                {"name": "expiration", "type": "uint256"},
                {"name": "nonce", "type": "uint256"},
                {"name": "feeRateBps", "type": "uint256"},
                {"name": "side", "type": "uint8"},
                {"name": "signatureType", "type": "uint8"}
            ]
        },
        "primaryType": "Order",
        "domain": {
            "name": "Polymarket CTF Exchange",
            "version": "1",
            "chainId": POLYGON_CHAIN_ID,
            "verifyingContract": exchange
        },
        "message": {
            "salt": order.salt,
            "maker": order.maker,
            "signer": order.signer,
            "taker": order.taker,
            "tokenId": order.token_id,
            "makerAmount": order.maker_amount,
            "takerAmount": order.taker_amount,
            "expiration": order.expiration,
            "nonce": order.nonce,
            "feeRateBps": order.fee_rate_bps,
            "side": order.side,
            "signatureType": order.signature_type
        }
    }).to_string();

    let output = EvmSigner
        .sign_typed_data(&privkey, &typed_data_json)
        .map_err(|e| anyhow::anyhow!("Order signing failed: {}", e))?;

    Ok(format!("0x{}", hex::encode(&output.signature)))
}
