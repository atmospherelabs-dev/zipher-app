//! Multi-chain x402 detection and cross-chain funding.
//!
//! When an x402 paywall requires payment on an EVM chain (e.g. USDC on Base),
//! this module detects the requirement, estimates how much ZEC to swap, and
//! checks on-chain balances. The actual x402 payment is handled by OWS
//! (`ows pay request`) which uses EIP-3009 TransferWithAuthorization.
//!
//! The mental model: Zcash is the vault. The agent moves just what it needs
//! to whatever chain, does the job, and sweeps the change back.

use anyhow::{anyhow, Result};
use serde::{Deserialize, Serialize};

use crate::swap;

// ---------------------------------------------------------------------------
// Known EVM chain configs
// ---------------------------------------------------------------------------

#[derive(Debug, Clone)]
pub struct EvmChain {
    pub chain_id: u64,
    pub name: &'static str,
    pub rpc_url: &'static str,
    pub near_intents_blockchain: &'static str,
}

pub const BASE_MAINNET: EvmChain = EvmChain {
    chain_id: 8453,
    name: "Base",
    rpc_url: "https://mainnet.base.org",
    near_intents_blockchain: "base",
};

pub const BASE_SEPOLIA: EvmChain = EvmChain {
    chain_id: 84532,
    name: "Base Sepolia",
    rpc_url: "https://sepolia.base.org",
    near_intents_blockchain: "base",
};

pub const BSC_MAINNET: EvmChain = EvmChain {
    chain_id: 56,
    name: "BNB Smart Chain",
    rpc_url: "https://bsc-dataseed.binance.org",
    near_intents_blockchain: "bsc",
};

pub fn chain_from_network(network: &str) -> Option<EvmChain> {
    match network {
        "eip155:8453" => Some(BASE_MAINNET),
        "eip155:84532" => Some(BASE_SEPOLIA),
        "eip155:56" => Some(BSC_MAINNET),
        _ => None,
    }
}

// ---------------------------------------------------------------------------
// x402 EVM payment detection
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EvmPaymentInfo {
    pub network: String,
    pub asset_contract: String,
    pub asset_symbol: String,
    pub amount_raw: String,
    pub decimals: u32,
    pub pay_to: String,
    pub chain: EvmChainInfo,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EvmChainInfo {
    pub chain_id: u64,
    pub name: String,
    pub rpc_url: String,
    pub near_intents_blockchain: String,
}

/// Parse x402 accepts[] for an EVM chain payment (non-Zcash).
/// Returns payment info if a supported EVM chain + asset is found.
pub fn parse_evm_x402(body: &str) -> Result<EvmPaymentInfo> {
    let parsed: serde_json::Value =
        serde_json::from_str(body).map_err(|e| anyhow!("Invalid x402 JSON: {e}"))?;

    let accepts = parsed["accepts"]
        .as_array()
        .ok_or_else(|| anyhow!("No accepts[] in x402 body"))?;

    for accept in accepts {
        let network = accept["network"].as_str().unwrap_or_default();

        if let Some(chain) = chain_from_network(network) {
            let asset = accept["asset"].as_str().unwrap_or_default();
            let amount = accept["amount"].as_str().unwrap_or_default();
            let pay_to = accept["payTo"].as_str().unwrap_or_default();

            let asset_symbol = accept["extra"]["name"]
                .as_str()
                .unwrap_or("USDC")
                .to_string();

            let decimals = match asset_symbol.to_uppercase().as_str() {
                "USDC" | "USDT" => 6,
                _ => 18,
            };

            return Ok(EvmPaymentInfo {
                network: network.to_string(),
                asset_contract: asset.to_string(),
                asset_symbol,
                amount_raw: amount.to_string(),
                decimals,
                pay_to: pay_to.to_string(),
                chain: EvmChainInfo {
                    chain_id: chain.chain_id,
                    name: chain.name.to_string(),
                    rpc_url: chain.rpc_url.to_string(),
                    near_intents_blockchain: chain.near_intents_blockchain.to_string(),
                },
            });
        }
    }

    Err(anyhow!("No supported EVM chain found in x402 accepts[]"))
}

// ---------------------------------------------------------------------------
// Swap estimation
// ---------------------------------------------------------------------------

/// Calculate how much of the target token to swap for.
/// Adds a small buffer (5%) to account for swap slippage.
pub fn swap_amount_with_buffer(amount_raw: &str, decimals: u32) -> Result<f64> {
    let raw = amount_raw
        .parse::<f64>()
        .map_err(|e| anyhow!("Invalid amount: {e}"))?;
    let human = raw / 10f64.powi(decimals as i32);
    Ok(human * 1.05)
}

/// Convert a human-readable token amount to ZEC zatoshis for swap.
/// Uses NEAR Intents token prices for estimation.
pub async fn estimate_zec_needed(
    target_symbol: &str,
    target_chain: &str,
    target_amount_human: f64,
) -> Result<u64> {
    let tokens = swap::get_tokens().await?;

    let zec_token = tokens
        .iter()
        .find(|t| t.symbol.eq_ignore_ascii_case("ZEC"))
        .ok_or_else(|| anyhow!("ZEC not found in swap tokens"))?;

    let target_token = tokens
        .iter()
        .find(|t| {
            t.symbol.eq_ignore_ascii_case(target_symbol)
                && t.blockchain.eq_ignore_ascii_case(target_chain)
        })
        .ok_or_else(|| anyhow!("{} on {} not found in swap tokens", target_symbol, target_chain))?;

    if let (Some(zec_price), Some(target_price)) = (zec_token.price, target_token.price) {
        if zec_price > 0.0 {
            let zec_needed = (target_amount_human * target_price) / zec_price;
            let zatoshis = (zec_needed * 1e8 * 1.10) as u64; // 10% buffer
            return Ok(zatoshis);
        }
    }

    Err(anyhow!("Cannot estimate ZEC price for {} swap", target_symbol))
}

// ---------------------------------------------------------------------------
// ERC-20 balance (for sweep detection)
// ---------------------------------------------------------------------------

/// Get the balance of an ERC-20 token for an address on an EVM chain.
pub async fn get_erc20_balance(rpc_url: &str, token_contract: &str, owner: &str) -> Result<u128> {
    let owner_clean = owner.trim_start_matches("0x");
    let owner_bytes = hex::decode(owner_clean).map_err(|e| anyhow!("Invalid address: {e}"))?;

    // balanceOf(address) selector: 0x70a08231
    let mut data = vec![0x70, 0xa0, 0x82, 0x31];
    data.extend_from_slice(&[0u8; 12]);
    data.extend_from_slice(&owner_bytes);

    let client = reqwest::Client::new();
    let body = serde_json::json!({
        "jsonrpc": "2.0",
        "method": "eth_call",
        "params": [{
            "to": token_contract,
            "data": format!("0x{}", hex::encode(&data)),
        }, "latest"],
        "id": 1,
    });

    let resp: serde_json::Value = client
        .post(rpc_url)
        .json(&body)
        .send()
        .await
        .map_err(|e| anyhow!("RPC error: {e}"))?
        .json()
        .await
        .map_err(|e| anyhow!("RPC parse error: {e}"))?;

    let hex_str = resp["result"]
        .as_str()
        .ok_or_else(|| anyhow!("No result in balanceOf response"))?;

    let balance = u128::from_str_radix(hex_str.trim_start_matches("0x"), 16)
        .map_err(|e| anyhow!("Invalid balance hex: {e}"))?;

    Ok(balance)
}

/// Known token contract addresses for balance checking.
pub fn token_contract(symbol: &str, chain_id: u64) -> Option<&'static str> {
    match (symbol.to_uppercase().as_str(), chain_id) {
        ("USDC", 8453) => Some("0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"),
        ("USDT", 56) => Some("0x55d398326f99059fF775485246999027B3197955"),
        ("USDC", 56) => Some("0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d"),
        _ => None,
    }
}
