//! Blind relay for Zipher HITL approvals (protocol v1).
//!
//! It stores SHA-256 hashes of each side's bearer token and opaque ciphertexts.
//! It never sees keys, pairing secrets or payment details, and it does not log
//! request bodies, tokens or client addresses. Messages live only in memory;
//! only paired channels (their token hashes) are optionally persisted so a
//! restart does not force everyone to re-pair.

pub mod push;

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use axum::extract::{DefaultBodyLimit, Path, State};
use axum::http::{HeaderMap, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post, put};
use axum::{Json, Router};
use serde::{Deserialize, Serialize};
use tokio::sync::Mutex;
use zipher_hitl_protocol::wire::{PendingRequests, PostRequest, RegisterChannel, MAX_BLOB_CHARS};
use zipher_hitl_protocol::{token_matches, unb64, PairResponse, Sealed, MAX_REQUEST_TTL_SECS};

pub const MAX_OPEN_REQUESTS: usize = 8;
pub const MAX_CHANNELS: usize = 50_000;
pub const UNPAIRED_TTL: Duration = Duration::from_secs(600);
pub const REGISTRATIONS_PER_MINUTE: u32 = 120;
const BODY_LIMIT: usize = 16 * 1024;

#[derive(Clone, Copy, PartialEq, Eq)]
enum Side {
    Agent,
    Phone,
}

#[derive(Clone, Serialize, Deserialize)]
struct StoredChannel {
    agent_hash: [u8; 32],
    phone_hash: [u8; 32],
    paired: bool,
    /// Optional wake-up target. Persisted so pushes survive a relay restart.
    #[serde(default)]
    push: Option<push::PushTarget>,
}

struct Channel {
    stored: StoredChannel,
    created: Instant,
    pair_blob: Option<PairResponse>,
    requests: HashMap<String, PostRequest>,
    decisions: HashMap<String, (Sealed, u64)>,
}

struct Inner {
    channels: HashMap<[u8; 16], Channel>,
    window_start: Instant,
    registrations_in_window: u32,
}

#[derive(Clone)]
pub struct Relay {
    inner: Arc<Mutex<Inner>>,
    state_file: Option<PathBuf>,
    apns: Option<Arc<push::Apns>>,
}

fn now_unix() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
}

fn err(status: StatusCode, msg: &'static str) -> Response {
    (status, Json(serde_json::json!({ "error": msg }))).into_response()
}

fn not_found() -> Response {
    // Unknown channel and wrong token look the same, so the relay is no oracle.
    err(StatusCode::NOT_FOUND, "not found")
}

fn bearer(headers: &HeaderMap) -> Option<Vec<u8>> {
    let v = headers.get("authorization")?.to_str().ok()?;
    let t = v.strip_prefix("Bearer ")?;
    unb64::<32>(t).ok().map(|a| a.to_vec())
}

fn valid_approval_id(id: &str) -> bool {
    id.len() == 32 && id.bytes().all(|b| b.is_ascii_hexdigit())
}

fn sealed_ok(s: &Sealed) -> bool {
    s.nonce.len() <= 64 && s.ciphertext.len() <= MAX_BLOB_CHARS
}

impl Relay {
    pub fn new(state_file: Option<PathBuf>) -> Self {
        Self {
            inner: Arc::new(Mutex::new(Inner {
                channels: HashMap::new(),
                window_start: Instant::now(),
                registrations_in_window: 0,
            })),
            state_file,
            apns: None,
        }
    }

    /// Enable content-free wake-up pushes.
    pub fn with_apns(mut self, apns: push::Apns) -> Self {
        self.apns = Some(Arc::new(apns));
        self
    }

    /// Load paired channels saved by a previous run.
    pub async fn load(&self) -> anyhow::Result<usize> {
        let Some(path) = &self.state_file else { return Ok(0) };
        let data = match tokio::fs::read(path).await {
            Ok(d) => d,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(0),
            Err(e) => return Err(e.into()),
        };
        let saved: HashMap<String, StoredChannel> = serde_json::from_slice(&data)?;
        let mut inner = self.inner.lock().await;
        for (id, stored) in saved {
            let Ok(id) = unb64::<16>(&id) else { continue };
            inner.channels.insert(
                id,
                Channel {
                    stored,
                    created: Instant::now(),
                    pair_blob: None,
                    requests: HashMap::new(),
                    decisions: HashMap::new(),
                },
            );
        }
        Ok(inner.channels.len())
    }

    async fn persist(&self, inner: &Inner) {
        let Some(path) = &self.state_file else { return };
        let saved: HashMap<String, &StoredChannel> = inner
            .channels
            .iter()
            .filter(|(_, c)| c.stored.paired)
            .map(|(id, c)| (zipher_hitl_protocol::b64(id), &c.stored))
            .collect();
        let Ok(json) = serde_json::to_vec(&saved) else { return };
        let tmp = path.with_extension("tmp");
        if tokio::fs::write(&tmp, json).await.is_ok() {
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                let _ = tokio::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o600)).await;
            }
            let _ = tokio::fs::rename(&tmp, path).await;
        }
    }

    /// Drop expired messages and abandoned pairings.
    pub async fn sweep(&self) {
        let now = now_unix();
        let mut inner = self.inner.lock().await;
        inner.channels.retain(|_, c| c.stored.paired || c.created.elapsed() < UNPAIRED_TTL);
        for c in inner.channels.values_mut() {
            c.requests.retain(|_, r| r.expires_at >= now);
            c.decisions.retain(|_, (_, exp)| *exp >= now);
        }
    }

    pub fn router(self) -> Router {
        Router::new()
            .route("/health", get(|| async { "ok" }))
            .route("/v1/channels", post(register))
            .route("/v1/channels/{c}", axum::routing::delete(unpair))
            .route("/v1/channels/{c}/pair", post(post_pair).get(get_pair))
            .route("/v1/channels/{c}/push", put(put_push).delete(delete_push))
            .route("/v1/channels/{c}/requests", post(post_request).get(get_requests))
            .route("/v1/channels/{c}/decisions/{id}", post(post_decision).get(get_decision))
            .layer(DefaultBodyLimit::max(BODY_LIMIT))
            .with_state(self)
    }
}

/// Find a channel the caller is authorised for on the given side.
fn authed<'a>(inner: &'a mut Inner, c: &str, headers: &HeaderMap, side: Side) -> Option<&'a mut Channel> {
    let id = unb64::<16>(c).ok()?;
    let token = bearer(headers)?;
    let ch = inner.channels.get_mut(&id)?;
    let hash = match side {
        Side::Agent => &ch.stored.agent_hash,
        Side::Phone => &ch.stored.phone_hash,
    };
    token_matches(&token, hash).then_some(ch)
}

async fn register(State(relay): State<Relay>, Json(body): Json<RegisterChannel>) -> Response {
    let (Ok(id), Ok(agent_hash), Ok(phone_hash)) = (
        unb64::<16>(&body.channel_id),
        unb64::<32>(&body.agent_token_hash),
        unb64::<32>(&body.phone_token_hash),
    ) else {
        return err(StatusCode::BAD_REQUEST, "invalid channel registration");
    };
    if agent_hash == phone_hash {
        return err(StatusCode::BAD_REQUEST, "invalid channel registration");
    }
    let mut inner = relay.inner.lock().await;
    if inner.window_start.elapsed() > Duration::from_secs(60) {
        inner.window_start = Instant::now();
        inner.registrations_in_window = 0;
    }
    if inner.registrations_in_window >= REGISTRATIONS_PER_MINUTE || inner.channels.len() >= MAX_CHANNELS {
        return err(StatusCode::TOO_MANY_REQUESTS, "try again later");
    }
    if inner.channels.contains_key(&id) {
        return err(StatusCode::CONFLICT, "channel exists");
    }
    inner.registrations_in_window += 1;
    inner.channels.insert(
        id,
        Channel {
            stored: StoredChannel { agent_hash, phone_hash, paired: false, push: None },
            created: Instant::now(),
            pair_blob: None,
            requests: HashMap::new(),
            decisions: HashMap::new(),
        },
    );
    StatusCode::CREATED.into_response()
}

async fn post_pair(
    State(relay): State<Relay>,
    Path(c): Path<String>,
    headers: HeaderMap,
    Json(body): Json<PairResponse>,
) -> Response {
    if body.phone_x25519.len() > 64 || body.phone_ed25519.len() > 64 || body.mac.len() > 64 {
        return err(StatusCode::BAD_REQUEST, "invalid pairing response");
    }
    let mut inner = relay.inner.lock().await;
    let Some(ch) = authed(&mut inner, &c, &headers, Side::Phone) else { return not_found() };
    if ch.stored.paired || ch.pair_blob.is_some() {
        return err(StatusCode::CONFLICT, "already paired");
    }
    ch.pair_blob = Some(body);
    StatusCode::CREATED.into_response()
}

async fn get_pair(State(relay): State<Relay>, Path(c): Path<String>, headers: HeaderMap) -> Response {
    let mut inner = relay.inner.lock().await;
    let Some(ch) = authed(&mut inner, &c, &headers, Side::Agent) else { return not_found() };
    let Some(blob) = ch.pair_blob.take() else {
        return StatusCode::NO_CONTENT.into_response();
    };
    ch.stored.paired = true;
    relay.persist(&inner).await;
    Json(blob).into_response()
}

async fn unpair(State(relay): State<Relay>, Path(c): Path<String>, headers: HeaderMap) -> Response {
    let mut inner = relay.inner.lock().await;
    let ok = authed(&mut inner, &c, &headers, Side::Agent).is_some()
        || authed(&mut inner, &c, &headers, Side::Phone).is_some();
    if !ok {
        return not_found();
    }
    if let Ok(id) = unb64::<16>(&c) {
        inner.channels.remove(&id);
    }
    relay.persist(&inner).await;
    StatusCode::NO_CONTENT.into_response()
}

async fn post_request(
    State(relay): State<Relay>,
    Path(c): Path<String>,
    headers: HeaderMap,
    Json(body): Json<PostRequest>,
) -> Response {
    let now = now_unix();
    if !valid_approval_id(&body.approval_id)
        || !sealed_ok(&body.sealed)
        || body.expires_at <= now
        || body.expires_at > now + MAX_REQUEST_TTL_SECS
    {
        return err(StatusCode::BAD_REQUEST, "invalid request");
    }
    let mut inner = relay.inner.lock().await;
    let Some(ch) = authed(&mut inner, &c, &headers, Side::Agent) else { return not_found() };
    if !ch.stored.paired {
        return err(StatusCode::CONFLICT, "not paired");
    }
    ch.requests.retain(|_, r| r.expires_at >= now);
    if ch.requests.contains_key(&body.approval_id) || ch.decisions.contains_key(&body.approval_id) {
        return err(StatusCode::CONFLICT, "duplicate approval id");
    }
    if ch.requests.len() >= MAX_OPEN_REQUESTS {
        return err(StatusCode::TOO_MANY_REQUESTS, "too many open requests");
    }
    let expires_at = body.expires_at;
    ch.requests.insert(body.approval_id.clone(), body);
    let target = ch.stored.push.clone();
    drop(inner);

    if let (Some(apns), Some(target)) = (relay.apns.clone(), target) {
        let relay = relay.clone();
        tokio::spawn(async move {
            if apns.wake(&target, expires_at).await == push::PushOutcome::TokenGone {
                relay.forget_push(&c, &target).await;
            }
        });
    }
    StatusCode::CREATED.into_response()
}

impl Relay {
    async fn forget_push(&self, c: &str, target: &push::PushTarget) {
        let Ok(id) = unb64::<16>(c) else { return };
        let mut inner = self.inner.lock().await;
        if let Some(ch) = inner.channels.get_mut(&id) {
            if ch.stored.push.as_ref() == Some(target) {
                ch.stored.push = None;
            }
        }
        self.persist(&inner).await;
    }
}

async fn put_push(
    State(relay): State<Relay>,
    Path(c): Path<String>,
    headers: HeaderMap,
    Json(body): Json<push::PushTarget>,
) -> Response {
    if body.validate().is_err() {
        return err(StatusCode::BAD_REQUEST, "invalid push target");
    }
    let mut inner = relay.inner.lock().await;
    let Some(ch) = authed(&mut inner, &c, &headers, Side::Phone) else { return not_found() };
    if !ch.stored.paired {
        return err(StatusCode::CONFLICT, "not paired");
    }
    ch.stored.push = Some(body);
    relay.persist(&inner).await;
    StatusCode::NO_CONTENT.into_response()
}

async fn delete_push(State(relay): State<Relay>, Path(c): Path<String>, headers: HeaderMap) -> Response {
    let mut inner = relay.inner.lock().await;
    let Some(ch) = authed(&mut inner, &c, &headers, Side::Phone) else { return not_found() };
    ch.stored.push = None;
    relay.persist(&inner).await;
    StatusCode::NO_CONTENT.into_response()
}

async fn get_requests(State(relay): State<Relay>, Path(c): Path<String>, headers: HeaderMap) -> Response {
    let now = now_unix();
    let mut inner = relay.inner.lock().await;
    let Some(ch) = authed(&mut inner, &c, &headers, Side::Phone) else { return not_found() };
    ch.requests.retain(|_, r| r.expires_at >= now);
    let mut requests: Vec<PostRequest> = ch.requests.values().cloned().collect();
    requests.sort_by_key(|r| r.expires_at);
    Json(PendingRequests { requests }).into_response()
}

async fn post_decision(
    State(relay): State<Relay>,
    Path((c, id)): Path<(String, String)>,
    headers: HeaderMap,
    Json(body): Json<Sealed>,
) -> Response {
    if !valid_approval_id(&id) || !sealed_ok(&body) {
        return err(StatusCode::BAD_REQUEST, "invalid decision");
    }
    let mut inner = relay.inner.lock().await;
    let Some(ch) = authed(&mut inner, &c, &headers, Side::Phone) else { return not_found() };
    // One decision per request, and only while the request is open.
    let Some(req) = ch.requests.remove(&id) else { return not_found() };
    if req.expires_at < now_unix() {
        return not_found();
    }
    ch.decisions.insert(id, (body, req.expires_at));
    StatusCode::CREATED.into_response()
}

async fn get_decision(
    State(relay): State<Relay>,
    Path((c, id)): Path<(String, String)>,
    headers: HeaderMap,
) -> Response {
    let mut inner = relay.inner.lock().await;
    let Some(ch) = authed(&mut inner, &c, &headers, Side::Agent) else { return not_found() };
    match ch.decisions.remove(&id) {
        Some((sealed, exp)) if exp >= now_unix() => Json(sealed).into_response(),
        Some(_) => not_found(),
        None if ch.requests.contains_key(&id) => StatusCode::NO_CONTENT.into_response(),
        None => not_found(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::body::Body;
    use axum::http::Request;
    use http_body_util::BodyExt;
    use tower::ServiceExt;
    use zipher_hitl_protocol::*;

    async fn call(app: &Router, method: &str, path: &str, token: Option<&[u8; 32]>, body: Option<serde_json::Value>) -> (StatusCode, serde_json::Value) {
        let mut req = Request::builder().method(method).uri(path);
        if let Some(t) = token {
            req = req.header("authorization", format!("Bearer {}", b64(t)));
        }
        let req = match body {
            Some(b) => req.header("content-type", "application/json").body(Body::from(b.to_string())),
            None => req.body(Body::empty()),
        }
        .unwrap();
        let resp = app.clone().oneshot(req).await.unwrap();
        let status = resp.status();
        let bytes = resp.into_body().collect().await.unwrap().to_bytes();
        (status, serde_json::from_slice(&bytes).unwrap_or(serde_json::Value::Null))
    }

    struct Setup {
        app: Router,
        agent: AgentSecret,
        offer: PairingOffer,
        phone: PhoneKeys,
        pinned: PhonePublic,
        c: String,
    }

    async fn paired_setup() -> Setup {
        let app = Relay::new(None).router();
        let agent = AgentSecret::generate();
        let offer = PairingOffer::new("https://relay.example", "agent", &agent).unwrap();
        let tokens = offer.tokens();
        let c = b64(&offer.channel_id);
        let reg = serde_json::json!({
            "channel_id": c,
            "agent_token_hash": b64(&token_hash(&tokens.agent)),
            "phone_token_hash": b64(&token_hash(&tokens.phone)),
        });
        assert_eq!(call(&app, "POST", "/v1/channels", None, Some(reg.clone())).await.0, StatusCode::CREATED);
        assert_eq!(call(&app, "POST", "/v1/channels", None, Some(reg)).await.0, StatusCode::CONFLICT);

        // Phone side reads only the URI.
        let phone_offer = PairingOffer::from_uri(&offer.to_uri()).unwrap();
        let phone = PhoneKeys::generate();
        let resp = make_pair_response(&phone_offer, &phone);
        let pair_path = format!("/v1/channels/{c}/pair");
        assert_eq!(
            call(&app, "GET", &pair_path, Some(&tokens.agent), None).await.0,
            StatusCode::NO_CONTENT
        );
        // The agent token cannot post as the phone.
        assert_eq!(
            call(&app, "POST", &pair_path, Some(&tokens.agent), Some(serde_json::to_value(&resp).unwrap())).await.0,
            StatusCode::NOT_FOUND
        );
        assert_eq!(
            call(&app, "POST", &pair_path, Some(&phone_offer.tokens().phone), Some(serde_json::to_value(&resp).unwrap())).await.0,
            StatusCode::CREATED
        );
        let (s, blob) = call(&app, "GET", &pair_path, Some(&tokens.agent), None).await;
        assert_eq!(s, StatusCode::OK);
        let pinned = verify_pair_response(&offer, &serde_json::from_value(blob).unwrap()).unwrap();
        Setup { app, agent, offer, phone, pinned, c }
    }

    fn request_for(now: u64) -> ApprovalRequest {
        ApprovalRequest {
            approval_id: new_approval_id(),
            network: "main".into(),
            address: "u1merchant".into(),
            amount: 250_000_000,
            fee: 10_000,
            memo: None,
            context_id: Some("order-9".into()),
            tool: "propose_send".into(),
            created_at: now,
            expires_at: now + 300,
        }
    }

    #[tokio::test]
    async fn full_flow_through_the_relay() {
        let s = paired_setup().await;
        let tokens = s.offer.tokens();
        let now = now_unix();
        let req = request_for(now);
        let sealed = seal_request(&s.agent, &s.pinned, &s.offer.channel_id, &req).unwrap();
        let post = serde_json::to_value(PostRequest { approval_id: req.approval_id.clone(), expires_at: req.expires_at, sealed }).unwrap();
        let req_path = format!("/v1/channels/{}/requests", s.c);
        assert_eq!(call(&s.app, "POST", &req_path, Some(&tokens.agent), Some(post.clone())).await.0, StatusCode::CREATED);
        assert_eq!(call(&s.app, "POST", &req_path, Some(&tokens.agent), Some(post)).await.0, StatusCode::CONFLICT);

        let dec_path = format!("/v1/channels/{}/decisions/{}", s.c, req.approval_id);
        assert_eq!(call(&s.app, "GET", &dec_path, Some(&tokens.agent), None).await.0, StatusCode::NO_CONTENT);

        // Phone polls, decrypts and signs.
        let (st, list) = call(&s.app, "GET", &req_path, Some(&tokens.phone), None).await;
        assert_eq!(st, StatusCode::OK);
        let list: PendingRequests = serde_json::from_value(list).unwrap();
        assert_eq!(list.requests.len(), 1);
        let item = &list.requests[0];
        let opened = open_request(&s.phone, &s.offer.agent_public, &s.offer.channel_id, &item.approval_id, &item.sealed).unwrap();
        assert_eq!(opened, req);
        let d = sign_decision(&s.phone, &opened, true, now + 1);
        let sealed_d = seal_decision(&s.phone, &s.offer.agent_public, &s.offer.channel_id, &d).unwrap();
        let body = serde_json::to_value(&sealed_d).unwrap();
        assert_eq!(call(&s.app, "POST", &dec_path, Some(&tokens.phone), Some(body.clone())).await.0, StatusCode::CREATED);
        // Only one decision per request.
        assert_eq!(call(&s.app, "POST", &dec_path, Some(&tokens.phone), Some(body)).await.0, StatusCode::NOT_FOUND);

        // Agent reads it once, then it is gone.
        let (st, got) = call(&s.app, "GET", &dec_path, Some(&tokens.agent), None).await;
        assert_eq!(st, StatusCode::OK);
        let got: Sealed = serde_json::from_value(got).unwrap();
        let decision = open_decision(&s.agent, &s.pinned, &s.offer.channel_id, &req.approval_id, &got).unwrap();
        assert!(verify_decision(&s.pinned, &req, &decision, now + 2).unwrap());
        assert_eq!(call(&s.app, "GET", &dec_path, Some(&tokens.agent), None).await.0, StatusCode::NOT_FOUND);
        let (_, list) = call(&s.app, "GET", &req_path, Some(&tokens.phone), None).await;
        assert!(list["requests"].as_array().unwrap().is_empty());
    }

    #[tokio::test]
    async fn wrong_tokens_and_bad_input_are_rejected() {
        let s = paired_setup().await;
        let tokens = s.offer.tokens();
        let req_path = format!("/v1/channels/{}/requests", s.c);
        assert_eq!(call(&s.app, "GET", &req_path, None, None).await.0, StatusCode::NOT_FOUND);
        assert_eq!(call(&s.app, "GET", &req_path, Some(&[1u8; 32]), None).await.0, StatusCode::NOT_FOUND);
        assert_eq!(call(&s.app, "GET", &req_path, Some(&tokens.agent), None).await.0, StatusCode::NOT_FOUND);

        let now = now_unix();
        let sealed = Sealed { nonce: b64(&[0u8; 24]), ciphertext: "A".repeat(10) };
        let too_long = serde_json::json!({"approval_id": new_approval_id(), "expires_at": now + MAX_REQUEST_TTL_SECS + 5, "sealed": sealed});
        assert_eq!(call(&s.app, "POST", &req_path, Some(&tokens.agent), Some(too_long)).await.0, StatusCode::BAD_REQUEST);
        let big = Sealed { nonce: b64(&[0u8; 24]), ciphertext: "A".repeat(MAX_BLOB_CHARS + 1) };
        let big = serde_json::json!({"approval_id": new_approval_id(), "expires_at": now + 60, "sealed": big});
        assert_eq!(call(&s.app, "POST", &req_path, Some(&tokens.agent), Some(big)).await.0, StatusCode::BAD_REQUEST);

        for _ in 0..MAX_OPEN_REQUESTS {
            let ok = serde_json::json!({"approval_id": new_approval_id(), "expires_at": now + 60, "sealed": sealed});
            assert_eq!(call(&s.app, "POST", &req_path, Some(&tokens.agent), Some(ok)).await.0, StatusCode::CREATED);
        }
        let ok = serde_json::json!({"approval_id": new_approval_id(), "expires_at": now + 60, "sealed": sealed});
        assert_eq!(call(&s.app, "POST", &req_path, Some(&tokens.agent), Some(ok)).await.0, StatusCode::TOO_MANY_REQUESTS);

        // Either side can unpair; afterwards the channel is gone.
        assert_eq!(call(&s.app, "DELETE", &format!("/v1/channels/{}", s.c), Some(&tokens.phone), None).await.0, StatusCode::NO_CONTENT);
        assert_eq!(call(&s.app, "GET", &req_path, Some(&tokens.phone), None).await.0, StatusCode::NOT_FOUND);
    }

    #[tokio::test]
    async fn push_is_content_free_signed_and_drops_dead_tokens() {
        use ring::signature::{EcdsaKeyPair, KeyPair, UnparsedPublicKey, ECDSA_P256_SHA256_FIXED, ECDSA_P256_SHA256_FIXED_SIGNING};
        use std::sync::Mutex as StdMutex;

        // Mock APNs: records each push, answers 200 then 410.
        #[derive(Clone, Default)]
        struct Seen(Arc<StdMutex<Vec<(String, HeaderMap, String)>>>);
        let seen = Seen::default();
        let calls = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let mock = {
            let seen = seen.clone();
            let calls = calls.clone();
            Router::new().route(
                "/3/device/{token}",
                post(move |Path(token): Path<String>, headers: HeaderMap, body: String| {
                    let seen = seen.clone();
                    let calls = calls.clone();
                    async move {
                        seen.0.lock().unwrap().push((token, headers, body));
                        if calls.fetch_add(1, std::sync::atomic::Ordering::SeqCst) == 0 {
                            StatusCode::OK
                        } else {
                            StatusCode::GONE
                        }
                    }
                }),
            )
        };
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let mock_url = format!("http://{}", listener.local_addr().unwrap());
        tokio::spawn(async move { axum::serve(listener, mock).await.unwrap() });

        let rng = ring::rand::SystemRandom::new();
        let pkcs8 = EcdsaKeyPair::generate_pkcs8(&ECDSA_P256_SHA256_FIXED_SIGNING, &rng).unwrap();
        let public = EcdsaKeyPair::from_pkcs8(&ECDSA_P256_SHA256_FIXED_SIGNING, pkcs8.as_ref(), &rng)
            .unwrap()
            .public_key()
            .as_ref()
            .to_vec();
        use base64::Engine as _;
        let pem = format!(
            "-----BEGIN PRIVATE KEY-----\n{}\n-----END PRIVATE KEY-----\n",
            base64::engine::general_purpose::STANDARD.encode(pkcs8.as_ref())
        );
        let apns = push::Apns::new(&pem, "KEYID12345", "TEAMID1234", "dev.atmospherelabs.zipher", Some(mock_url)).unwrap();

        let relay = Relay::new(None).with_apns(apns);
        let app = relay.clone().router();
        let agent = AgentSecret::generate();
        let offer = PairingOffer::new("https://relay.example", "agent", &agent).unwrap();
        let t = offer.tokens();
        let c = b64(&offer.channel_id);
        let reg = serde_json::json!({"channel_id": c, "agent_token_hash": b64(&token_hash(&t.agent)), "phone_token_hash": b64(&token_hash(&t.phone))});
        call(&app, "POST", "/v1/channels", None, Some(reg)).await;
        let phone = PhoneKeys::generate();
        call(&app, "POST", &format!("/v1/channels/{c}/pair"), Some(&t.phone), Some(serde_json::to_value(make_pair_response(&offer, &phone)).unwrap())).await;
        let (_, blob) = call(&app, "GET", &format!("/v1/channels/{c}/pair"), Some(&t.agent), None).await;
        let pinned = verify_pair_response(&offer, &serde_json::from_value(blob).unwrap()).unwrap();

        let push_path = format!("/v1/channels/{c}/push");
        let token = "a".repeat(64);
        let target = serde_json::json!({"platform": "apns", "token": token, "sandbox": true});
        assert_eq!(call(&app, "PUT", &push_path, Some(&t.agent), Some(target.clone())).await.0, StatusCode::NOT_FOUND);
        assert_eq!(call(&app, "PUT", &push_path, Some(&t.phone), Some(serde_json::json!({"platform": "apns", "token": "zz"}))).await.0, StatusCode::BAD_REQUEST);
        assert_eq!(call(&app, "PUT", &push_path, Some(&t.phone), Some(target)).await.0, StatusCode::NO_CONTENT);

        let send = |amount: u64| {
            let now = now_unix();
            let req = ApprovalRequest {
                approval_id: new_approval_id(), network: "main".into(), address: "u1secretaddress".into(),
                amount, fee: 10_000, memo: Some("secret memo".into()), context_id: None,
                tool: "propose_send".into(), created_at: now, expires_at: now + 300,
            };
            let sealed = seal_request(&agent, &pinned, &offer.channel_id, &req).unwrap();
            serde_json::to_value(PostRequest { approval_id: req.approval_id.clone(), expires_at: req.expires_at, sealed }).unwrap()
        };
        let req_path = format!("/v1/channels/{c}/requests");
        call(&app, "POST", &req_path, Some(&t.agent), Some(send(123_456_789))).await;
        for _ in 0..50 {
            if !seen.0.lock().unwrap().is_empty() { break }
            tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        }
        {
            let got = seen.0.lock().unwrap();
            assert_eq!(got.len(), 1);
            let (tok, headers, body) = &got[0];
            assert_eq!(tok, &token);
            assert_eq!(headers["apns-topic"], "dev.atmospherelabs.zipher");
            assert_eq!(headers["apns-push-type"], "alert");
            // Nothing about the payment reaches Apple.
            for secret in ["123456789", "1.23456789", "u1secretaddress", "secret memo"] {
                assert!(!body.contains(secret), "push leaked {secret}");
            }
            // The provider token verifies with the key's public half.
            let jwt = headers["authorization"].to_str().unwrap().strip_prefix("bearer ").unwrap();
            let (input, sig) = jwt.rsplit_once('.').unwrap();
            let sig = base64::engine::general_purpose::URL_SAFE_NO_PAD.decode(sig).unwrap();
            UnparsedPublicKey::new(&ECDSA_P256_SHA256_FIXED, &public).verify(input.as_bytes(), &sig).unwrap();
        }

        // Second push gets 410 Gone: the relay forgets the token.
        call(&app, "POST", &req_path, Some(&t.agent), Some(send(1))).await;
        for _ in 0..50 {
            let gone = relay.inner.lock().await.channels.values().all(|ch| ch.stored.push.is_none());
            if gone { break }
            tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        }
        assert!(relay.inner.lock().await.channels.values().all(|ch| ch.stored.push.is_none()));
    }

    #[tokio::test]
    async fn paired_channels_survive_restart_but_messages_do_not() {
        let dir = std::env::temp_dir().join(format!("zipher-relay-test-{}", new_approval_id()));
        std::fs::create_dir_all(&dir).unwrap();
        let file = dir.join("channels.json");
        let relay = Relay::new(Some(file.clone()));
        let app = relay.clone().router();
        let agent = AgentSecret::generate();
        let offer = PairingOffer::new("https://relay.example", "agent", &agent).unwrap();
        let t = offer.tokens();
        let c = b64(&offer.channel_id);
        let reg = serde_json::json!({"channel_id": c, "agent_token_hash": b64(&token_hash(&t.agent)), "phone_token_hash": b64(&token_hash(&t.phone))});
        call(&app, "POST", "/v1/channels", None, Some(reg)).await;
        let resp = make_pair_response(&offer, &PhoneKeys::generate());
        call(&app, "POST", &format!("/v1/channels/{c}/pair"), Some(&t.phone), Some(serde_json::to_value(&resp).unwrap())).await;
        call(&app, "GET", &format!("/v1/channels/{c}/pair"), Some(&t.agent), None).await;

        let saved = std::fs::read_to_string(&file).unwrap();
        assert!(!saved.contains(&b64(t.agent.as_ref())) && !saved.contains(&b64(t.phone.as_ref())));

        let restarted = Relay::new(Some(file));
        assert_eq!(restarted.load().await.unwrap(), 1);
        let app2 = restarted.router();
        let (st, list) = call(&app2, "GET", &format!("/v1/channels/{c}/requests"), Some(&t.phone), None).await;
        assert_eq!(st, StatusCode::OK);
        assert!(list["requests"].as_array().unwrap().is_empty());
        std::fs::remove_dir_all(dir).unwrap();
    }
}
