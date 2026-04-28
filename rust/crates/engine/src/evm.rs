//! Shared EVM helpers: RPC calls, RLP encoding, dynamic gas fees, receipt polling.
//!
//! Extracted and generalized from `myriad.rs`. The RLP encoder uses `&[u8]`
//! for the transaction `value` field to avoid integer overflow (Dart's `int`
//! caused silent zero-value transactions that nodes accepted but never mined).

use anyhow::{anyhow, Result};
use serde::Deserialize;
use tracing::info;

// ---------------------------------------------------------------------------
// Chain registry
// ---------------------------------------------------------------------------

#[derive(Debug, Clone)]
pub struct ChainConfig {
    pub chain_id: u64,
    pub name: &'static str,
    pub rpc_url: &'static str,
    pub native_symbol: &'static str,
    pub native_decimals: u8,
    pub explorer_tx: &'static str,
}

pub const POLYGON: ChainConfig = ChainConfig {
    chain_id: 137,
    name: "Polygon",
    rpc_url: "https://polygon-bor-rpc.publicnode.com",
    native_symbol: "POL",
    native_decimals: 18,
    explorer_tx: "https://polygonscan.com/tx/",
};

pub const BSC: ChainConfig = ChainConfig {
    chain_id: 56,
    name: "BNB Smart Chain",
    rpc_url: "https://bsc-dataseed.binance.org/",
    native_symbol: "BNB",
    native_decimals: 18,
    explorer_tx: "https://bscscan.com/tx/",
};

pub const ETHEREUM: ChainConfig = ChainConfig {
    chain_id: 1,
    name: "Ethereum",
    rpc_url: "https://ethereum-rpc.publicnode.com",
    native_symbol: "ETH",
    native_decimals: 18,
    explorer_tx: "https://etherscan.io/tx/",
};

pub const BASE: ChainConfig = ChainConfig {
    chain_id: 8453,
    name: "Base",
    rpc_url: "https://mainnet.base.org",
    native_symbol: "ETH",
    native_decimals: 18,
    explorer_tx: "https://basescan.org/tx/",
};

pub const ARBITRUM: ChainConfig = ChainConfig {
    chain_id: 42161,
    name: "Arbitrum One",
    rpc_url: "https://arb1.arbitrum.io/rpc",
    native_symbol: "ETH",
    native_decimals: 18,
    explorer_tx: "https://arbiscan.io/tx/",
};

pub fn chain_by_name(name: &str) -> Option<&'static ChainConfig> {
    match name.to_lowercase().as_str() {
        "polygon" | "matic" | "pol" => Some(&POLYGON),
        "bsc" | "bnb" => Some(&BSC),
        "ethereum" | "eth" => Some(&ETHEREUM),
        "base" => Some(&BASE),
        "arbitrum" | "arb" => Some(&ARBITRUM),
        _ => None,
    }
}

pub fn chain_by_id(id: u64) -> Option<&'static ChainConfig> {
    match id {
        137 => Some(&POLYGON),
        56 => Some(&BSC),
        1 => Some(&ETHEREUM),
        8453 => Some(&BASE),
        42161 => Some(&ARBITRUM),
        _ => None,
    }
}

// ---------------------------------------------------------------------------
// Well-known token addresses (ParaSwap uses 0xEEE... for native)
// ---------------------------------------------------------------------------

pub const PARASWAP_NATIVE: &str = "0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE";

#[derive(Debug, Clone)]
pub struct TokenInfo {
    pub symbol: &'static str,
    pub address: &'static str,
    pub decimals: u8,
}

pub fn known_tokens(chain_id: u64) -> Vec<TokenInfo> {
    match chain_id {
        137 => vec![
            TokenInfo { symbol: "POL",    address: PARASWAP_NATIVE, decimals: 18 },
            TokenInfo { symbol: "USDC.e", address: "0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174", decimals: 6 },
            TokenInfo { symbol: "USDC",   address: "0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359", decimals: 6 },
            TokenInfo { symbol: "USDT",   address: "0xc2132D05D31c914a87C6611C10748AEb04B58e8F", decimals: 6 },
            TokenInfo { symbol: "WETH",   address: "0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619", decimals: 18 },
            TokenInfo { symbol: "WMATIC", address: "0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270", decimals: 18 },
        ],
        56 => vec![
            TokenInfo { symbol: "BNB",  address: PARASWAP_NATIVE, decimals: 18 },
            TokenInfo { symbol: "USDT", address: "0x55d398326f99059fF775485246999027B3197955", decimals: 18 },
            TokenInfo { symbol: "USDC", address: "0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d", decimals: 18 },
            TokenInfo { symbol: "WBNB", address: "0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c", decimals: 18 },
        ],
        1 => vec![
            TokenInfo { symbol: "ETH",  address: PARASWAP_NATIVE, decimals: 18 },
            TokenInfo { symbol: "USDC", address: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48", decimals: 6 },
            TokenInfo { symbol: "USDT", address: "0xdAC17F958D2ee523a2206206994597C13D831ec7", decimals: 6 },
            TokenInfo { symbol: "WETH", address: "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2", decimals: 18 },
        ],
        8453 => vec![
            TokenInfo { symbol: "ETH",  address: PARASWAP_NATIVE, decimals: 18 },
            TokenInfo { symbol: "USDC", address: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913", decimals: 6 },
        ],
        42161 => vec![
            TokenInfo { symbol: "ETH",  address: PARASWAP_NATIVE, decimals: 18 },
            TokenInfo { symbol: "USDC", address: "0xaf88d065e77c8cC2239327C5EDb3A432268e5831", decimals: 6 },
            TokenInfo { symbol: "USDT", address: "0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9", decimals: 6 },
        ],
        _ => vec![],
    }
}

// ---------------------------------------------------------------------------
// JSON-RPC helper
// ---------------------------------------------------------------------------

async fn rpc_call(rpc_url: &str, method: &str, params: serde_json::Value) -> Result<serde_json::Value> {
    let client = reqwest::Client::new();
    let body = serde_json::json!({
        "jsonrpc": "2.0",
        "method": method,
        "params": params,
        "id": 1,
    });

    let resp: serde_json::Value = client
        .post(rpc_url)
        .json(&body)
        .send()
        .await
        .map_err(|e| anyhow!("RPC {} error: {}", method, e))?
        .json()
        .await
        .map_err(|e| anyhow!("RPC {} parse error: {}", method, e))?;

    if let Some(err) = resp.get("error") {
        let msg = err.get("message").and_then(|m| m.as_str()).unwrap_or("unknown");
        return Err(anyhow!("RPC {} returned error: {}", method, msg));
    }

    Ok(resp)
}

fn parse_hex_u64(hex: &str) -> Result<u64> {
    u64::from_str_radix(hex.trim_start_matches("0x"), 16)
        .map_err(|e| anyhow!("Invalid hex u64 '{}': {}", hex, e))
}

fn parse_hex_u128(hex: &str) -> Result<u128> {
    u128::from_str_radix(hex.trim_start_matches("0x"), 16)
        .map_err(|e| anyhow!("Invalid hex u128 '{}': {}", hex, e))
}

// ---------------------------------------------------------------------------
// Balance & nonce
// ---------------------------------------------------------------------------

pub async fn get_native_balance(rpc_url: &str, address: &str) -> Result<u128> {
    let resp = rpc_call(rpc_url, "eth_getBalance", serde_json::json!([address, "latest"])).await?;
    let hex = resp["result"].as_str().ok_or_else(|| anyhow!("No result in balance response"))?;
    parse_hex_u128(hex)
}

pub async fn get_erc20_balance(rpc_url: &str, token: &str, owner: &str) -> Result<u128> {
    let owner_clean = owner.trim_start_matches("0x");
    let owner_bytes = hex::decode(owner_clean).map_err(|e| anyhow!("Invalid address: {e}"))?;

    // balanceOf(address) selector: 0x70a08231
    let mut data = vec![0x70, 0xa0, 0x82, 0x31];
    data.extend_from_slice(&[0u8; 12]);
    data.extend_from_slice(&owner_bytes);

    let resp = rpc_call(
        rpc_url,
        "eth_call",
        serde_json::json!([{
            "to": token,
            "data": format!("0x{}", hex::encode(&data)),
        }, "latest"]),
    ).await?;

    let hex = resp["result"].as_str().ok_or_else(|| anyhow!("No result in balanceOf response"))?;
    parse_hex_u128(hex)
}

pub async fn get_nonce(rpc_url: &str, address: &str) -> Result<u64> {
    let resp = rpc_call(rpc_url, "eth_getTransactionCount", serde_json::json!([address, "latest"])).await?;
    let hex = resp["result"].as_str().ok_or_else(|| anyhow!("No result in nonce response"))?;
    parse_hex_u64(hex)
}

pub async fn estimate_gas(
    rpc_url: &str,
    from: &str,
    to: &str,
    data: &[u8],
    value_hex: Option<&str>,
) -> Result<u64> {
    let mut tx = serde_json::json!({
        "from": from,
        "to": to,
        "data": format!("0x{}", hex::encode(data)),
    });
    if let Some(v) = value_hex {
        tx["value"] = serde_json::Value::String(v.to_string());
    }
    let resp = rpc_call(rpc_url, "eth_estimateGas", serde_json::json!([tx])).await?;
    let hex = resp["result"].as_str().ok_or_else(|| anyhow!("No result in gas estimate"))?;
    parse_hex_u64(hex)
}

// ---------------------------------------------------------------------------
// Dynamic EIP-1559 gas fees
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Copy)]
pub struct Eip1559Fees {
    pub max_priority_fee_per_gas: u64,
    pub max_fee_per_gas: u64,
}

impl std::fmt::Display for Eip1559Fees {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "priority: {:.1} gwei, maxFee: {:.1} gwei",
            self.max_priority_fee_per_gas as f64 / 1e9,
            self.max_fee_per_gas as f64 / 1e9,
        )
    }
}

#[derive(Debug, Deserialize)]
#[allow(dead_code)]
struct GasStationResponse {
    fast: GasStationTier,
    #[serde(rename = "estimatedBaseFee")]
    estimated_base_fee: Option<f64>,
}

#[derive(Debug, Deserialize)]
struct GasStationTier {
    #[serde(rename = "maxPriorityFee")]
    max_priority_fee: f64,
    #[serde(rename = "maxFee")]
    max_fee: f64,
}

async fn polygon_gas_station() -> Result<Eip1559Fees> {
    let client = reqwest::Client::new();
    let resp: GasStationResponse = client
        .get("https://gasstation.polygon.technology/v2")
        .send()
        .await
        .map_err(|e| anyhow!("Gas station error: {e}"))?
        .json()
        .await
        .map_err(|e| anyhow!("Gas station parse error: {e}"))?;

    let priority = (resp.fast.max_priority_fee * 1e9) as u64;
    let max_fee = (resp.fast.max_fee * 1e9) as u64;

    Ok(Eip1559Fees {
        max_priority_fee_per_gas: priority,
        max_fee_per_gas: max_fee,
    })
}

async fn rpc_gas_fees(rpc_url: &str) -> Result<Eip1559Fees> {
    let priority_resp = rpc_call(rpc_url, "eth_maxPriorityFeePerGas", serde_json::json!([])).await?;
    let priority_hex = priority_resp["result"].as_str().unwrap_or("0x0");
    let priority = parse_hex_u64(priority_hex)?;

    let fee_resp = rpc_call(
        rpc_url,
        "eth_feeHistory",
        serde_json::json!(["0x1", "latest", []]),
    ).await?;

    let base_fee = fee_resp["result"]["baseFeePerGas"]
        .as_array()
        .and_then(|arr| arr.last())
        .and_then(|v| v.as_str())
        .map(|h| parse_hex_u64(h).unwrap_or(0))
        .unwrap_or(0);

    // maxFee = 2 * baseFee + priorityFee (standard EIP-1559 formula)
    let max_fee = 2 * base_fee + priority;

    Ok(Eip1559Fees {
        max_priority_fee_per_gas: priority,
        max_fee_per_gas: max_fee,
    })
}

pub async fn suggest_eip1559_fees(rpc_url: &str, chain_id: u64) -> Result<Eip1559Fees> {
    if chain_id == 137 {
        match polygon_gas_station().await {
            Ok(fees) => {
                info!("Gas fees from Polygon Gas Station: {}", fees);
                return Ok(fees);
            }
            Err(e) => {
                info!("Gas Station failed, falling back to RPC: {}", e);
            }
        }
    }

    let fees = rpc_gas_fees(rpc_url).await?;
    info!("Gas fees from RPC: {}", fees);
    Ok(fees)
}

// ---------------------------------------------------------------------------
// Minimal RLP encoder
// ---------------------------------------------------------------------------

pub fn rlp_encode_u64(val: u64) -> Vec<u8> {
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

pub fn rlp_encode_bytes(data: &[u8]) -> Vec<u8> {
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

pub fn rlp_encode_list(items: &[Vec<u8>]) -> Vec<u8> {
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

/// RLP-encode an arbitrary-precision big-endian value.
/// Accepts raw big-endian bytes (leading zeros stripped by caller, or we strip here).
fn rlp_encode_uint(val: &[u8]) -> Vec<u8> {
    let start = val.iter().position(|&b| b != 0).unwrap_or(val.len());
    let trimmed = &val[start..];
    if trimmed.is_empty() {
        vec![0x80] // zero
    } else {
        rlp_encode_bytes(trimmed)
    }
}

// ---------------------------------------------------------------------------
// EIP-1559 transaction builder
// ---------------------------------------------------------------------------

/// Build an unsigned EIP-1559 transaction as typed envelope bytes (0x02 || RLP).
///
/// `value_wei` is big-endian bytes of the wei amount. Use `&[]` or `&[0]` for
/// zero-value calls. This avoids the u64 overflow that plagued the Dart encoder.
pub fn build_unsigned_eip1559_tx(
    chain_id: u64,
    nonce: u64,
    max_priority_fee: u64,
    max_fee: u64,
    gas_limit: u64,
    to: &str,
    value_wei: &[u8],
    data: &[u8],
) -> Vec<u8> {
    let items = vec![
        rlp_encode_u64(chain_id),
        rlp_encode_u64(nonce),
        rlp_encode_u64(max_priority_fee),
        rlp_encode_u64(max_fee),
        rlp_encode_u64(gas_limit),
        rlp_encode_address(to),
        rlp_encode_uint(value_wei),
        rlp_encode_bytes(data),
        rlp_encode_list(&[]), // access_list (empty)
    ];

    let rlp = rlp_encode_list(&items);
    let mut out = Vec::with_capacity(1 + rlp.len());
    out.push(0x02); // EIP-1559 type prefix
    out.extend_from_slice(&rlp);
    out
}

/// Convert a u128 wei amount into big-endian bytes (leading zeros stripped).
pub fn u128_to_be_trimmed(val: u128) -> Vec<u8> {
    if val == 0 {
        return vec![];
    }
    let bytes = val.to_be_bytes();
    let start = bytes.iter().position(|&b| b != 0).unwrap_or(15);
    bytes[start..].to_vec()
}

// ---------------------------------------------------------------------------
// Receipt polling
// ---------------------------------------------------------------------------

#[derive(Debug, Clone)]
pub struct TxReceipt {
    pub status: bool,
    pub block_number: u64,
    pub gas_used: u64,
    pub tx_hash: String,
}

pub async fn wait_for_receipt(rpc_url: &str, tx_hash: &str, timeout_secs: u64) -> Result<TxReceipt> {
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(timeout_secs);
    let mut interval = 3;

    loop {
        let resp = rpc_call(
            rpc_url,
            "eth_getTransactionReceipt",
            serde_json::json!([tx_hash]),
        ).await?;

        if let Some(result) = resp.get("result") {
            if !result.is_null() {
                let status_hex = result["status"].as_str().unwrap_or("0x0");
                let block_hex = result["blockNumber"].as_str().unwrap_or("0x0");
                let gas_hex = result["gasUsed"].as_str().unwrap_or("0x0");

                return Ok(TxReceipt {
                    status: status_hex == "0x1",
                    block_number: parse_hex_u64(block_hex).unwrap_or(0),
                    gas_used: parse_hex_u64(gas_hex).unwrap_or(0),
                    tx_hash: tx_hash.to_string(),
                });
            }
        }

        if std::time::Instant::now() >= deadline {
            return Err(anyhow!("Receipt timeout after {}s for tx {}", timeout_secs, tx_hash));
        }

        info!("Waiting for receipt... ({}s intervals)", interval);
        tokio::time::sleep(std::time::Duration::from_secs(interval)).await;
        interval = (interval + 1).min(10);
    }
}

// ---------------------------------------------------------------------------
// Sign + broadcast + wait (full flow)
// ---------------------------------------------------------------------------

pub async fn sign_and_broadcast(
    seed_phrase: &str,
    unsigned_tx: &[u8],
    rpc_url: &str,
) -> Result<String> {
    let signed = crate::ows::sign_evm_tx(seed_phrase, unsigned_tx)?;
    let signed_hex = format!("0x{}", hex::encode(&signed));

    info!("Broadcasting signed tx ({} bytes)...", signed.len());

    let resp = rpc_call(
        rpc_url,
        "eth_sendRawTransaction",
        serde_json::json!([signed_hex]),
    ).await?;

    resp["result"]
        .as_str()
        .map(|s| s.to_string())
        .ok_or_else(|| anyhow!("No tx hash in sendRawTransaction response"))
}

// ---------------------------------------------------------------------------
// ERC-20 approve helper
// ---------------------------------------------------------------------------

fn build_erc20_approve_data(spender: &str, amount: u128) -> Vec<u8> {
    let spender_clean = spender.trim_start_matches("0x");
    let mut data = Vec::with_capacity(68);
    // approve(address,uint256) selector: 0x095ea7b3
    data.extend_from_slice(&[0x09, 0x5e, 0xa7, 0xb3]);
    // address padded to 32 bytes
    data.extend_from_slice(&[0u8; 12]);
    data.extend_from_slice(&hex::decode(spender_clean).unwrap_or_default());
    // uint256 max approval
    let amount_bytes = amount.to_be_bytes();
    data.extend_from_slice(&[0u8; 16]); // pad to 32 bytes total
    data.extend_from_slice(&amount_bytes);
    data
}

/// Approve a spender for an ERC-20 token. Returns the tx hash.
pub async fn approve_erc20(
    rpc_url: &str,
    seed_phrase: &str,
    owner: &str,
    token: &str,
    spender: &str,
    amount: u128,
    chain_id: u64,
    fees: &Eip1559Fees,
) -> Result<String> {
    let nonce = get_nonce(rpc_url, owner).await?;
    let calldata = build_erc20_approve_data(spender, amount);

    let gas = estimate_gas(rpc_url, owner, token, &calldata, None).await
        .unwrap_or(80_000);
    let gas_with_buffer = gas + gas / 5; // +20%

    info!("Approving {} to spend token {} (gas: {})", spender, token, gas_with_buffer);

    let unsigned = build_unsigned_eip1559_tx(
        chain_id,
        nonce,
        fees.max_priority_fee_per_gas,
        fees.max_fee_per_gas,
        gas_with_buffer,
        token,
        &[], // zero value
        &calldata,
    );

    let tx_hash = sign_and_broadcast(seed_phrase, &unsigned, rpc_url).await?;
    info!("Approve tx: {}", tx_hash);

    wait_for_receipt(rpc_url, &tx_hash, 120).await?;
    info!("Approve confirmed");

    Ok(tx_hash)
}

// ---------------------------------------------------------------------------
// ERC-20 allowance check
// ---------------------------------------------------------------------------

pub async fn get_erc20_allowance(rpc_url: &str, token: &str, owner: &str, spender: &str) -> Result<u128> {
    let owner_clean = owner.trim_start_matches("0x");
    let spender_clean = spender.trim_start_matches("0x");

    // allowance(address,address) selector: 0xdd62ed3e
    let mut data = vec![0xdd, 0x62, 0xed, 0x3e];
    data.extend_from_slice(&[0u8; 12]);
    data.extend_from_slice(&hex::decode(owner_clean).map_err(|e| anyhow!("bad owner: {e}"))?);
    data.extend_from_slice(&[0u8; 12]);
    data.extend_from_slice(&hex::decode(spender_clean).map_err(|e| anyhow!("bad spender: {e}"))?);

    let resp = rpc_call(
        rpc_url,
        "eth_call",
        serde_json::json!([{
            "to": token,
            "data": format!("0x{}", hex::encode(&data)),
        }, "latest"]),
    ).await?;

    let hex_str = resp["result"].as_str().ok_or_else(|| anyhow!("No result in allowance"))?;
    parse_hex_u128(hex_str)
}

// ---------------------------------------------------------------------------
// ERC-1155 helpers
// ---------------------------------------------------------------------------

/// `isApprovedForAll(address,address)` — selector 0xe985e9c5
pub async fn erc1155_is_approved_for_all(
    rpc_url: &str,
    owner: &str,
    token_contract: &str,
    operator: &str,
) -> Result<bool> {
    let owner_clean = owner.trim_start_matches("0x");
    let op_clean = operator.trim_start_matches("0x");

    let mut data = vec![0xe9, 0x85, 0xe9, 0xc5];
    data.extend_from_slice(&[0u8; 12]);
    data.extend_from_slice(&hex::decode(owner_clean).map_err(|e| anyhow!("bad owner: {e}"))?);
    data.extend_from_slice(&[0u8; 12]);
    data.extend_from_slice(&hex::decode(op_clean).map_err(|e| anyhow!("bad operator: {e}"))?);

    let resp = rpc_call(
        rpc_url,
        "eth_call",
        serde_json::json!([{
            "to": token_contract,
            "data": format!("0x{}", hex::encode(&data)),
        }, "latest"]),
    ).await?;

    let hex_str = resp["result"].as_str().unwrap_or("0x0");
    let val = parse_hex_u128(hex_str).unwrap_or(0);
    Ok(val != 0)
}

/// `setApprovalForAll(address,bool)` — selector 0xa22cb465.
/// Signs, broadcasts, and waits for receipt. Returns the tx hash.
pub async fn erc1155_set_approval_for_all(
    rpc_url: &str,
    seed_phrase: &str,
    owner: &str,
    token_contract: &str,
    operator: &str,
    approved: bool,
    chain_id: u64,
    fees: &Eip1559Fees,
) -> Result<String> {
    let op_clean = operator.trim_start_matches("0x");

    let mut calldata = vec![0xa2, 0x2c, 0xb4, 0x65];
    calldata.extend_from_slice(&[0u8; 12]);
    calldata.extend_from_slice(&hex::decode(op_clean).map_err(|e| anyhow!("bad operator: {e}"))?);
    calldata.extend_from_slice(&[0u8; 31]);
    calldata.push(if approved { 1 } else { 0 });

    let nonce = get_nonce(rpc_url, owner).await?;
    let gas = estimate_gas(rpc_url, owner, token_contract, &calldata, None)
        .await
        .unwrap_or(80_000);
    let gas_with_buffer = gas + gas / 5;

    let unsigned = build_unsigned_eip1559_tx(
        chain_id,
        nonce,
        fees.max_priority_fee_per_gas,
        fees.max_fee_per_gas,
        gas_with_buffer,
        token_contract,
        &[],
        &calldata,
    );

    let tx_hash = sign_and_broadcast(seed_phrase, &unsigned, rpc_url).await?;
    info!("ERC-1155 setApprovalForAll tx: {}", tx_hash);

    wait_for_receipt(rpc_url, &tx_hash, 120).await?;
    Ok(tx_hash)
}

// ---------------------------------------------------------------------------
// Formatting helpers
// ---------------------------------------------------------------------------

pub fn format_token_amount(raw: u128, decimals: u8) -> String {
    let divisor = 10u128.pow(decimals as u32);
    let whole = raw / divisor;
    let frac = raw % divisor;
    if decimals == 0 {
        return whole.to_string();
    }
    let frac_str = format!("{:0>width$}", frac, width = decimals as usize);
    let trimmed = frac_str.trim_end_matches('0');
    if trimmed.is_empty() {
        format!("{}.0", whole)
    } else {
        format!("{}.{}", whole, trimmed)
    }
}

/// Parse a human-readable amount (e.g. "1.5") into raw token units.
pub fn parse_token_amount(input: &str, decimals: u8) -> Result<u128> {
    let parts: Vec<&str> = input.split('.').collect();
    let whole: u128 = parts[0].parse().map_err(|_| anyhow!("Invalid amount"))?;

    let frac: u128 = if parts.len() > 1 {
        let frac_str = parts[1];
        let padded = format!("{:0<width$}", frac_str, width = decimals as usize);
        let truncated = &padded[..decimals as usize];
        truncated.parse().map_err(|_| anyhow!("Invalid fractional part"))?
    } else {
        0
    };

    Ok(whole * 10u128.pow(decimals as u32) + frac)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_rlp_encode_u64() {
        assert_eq!(rlp_encode_u64(0), vec![0x80]);
        assert_eq!(rlp_encode_u64(1), vec![0x01]);
        assert_eq!(rlp_encode_u64(127), vec![0x7f]);
        assert_eq!(rlp_encode_u64(128), vec![0x81, 0x80]);
    }

    #[test]
    fn test_rlp_encode_uint_large() {
        // 1 ETH = 1e18 = 0x0DE0B6B3A7640000
        let val: u128 = 1_000_000_000_000_000_000;
        let bytes = u128_to_be_trimmed(val);
        let encoded = rlp_encode_uint(&bytes);
        // Should be: 0x88 (length prefix 8 bytes) + the 8 bytes
        assert_eq!(encoded[0], 0x88);
        assert_eq!(encoded.len(), 9);
    }

    #[test]
    fn test_format_token_amount() {
        assert_eq!(format_token_amount(1_000_000, 6), "1.0");
        assert_eq!(format_token_amount(1_500_000, 6), "1.5");
        assert_eq!(format_token_amount(1_000_000_000_000_000_000, 18), "1.0");
    }

    #[test]
    fn test_parse_token_amount() {
        assert_eq!(parse_token_amount("1.5", 6).unwrap(), 1_500_000);
        assert_eq!(parse_token_amount("1", 18).unwrap(), 1_000_000_000_000_000_000);
        assert_eq!(parse_token_amount("0.001", 6).unwrap(), 1_000);
    }

    #[test]
    fn test_eip1559_tx_structure() {
        let tx = build_unsigned_eip1559_tx(
            137,   // Polygon
            0,     // nonce
            30_000_000_000, // 30 gwei priority
            100_000_000_000, // 100 gwei max
            21_000, // gas limit
            "0x0000000000000000000000000000000000000001",
            &u128_to_be_trimmed(1_000_000_000_000_000_000), // 1 POL
            &[], // no data
        );
        assert_eq!(tx[0], 0x02); // EIP-1559 type
    }
}
