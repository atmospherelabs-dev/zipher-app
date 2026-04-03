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

fn payment_required_body(
    pay_to: &str,
    network: &str,
    price: u64,
    path: &str,
) -> serde_json::Value {
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
    _version: u8,
    payload: TxPayloadInner,
}

#[derive(Deserialize)]
struct TxPayloadInner {
    txid: String,
}

async fn verify_payment(
    headers: &HeaderMap,
    state: &AppState,
    expected_amount_zec: f64,
) -> Result<(), (StatusCode, Json<serde_json::Value>)> {
    let sig_header = headers
        .get("PAYMENT-SIGNATURE")
        .or_else(|| headers.get("payment-signature"))
        .and_then(|v| v.to_str().ok());

    let sig_b64 = match sig_header {
        Some(s) => s,
        None => return Err((StatusCode::PAYMENT_REQUIRED, Json(serde_json::json!({"error": "missing_payment"})))),
    };

    let decoded = base64::Engine::decode(
        &base64::engine::general_purpose::STANDARD,
        sig_b64,
    )
    .map_err(|_| {
        (StatusCode::BAD_REQUEST, Json(serde_json::json!({"error": "invalid PAYMENT-SIGNATURE encoding"})))
    })?;

    let payload: PaymentSignaturePayload = serde_json::from_slice(&decoded).map_err(|_| {
        (StatusCode::BAD_REQUEST, Json(serde_json::json!({"error": "invalid PAYMENT-SIGNATURE JSON"})))
    })?;

    let txid = &payload.payload.txid;

    let api_key = match state.cipherpay_key.as_deref() {
        Some(k) => k,
        None => {
            // Demo mode: accept any credential without CipherPay verification
            tracing::warn!("Demo mode: accepting payment {} without verification", &txid[..16]);
            zipher_engine::audit::log_event(
                &state.data_dir,
                "serve_payment_demo",
                None,
                Some((expected_amount_zec * 1e8) as u64),
                None,
                Some(txid),
                None,
                None,
            )
            .ok();
            return Ok(());
        }
    };

    let cipherpay_url = std::env::var("CIPHERPAY_URL")
        .unwrap_or_else(|_| CIPHERPAY_API.to_string());
    let client = reqwest::Client::new();
    let resp = client
        .post(&format!("{}{}", cipherpay_url, VERIFY_PATH))
        .header("Authorization", format!("Bearer {}", api_key))
        .json(&serde_json::json!({
            "txid": txid,
            "expected_amount_zec": expected_amount_zec,
            "protocol": "x402"
        }))
        .send()
        .await
        .map_err(|e| {
            (StatusCode::BAD_GATEWAY, Json(serde_json::json!({"error": format!("CipherPay verify failed: {}", e)})))
        })?;

    if !resp.status().is_success() {
        let text = resp.text().await.unwrap_or_default();
        return Err((
            StatusCode::PAYMENT_REQUIRED,
            Json(serde_json::json!({"error": "payment verification failed", "details": text})),
        ));
    }

    zipher_engine::audit::log_event(
        &state.data_dir,
        "serve_payment_verified",
        None,
        Some((expected_amount_zec * 1e8) as u64),
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
    let price_zec = state.price_zatoshis as f64 / 1e8;

    if verify_payment(&headers, &state, price_zec).await.is_err() {
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
// Endpoint: GET /api/markets
// ---------------------------------------------------------------------------

#[derive(Deserialize)]
struct MarketsQuery {
    keyword: Option<String>,
    limit: Option<u32>,
}

async fn markets_handler(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Query(query): Query<MarketsQuery>,
) -> impl IntoResponse {
    let price_zec = state.price_zatoshis as f64 / 1e8;

    if verify_payment(&headers, &state, price_zec).await.is_err() {
        let body = payment_required_body(
            &state.pay_to,
            &state.network,
            state.price_zatoshis,
            "/api/markets",
        );
        return (StatusCode::PAYMENT_REQUIRED, Json(body)).into_response();
    }

    let limit = query.limit.unwrap_or(30);

    match zipher_engine::myriad::get_markets(query.keyword.as_deref(), limit).await {
        Ok(markets) => {
            let ranked = zipher_engine::myriad::rank_for_research(&markets);
            Json(serde_json::json!({
                "status": "ok",
                "markets": ranked
            }))
            .into_response()
        }
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(serde_json::json!({"error": format!("{:#}", e)})),
        )
            .into_response(),
    }
}

// ---------------------------------------------------------------------------
// Endpoint: GET /api/analyze?market_id=...&outcome=...&prob=...&confidence=...
// ---------------------------------------------------------------------------

#[derive(Deserialize)]
struct AnalyzeQuery {
    market_id: u64,
    outcome: usize,
    prob: f64,
    confidence: f64,
    bankroll: Option<f64>,
    max_bet: Option<f64>,
}

async fn analyze_handler(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Query(query): Query<AnalyzeQuery>,
) -> impl IntoResponse {
    let price_zec = state.price_zatoshis as f64 / 1e8;

    if verify_payment(&headers, &state, price_zec).await.is_err() {
        let body = payment_required_body(
            &state.pay_to,
            &state.network,
            state.price_zatoshis,
            "/api/analyze",
        );
        return (StatusCode::PAYMENT_REQUIRED, Json(body)).into_response();
    }

    let market = match zipher_engine::myriad::get_market(query.market_id).await {
        Ok(m) => m,
        Err(e) => {
            return (
                StatusCode::BAD_REQUEST,
                Json(serde_json::json!({"error": format!("Market not found: {:#}", e)})),
            )
                .into_response();
        }
    };

    let bankroll = query.bankroll.unwrap_or(100.0);
    let max_bet = query.max_bet.unwrap_or(10.0);

    let signal = zipher_engine::myriad::analyze_opportunity(
        &market,
        query.outcome,
        query.prob,
        query.confidence,
        bankroll,
        max_bet,
    );

    Json(serde_json::json!({
        "status": "ok",
        "signal": signal
    }))
    .into_response()
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

pub async fn cmd_serve(config: &Config, port: u16, price: Option<u64>) {
    let price_zatoshis = price.unwrap_or(DEFAULT_PRICE_ZATOSHIS);

    let network_str = if config.network == Network::TestNetwork {
        "zcash:testnet"
    } else {
        "zcash:mainnet"
    };

    let pay_to = match zipher_engine::query::get_addresses().await {
        Ok(addrs) if !addrs.is_empty() => addrs[0].address.clone(),
        _ => {
            eprintln!("Error: No wallet address available. Create a wallet first: zipher-cli wallet create");
            std::process::exit(1);
        }
    };

    let cipherpay_key = std::env::var("CIPHERPAY_API_KEY").ok();
    if cipherpay_key.is_none() {
        eprintln!("Warning: CIPHERPAY_API_KEY not set. Payment verification will be skipped (demo mode).");
        eprintln!("         In demo mode, any PAYMENT-SIGNATURE header is accepted.");
    }

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
        .route("/api/markets", get(markets_handler))
        .route("/api/analyze", get(analyze_handler))
        .layer(tower_http::cors::CorsLayer::permissive())
        .with_state(state);

    let price_zec = price_zatoshis as f64 / 1e8;
    println!("Zipher Agent API");
    println!("  Listening:  http://0.0.0.0:{}", port);
    println!("  Protocol:   x402 (pay-per-call with shielded ZEC)");
    println!("  Price:      {} ZEC per call ({} zatoshis)", price_zec, price_zatoshis);
    println!("  Pay to:     {}", &pay_to[..pay_to.len().min(20)]);
    println!();
    println!("Endpoints:");
    println!("  GET /health              — no payment required");
    println!("  GET /api/research?topic=  — web research via Firecrawl");
    println!("  GET /api/markets          — prediction markets scan");
    println!("  GET /api/analyze          — Kelly Criterion analysis");
    println!();
    println!("Agents pay with: PAYMENT-SIGNATURE header (x402 protocol)");

    let listener = tokio::net::TcpListener::bind(format!("0.0.0.0:{}", port))
        .await
        .expect("Failed to bind port");

    axum::serve(listener, app).await.expect("Server error");
}
