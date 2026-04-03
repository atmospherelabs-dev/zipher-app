use anyhow::{anyhow, Result};
use serde::{Deserialize, Serialize};

// ---------------------------------------------------------------------------
// Near Intents swap client — ported from lib/services/near_intents.dart
// ---------------------------------------------------------------------------

const BASE_URL: &str = "https://1click.chaindefuser.com/v0";
const AFFILIATE_ADDRESS: &str = "cipherscan.near";
const AFFILIATE_FEE_BPS: u32 = 50;
const REFERRAL: &str = "zipher";
const QUOTE_WAITING_TIME_MS: u32 = 3000;

const DEFAULT_API_KEY: &str = "eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCIsImtpZCI6IjIwMjUtMDEtMTItdjEifQ.eyJ2IjoxLCJrZXlfdHlwZSI6ImRpc3RyaWJ1dGlvbl9jaGFubmVsIiwicGFydG5lcl9pZCI6ImNpcGhlcnNjYW4iLCJpYXQiOjE3NzEzMTg2NjEsImV4cCI6MTgwMjg1NDY2MX0.Lcyle1wo7WnNT8eXrL7oOk3cpZakyjkGqBYjCpoFCkxtQC_Et1FE_3mK0nRODoYwutOuDPkw-JIRl47hmGhSmdCl-5r8R3Tw4LrQk-UY0g5a6WWfyjlrqTPeyexnRyKN-ry6Mm3kDwJm4g9uDxUFhea11lOnbNyD4SyuWRi_6Tp3Ch_ucTV2O6il5m8ZRhWi3yKV9yl4SUf324chPtLefwiTxJB-psA05vU0jurKpjO18t37Vuty6On1rgAQqMfm_h2KOwtjxhFk5ey5vk6dvfMfTsvsH08_bYeK45nLihtDtsPyKQKV1snhSwyjdzWZB5R5fZHSn7x4gw_bEf91FA";

fn api_key() -> String {
    std::env::var("NEAR_INTENTS_KEY").unwrap_or_else(|_| DEFAULT_API_KEY.to_string())
}

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SwapToken {
    #[serde(alias = "defuseAssetId", alias = "assetId")]
    pub asset_id: String,
    pub symbol: String,
    pub blockchain: String,
    pub decimals: u32,
    #[serde(default)]
    pub price: Option<f64>,
    #[serde(default)]
    pub icon: Option<String>,
}

impl SwapToken {
    pub fn display_name(&self) -> String {
        format!("{} ({})", self.symbol, self.blockchain.to_uppercase())
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SwapQuote {
    pub deposit_address: String,
    pub amount_in: String,
    pub amount_out: String,
    #[serde(default)]
    pub min_amount_out: Option<String>,
    pub deadline: String,
    #[serde(default)]
    pub origin_asset: Option<String>,
    #[serde(default)]
    pub destination_asset: Option<String>,
    #[serde(default)]
    pub recipient: Option<String>,
    #[serde(default)]
    pub refund_to: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SwapStatus {
    pub status: String,
    #[serde(default, rename = "txHashIn")]
    pub tx_hash_in: Option<String>,
    #[serde(default, rename = "txHashOut")]
    pub tx_hash_out: Option<String>,
}

impl SwapStatus {
    pub fn is_pending(&self) -> bool {
        self.status == "PENDING" || self.status == "PENDING_DEPOSIT"
    }
    pub fn is_processing(&self) -> bool {
        self.status == "PROCESSING" || self.status == "CONFIRMING"
    }
    pub fn is_success(&self) -> bool {
        self.status == "SUCCESS" || self.status == "COMPLETED"
    }
    pub fn is_failed(&self) -> bool {
        self.status == "FAILED" || self.status == "EXPIRED"
    }
    pub fn is_refunded(&self) -> bool {
        self.status == "REFUNDED"
    }
    pub fn is_terminal(&self) -> bool {
        self.is_success() || self.is_failed() || self.is_refunded()
    }
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

fn client() -> reqwest::Client {
    reqwest::Client::new()
}

fn auth_headers() -> reqwest::header::HeaderMap {
    let mut headers = reqwest::header::HeaderMap::new();
    headers.insert(
        reqwest::header::CONTENT_TYPE,
        "application/json".parse().unwrap(),
    );
    let key = api_key();
    if !key.is_empty() {
        headers.insert(
            reqwest::header::AUTHORIZATION,
            format!("Bearer {key}").parse().unwrap(),
        );
    }
    headers
}

/// Fetch available swap tokens from Near Intents.
pub async fn get_tokens() -> Result<Vec<SwapToken>> {
    let resp = client()
        .get(format!("{BASE_URL}/tokens"))
        .headers(auth_headers())
        .send()
        .await
        .map_err(|e| anyhow!("Failed to fetch tokens: {e}"))?;

    if !resp.status().is_success() {
        let status = resp.status();
        let body = resp.text().await.unwrap_or_default();
        return Err(anyhow!("Token fetch failed ({}): {}", status, body));
    }

    let tokens: Vec<SwapToken> = resp
        .json()
        .await
        .map_err(|e| anyhow!("Failed to parse tokens: {e}"))?;
    Ok(tokens)
}

/// Find the ZEC token from the token list.
pub fn find_zec_token(tokens: &[SwapToken]) -> Option<&SwapToken> {
    tokens.iter().find(|t| t.symbol.eq_ignore_ascii_case("ZEC"))
}

/// Filter tokens to only those swappable (non-ZEC, with price).
pub fn swappable_tokens(tokens: &[SwapToken]) -> Vec<&SwapToken> {
    let mut list: Vec<&SwapToken> = tokens
        .iter()
        .filter(|t| {
            !t.symbol.eq_ignore_ascii_case("ZEC")
                && t.price.map_or(false, |p| p > 0.0)
        })
        .collect();
    list.sort_by(|a, b| a.symbol.cmp(&b.symbol));
    list
}

/// Request a swap quote from Near Intents.
///
/// `origin_asset` / `destination_asset` are the full defuse asset IDs.
/// `amount` is in the smallest unit of the origin asset.
/// `recipient` is the destination chain address.
/// `refund_to` is the origin chain refund address.
pub async fn get_quote(
    origin_asset: &str,
    destination_asset: &str,
    amount: &str,
    recipient: &str,
    refund_to: &str,
    slippage_bps: u32,
) -> Result<SwapQuote> {
    let deadline = chrono_deadline(2);

    let body = serde_json::json!({
        "dry": false,
        "swapType": "EXACT_INPUT",
        "slippageTolerance": slippage_bps,
        "originAsset": origin_asset,
        "depositType": "ORIGIN_CHAIN",
        "destinationAsset": destination_asset,
        "amount": amount,
        "refundTo": refund_to,
        "refundType": "ORIGIN_CHAIN",
        "recipient": recipient,
        "recipientType": "DESTINATION_CHAIN",
        "deadline": deadline,
        "quoteWaitingTimeMs": QUOTE_WAITING_TIME_MS,
        "appFees": [{
            "recipient": AFFILIATE_ADDRESS,
            "fee": AFFILIATE_FEE_BPS,
        }],
        "referral": REFERRAL,
    });

    let resp = client()
        .post(format!("{BASE_URL}/quote"))
        .headers(auth_headers())
        .json(&body)
        .send()
        .await
        .map_err(|e| anyhow!("Quote request failed: {e}"))?;

    if !resp.status().is_success() {
        let status = resp.status();
        let text = resp.text().await.unwrap_or_default();
        let msg = try_parse_error(&text).unwrap_or(format!("Quote failed ({})", status));
        return Err(anyhow!("{}", msg));
    }

    let json: serde_json::Value = resp
        .json()
        .await
        .map_err(|e| anyhow!("Failed to parse quote: {e}"))?;

    let quote = json.get("quote").unwrap_or(&json);
    let request = json.get("quoteRequest").cloned().unwrap_or(serde_json::json!({}));

    let deposit_address = quote
        .get("depositAddress")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();

    let amount_in = request
        .get("amount")
        .or_else(|| quote.get("amountIn"))
        .and_then(|v| v.as_str().or_else(|| v.as_u64().map(|_| "0")))
        .unwrap_or("0")
        .to_string();

    let amount_out = quote
        .get("amountOut")
        .and_then(|v| v.as_str().or_else(|| v.as_u64().map(|_| "0")))
        .unwrap_or("0")
        .to_string();

    let min_amount_out = quote
        .get("minAmountOut")
        .and_then(|v| v.as_str())
        .map(|s| s.to_string());

    let deadline_str = request
        .get("deadline")
        .or_else(|| quote.get("deadline"))
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();

    Ok(SwapQuote {
        deposit_address,
        amount_in,
        amount_out,
        min_amount_out,
        deadline: deadline_str,
        origin_asset: Some(origin_asset.to_string()),
        destination_asset: Some(destination_asset.to_string()),
        recipient: Some(recipient.to_string()),
        refund_to: Some(refund_to.to_string()),
    })
}

/// Notify Near Intents that a deposit has been made.
pub async fn submit_deposit(tx_hash: &str, deposit_address: &str) -> Result<()> {
    let body = serde_json::json!({
        "txHash": tx_hash,
        "depositAddress": deposit_address,
    });

    let resp = client()
        .post(format!("{BASE_URL}/deposit/submit"))
        .headers(auth_headers())
        .json(&body)
        .send()
        .await
        .map_err(|e| anyhow!("Deposit submit failed: {e}"))?;

    if !resp.status().is_success() {
        let status = resp.status();
        let text = resp.text().await.unwrap_or_default();
        return Err(anyhow!("Deposit submit failed ({}): {}", status, text));
    }

    Ok(())
}

/// Check the status of a swap by deposit address.
pub async fn get_status(deposit_address: &str) -> Result<SwapStatus> {
    let resp = client()
        .get(format!(
            "{BASE_URL}/status?depositAddress={deposit_address}"
        ))
        .headers(auth_headers())
        .send()
        .await
        .map_err(|e| anyhow!("Status check failed: {e}"))?;

    if !resp.status().is_success() {
        let status = resp.status();
        let text = resp.text().await.unwrap_or_default();
        return Err(anyhow!("Status check failed ({}): {}", status, text));
    }

    let status: SwapStatus = resp
        .json()
        .await
        .map_err(|e| anyhow!("Failed to parse status: {e}"))?;
    Ok(status)
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn chrono_deadline(hours: u64) -> String {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs();
    let deadline = now + hours * 3600;

    let secs = deadline;
    let days = secs / 86400;
    let time_secs = secs % 86400;
    let hours_of_day = time_secs / 3600;
    let minutes = (time_secs % 3600) / 60;
    let seconds = time_secs % 60;

    // Approximate year/month/day from days since epoch (sufficient for deadline)
    let (year, month, day) = days_to_ymd(days);

    format!(
        "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}Z",
        year, month, day, hours_of_day, minutes, seconds
    )
}

fn days_to_ymd(mut days: u64) -> (u64, u64, u64) {
    // Algorithm from http://howardhinnant.github.io/date_algorithms.html
    days += 719468;
    let era = days / 146097;
    let doe = days - era * 146097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = if m <= 2 { y + 1 } else { y };
    (y, m, d)
}

fn try_parse_error(body: &str) -> Option<String> {
    let json: serde_json::Value = serde_json::from_str(body).ok()?;
    json.get("message")
        .or_else(|| json.get("error"))
        .and_then(|v| v.as_str())
        .map(|s| s.to_string())
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn find_zec_in_token_list() {
        let tokens = vec![
            SwapToken {
                asset_id: "nep141:zec.near".into(),
                symbol: "ZEC".into(),
                blockchain: "zec".into(),
                decimals: 8,
                price: Some(35.0),
                icon: None,
            },
            SwapToken {
                asset_id: "nep141:usdc.near".into(),
                symbol: "USDC".into(),
                blockchain: "eth".into(),
                decimals: 6,
                price: Some(1.0),
                icon: None,
            },
        ];

        assert!(find_zec_token(&tokens).is_some());
        assert_eq!(swappable_tokens(&tokens).len(), 1);
    }

    #[test]
    fn status_states() {
        let pending = SwapStatus {
            status: "PENDING".into(),
            tx_hash_in: None,
            tx_hash_out: None,
        };
        assert!(pending.is_pending());
        assert!(!pending.is_terminal());

        let success = SwapStatus {
            status: "COMPLETED".into(),
            tx_hash_in: Some("abc".into()),
            tx_hash_out: Some("def".into()),
        };
        assert!(success.is_success());
        assert!(success.is_terminal());
    }

    #[test]
    fn deadline_format() {
        let d = chrono_deadline(2);
        assert!(d.ends_with('Z'));
        assert!(d.contains('T'));
        assert_eq!(d.len(), 20);
    }
}
