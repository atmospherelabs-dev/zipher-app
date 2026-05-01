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
