use anyhow::{anyhow, Result};
use base64::{engine::general_purpose::STANDARD as B64, Engine as _};
use serde::{Deserialize, Serialize};

// ---------------------------------------------------------------------------
// x402 protocol types — matches @cipherpay/x402 PaymentRequired schema
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PaymentRequired {
    pub x402_version: u8,
    #[serde(default)]
    pub resource: Option<ResourceInfo>,
    pub accepts: Vec<PaymentRequirements>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ResourceInfo {
    pub url: Option<String>,
    pub description: Option<String>,
    pub mime_type: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PaymentRequirements {
    pub scheme: String,
    pub network: String,
    pub asset: String,
    pub amount: String,
    pub pay_to: String,
    pub max_timeout_seconds: u64,
    #[serde(default)]
    pub extra: Option<serde_json::Value>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct PaymentPayload {
    x402_version: u8,
    accepted: PaymentRequirements,
    payload: TxPayload,
}

#[derive(Debug, Serialize)]
struct TxPayload {
    txid: String,
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Parse an HTTP 402 response body and extract the Zcash payment requirements.
///
/// `expected_network` should be `"zcash:mainnet"` or `"zcash:testnet"`.
/// Returns the first matching `accepts[]` entry.
pub fn parse_402_response(
    json: &str,
    expected_network: &str,
) -> Result<PaymentRequirements> {
    let body: PaymentRequired =
        serde_json::from_str(json).map_err(|e| anyhow!("Invalid x402 body: {e}"))?;

    if body.x402_version != 2 {
        return Err(anyhow!(
            "Unsupported x402 version: {} (expected 2)",
            body.x402_version
        ));
    }

    let req = body
        .accepts
        .into_iter()
        .find(|a| a.network == expected_network && a.asset.eq_ignore_ascii_case("ZEC"))
        .ok_or_else(|| {
            anyhow!(
                "No Zcash payment option found for network '{expected_network}'"
            )
        })?;

    let _amount: u64 = req
        .amount
        .parse()
        .map_err(|_| anyhow!("Invalid amount '{}': expected zatoshis as integer string", req.amount))?;

    if req.pay_to.is_empty() {
        return Err(anyhow!("payTo address is empty"));
    }

    Ok(req)
}

/// Extract the payment amount in zatoshis from a `PaymentRequirements`.
pub fn amount_zatoshis(req: &PaymentRequirements) -> Result<u64> {
    req.amount
        .parse()
        .map_err(|_| anyhow!("Invalid amount '{}'", req.amount))
}

/// Build the base64-encoded `PAYMENT-SIGNATURE` header value from a txid
/// and the payment requirements that were fulfilled.
pub fn build_payment_signature(txid: &str, requirements: &PaymentRequirements) -> String {
    let payload = PaymentPayload {
        x402_version: 2,
        accepted: requirements.clone(),
        payload: TxPayload {
            txid: txid.to_string(),
        },
    };
    let json = serde_json::to_string(&payload).expect("PaymentPayload is always serializable");
    B64.encode(json.as_bytes())
}

#[cfg(test)]
mod tests {
    use super::*;

    const SAMPLE_402: &str = r#"{
        "x402Version": 2,
        "resource": { "url": "/api/data" },
        "accepts": [{
            "scheme": "exact",
            "network": "zcash:mainnet",
            "asset": "ZEC",
            "amount": "100000",
            "payTo": "u1testaddress",
            "maxTimeoutSeconds": 120,
            "extra": {}
        }]
    }"#;

    #[test]
    fn parse_valid_402() {
        let req = parse_402_response(SAMPLE_402, "zcash:mainnet").unwrap();
        assert_eq!(req.pay_to, "u1testaddress");
        assert_eq!(amount_zatoshis(&req).unwrap(), 100_000);
    }

    #[test]
    fn parse_wrong_network() {
        let err = parse_402_response(SAMPLE_402, "zcash:testnet").unwrap_err();
        assert!(err.to_string().contains("No Zcash payment option"));
    }

    #[test]
    fn build_signature_roundtrip() {
        let req = parse_402_response(SAMPLE_402, "zcash:mainnet").unwrap();
        let sig = build_payment_signature("abcd1234", &req);
        let decoded = B64.decode(&sig).unwrap();
        let json: serde_json::Value = serde_json::from_slice(&decoded).unwrap();
        assert_eq!(json["payload"]["txid"], "abcd1234");
        assert_eq!(json["x402Version"], 2);
        assert_eq!(json["accepted"]["payTo"], "u1testaddress");
    }
}
