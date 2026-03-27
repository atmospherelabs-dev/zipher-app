use anyhow::{anyhow, Result};
use base64::{engine::general_purpose::URL_SAFE_NO_PAD as B64URL, Engine as _};
use serde::{Deserialize, Serialize};

// ---------------------------------------------------------------------------
// MPP (Machine Payments Protocol) client
//
// Implements the client side of draft-httpauth-payment-00:
//   WWW-Authenticate: Payment id="...", method="zcash", intent="charge", request="..."
//   Authorization: Payment <base64url credential>
//   Payment-Receipt: <base64url receipt>
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MppChallenge {
    pub id: String,
    pub realm: String,
    pub method: String,
    pub intent: String,
    pub request: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub expires: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub digest: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub opaque: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct MppChargeRequest {
    pub amount: String,
    pub currency: String,
    #[serde(default)]
    pub recipient: Option<String>,
    #[serde(default)]
    pub description: Option<String>,
    #[serde(default, rename = "externalId")]
    pub external_id: Option<String>,
    #[serde(default, rename = "methodDetails")]
    pub method_details: Option<serde_json::Value>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct MppReceipt {
    pub status: String,
    pub method: String,
    pub timestamp: String,
    #[serde(default)]
    pub reference: Option<String>,
}

#[derive(Debug, Serialize)]
struct MppCredential {
    challenge: MppChallenge,
    payload: MppPayload,
}

#[derive(Debug, Serialize)]
struct MppPayload {
    txid: String,
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Parse a `WWW-Authenticate: Payment` header value into an MppChallenge.
///
/// Format: `Payment id="...", realm="...", method="...", intent="...", request="..."`
pub fn parse_www_authenticate(header_value: &str) -> Result<MppChallenge> {
    let trimmed = header_value.trim();

    let params_str = trimmed
        .strip_prefix("Payment")
        .or_else(|| trimmed.strip_prefix("payment"))
        .ok_or_else(|| anyhow!("WWW-Authenticate header does not use Payment scheme"))?
        .trim();

    let params = parse_auth_params(params_str)?;

    let id = params
        .get("id")
        .ok_or_else(|| anyhow!("Missing 'id' in Payment challenge"))?
        .clone();
    let realm = params
        .get("realm")
        .ok_or_else(|| anyhow!("Missing 'realm' in Payment challenge"))?
        .clone();
    let method = params
        .get("method")
        .ok_or_else(|| anyhow!("Missing 'method' in Payment challenge"))?
        .clone();
    let intent = params
        .get("intent")
        .ok_or_else(|| anyhow!("Missing 'intent' in Payment challenge"))?
        .clone();
    let request = params
        .get("request")
        .ok_or_else(|| anyhow!("Missing 'request' in Payment challenge"))?
        .clone();

    Ok(MppChallenge {
        id,
        realm,
        method,
        intent,
        request,
        expires: params.get("expires").cloned(),
        description: params.get("description").cloned(),
        digest: params.get("digest").cloned(),
        opaque: params.get("opaque").cloned(),
    })
}

/// Decode the `request` field (base64url JSON) from the challenge and extract
/// the Zcash charge parameters.
pub fn decode_charge_request(challenge: &MppChallenge) -> Result<MppChargeRequest> {
    if challenge.intent != "charge" {
        return Err(anyhow!(
            "Unsupported MPP intent '{}' (expected 'charge')",
            challenge.intent
        ));
    }

    let json_bytes = B64URL
        .decode(&challenge.request)
        .map_err(|e| anyhow!("Invalid base64url in request: {}", e))?;
    let req: MppChargeRequest = serde_json::from_slice(&json_bytes)
        .map_err(|e| anyhow!("Invalid charge request JSON: {}", e))?;

    Ok(req)
}

/// Extract the payment amount in zatoshis from charge request.
pub fn charge_amount_zatoshis(req: &MppChargeRequest) -> Result<u64> {
    req.amount
        .parse()
        .map_err(|_| anyhow!("Invalid amount '{}': expected zatoshis", req.amount))
}

/// Extract the recipient address from charge request.
pub fn charge_recipient(req: &MppChargeRequest) -> Result<String> {
    req.recipient
        .clone()
        .ok_or_else(|| anyhow!("No recipient in MPP charge request"))
}

/// Build the `Authorization: Payment` header value (base64url credential JSON).
pub fn build_credential(challenge: &MppChallenge, txid: &str) -> String {
    let credential = MppCredential {
        challenge: challenge.clone(),
        payload: MppPayload {
            txid: txid.to_string(),
        },
    };
    let json = serde_json::to_string(&credential).expect("MppCredential is always serializable");
    B64URL.encode(json.as_bytes())
}

/// Parse a `Payment-Receipt` header value (base64url JSON).
pub fn parse_receipt(header_value: &str) -> Result<MppReceipt> {
    let json_bytes = B64URL
        .decode(header_value.trim())
        .map_err(|e| anyhow!("Invalid base64url in Payment-Receipt: {}", e))?;
    let receipt: MppReceipt = serde_json::from_slice(&json_bytes)
        .map_err(|e| anyhow!("Invalid receipt JSON: {}", e))?;
    Ok(receipt)
}

/// Check if a method string matches Zcash (case-insensitive).
pub fn is_zcash_method(method: &str) -> bool {
    method.eq_ignore_ascii_case("zcash")
}

// ---------------------------------------------------------------------------
// Auth param parser (RFC 9110 style)
// ---------------------------------------------------------------------------

fn parse_auth_params(input: &str) -> Result<std::collections::HashMap<String, String>> {
    let mut params = std::collections::HashMap::new();
    let mut remaining = input.trim();

    while !remaining.is_empty() {
        remaining = remaining.trim_start_matches(|c: char| c == ',' || c.is_whitespace());
        if remaining.is_empty() {
            break;
        }

        let eq_pos = remaining
            .find('=')
            .ok_or_else(|| anyhow!("Malformed auth-param: no '=' found in '{}'", remaining))?;
        let key = remaining[..eq_pos].trim().to_lowercase();
        remaining = remaining[eq_pos + 1..].trim();

        let value;
        if remaining.starts_with('"') {
            remaining = &remaining[1..];
            let mut end = 0;
            let mut escaped = false;
            for (i, c) in remaining.char_indices() {
                if escaped {
                    escaped = false;
                    continue;
                }
                if c == '\\' {
                    escaped = true;
                    continue;
                }
                if c == '"' {
                    end = i;
                    break;
                }
            }
            value = remaining[..end].to_string();
            remaining = &remaining[end + 1..];
        } else {
            let end = remaining
                .find(|c: char| c == ',' || c.is_whitespace())
                .unwrap_or(remaining.len());
            value = remaining[..end].to_string();
            remaining = &remaining[end..];
        }

        params.insert(key, value);
    }

    Ok(params)
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_payment_challenge() {
        let header = r#"Payment id="abc123", realm="api.example.com", method="zcash", intent="charge", request="eyJhbW91bnQiOiIxMDAwMDAiLCJjdXJyZW5jeSI6InplYyIsInJlY2lwaWVudCI6InUxdGVzdCJ9""#;
        let challenge = parse_www_authenticate(header).unwrap();
        assert_eq!(challenge.id, "abc123");
        assert_eq!(challenge.realm, "api.example.com");
        assert_eq!(challenge.method, "zcash");
        assert_eq!(challenge.intent, "charge");
        assert!(is_zcash_method(&challenge.method));
    }

    #[test]
    fn decode_charge_and_build_credential() {
        let request_json = r#"{"amount":"100000","currency":"zec","recipient":"u1test"}"#;
        let request_b64 = B64URL.encode(request_json.as_bytes());
        let challenge = MppChallenge {
            id: "test-id".into(),
            realm: "test.com".into(),
            method: "zcash".into(),
            intent: "charge".into(),
            request: request_b64,
            expires: None,
            description: None,
            digest: None,
            opaque: None,
        };

        let req = decode_charge_request(&challenge).unwrap();
        assert_eq!(charge_amount_zatoshis(&req).unwrap(), 100_000);
        assert_eq!(charge_recipient(&req).unwrap(), "u1test");

        let cred = build_credential(&challenge, "txid_abc");
        let decoded = B64URL.decode(&cred).unwrap();
        let json: serde_json::Value = serde_json::from_slice(&decoded).unwrap();
        assert_eq!(json["payload"]["txid"], "txid_abc");
        assert_eq!(json["challenge"]["id"], "test-id");
    }

    #[test]
    fn parse_receipt() {
        let receipt_json = r#"{"status":"success","method":"zcash","timestamp":"2026-03-25T12:00:00Z","reference":"txid_abc"}"#;
        let receipt_b64 = B64URL.encode(receipt_json.as_bytes());
        let receipt = super::parse_receipt(&receipt_b64).unwrap();
        assert_eq!(receipt.status, "success");
        assert_eq!(receipt.reference.unwrap(), "txid_abc");
    }

    #[test]
    fn non_zcash_method() {
        assert!(!is_zcash_method("tempo"));
        assert!(!is_zcash_method("stripe"));
        assert!(is_zcash_method("Zcash"));
        assert!(is_zcash_method("ZCASH"));
    }
}
