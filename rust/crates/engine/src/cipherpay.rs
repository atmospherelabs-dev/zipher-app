use anyhow::{anyhow, Result};
use serde::{Deserialize, Serialize};

const CIPHERPAY_BASE: &str = "https://api.cipherpay.app";

fn resolve_url() -> String {
    std::env::var("CIPHERPAY_URL").unwrap_or_else(|_| CIPHERPAY_BASE.to_string())
}

fn resolve_api_key() -> Result<String> {
    std::env::var("CIPHERPAY_API_KEY")
        .map_err(|_| anyhow!("CIPHERPAY_API_KEY not set — register as a merchant first"))
}

fn client() -> reqwest::Client {
    reqwest::Client::new()
}

#[derive(Debug, Serialize, Deserialize)]
pub struct InvoiceCreated {
    pub invoice_id: String,
    pub memo_code: String,
    pub amount: f64,
    pub currency: String,
    pub price_zec: f64,
    pub payment_address: String,
    pub zcash_uri: String,
    pub expires_at: String,
    pub checkout_url: Option<String>,
}

/// Create a CipherPay invoice via the merchant API.
pub async fn create_invoice(
    product_name: &str,
    amount: f64,
    currency: &str,
) -> Result<InvoiceCreated> {
    let base = resolve_url();
    let api_key = resolve_api_key()?;

    let resp = client()
        .post(format!("{base}/api/invoices"))
        .header("Authorization", format!("Bearer {api_key}"))
        .json(&serde_json::json!({
            "product_name": product_name,
            "amount": amount,
            "currency": currency,
        }))
        .send()
        .await
        .map_err(|e| anyhow!("Invoice creation failed: {e}"))?;

    if !resp.status().is_success() {
        let status = resp.status();
        let body = resp.text().await.unwrap_or_default();
        return Err(anyhow!("Invoice creation failed ({}): {}", status, body));
    }

    let invoice: InvoiceCreated = resp
        .json()
        .await
        .map_err(|e| anyhow!("Failed to parse invoice response: {e}"))?;

    Ok(invoice)
}

#[derive(Debug, Serialize, Deserialize)]
pub struct InvoiceStatus {
    pub id: String,
    pub status: String,
    pub price_zec: f64,
    pub price_eur: f64,
    pub payment_address: String,
    pub received_zec: Option<f64>,
    pub detected_txid: Option<String>,
    pub expires_at: String,
    pub created_at: String,
    pub product_name: Option<String>,
    pub memo_code: String,
}

/// Get invoice status from CipherPay.
pub async fn check_invoice(invoice_id: &str) -> Result<InvoiceStatus> {
    let base = resolve_url();

    let resp = client()
        .get(format!("{base}/api/invoices/{invoice_id}"))
        .send()
        .await
        .map_err(|e| anyhow!("Invoice check failed: {e}"))?;

    if !resp.status().is_success() {
        let status = resp.status();
        let body = resp.text().await.unwrap_or_default();
        return Err(anyhow!("Invoice check failed ({}): {}", status, body));
    }

    let invoice: InvoiceStatus = resp
        .json()
        .await
        .map_err(|e| anyhow!("Failed to parse invoice: {e}"))?;

    Ok(invoice)
}

#[derive(Debug, Serialize, Deserialize)]
pub struct MerchantBalance {
    pub merchant_id: String,
    pub name: String,
    pub payment_address: String,
    pub total_invoices: i64,
    pub confirmed: i64,
    pub total_zec: f64,
}

/// Get merchant balance/stats from CipherPay (requires auth).
pub async fn merchant_balance() -> Result<MerchantBalance> {
    let base = resolve_url();
    let api_key = resolve_api_key()?;

    let resp = client()
        .get(format!("{base}/api/merchants/me"))
        .header("Authorization", format!("Bearer {api_key}"))
        .send()
        .await
        .map_err(|e| anyhow!("Balance request failed: {e}"))?;

    if !resp.status().is_success() {
        let status = resp.status();
        let body = resp.text().await.unwrap_or_default();
        return Err(anyhow!("Balance request failed ({}): {}", status, body));
    }

    let json: serde_json::Value = resp
        .json()
        .await
        .map_err(|e| anyhow!("Failed to parse merchant response: {e}"))?;

    let stats = json.get("stats").unwrap_or(&serde_json::Value::Null);

    Ok(MerchantBalance {
        merchant_id: json["id"].as_str().unwrap_or("").to_string(),
        name: json["name"].as_str().unwrap_or("").to_string(),
        payment_address: json["payment_address"].as_str().unwrap_or("").to_string(),
        total_invoices: stats["total_invoices"].as_i64().unwrap_or(0),
        confirmed: stats["confirmed"].as_i64().unwrap_or(0),
        total_zec: stats["total_zec"].as_f64().unwrap_or(0.0),
    })
}

// ---------------------------------------------------------------------------
// Paying a CipherPay invoice (buyer side)
// ---------------------------------------------------------------------------

/// One output of CipherPay's `GET /api/invoices/{id}/payment-request`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PaymentRequestOutput {
    pub address: String,
    pub amount_zatoshis: u64,
    pub memo: String,
    pub purpose: String,
    #[serde(default)]
    pub required: bool,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct PaymentRequestMerchant {
    pub name: Option<String>,
    pub origin: Option<String>,
}

/// CipherPay payment request, version 1.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PaymentRequest {
    pub version: u32,
    pub invoice_id: String,
    pub network: String,
    pub status: String,
    pub payable: bool,
    pub not_payable_reason: Option<String>,
    pub expires_at: String,
    #[serde(default)]
    pub merchant: PaymentRequestMerchant,
    pub description: Option<String>,
    #[serde(default)]
    pub outputs: Vec<PaymentRequestOutput>,
    pub checkout_url: Option<String>,
}

/// What the wallet will actually send for an invoice.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct InvoicePayment {
    pub invoice_id: String,
    pub address: String,
    pub amount_zatoshis: u64,
    pub memo: String,
    /// Optional platform fee output not included in this payment; CipherPay
    /// bills it to the merchant instead.
    pub platform_fee_not_sent_zatoshis: u64,
}

fn is_invoice_id(s: &str) -> bool {
    uuid::Uuid::parse_str(s).is_ok() && s.len() == 36
}

/// Accepts an invoice ID, a hosted checkout URL (`.../pay/<id>`, any locale,
/// with or without `#checkout=` fragment) or an API URL (`.../invoices/<id>/...`).
/// Only the ID is kept: the request is always fetched from the configured
/// CipherPay API, never from the host in the supplied URL.
pub fn invoice_id_from_ref(input: &str) -> Result<String> {
    let trimmed = input.trim();
    if is_invoice_id(trimmed) {
        return Ok(trimmed.to_ascii_lowercase());
    }
    let path = trimmed
        .split(['#', '?'])
        .next()
        .unwrap_or_default();
    let segments: Vec<&str> = path.split('/').filter(|s| !s.is_empty()).collect();
    for pair in segments.windows(2) {
        if (pair[0] == "pay" || pair[0] == "invoices") && is_invoice_id(pair[1]) {
            return Ok(pair[1].to_ascii_lowercase());
        }
    }
    Err(anyhow!(
        "INVALID_PROPOSAL: expected a CipherPay invoice ID or checkout URL (…/pay/<invoice-id>)"
    ))
}

fn is_memo_code(memo: &str) -> bool {
    memo.strip_prefix("CP-").is_some_and(|rest| {
        (6..=16).contains(&rest.len()) && rest.bytes().all(|b| b.is_ascii_uppercase() || b.is_ascii_digit())
    })
}

/// Validate a payment request and select the single required invoice output.
pub fn invoice_payment(
    req: &PaymentRequest,
    expected_invoice_id: &str,
    expected_network: &str,
) -> Result<InvoicePayment> {
    if req.version != 1 {
        return Err(anyhow!("INVALID_PROPOSAL: unsupported payment request version {}", req.version));
    }
    if !req.invoice_id.eq_ignore_ascii_case(expected_invoice_id) {
        return Err(anyhow!("INVALID_PROPOSAL: payment request is for a different invoice"));
    }
    if req.network != expected_network {
        return Err(anyhow!(
            "INVALID_PROPOSAL: invoice is on {}, wallet is on {expected_network}",
            req.network
        ));
    }
    if !req.payable {
        return Err(anyhow!(
            "INVALID_PROPOSAL: invoice is not payable ({}, status {})",
            req.not_payable_reason.as_deref().unwrap_or("unknown reason"),
            req.status
        ));
    }
    let mut invoice_output = None;
    let mut fee = 0u64;
    for out in &req.outputs {
        match (out.purpose.as_str(), out.required) {
            ("invoice", true) if invoice_output.is_none() => invoice_output = Some(out),
            ("platform_fee", false) => fee = fee.saturating_add(out.amount_zatoshis),
            // Any other required output is something this wallet would skip:
            // refuse rather than underpay.
            _ => {
                return Err(anyhow!(
                    "INVALID_PROPOSAL: unsupported payment request output ({}, required: {})",
                    out.purpose, out.required
                ))
            }
        }
    }
    let out = invoice_output
        .ok_or_else(|| anyhow!("INVALID_PROPOSAL: payment request has no invoice output"))?;
    if out.amount_zatoshis == 0 {
        return Err(anyhow!("INVALID_PROPOSAL: invoice amount is zero"));
    }
    if !is_memo_code(&out.memo) {
        return Err(anyhow!("INVALID_PROPOSAL: unexpected invoice memo"));
    }
    out.address
        .parse::<zcash_address::ZcashAddress>()
        .map_err(|_| anyhow!("INVALID_PROPOSAL: invalid invoice address"))?;
    Ok(InvoicePayment {
        invoice_id: req.invoice_id.to_ascii_lowercase(),
        address: out.address.clone(),
        amount_zatoshis: out.amount_zatoshis,
        memo: out.memo.clone(),
        platform_fee_not_sent_zatoshis: fee,
    })
}

/// Fetch an invoice's payment request from the configured CipherPay API.
pub async fn fetch_payment_request(invoice_id: &str) -> Result<PaymentRequest> {
    if !is_invoice_id(invoice_id) {
        return Err(anyhow!("INVALID_PROPOSAL: invalid invoice ID"));
    }
    let base = resolve_url();
    let http = reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .timeout(std::time::Duration::from_secs(15))
        .build()
        .map_err(|e| anyhow!("HTTP client: {e}"))?;
    let resp = http
        .get(format!("{}/api/invoices/{invoice_id}/payment-request", base.trim_end_matches('/')))
        .send()
        .await
        .map_err(|e| anyhow!("Payment request fetch failed (connection): {e}"))?;
    let status = resp.status();
    if status == reqwest::StatusCode::NOT_FOUND {
        return Err(anyhow!("INVALID_PROPOSAL: invoice not found at {base}"));
    }
    if !status.is_success() {
        return Err(anyhow!("Payment request fetch failed ({status})"));
    }
    let bytes = resp
        .bytes()
        .await
        .map_err(|e| anyhow!("Payment request fetch failed (connection): {e}"))?;
    if bytes.len() > 64 * 1024 {
        return Err(anyhow!("INVALID_PROPOSAL: payment request too large"));
    }
    serde_json::from_slice(&bytes).map_err(|e| anyhow!("INVALID_PROPOSAL: malformed payment request: {e}"))
}

#[cfg(test)]
mod invoice_payment_tests {
    use super::*;

    const ID: &str = "0f8fad5b-d9cb-469f-a165-70867728950e";
    fn addr() -> String {
        // Well-formed encoding; key validity and network are checked at proposal time.
        <zcash_address::ZcashAddress as zcash_address::ToAddress>::from_sapling(zcash_protocol::consensus::NetworkType::Main, [7u8; 43]).encode()
    }

    fn request() -> PaymentRequest {
        let addr = addr();
        serde_json::from_value(serde_json::json!({
            "version": 1, "invoice_id": ID, "network": "zcash:mainnet", "status": "pending",
            "payable": true, "not_payable_reason": null, "expires_at": "2099-01-01T00:00:00Z",
            "merchant": {"name": "Shop", "origin": null}, "description": "Ice",
            "outputs": [
                {"address": addr, "amount_zatoshis": 12_340_000, "memo": "CP-AB12CD34", "purpose": "invoice", "required": true},
                {"address": addr, "amount_zatoshis": 123_400, "memo": format!("FEE-{ID}"), "purpose": "platform_fee", "required": false}
            ],
            "checkout_url": format!("https://cipherpay.app/pay/{ID}"),
        })).unwrap()
    }

    #[test]
    fn refs_resolve_to_the_invoice_id_only() {
        assert_eq!(invoice_id_from_ref(ID).unwrap(), ID);
        assert_eq!(invoice_id_from_ref(&format!("https://cipherpay.app/en/pay/{ID}#checkout=abc")).unwrap(), ID);
        assert_eq!(invoice_id_from_ref(&format!("https://evil.example/pay/{}?x=1", ID.to_uppercase())).unwrap(), ID);
        assert_eq!(invoice_id_from_ref(&format!("https://api.cipherpay.app/api/invoices/{ID}/payment-request")).unwrap(), ID);
        assert!(invoice_id_from_ref("CP-AB12CD34").is_err());
        assert!(invoice_id_from_ref("https://cipherpay.app/pay/../../etc").is_err());
    }

    #[test]
    fn selects_the_invoice_output_and_reports_the_skipped_fee() {
        let p = invoice_payment(&request(), ID, "zcash:mainnet").unwrap();
        assert_eq!(p.amount_zatoshis, 12_340_000);
        assert_eq!(p.memo, "CP-AB12CD34");
        assert_eq!(p.address, addr());
        assert_eq!(p.platform_fee_not_sent_zatoshis, 123_400);
    }

    #[test]
    fn refuses_unsafe_or_unexpected_requests() {
        let cases: Vec<(Box<dyn Fn(&mut PaymentRequest)>, &str)> = vec![
            (Box::new(|r| r.payable = false), "not payable"),
            (Box::new(|r| r.network = "zcash:testnet".into()), "wallet is on"),
            (Box::new(|r| r.invoice_id = "11111111-1111-4111-8111-111111111111".into()), "different invoice"),
            (Box::new(|r| r.version = 2), "version"),
            (Box::new(|r| r.outputs[0].memo = "hello".into()), "memo"),
            (Box::new(|r| r.outputs[0].amount_zatoshis = 0), "zero"),
            (Box::new(|r| r.outputs[0].address = "not-an-address".into()), "address"),
            (Box::new(|r| r.outputs[1].required = true), "unsupported"),
            (Box::new(|r| { let o = r.outputs[0].clone(); r.outputs.push(o); }), "unsupported"),
            (Box::new(|r| r.outputs.remove(0).memo.clear()), "no invoice output"),
        ];
        for (mutate, expected) in cases {
            let mut r = request();
            mutate(&mut r);
            let err = invoice_payment(&r, ID, "zcash:mainnet").unwrap_err().to_string();
            assert!(err.contains("INVALID_PROPOSAL") && err.contains(expected), "{err}");
        }
    }
}
