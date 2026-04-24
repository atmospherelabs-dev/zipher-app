//! ParaSwap DEX aggregator client for same-chain EVM swaps.
//!
//! Supports all EVM chains that ParaSwap covers (Polygon, BSC, Ethereum, Base,
//! Arbitrum, etc.) through a single API. Uses the Velora (v6.2) API.
//!
//! Flow: get_quote → approve (if ERC-20 source) → build_swap_tx → sign → broadcast → wait

use anyhow::{anyhow, Result};
use serde::Deserialize;
use tracing::info;

use crate::evm;

const PARASWAP_API: &str = "https://api.paraswap.io";
const PARTNER: &str = "zipher";

// ---------------------------------------------------------------------------
// API response types
// ---------------------------------------------------------------------------

#[derive(Debug, Deserialize)]
pub struct PriceRoute {
    #[serde(rename = "blockNumber")]
    pub block_number: Option<u64>,
    #[serde(rename = "srcToken")]
    pub src_token: String,
    #[serde(rename = "srcDecimals")]
    pub src_decimals: u32,
    #[serde(rename = "srcAmount")]
    pub src_amount: String,
    #[serde(rename = "destToken")]
    pub dest_token: String,
    #[serde(rename = "destDecimals")]
    pub dest_decimals: u32,
    #[serde(rename = "destAmount")]
    pub dest_amount: String,
    #[serde(rename = "gasCost")]
    pub gas_cost: Option<String>,
    #[serde(rename = "bestRoute")]
    pub best_route: Option<serde_json::Value>,
    #[serde(rename = "tokenTransferProxy")]
    pub token_transfer_proxy: Option<String>,
    #[serde(rename = "contractAddress")]
    pub contract_address: Option<String>,
}

#[derive(Debug, Deserialize)]
struct PriceResponse {
    #[serde(rename = "priceRoute")]
    price_route: PriceRoute,
}

#[derive(Debug, Clone)]
pub struct SwapQuote {
    pub src_token: String,
    pub src_decimals: u32,
    pub src_amount: String,
    pub dest_token: String,
    pub dest_decimals: u32,
    pub dest_amount: String,
    pub price_route_json: serde_json::Value,
    pub token_transfer_proxy: String,
    pub contract_address: String,
}

#[derive(Debug, Deserialize)]
#[allow(dead_code)]
struct TxResponse {
    to: String,
    data: String,
    value: String,
    #[serde(rename = "gasPrice")]
    gas_price: Option<String>,
    gas: Option<String>,
    #[serde(rename = "chainId")]
    chain_id: Option<u64>,
}

#[derive(Debug, Clone)]
pub struct SwapTx {
    pub to: String,
    pub data: Vec<u8>,
    pub value_wei: Vec<u8>,
    pub gas_estimate: u64,
}

// ---------------------------------------------------------------------------
// ParaSwap API calls
// ---------------------------------------------------------------------------

pub async fn get_quote(
    chain_id: u64,
    src_token: &str,
    src_decimals: u32,
    dest_token: &str,
    dest_decimals: u32,
    amount: &str,
    user_address: &str,
) -> Result<SwapQuote> {
    let client = reqwest::Client::new();
    let url = format!(
        "{}/prices?srcToken={}&srcDecimals={}&destToken={}&destDecimals={}&amount={}&network={}&side=SELL&partner={}&userAddress={}",
        PARASWAP_API,
        src_token, src_decimals,
        dest_token, dest_decimals,
        amount, chain_id,
        PARTNER, user_address,
    );

    info!("ParaSwap quote: {}", url);

    let resp = client
        .get(&url)
        .header("accept", "application/json")
        .send()
        .await
        .map_err(|e| anyhow!("ParaSwap quote request failed: {e}"))?;

    let status = resp.status();
    let text = resp.text().await.unwrap_or_default();

    if !status.is_success() {
        return Err(anyhow!("ParaSwap /prices returned {}: {}", status, &text[..text.len().min(500)]));
    }

    let parsed: PriceResponse = serde_json::from_str(&text)
        .map_err(|e| anyhow!("Failed to parse ParaSwap quote: {e} — body: {}", &text[..text.len().min(300)]))?;

    let pr = parsed.price_route;
    let full_json: serde_json::Value = serde_json::from_str(&text)?;

    Ok(SwapQuote {
        src_token: pr.src_token,
        src_decimals: pr.src_decimals,
        src_amount: pr.src_amount,
        dest_token: pr.dest_token,
        dest_decimals: pr.dest_decimals,
        dest_amount: pr.dest_amount,
        price_route_json: full_json["priceRoute"].clone(),
        token_transfer_proxy: pr.token_transfer_proxy.unwrap_or_default(),
        contract_address: pr.contract_address.unwrap_or_default(),
    })
}

pub async fn build_swap_tx(
    chain_id: u64,
    quote: &SwapQuote,
    user_address: &str,
    slippage_bps: u32,
) -> Result<SwapTx> {
    let client = reqwest::Client::new();
    let url = format!("{}/transactions/{}?ignoreChecks=true", PARASWAP_API, chain_id);

    let body = serde_json::json!({
        "srcToken": quote.src_token,
        "srcDecimals": quote.src_decimals,
        "srcAmount": quote.src_amount,
        "destToken": quote.dest_token,
        "destDecimals": quote.dest_decimals,
        "slippage": slippage_bps,
        "userAddress": user_address,
        "partner": PARTNER,
        "priceRoute": quote.price_route_json,
    });

    info!("ParaSwap build tx for chain {}", chain_id);

    let resp = client
        .post(&url)
        .header("accept", "application/json")
        .header("content-type", "application/json")
        .json(&body)
        .send()
        .await
        .map_err(|e| anyhow!("ParaSwap /transactions failed: {e}"))?;

    let status = resp.status();
    let text = resp.text().await.unwrap_or_default();

    if !status.is_success() {
        return Err(anyhow!("ParaSwap /transactions returned {}: {}", status, &text[..text.len().min(500)]));
    }

    let tx_resp: TxResponse = serde_json::from_str(&text)
        .map_err(|e| anyhow!("Failed to parse ParaSwap tx: {e} — body: {}", &text[..text.len().min(300)]))?;

    let data_clean = tx_resp.data.trim_start_matches("0x");
    let data_bytes = hex::decode(data_clean).map_err(|e| anyhow!("Bad tx data hex: {e}"))?;

    // ParaSwap returns value as decimal string; only parse as hex if 0x-prefixed
    let value_u128 = if tx_resp.value.starts_with("0x") {
        u128::from_str_radix(tx_resp.value.trim_start_matches("0x"), 16).unwrap_or(0)
    } else {
        tx_resp.value.parse::<u128>().unwrap_or(0)
    };
    let value_bytes = evm::u128_to_be_trimmed(value_u128);

    // gas can be decimal or hex
    let gas_estimate = tx_resp
        .gas
        .as_deref()
        .and_then(|g| {
            if g.starts_with("0x") {
                u64::from_str_radix(g.trim_start_matches("0x"), 16).ok()
            } else {
                g.parse::<u64>().ok()
            }
        })
        .unwrap_or(500_000);

    Ok(SwapTx {
        to: tx_resp.to,
        data: data_bytes,
        value_wei: value_bytes,
        gas_estimate,
    })
}

// ---------------------------------------------------------------------------
// Full swap orchestration
// ---------------------------------------------------------------------------

pub struct SwapParams {
    pub rpc_url: String,
    pub seed_phrase: String,
    pub chain_id: u64,
    pub user_address: String,
    pub src_token: String,
    pub src_decimals: u32,
    pub dest_token: String,
    pub dest_decimals: u32,
    pub amount_raw: String,
    pub slippage_bps: u32,
}

pub struct SwapResult {
    pub tx_hash: String,
    pub receipt: evm::TxReceipt,
    pub src_amount: String,
    pub dest_amount_expected: String,
}

/// Execute a full same-chain swap: quote → approve → build → sign → broadcast → wait.
///
/// Prints step-by-step diagnostics for CLI debugging.
pub async fn execute_swap(params: &SwapParams) -> Result<SwapResult> {
    // Step 1: Quote
    info!("[swap] Getting quote...");
    let quote = get_quote(
        params.chain_id,
        &params.src_token,
        params.src_decimals,
        &params.dest_token,
        params.dest_decimals,
        &params.amount_raw,
        &params.user_address,
    ).await?;

    let dest_human = evm::format_token_amount(
        quote.dest_amount.parse::<u128>().unwrap_or(0),
        quote.dest_decimals as u8,
    );
    info!("[swap] Quote: {} -> {} (expected output)", params.amount_raw, dest_human);

    // Step 2: Approve if source is ERC-20 (not native token)
    let is_native = params.src_token.eq_ignore_ascii_case(evm::PARASWAP_NATIVE);
    if !is_native && !quote.token_transfer_proxy.is_empty() {
        let allowance = evm::get_erc20_allowance(
            &params.rpc_url,
            &params.src_token,
            &params.user_address,
            &quote.token_transfer_proxy,
        ).await.unwrap_or(0);

        let needed: u128 = params.amount_raw.parse().unwrap_or(0);
        if allowance < needed {
            info!("[swap] Allowance {} < needed {}, approving...", allowance, needed);
            let fees = evm::suggest_eip1559_fees(&params.rpc_url, params.chain_id).await?;
            evm::approve_erc20(
                &params.rpc_url,
                &params.seed_phrase,
                &params.user_address,
                &params.src_token,
                &quote.token_transfer_proxy,
                u128::MAX,
                params.chain_id,
                &fees,
            ).await?;
        } else {
            info!("[swap] Allowance sufficient ({})", allowance);
        }
    }

    // Step 3: Build swap tx
    info!("[swap] Building swap transaction...");
    let swap_tx = build_swap_tx(
        params.chain_id,
        &quote,
        &params.user_address,
        params.slippage_bps,
    ).await?;

    // Step 4: Dynamic gas fees
    info!("[swap] Fetching dynamic gas fees...");
    let fees = evm::suggest_eip1559_fees(&params.rpc_url, params.chain_id).await?;
    info!("[swap] Fees: {}", fees);

    // Step 5: Get nonce
    let nonce = evm::get_nonce(&params.rpc_url, &params.user_address).await?;
    info!("[swap] Nonce: {}", nonce);

    // Step 6: Build unsigned EIP-1559 tx
    let gas_with_buffer = swap_tx.gas_estimate + swap_tx.gas_estimate / 5; // +20%
    info!("[swap] Gas limit: {} (estimate {} + 20%)", gas_with_buffer, swap_tx.gas_estimate);

    let unsigned = evm::build_unsigned_eip1559_tx(
        params.chain_id,
        nonce,
        fees.max_priority_fee_per_gas,
        fees.max_fee_per_gas,
        gas_with_buffer,
        &swap_tx.to,
        &swap_tx.value_wei,
        &swap_tx.data,
    );

    info!("[swap] Unsigned tx hex ({} bytes): 0x{}", unsigned.len(), hex::encode(&unsigned));

    // Step 7: Sign and broadcast
    info!("[swap] Signing with OWS and broadcasting...");
    let tx_hash = evm::sign_and_broadcast(
        &params.seed_phrase,
        &unsigned,
        &params.rpc_url,
    ).await?;

    info!("[swap] Broadcast OK — tx hash: {}", tx_hash);

    // Step 8: Wait for receipt
    info!("[swap] Waiting for receipt (timeout: 120s)...");
    let receipt = evm::wait_for_receipt(&params.rpc_url, &tx_hash, 120).await?;

    if receipt.status {
        info!("[swap] SUCCESS — block {}, gas used: {}", receipt.block_number, receipt.gas_used);
    } else {
        info!("[swap] REVERTED — block {}, gas used: {}", receipt.block_number, receipt.gas_used);
        return Err(anyhow!("Swap transaction reverted (block {})", receipt.block_number));
    }

    Ok(SwapResult {
        tx_hash,
        receipt,
        src_amount: quote.src_amount.clone(),
        dest_amount_expected: quote.dest_amount.clone(),
    })
}
