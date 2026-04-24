use anyhow::Result;
use serde::{Deserialize, Serialize};
use tracing::info;

const MYRIAD_API: &str = "https://api-v2.myriadprotocol.com";

pub const BSC_NETWORK_ID: u64 = 56;
pub const PM_CONTRACT: &str = "0x39E66eE6b2ddaf4DEfDEd3038E0162180dbeF340";
pub const USDT_BSC: &str = "0x55d398326f99059fF775485246999027B3197955";
pub const BSC_RPC: &str = "https://bsc-dataseed.binance.org/";

// ---------------------------------------------------------------------------
// API Types
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Market {
    pub id: u64,
    pub title: String,
    pub description: Option<String>,
    pub state: Option<String>,
    pub network_id: Option<u64>,
    #[serde(default)]
    pub outcomes: Vec<Outcome>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Outcome {
    pub title: String,
    #[serde(default)]
    pub price: f64,
    pub outcome_id: Option<u64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TradeQuote {
    pub calldata: String,
    #[serde(default)]
    pub shares: f64,
    #[serde(default)]
    pub value: f64,
    #[serde(default)]
    pub price: f64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PortfolioEntry {
    pub market_id: u64,
    pub outcome_id: u64,
    #[serde(default)]
    pub shares: f64,
    pub market_title: Option<String>,
    #[serde(default)]
    pub market_slug: Option<String>,
    #[serde(default)]
    pub image_url: Option<String>,
}

// API response wrappers (Myriad wraps results in {"data": ...})
#[derive(Debug, Deserialize)]
struct ApiListResponse<T> {
    data: Vec<T>,
}

#[derive(Debug, Deserialize)]
struct ApiItemResponse<T> {
    data: T,
}

// ---------------------------------------------------------------------------
// Myriad REST API Client
// ---------------------------------------------------------------------------

pub async fn get_markets(keyword: Option<&str>, limit: u32) -> Result<Vec<Market>> {
    let client = reqwest::Client::new();
    let mut url = format!("{}/markets?network_id={}&limit={}", MYRIAD_API, BSC_NETWORK_ID, limit);
    if let Some(kw) = keyword {
        let encoded: String = kw.chars().map(|c| {
            if c.is_ascii_alphanumeric() || "-_.~".contains(c) { c.to_string() }
            else { format!("%{:02X}", c as u8) }
        }).collect();
        url.push_str(&format!("&keyword={}", encoded));
    }

    info!("Fetching markets from Myriad...");
    let resp = client.get(&url).send().await
        .map_err(|e| anyhow::anyhow!("Myriad API error: {}", e))?;

    let status = resp.status();
    let text = resp.text().await
        .map_err(|e| anyhow::anyhow!("Failed to read response: {}", e))?;

    if !status.is_success() {
        return Err(anyhow::anyhow!("Myriad API returned {}: {}", status, &text[..text.len().min(200)]));
    }

    let wrapper: ApiListResponse<Market> = serde_json::from_str(&text)
        .map_err(|e| anyhow::anyhow!("Failed to parse markets: {} — body: {}", e, &text[..text.len().min(200)]))?;
    info!("Found {} prediction markets on BNB Chain", wrapper.data.len());

    Ok(wrapper.data)
}

pub async fn get_market(id: u64) -> Result<Market> {
    let client = reqwest::Client::new();
    let url = format!("{}/markets/{}?network_id={}", MYRIAD_API, id, BSC_NETWORK_ID);

    info!("Fetching market #{} from Myriad...", id);
    let resp = client.get(&url).send().await
        .map_err(|e| anyhow::anyhow!("Myriad API error: {}", e))?;

    let status = resp.status();
    let text = resp.text().await
        .map_err(|e| anyhow::anyhow!("Failed to read response: {}", e))?;

    if !status.is_success() {
        return Err(anyhow::anyhow!("Myriad API returned {}: {}", status, &text[..text.len().min(200)]));
    }

    let market: Market = serde_json::from_str(&text)
        .or_else(|_| {
            let wrapper: ApiItemResponse<Market> = serde_json::from_str(&text)?;
            Ok::<_, serde_json::Error>(wrapper.data)
        })
        .map_err(|e| anyhow::anyhow!("Failed to parse market: {} — body: {}", e, &text[..text.len().min(200)]))?;
    info!("Market #{}: \"{}\" — {} outcomes", market.id, market.title, market.outcomes.len());

    Ok(market)
}

pub async fn get_quote(
    market_id: u64,
    outcome_id: u64,
    action: &str,
    value: f64,
    slippage: f64,
) -> Result<TradeQuote> {
    let client = reqwest::Client::new();
    let url = format!("{}/markets/quote", MYRIAD_API);

    let body = serde_json::json!({
        "market_id": market_id,
        "outcome_id": outcome_id,
        "network_id": BSC_NETWORK_ID,
        "action": action,
        "value": value,
        "slippage": slippage,
    });

    info!("Requesting quote: market={}, outcome={}, {} ${:.2}...", market_id, outcome_id, action, value);
    let resp = client.post(&url).json(&body).send().await
        .map_err(|e| anyhow::anyhow!("Myriad quote error: {}", e))?;

    let status = resp.status();
    let text = resp.text().await.unwrap_or_default();
    if !status.is_success() {
        return Err(anyhow::anyhow!("Myriad quote failed ({}): {}", status, &text[..text.len().min(200)]));
    }

    let quote: TradeQuote = serde_json::from_str(&text)
        .map_err(|e| anyhow::anyhow!("Failed to parse quote: {} — body: {}", e, &text[..text.len().min(200)]))?;
    info!("Quote received: {:.4} shares, calldata ready ({} bytes)", quote.shares, quote.calldata.len());

    Ok(quote)
}

pub async fn get_portfolio(address: &str) -> Result<Vec<PortfolioEntry>> {
    let client = reqwest::Client::new();
    let url = format!("{}/users/{}/portfolio", MYRIAD_API, address);

    info!("Checking portfolio for {}...", &address[..address.len().min(10)]);
    let resp = client.get(&url).send().await
        .map_err(|e| anyhow::anyhow!("Myriad portfolio error: {}", e))?;

    let status = resp.status();
    let text = resp.text().await
        .map_err(|e| anyhow::anyhow!("Failed to read portfolio response: {}", e))?;

    if !status.is_success() {
        return Err(anyhow::anyhow!("Portfolio API returned {}: {}", status, &text[..text.len().min(200)]));
    }

    let entries: Vec<PortfolioEntry> = serde_json::from_str(&text)
        .or_else(|_| {
            let wrapper: ApiListResponse<PortfolioEntry> = serde_json::from_str(&text)?;
            Ok::<_, serde_json::Error>(wrapper.data)
        })
        .map_err(|e| anyhow::anyhow!("Failed to parse portfolio: {} — body: {}", e, &text[..text.len().min(200)]))?;
    info!("Found {} open positions", entries.len());

    Ok(entries)
}

// ---------------------------------------------------------------------------
// Market Scanning — pre-filter for researchable markets
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize)]
pub struct ScannedMarket {
    pub market: Market,
    /// Market-implied probability for each outcome (= price)
    pub implied_probs: Vec<f64>,
    /// Sum of all outcome prices. >1.0 means overround (vig), <1.0 means leaky book.
    pub book_sum: f64,
    /// How uncertain the market is: 1.0 = max entropy (50/50), 0.0 = decided.
    pub uncertainty: f64,
}

/// Scan markets and return those worth researching.
/// Filters: open, has outcomes with prices, reasonable book structure.
pub fn scan_markets(markets: &[Market]) -> Vec<ScannedMarket> {
    let mut scanned: Vec<ScannedMarket> = markets
        .iter()
        .filter(|m| {
            m.state.as_deref() == Some("open")
                && m.outcomes.len() >= 2
                && m.outcomes.iter().any(|o| o.price > 0.01)
        })
        .filter_map(|m| {
            let prices: Vec<f64> = m.outcomes.iter().map(|o| o.price).collect();
            let book_sum: f64 = prices.iter().sum();
            if book_sum < 0.5 { return None; } // garbage data

            // Normalize to implied probabilities
            let implied: Vec<f64> = prices.iter().map(|p| p / book_sum).collect();

            // Shannon entropy as uncertainty measure (normalized 0..1)
            let n = implied.len() as f64;
            let max_entropy = n.ln();
            let entropy: f64 = implied.iter()
                .filter(|&&p| p > 0.0)
                .map(|&p| -p * p.ln())
                .sum();
            let uncertainty = if max_entropy > 0.0 { entropy / max_entropy } else { 0.0 };

            Some(ScannedMarket {
                market: m.clone(),
                implied_probs: implied,
                book_sum,
                uncertainty,
            })
        })
        .collect();

    // Sort by uncertainty descending — most uncertain = most opportunity
    scanned.sort_by(|a, b| b.uncertainty.partial_cmp(&a.uncertainty).unwrap_or(std::cmp::Ordering::Equal));
    scanned
}

// ---------------------------------------------------------------------------
// Strategy — Edge Calculation & Kelly Sizing
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize)]
pub struct TradeSignal {
    pub market_id: u64,
    pub market_title: String,
    pub outcome_index: usize,
    pub outcome_title: String,
    /// Market-implied probability (from the price)
    pub market_prob: f64,
    /// Agent's estimated probability (from LLM + research)
    pub estimated_prob: f64,
    /// Raw edge: estimated_prob - market_prob
    pub edge: f64,
    /// Full Kelly fraction of bankroll to bet
    pub kelly_fraction: f64,
    /// Recommended bet after applying fractional Kelly and risk caps
    pub recommended_bet_usdt: f64,
    /// Expected value per dollar risked
    pub expected_value: f64,
    /// Confidence level used for fractional Kelly (0.0-1.0)
    pub confidence: f64,
    pub reason: String,
}

/// Calculate the optimal bet using Kelly Criterion.
///
/// The Kelly formula for binary bets:
///   f* = (p * b - q) / b
/// where p = estimated probability, q = 1-p, b = net odds (payout - 1).
///
/// In prediction markets, buying at price `market_prob`:
///   payout if win = 1.0 / market_prob
///   b = (1.0 / market_prob) - 1.0
///   f* = (estimated_prob - market_prob) / (1.0 - market_prob)
///
/// Fractional Kelly scales this by a confidence multiplier (typically 0.25-0.5)
/// to account for probability estimation uncertainty.
pub fn kelly_fraction(estimated_prob: f64, market_prob: f64) -> f64 {
    if market_prob <= 0.01 || market_prob >= 0.99 || estimated_prob <= market_prob {
        return 0.0;
    }
    (estimated_prob - market_prob) / (1.0 - market_prob)
}

/// Analyze a market given the agent's probability estimate.
/// Returns a trade signal with Kelly-sized recommendation.
///
/// Arguments:
/// - `market`: The prediction market
/// - `outcome_index`: Which outcome the agent believes is underpriced
/// - `estimated_prob`: Agent's probability estimate (0.0-1.0) for that outcome
/// - `confidence`: How confident the agent is in its estimate (0.0-1.0).
///   Maps to fractional Kelly: 0.25 (low) to 0.5 (high). Most experts recommend
///   never going above half Kelly.
/// - `bankroll`: Total available capital in USDT
/// - `max_bet`: Hard cap on any single bet (risk control)
pub fn analyze_opportunity(
    market: &Market,
    outcome_index: usize,
    estimated_prob: f64,
    confidence: f64,
    bankroll: f64,
    max_bet: f64,
) -> Option<TradeSignal> {
    let outcome = market.outcomes.get(outcome_index)?;
    let market_prob = outcome.price;

    if market_prob <= 0.01 || market_prob >= 0.99 {
        return None;
    }

    let edge = estimated_prob - market_prob;
    if edge <= 0.0 {
        return None; // no edge, no trade
    }

    let full_kelly = kelly_fraction(estimated_prob, market_prob);

    // Fractional Kelly: scale by confidence.
    // confidence 0.0 → quarter Kelly (conservative), 1.0 → half Kelly (aggressive).
    // Never go above half Kelly — academic consensus.
    let kelly_multiplier = 0.25 + (confidence.clamp(0.0, 1.0) * 0.25);
    let fractional = full_kelly * kelly_multiplier;

    // Position size = fraction of bankroll, capped at max_bet
    let bet_amount = (fractional * bankroll)
        .min(max_bet)
        .max(0.0);

    // Expected value per dollar: EV = p * payout - 1
    let payout = 1.0 / market_prob;
    let ev = estimated_prob * payout - 1.0;

    let reason = format!(
        "Edge {:.1}% (you: {:.0}% vs market: {:.0}%). \
         Kelly {:.1}% of bankroll (×{:.2} fractional). \
         EV ${:.3} per $1 risked.",
        edge * 100.0,
        estimated_prob * 100.0,
        market_prob * 100.0,
        fractional * 100.0,
        kelly_multiplier,
        ev,
    );

    Some(TradeSignal {
        market_id: market.id,
        market_title: market.title.clone(),
        outcome_index,
        outcome_title: outcome.title.clone(),
        market_prob,
        estimated_prob,
        edge,
        kelly_fraction: fractional,
        recommended_bet_usdt: bet_amount,
        expected_value: ev,
        confidence,
        reason,
    })
}

/// Quick scan: rank markets by how "researchable" they are.
/// Does NOT estimate probabilities (that's the LLM's job).
/// Returns markets sorted by uncertainty — the most contested markets
/// are where information edge is most valuable.
pub fn rank_for_research(markets: &[Market]) -> Vec<ScannedMarket> {
    let mut scanned = scan_markets(markets);
    // Filter out nearly-decided markets (one outcome > 90%)
    scanned.retain(|s| s.uncertainty > 0.3);
    scanned
}

// ---------------------------------------------------------------------------
// ERC-20 calldata builders
// ---------------------------------------------------------------------------

pub fn build_erc20_approve_calldata(spender: &str, amount_hex: &str) -> Vec<u8> {
    let spender_clean = spender.trim_start_matches("0x");
    let mut data = Vec::with_capacity(68);
    // approve(address,uint256) selector: 0x095ea7b3
    data.extend_from_slice(&[0x09, 0x5e, 0xa7, 0xb3]);
    // address padded to 32 bytes
    data.extend_from_slice(&[0u8; 12]);
    data.extend_from_slice(&hex::decode(spender_clean).unwrap_or_default());
    // amount padded to 32 bytes
    let amount_bytes = hex::decode(amount_hex).unwrap_or_default();
    let pad = 32 - amount_bytes.len().min(32);
    data.extend_from_slice(&vec![0u8; pad]);
    data.extend_from_slice(&amount_bytes[..amount_bytes.len().min(32)]);
    data
}

// ---------------------------------------------------------------------------
// Minimal RLP Encoder for EIP-1559 Transactions
// ---------------------------------------------------------------------------

fn rlp_encode_u64(val: u64) -> Vec<u8> {
    if val == 0 {
        return vec![0x80];
    }
    let bytes = val.to_be_bytes();
    let start = bytes.iter().position(|&b| b != 0).unwrap_or(7);
    let trimmed = &bytes[start..];
    if trimmed.len() == 1 && trimmed[0] < 0x80 {
        trimmed.to_vec()
    } else {
        let mut out = vec![0x80 + trimmed.len() as u8];
        out.extend_from_slice(trimmed);
        out
    }
}

fn rlp_encode_bytes(data: &[u8]) -> Vec<u8> {
    if data.is_empty() {
        return vec![0x80];
    }
    if data.len() == 1 && data[0] < 0x80 {
        return data.to_vec();
    }
    if data.len() <= 55 {
        let mut out = vec![0x80 + data.len() as u8];
        out.extend_from_slice(data);
        out
    } else {
        let len_bytes = data.len().to_be_bytes();
        let start = len_bytes.iter().position(|&b| b != 0).unwrap_or(7);
        let len_trimmed = &len_bytes[start..];
        let mut out = vec![0xb7 + len_trimmed.len() as u8];
        out.extend_from_slice(len_trimmed);
        out.extend_from_slice(data);
        out
    }
}

fn rlp_encode_address(addr: &str) -> Vec<u8> {
    let clean = addr.trim_start_matches("0x");
    let bytes = hex::decode(clean).unwrap_or_default();
    rlp_encode_bytes(&bytes)
}

fn rlp_encode_list(items: &[Vec<u8>]) -> Vec<u8> {
    let payload: Vec<u8> = items.iter().flat_map(|i| i.iter().copied()).collect();
    if payload.len() <= 55 {
        let mut out = vec![0xc0 + payload.len() as u8];
        out.extend_from_slice(&payload);
        out
    } else {
        let len_bytes = payload.len().to_be_bytes();
        let start = len_bytes.iter().position(|&b| b != 0).unwrap_or(7);
        let len_trimmed = &len_bytes[start..];
        let mut out = vec![0xf7 + len_trimmed.len() as u8];
        out.extend_from_slice(len_trimmed);
        out.extend_from_slice(&payload);
        out
    }
}

/// Build an unsigned EIP-1559 transaction as typed envelope bytes (0x02 || RLP).
pub fn build_unsigned_eip1559_tx(
    chain_id: u64,
    nonce: u64,
    max_priority_fee: u64,
    max_fee: u64,
    gas_limit: u64,
    to: &str,
    value: u64,
    data: &[u8],
) -> Vec<u8> {
    let items = vec![
        rlp_encode_u64(chain_id),
        rlp_encode_u64(nonce),
        rlp_encode_u64(max_priority_fee),
        rlp_encode_u64(max_fee),
        rlp_encode_u64(gas_limit),
        rlp_encode_address(to),
        rlp_encode_u64(value),
        rlp_encode_bytes(data),
        rlp_encode_list(&[]),     // access_list (empty)
    ];

    let rlp = rlp_encode_list(&items);
    let mut out = Vec::with_capacity(1 + rlp.len());
    out.push(0x02); // EIP-1559 type prefix
    out.extend_from_slice(&rlp);
    out
}

// ---------------------------------------------------------------------------
// BNB Chain JSON-RPC Helpers
// ---------------------------------------------------------------------------

pub async fn get_bnb_balance(rpc_url: &str, address: &str) -> Result<u128> {
    let client = reqwest::Client::new();
    let body = serde_json::json!({
        "jsonrpc": "2.0",
        "method": "eth_getBalance",
        "params": [address, "latest"],
        "id": 1,
    });

    let resp: serde_json::Value = client.post(rpc_url).json(&body).send().await
        .map_err(|e| anyhow::anyhow!("RPC error: {}", e))?
        .json().await
        .map_err(|e| anyhow::anyhow!("RPC parse error: {}", e))?;

    let hex_str = resp["result"].as_str()
        .ok_or_else(|| anyhow::anyhow!("No result in balance response"))?;
    let balance = u128::from_str_radix(hex_str.trim_start_matches("0x"), 16)
        .map_err(|e| anyhow::anyhow!("Invalid balance hex: {}", e))?;

    Ok(balance)
}

/// Minimum BNB needed for gas (approve + bet + buffer for future txs)
pub const MIN_BNB_FOR_GAS: u128 = 2_000_000_000_000_000; // 0.002 BNB

pub async fn get_nonce(rpc_url: &str, address: &str) -> Result<u64> {
    let client = reqwest::Client::new();
    let body = serde_json::json!({
        "jsonrpc": "2.0",
        "method": "eth_getTransactionCount",
        "params": [address, "latest"],
        "id": 1,
    });

    let resp: serde_json::Value = client.post(rpc_url).json(&body).send().await
        .map_err(|e| anyhow::anyhow!("RPC error: {}", e))?
        .json().await
        .map_err(|e| anyhow::anyhow!("RPC parse error: {}", e))?;

    let hex_str = resp["result"].as_str()
        .ok_or_else(|| anyhow::anyhow!("No result in nonce response"))?;
    let nonce = u64::from_str_radix(hex_str.trim_start_matches("0x"), 16)
        .map_err(|e| anyhow::anyhow!("Invalid nonce hex: {}", e))?;

    Ok(nonce)
}

pub async fn estimate_gas(rpc_url: &str, from: &str, to: &str, data: &[u8]) -> Result<u64> {
    let client = reqwest::Client::new();
    let body = serde_json::json!({
        "jsonrpc": "2.0",
        "method": "eth_estimateGas",
        "params": [{
            "from": from,
            "to": to,
            "data": format!("0x{}", hex::encode(data)),
        }],
        "id": 1,
    });

    let resp: serde_json::Value = client.post(rpc_url).json(&body).send().await
        .map_err(|e| anyhow::anyhow!("RPC error: {}", e))?
        .json().await
        .map_err(|e| anyhow::anyhow!("RPC parse error: {}", e))?;

    let hex_str = resp["result"].as_str()
        .ok_or_else(|| anyhow::anyhow!("No result in gas estimate"))?;
    let gas = u64::from_str_radix(hex_str.trim_start_matches("0x"), 16)
        .map_err(|e| anyhow::anyhow!("Invalid gas hex: {}", e))?;

    Ok(gas)
}
