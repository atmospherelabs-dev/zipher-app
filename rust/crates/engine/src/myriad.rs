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
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PortfolioEntry {
    pub market_id: u64,
    pub outcome_id: u64,
    #[serde(default)]
    pub shares: f64,
    pub market_title: Option<String>,
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
