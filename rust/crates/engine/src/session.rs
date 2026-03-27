use anyhow::{anyhow, Result};
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

// ---------------------------------------------------------------------------
// Session-based payments — CipherPay prepaid credit model
//
// Flow:
// 1. Agent sends shielded ZEC with memo to merchant's address
// 2. Agent calls CipherPay POST /api/sessions/open with {txid, merchant_id}
// 3. CipherPay verifies payment, issues bearer token + credit balance
// 4. Agent uses Authorization: Bearer {token} for subsequent requests (instant)
// 5. Merchant validates token with CipherPay (cacheable, sub-ms)
// 6. When balance depletes or session expires, agent gets 402 again
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Session {
    pub session_id: String,
    pub bearer_token: String,
    pub server_url: String,
    pub deposit_txid: String,
    pub balance_remaining: u64,
    pub expires_at: String,
    pub created_at: String,
    pub cost_per_request: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionSummary {
    pub session_id: String,
    pub requests_made: u64,
    pub balance_used: u64,
    pub balance_remaining: u64,
    pub status: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionStore {
    pub sessions: Vec<Session>,
}

impl SessionStore {
    pub fn new() -> Self {
        Self { sessions: Vec::new() }
    }

    pub fn add(&mut self, session: Session) {
        self.sessions.retain(|s| s.session_id != session.session_id);
        self.sessions.push(session);
    }

    pub fn remove(&mut self, session_id: &str) {
        self.sessions.retain(|s| s.session_id != session_id);
    }

    pub fn find_for_server(&self, server_url: &str) -> Option<&Session> {
        self.sessions
            .iter()
            .find(|s| s.server_url == server_url && s.balance_remaining > 0)
    }

    pub fn find_by_id(&self, session_id: &str) -> Option<&Session> {
        self.sessions.iter().find(|s| s.session_id == session_id)
    }
}

impl Default for SessionStore {
    fn default() -> Self {
        Self::new()
    }
}

// ---------------------------------------------------------------------------
// Persistence
// ---------------------------------------------------------------------------

fn sessions_path(data_dir: &str) -> PathBuf {
    Path::new(data_dir).join("sessions.json")
}

pub fn load_sessions(data_dir: &str) -> SessionStore {
    let path = sessions_path(data_dir);
    match std::fs::read_to_string(&path) {
        Ok(contents) => serde_json::from_str(&contents).unwrap_or_default(),
        Err(_) => SessionStore::new(),
    }
}

pub fn save_sessions(data_dir: &str, store: &SessionStore) -> Result<()> {
    let path = sessions_path(data_dir);
    let json = serde_json::to_string_pretty(store)?;
    std::fs::write(path, json)?;
    Ok(())
}

// ---------------------------------------------------------------------------
// CipherPay session API client
// ---------------------------------------------------------------------------

const CIPHERPAY_SESSION_BASE: &str = "https://api.cipherpay.app";

fn resolve_cipherpay_url(override_url: Option<&str>) -> String {
    if let Some(url) = override_url {
        return url.to_string();
    }
    std::env::var("CIPHERPAY_URL").unwrap_or_else(|_| CIPHERPAY_SESSION_BASE.to_string())
}

fn client() -> reqwest::Client {
    reqwest::Client::new()
}

/// Open a new session by notifying CipherPay of a deposit transaction.
///
/// The agent must have already sent ZEC to the merchant's address with
/// a memo containing `zipher:session:{merchant_id}`.
pub async fn open_session(
    cipherpay_url: Option<&str>,
    txid: &str,
    merchant_id: &str,
    server_url: &str,
    data_dir: &str,
) -> Result<Session> {
    let base = resolve_cipherpay_url(cipherpay_url);

    let resp = client()
        .post(format!("{base}/api/sessions/open"))
        .json(&serde_json::json!({
            "txid": txid,
            "merchant_id": merchant_id,
        }))
        .send()
        .await
        .map_err(|e| anyhow!("Session open request failed: {e}"))?;

    if !resp.status().is_success() {
        let status = resp.status();
        let body = resp.text().await.unwrap_or_default();
        return Err(anyhow!("Session open failed ({}): {}", status, body));
    }

    let json: serde_json::Value = resp
        .json()
        .await
        .map_err(|e| anyhow!("Failed to parse session response: {e}"))?;

    let session = Session {
        session_id: json["session_id"]
            .as_str()
            .unwrap_or("")
            .to_string(),
        bearer_token: json["bearer_token"]
            .as_str()
            .unwrap_or("")
            .to_string(),
        server_url: server_url.to_string(),
        deposit_txid: txid.to_string(),
        balance_remaining: json["balance"]
            .as_u64()
            .or_else(|| json["balance_remaining"].as_u64())
            .unwrap_or(0),
        expires_at: json["expires_at"]
            .as_str()
            .unwrap_or("")
            .to_string(),
        created_at: now_iso(),
        cost_per_request: json["cost_per_request"]
            .as_u64()
            .unwrap_or(0),
    };

    if session.session_id.is_empty() || session.bearer_token.is_empty() {
        return Err(anyhow!("Invalid session response: missing session_id or bearer_token"));
    }

    let mut store = load_sessions(data_dir);
    store.add(session.clone());
    save_sessions(data_dir, &store)?;

    Ok(session)
}

/// Make an authenticated request using a session's bearer token.
pub async fn session_request(
    session: &Session,
    url: &str,
    method: &str,
) -> Result<(u16, String, Option<u64>)> {
    let client = client();
    let builder = match method.to_uppercase().as_str() {
        "POST" => client.post(url),
        "PUT" => client.put(url),
        "DELETE" => client.delete(url),
        _ => client.get(url),
    };

    let resp = builder
        .header("Authorization", format!("Bearer {}", session.bearer_token))
        .send()
        .await
        .map_err(|e| anyhow!("Session request failed: {e}"))?;

    let status = resp.status().as_u16();
    let remaining = resp
        .headers()
        .get("x-session-balance")
        .and_then(|v| v.to_str().ok())
        .and_then(|s| s.parse::<u64>().ok());
    let body = resp.text().await.unwrap_or_default();

    Ok((status, body, remaining))
}

/// Check session balance with CipherPay.
pub async fn check_session(
    cipherpay_url: Option<&str>,
    session_id: &str,
) -> Result<SessionSummary> {
    let base = resolve_cipherpay_url(cipherpay_url);

    let resp = client()
        .get(format!("{base}/api/sessions/{session_id}"))
        .send()
        .await
        .map_err(|e| anyhow!("Session check failed: {e}"))?;

    if !resp.status().is_success() {
        let status = resp.status();
        let body = resp.text().await.unwrap_or_default();
        return Err(anyhow!("Session check failed ({}): {}", status, body));
    }

    let summary: SessionSummary = resp
        .json()
        .await
        .map_err(|e| anyhow!("Failed to parse session status: {e}"))?;
    Ok(summary)
}

/// Close a session and get final summary.
pub async fn close_session(
    cipherpay_url: Option<&str>,
    session_id: &str,
    data_dir: &str,
) -> Result<SessionSummary> {
    let base = resolve_cipherpay_url(cipherpay_url);

    let resp = client()
        .post(format!("{base}/api/sessions/{session_id}/close"))
        .send()
        .await
        .map_err(|e| anyhow!("Session close failed: {e}"))?;

    if !resp.status().is_success() {
        let status = resp.status();
        let body = resp.text().await.unwrap_or_default();
        return Err(anyhow!("Session close failed ({}): {}", status, body));
    }

    let summary: SessionSummary = resp
        .json()
        .await
        .map_err(|e| anyhow!("Failed to parse close response: {e}"))?;

    let mut store = load_sessions(data_dir);
    store.remove(session_id);
    save_sessions(data_dir, &store)?;

    Ok(summary)
}

/// List all active sessions.
pub fn list_sessions(data_dir: &str) -> Vec<Session> {
    let store = load_sessions(data_dir);
    store.sessions
}

/// Find an active session for a given server URL.
pub fn find_session(data_dir: &str, server_url: &str) -> Option<Session> {
    let store = load_sessions(data_dir);
    store.find_for_server(server_url).cloned()
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn now_iso() -> String {
    let secs = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs();

    let days = secs / 86400;
    let time_secs = secs % 86400;
    let hours = time_secs / 3600;
    let minutes = (time_secs % 3600) / 60;
    let seconds = time_secs % 60;

    let (year, month, day) = days_to_ymd(days);

    format!(
        "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}Z",
        year, month, day, hours, minutes, seconds
    )
}

fn days_to_ymd(mut days: u64) -> (u64, u64, u64) {
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

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn session_store_operations() {
        let mut store = SessionStore::new();
        assert_eq!(store.sessions.len(), 0);

        let session = Session {
            session_id: "s1".into(),
            bearer_token: "tok1".into(),
            server_url: "https://api.example.com".into(),
            deposit_txid: "txid1".into(),
            balance_remaining: 100000,
            expires_at: "2026-04-01T00:00:00Z".into(),
            created_at: "2026-03-16T00:00:00Z".into(),
            cost_per_request: 1000,
        };

        store.add(session.clone());
        assert_eq!(store.sessions.len(), 1);
        assert!(store.find_for_server("https://api.example.com").is_some());
        assert!(store.find_for_server("https://other.com").is_none());
        assert!(store.find_by_id("s1").is_some());

        store.remove("s1");
        assert_eq!(store.sessions.len(), 0);
    }

    #[test]
    fn session_store_dedup() {
        let mut store = SessionStore::new();

        let s1 = Session {
            session_id: "s1".into(),
            bearer_token: "tok1".into(),
            server_url: "https://api.example.com".into(),
            deposit_txid: "txid1".into(),
            balance_remaining: 100000,
            expires_at: "2026-04-01T00:00:00Z".into(),
            created_at: "2026-03-16T00:00:00Z".into(),
            cost_per_request: 1000,
        };

        store.add(s1.clone());
        store.add(Session {
            bearer_token: "tok2".into(),
            ..s1
        });

        assert_eq!(store.sessions.len(), 1);
        assert_eq!(store.sessions[0].bearer_token, "tok2");
    }

    #[test]
    fn serialization_roundtrip() {
        let store = SessionStore {
            sessions: vec![Session {
                session_id: "s1".into(),
                bearer_token: "tok1".into(),
                server_url: "https://api.example.com".into(),
                deposit_txid: "txid1".into(),
                balance_remaining: 50000,
                expires_at: "2026-04-01T00:00:00Z".into(),
                created_at: "2026-03-16T00:00:00Z".into(),
                cost_per_request: 500,
            }],
        };

        let json = serde_json::to_string(&store).unwrap();
        let parsed: SessionStore = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed.sessions.len(), 1);
        assert_eq!(parsed.sessions[0].session_id, "s1");
    }
}
