use std::sync::Arc;

use axum::{
    extract::{Query, State},
    http::{HeaderMap, StatusCode},
    response::{IntoResponse, Json},
    routing::get,
    Router,
};
use serde::Deserialize;
use zcash_protocol::consensus::Network;

use crate::Config;

const CIPHERPAY_API: &str = "https://api.cipherpay.app";
const VERIFY_PATH: &str = "/api/x402/verify";
const DEFAULT_PRICE_ZATOSHIS: u64 = 10_000; // 0.0001 ZEC per call

// ---------------------------------------------------------------------------
// Server state
// ---------------------------------------------------------------------------

struct AppState {
    pay_to: String,
    network: String,
    price_zatoshis: u64,
    cipherpay_key: Option<String>,
    data_dir: String,
}

// ---------------------------------------------------------------------------
// x402 response builder
// ---------------------------------------------------------------------------

fn payment_required_body(pay_to: &str, network: &str, price: u64, path: &str) -> serde_json::Value {
    serde_json::json!({
        "x402Version": 2,
        "resource": {
            "url": path,
            "description": "Zipher agent API — pay-per-call with shielded ZEC"
        },
        "accepts": [{
            "scheme": "exact",
            "network": network,
            "asset": "ZEC",
            "amount": price.to_string(),
            "payTo": pay_to,
            "maxTimeoutSeconds": 300
        }]
    })
}

// ---------------------------------------------------------------------------
// Payment verification
// ---------------------------------------------------------------------------

#[derive(Deserialize)]
struct PaymentSignaturePayload {
    #[serde(rename = "x402Version")]
    version: u8,
    payload: TxPayloadInner,
}

#[derive(Deserialize)]
struct TxPayloadInner {
    txid: String,
}

#[derive(Deserialize)]
struct VerificationResponse {
    valid: bool,
    previously_verified: bool,
    received_zatoshis: u64,
}

type PaymentError = (StatusCode, Json<serde_json::Value>);

fn payment_error(status: StatusCode, message: &str) -> PaymentError {
    (status, Json(serde_json::json!({ "error": message })))
}

fn validate_payment_payload(payload: &PaymentSignaturePayload) -> Result<(), PaymentError> {
    if payload.version != 2
        || payload.payload.txid.len() != 64
        || !payload
            .payload
            .txid
            .bytes()
            .all(|byte| byte.is_ascii_hexdigit())
    {
        return Err(payment_error(
            StatusCode::BAD_REQUEST,
            "payment must use x402 version 2 and a 64-character hexadecimal transaction ID",
        ));
    }
    Ok(())
}

async fn require_verified_payment(
    mut response: reqwest::Response,
    expected_zatoshis: u64,
) -> Result<(), PaymentError> {
    if !response.status().is_success() {
        return Err(payment_error(
            StatusCode::PAYMENT_REQUIRED,
            "payment verification failed",
        ));
    }

    // A successful HTTP request is not a successful payment. Bound the body
    // before parsing, including responses without a Content-Length header.
    const MAX_VERIFICATION_BYTES: usize = 16 * 1024;
    let mut body = Vec::new();
    while let Some(chunk) = response.chunk().await.map_err(|_| {
        payment_error(
            StatusCode::BAD_GATEWAY,
            "payment verifier response unavailable",
        )
    })? {
        if chunk.len() > MAX_VERIFICATION_BYTES - body.len() {
            return Err(payment_error(
                StatusCode::BAD_GATEWAY,
                "payment verifier response too large",
            ));
        }
        body.extend_from_slice(&chunk);
    }
    let verification: VerificationResponse = serde_json::from_slice(&body)
        .map_err(|_| payment_error(StatusCode::BAD_GATEWAY, "invalid payment verifier response"))?;
    if !verification.valid
        || verification.previously_verified
        || expected_zatoshis == 0
        || verification.received_zatoshis < expected_zatoshis
    {
        return Err(payment_error(
            StatusCode::PAYMENT_REQUIRED,
            "payment verification failed",
        ));
    }
    Ok(())
}

async fn verify_payment(
    headers: &HeaderMap,
    state: &AppState,
    expected_zatoshis: u64,
) -> Result<(), PaymentError> {
    let sig_header = headers
        .get("PAYMENT-SIGNATURE")
        .or_else(|| headers.get("payment-signature"))
        .and_then(|v| v.to_str().ok());

    let sig_b64 = match sig_header {
        Some(s) => s,
        None => {
            return Err((
                StatusCode::PAYMENT_REQUIRED,
                Json(serde_json::json!({"error": "missing_payment"})),
            ))
        }
    };

    let decoded = base64::Engine::decode(&base64::engine::general_purpose::STANDARD, sig_b64)
        .map_err(|_| {
            (
                StatusCode::BAD_REQUEST,
                Json(serde_json::json!({"error": "invalid PAYMENT-SIGNATURE encoding"})),
            )
        })?;

    let payload: PaymentSignaturePayload = serde_json::from_slice(&decoded).map_err(|_| {
        (
            StatusCode::BAD_REQUEST,
            Json(serde_json::json!({"error": "invalid PAYMENT-SIGNATURE JSON"})),
        )
    })?;

    validate_payment_payload(&payload)?;
    let txid = &payload.payload.txid;

    let api_key = match state.cipherpay_key.as_deref() {
        Some(k) => k,
        None => {
            // Demo mode: accept any credential without CipherPay verification
            tracing::warn!(
                "Demo mode: accepting payment {} without verification",
                &txid[..16]
            );
            zipher_engine::audit::log_event(
                &state.data_dir,
                "serve_payment_demo",
                None,
                Some(expected_zatoshis),
                None,
                Some(txid),
                None,
                None,
            )
            .ok();
            return Ok(());
        }
    };

    let cipherpay_url =
        std::env::var("CIPHERPAY_URL").unwrap_or_else(|_| CIPHERPAY_API.to_string());
    let client = reqwest::Client::builder()
        .connect_timeout(std::time::Duration::from_secs(5))
        .timeout(std::time::Duration::from_secs(15))
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .map_err(|_| payment_error(StatusCode::BAD_GATEWAY, "payment verifier unavailable"))?;
    let resp = client
        .post(&format!("{}{}", cipherpay_url, VERIFY_PATH))
        .header("Authorization", format!("Bearer {}", api_key))
        .json(&serde_json::json!({
            "txid": txid,
            "expected_amount_zec": expected_zatoshis as f64 / 100_000_000.0,
            "protocol": "x402"
        }))
        .send()
        .await
        .map_err(|e| {
            (
                StatusCode::BAD_GATEWAY,
                Json(serde_json::json!({"error": format!("CipherPay verify failed: {}", e)})),
            )
        })?;

    require_verified_payment(resp, expected_zatoshis).await?;

    zipher_engine::audit::log_event(
        &state.data_dir,
        "serve_payment_verified",
        None,
        Some(expected_zatoshis),
        None,
        Some(txid),
        None,
        None,
    )
    .ok();

    Ok(())
}

// ---------------------------------------------------------------------------
// Endpoint: GET /api/research?topic=...
// ---------------------------------------------------------------------------

#[derive(Deserialize)]
struct ResearchQuery {
    topic: String,
    limit: Option<usize>,
}

async fn research_handler(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Query(query): Query<ResearchQuery>,
) -> impl IntoResponse {
    if verify_payment(&headers, &state, state.price_zatoshis)
        .await
        .is_err()
    {
        let body = payment_required_body(
            &state.pay_to,
            &state.network,
            state.price_zatoshis,
            "/api/research",
        );
        return (StatusCode::PAYMENT_REQUIRED, Json(body)).into_response();
    }

    let limit = query.limit.unwrap_or(5).min(10);

    match zipher_engine::research::search_news(&query.topic, limit).await {
        Ok(report) => Json(serde_json::json!({
            "status": "ok",
            "report": report
        }))
        .into_response(),
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(serde_json::json!({"error": format!("{:#}", e)})),
        )
            .into_response(),
    }
}

// ---------------------------------------------------------------------------
// Endpoint: GET /health
// ---------------------------------------------------------------------------

async fn health_handler() -> Json<serde_json::Value> {
    Json(serde_json::json!({
        "status": "ok",
        "service": "zipher-agent-api",
        "protocol": "x402",
        "version": env!("CARGO_PKG_VERSION")
    }))
}

// ---------------------------------------------------------------------------
// Public entry point
// ---------------------------------------------------------------------------

pub async fn cmd_serve(
    config: &Config,
    port: u16,
    price: Option<u64>,
    listen: String,
    demo_accept_unverified: bool,
) {
    let price_zatoshis = price.unwrap_or(DEFAULT_PRICE_ZATOSHIS);

    let network_str = if config.network == Network::TestNetwork {
        "zcash:testnet"
    } else {
        "zcash:mainnet"
    };

    let pay_to = match zipher_engine::query::get_addresses().await {
        Ok(addrs) if !addrs.is_empty() => addrs[0].address.clone(),
        _ => {
            eprintln!(
                "Error: No wallet address available. Create a wallet first: zipher-cli wallet init"
            );
            std::process::exit(1);
        }
    };

    let cipherpay_key = std::env::var("CIPHERPAY_API_KEY")
        .ok()
        .filter(|key| !key.trim().is_empty());
    if cipherpay_key.is_none() && !demo_accept_unverified {
        eprintln!(
            "Error: CIPHERPAY_API_KEY is not set and --demo-accept-unverified was not passed."
        );
        eprintln!();
        eprintln!("By default the server refuses to start without payment verification, because");
        eprintln!(
            "any client sending a syntactically valid PAYMENT-SIGNATURE header would be served"
        );
        eprintln!("for free. To run in unverified demo mode anyway (e.g. local testing), pass:");
        eprintln!();
        eprintln!("    zipher-cli serve --demo-accept-unverified");
        eprintln!();
        std::process::exit(1);
    }
    if cipherpay_key.is_none() && demo_accept_unverified {
        eprintln!(
            "⚠  Demo mode: CIPHERPAY_API_KEY not set and --demo-accept-unverified was passed."
        );
        eprintln!("   Any PAYMENT-SIGNATURE header will be accepted. Do not expose externally.");
    }

    // Default CORS policy is restrictive — anyone needing wide-open CORS
    // for a real deployment can edit this knob deliberately. Was
    // `CorsLayer::permissive()` (audit finding H9).
    let cors = tower_http::cors::CorsLayer::new().allow_origin(
        tower_http::cors::AllowOrigin::list(Vec::<axum::http::HeaderValue>::new()),
    );

    let state = Arc::new(AppState {
        pay_to: pay_to.clone(),
        network: network_str.to_string(),
        price_zatoshis,
        cipherpay_key,
        data_dir: config.data_dir.clone(),
    });

    let app = Router::new()
        .route("/health", get(health_handler))
        .route("/api/research", get(research_handler))
        .layer(cors)
        .with_state(state);

    let price_zec = price_zatoshis as f64 / 1e8;
    println!("Zipher Agent API");
    println!("  Listening:  http://{}:{}", listen, port);
    if listen == "127.0.0.1" {
        println!("              (localhost only — pass --listen 0.0.0.0 to expose)");
    } else if listen == "0.0.0.0" {
        println!("              (exposed externally — use TLS + a reverse proxy)");
    }
    println!("  Protocol:   x402 (pay-per-call with shielded ZEC)");
    println!(
        "  Price:      {} ZEC per call ({} zatoshis)",
        price_zec, price_zatoshis
    );
    println!("  Pay to:     {}", &pay_to[..pay_to.len().min(20)]);
    println!();
    println!("Endpoints:");
    println!("  GET /health              — no payment required");
    println!("  GET /api/research?topic=  — web research via Firecrawl");
    println!();
    println!("Agents pay with: PAYMENT-SIGNATURE header (x402 protocol)");

    let listener = tokio::net::TcpListener::bind(format!("{}:{}", listen, port))
        .await
        .expect("Failed to bind port");

    axum::serve(listener, app).await.expect("Server error");
}

#[cfg(test)]
mod payment_security_tests {
    use super::*;

    async fn check_verifier_response(
        status: StatusCode,
        body: String,
        expected_zatoshis: u64,
    ) -> Result<(), PaymentError> {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let app = Router::new().route("/verify", get(move || async move { (status, body) }));
        let server = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
        let response = reqwest::Client::builder()
            .no_proxy()
            .timeout(std::time::Duration::from_secs(5))
            .build()
            .unwrap()
            .get(format!("http://{address}/verify"))
            .send()
            .await
            .unwrap();
        let result = require_verified_payment(response, expected_zatoshis).await;
        server.abort();
        result
    }

    #[tokio::test]
    async fn http_200_requires_a_new_verified_payment_covering_the_integer_price() {
        for (valid, replay, received, accepted) in [
            (true, false, 10_000, true),
            (true, false, 10_001, true),
            (false, false, 10_000, false),
            (false, false, 0, false),
            (false, true, 10_000, false),
            (true, true, 10_000, false),
            (true, false, 9_999, false),
        ] {
            let body = serde_json::json!({
                "valid": valid,
                "previously_verified": replay,
                "received_zatoshis": received,
            })
            .to_string();
            assert_eq!(
                check_verifier_response(StatusCode::OK, body, 10_000)
                    .await
                    .is_ok(),
                accepted
            );
        }
    }

    #[tokio::test]
    async fn malformed_missing_or_oversized_verifier_fields_fail_closed() {
        for body in [
            "{}".to_string(),
            "not json".to_string(),
            r#"{"valid":true,"received_zatoshis":10000}"#.to_string(),
            r#"{"valid":true,"previously_verified":false}"#.to_string(),
            r#"{"valid":"true","previously_verified":false,"received_zatoshis":10000}"#.to_string(),
            r#"{"valid":true,"previously_verified":false,"received_zatoshis":-1}"#.to_string(),
            " ".repeat(16 * 1024 + 1),
        ] {
            assert!(check_verifier_response(StatusCode::OK, body, 10_000)
                .await
                .is_err());
        }
        let body = r#"{"valid":true,"previously_verified":false,"received_zatoshis":10000}"#;
        for status in [StatusCode::UNAUTHORIZED, StatusCode::TEMPORARY_REDIRECT] {
            assert!(check_verifier_response(status, body.to_string(), 10_000)
                .await
                .is_err());
        }
        assert!(check_verifier_response(StatusCode::OK, body.to_string(), 0)
            .await
            .is_err());
    }

    #[test]
    fn invalid_payment_versions_and_transaction_ids_are_rejected_before_demo_or_network() {
        for (version, txid, accepted) in [
            (2, "a".repeat(64), true),
            (1, "a".repeat(64), false),
            (2, "a".repeat(63), false),
            (2, "g".repeat(64), false),
            (2, "".to_string(), false),
        ] {
            let payload = PaymentSignaturePayload {
                version,
                payload: TxPayloadInner { txid },
            };
            assert_eq!(validate_payment_payload(&payload).is_ok(), accepted);
        }
    }
}
