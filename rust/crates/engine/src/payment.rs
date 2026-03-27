use anyhow::{anyhow, Result};
use std::collections::HashMap;

use crate::{mpp, x402};

// ---------------------------------------------------------------------------
// Unified payment protocol handler — auto-detects x402 vs MPP
// ---------------------------------------------------------------------------

/// Represents a parsed 402 payment challenge, regardless of protocol.
#[derive(Debug, Clone)]
pub enum PaymentProtocol {
    X402 {
        requirements: x402::PaymentRequirements,
    },
    Mpp {
        challenge: mpp::MppChallenge,
        charge: mpp::MppChargeRequest,
    },
}

/// Common payment info extracted from either protocol.
#[derive(Debug, Clone, serde::Serialize)]
pub struct PaymentInfo {
    pub protocol: String,
    pub address: String,
    pub amount: u64,
}

impl PaymentProtocol {
    /// Extract the destination address.
    pub fn address(&self) -> Result<String> {
        match self {
            PaymentProtocol::X402 { requirements } => Ok(requirements.pay_to.clone()),
            PaymentProtocol::Mpp { charge, .. } => mpp::charge_recipient(charge),
        }
    }

    /// Extract the amount in zatoshis.
    pub fn amount_zatoshis(&self) -> Result<u64> {
        match self {
            PaymentProtocol::X402 { requirements } => x402::amount_zatoshis(requirements),
            PaymentProtocol::Mpp { charge, .. } => mpp::charge_amount_zatoshis(charge),
        }
    }

    /// Build the credential header for the retry request.
    /// Returns `(header_name, header_value)`.
    pub fn build_credential(&self, txid: &str) -> (String, String) {
        match self {
            PaymentProtocol::X402 { requirements } => (
                "PAYMENT-SIGNATURE".to_string(),
                x402::build_payment_signature(txid, requirements),
            ),
            PaymentProtocol::Mpp { challenge, .. } => (
                "Authorization".to_string(),
                format!("Payment {}", mpp::build_credential(challenge, txid)),
            ),
        }
    }

    /// Return a summary for display/logging.
    pub fn info(&self) -> Result<PaymentInfo> {
        Ok(PaymentInfo {
            protocol: match self {
                PaymentProtocol::X402 { .. } => "x402".to_string(),
                PaymentProtocol::Mpp { .. } => "mpp".to_string(),
            },
            address: self.address()?,
            amount: self.amount_zatoshis()?,
        })
    }
}

/// Detect which payment protocol is in use from an HTTP 402 response.
///
/// Checks `WWW-Authenticate: Payment` header first (MPP), then falls back
/// to parsing the response body as x402 JSON.
pub fn detect_protocol(
    headers: &HashMap<String, String>,
    body: &str,
    expected_network: &str,
) -> Result<PaymentProtocol> {
    if let Some(www_auth) = headers.get("www-authenticate").or(headers.get("WWW-Authenticate")) {
        if www_auth.starts_with("Payment") || www_auth.starts_with("payment") {
            let challenge = mpp::parse_www_authenticate(www_auth)?;

            if !mpp::is_zcash_method(&challenge.method) {
                return Err(anyhow!(
                    "MPP payment method '{}' is not Zcash",
                    challenge.method
                ));
            }

            let charge = mpp::decode_charge_request(&challenge)?;

            return Ok(PaymentProtocol::Mpp { challenge, charge });
        }
    }

    let requirements = x402::parse_402_response(body, expected_network)?;
    Ok(PaymentProtocol::X402 { requirements })
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use base64::Engine as _;

    #[test]
    fn detect_x402_from_body() {
        let body = r#"{
            "x402Version": 2,
            "accepts": [{
                "scheme": "exact",
                "network": "zcash:mainnet",
                "asset": "ZEC",
                "amount": "50000",
                "payTo": "u1addr",
                "maxTimeoutSeconds": 120
            }]
        }"#;
        let headers = HashMap::new();
        let protocol = detect_protocol(&headers, body, "zcash:mainnet").unwrap();

        match &protocol {
            PaymentProtocol::X402 { requirements } => {
                assert_eq!(requirements.pay_to, "u1addr");
            }
            _ => panic!("Expected x402"),
        }

        assert_eq!(protocol.amount_zatoshis().unwrap(), 50_000);
        assert_eq!(protocol.address().unwrap(), "u1addr");

        let (header_name, _) = protocol.build_credential("txid123");
        assert_eq!(header_name, "PAYMENT-SIGNATURE");
    }

    #[test]
    fn detect_mpp_from_header() {
        let request_json = r#"{"amount":"75000","currency":"zec","recipient":"u1mppaddr"}"#;
        let request_b64 =
            base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(request_json.as_bytes());

        let mut headers = HashMap::new();
        headers.insert(
            "www-authenticate".to_string(),
            format!(
                r#"Payment id="ch123", realm="api.test.com", method="zcash", intent="charge", request="{}""#,
                request_b64
            ),
        );

        let protocol = detect_protocol(&headers, "", "zcash:mainnet").unwrap();

        match &protocol {
            PaymentProtocol::Mpp { challenge, .. } => {
                assert_eq!(challenge.id, "ch123");
                assert_eq!(challenge.method, "zcash");
            }
            _ => panic!("Expected MPP"),
        }

        assert_eq!(protocol.amount_zatoshis().unwrap(), 75_000);
        assert_eq!(protocol.address().unwrap(), "u1mppaddr");

        let (header_name, _) = protocol.build_credential("txid456");
        assert_eq!(header_name, "Authorization");
    }
}
