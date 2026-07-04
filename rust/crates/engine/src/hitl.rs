//! Mobile HITL (Human-In-The-Loop) Approval Relay
//!
//! Connects headless agents (CLI/MCP) to the Zipher mobile app for
//! transaction approvals that exceed spending policy thresholds.
//!
//! Architecture:
//! - Agent stores pending approval locally (existing policy module)
//! - Agent POSTs approval request to relay server
//! - Mobile polls relay for pending requests
//! - Mobile submits approve/reject decision
//! - Agent polls relay for the decision
//!
//! Security invariants:
//! - Relay never sees seeds, private keys, or signed transactions
//! - Approval payloads are bound to (address, amount, context_id, expiry)
//! - Relay only carries metadata; signing happens locally in the engine

use anyhow::{anyhow, Result};
use serde::{Deserialize, Serialize};
use std::sync::Mutex;
use std::time::Duration;

const DEFAULT_RELAY_URL: &str = "https://relay.atmospherelabs.dev";
const APPROVAL_TTL: Duration = Duration::from_secs(300);

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

/// An approval request sent to the relay for mobile review.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HitlApprovalRequest {
    pub approval_id: String,
    pub channel_id: String,
    pub address: String,
    pub amount: u64,
    pub amount_zec: f64,
    pub memo_preview: Option<String>,
    pub context_id: Option<String>,
    pub tool_name: String,
    pub created_at_unix: u64,
    pub expires_at_unix: u64,
}

/// The decision sent back from the mobile app.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HitlDecision {
    pub approval_id: String,
    pub approved: bool,
    pub decided_at_unix: u64,
    /// Optional reason for rejection
    pub reason: Option<String>,
}

/// Pairing state stored locally — derived from `zipher pair <code>`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HitlPairing {
    pub channel_id: String,
    pub device_name: String,
    pub paired_at_unix: u64,
    pub relay_url: String,
}

/// Configuration for the HITL relay.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HitlConfig {
    pub enabled: bool,
    pub relay_url: String,
    pub pairing: Option<HitlPairing>,
}

impl Default for HitlConfig {
    fn default() -> Self {
        Self {
            enabled: false,
            relay_url: DEFAULT_RELAY_URL.to_string(),
            pairing: None,
        }
    }
}

// ---------------------------------------------------------------------------
// Local state
// ---------------------------------------------------------------------------

static HITL_CONFIG: Mutex<Option<HitlConfig>> = Mutex::new(None);

/// Load HITL config from data_dir. Returns default (disabled) if not found.
pub fn load_config(data_dir: &str) -> HitlConfig {
    let path = std::path::PathBuf::from(data_dir).join("hitl.json");
    match std::fs::read_to_string(&path) {
        Ok(data) => serde_json::from_str(&data).unwrap_or_default(),
        Err(_) => HitlConfig::default(),
    }
}

/// Save HITL config to data_dir.
pub fn save_config(data_dir: &str, config: &HitlConfig) -> Result<()> {
    let path = std::path::PathBuf::from(data_dir).join("hitl.json");
    let json = serde_json::to_string_pretty(config)?;
    std::fs::write(&path, json)?;
    *HITL_CONFIG.lock().unwrap() = Some(config.clone());
    Ok(())
}

/// Get the cached config (or load from disk).
pub fn get_config(data_dir: &str) -> HitlConfig {
    let guard = HITL_CONFIG.lock().unwrap();
    match guard.as_ref() {
        Some(c) => c.clone(),
        None => {
            drop(guard);
            let c = load_config(data_dir);
            *HITL_CONFIG.lock().unwrap() = Some(c.clone());
            c
        }
    }
}

// ---------------------------------------------------------------------------
// Pairing
// ---------------------------------------------------------------------------

/// Generate a pairing code for mobile to scan.
/// Returns (channel_id, pairing_code) where pairing_code is a short-lived token.
pub fn generate_pairing_code(data_dir: &str) -> Result<(String, String)> {
    let channel_id = format!("ch_{:016x}", rand::random::<u64>());
    let pairing_code = format!(
        "zipher://pair?channel={}&relay={}",
        channel_id,
        get_config(data_dir).relay_url,
    );
    Ok((channel_id, pairing_code))
}

/// Complete pairing from the agent side (after mobile confirms).
pub fn complete_pairing(
    data_dir: &str,
    channel_id: &str,
    device_name: &str,
    relay_url: Option<&str>,
) -> Result<HitlConfig> {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs();

    let mut config = get_config(data_dir);
    config.enabled = true;
    config.pairing = Some(HitlPairing {
        channel_id: channel_id.to_string(),
        device_name: device_name.to_string(),
        paired_at_unix: now,
        relay_url: relay_url.unwrap_or(DEFAULT_RELAY_URL).to_string(),
    });
    if let Some(url) = relay_url {
        config.relay_url = url.to_string();
    }
    save_config(data_dir, &config)?;
    Ok(config)
}

// ---------------------------------------------------------------------------
// Relay communication (agent side)
// ---------------------------------------------------------------------------

/// Push an approval request to the relay for mobile to review.
pub async fn push_approval_request(
    data_dir: &str,
    approval_id: &str,
    address: &str,
    amount: u64,
    memo: Option<&str>,
    context_id: Option<&str>,
    tool_name: &str,
) -> Result<()> {
    let config = get_config(data_dir);
    if !config.enabled {
        return Ok(());
    }
    let pairing = config.pairing.as_ref().ok_or_else(|| {
        anyhow!("HITL enabled but no pairing configured. Run `zipher pair` first.")
    })?;

    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs();

    let request = HitlApprovalRequest {
        approval_id: approval_id.to_string(),
        channel_id: pairing.channel_id.clone(),
        address: address.to_string(),
        amount,
        amount_zec: amount as f64 / 1e8,
        memo_preview: memo.map(|m| {
            if m.len() > 50 {
                format!("{}...", &m[..47])
            } else {
                m.to_string()
            }
        }),
        context_id: context_id.map(|s| s.to_string()),
        tool_name: tool_name.to_string(),
        created_at_unix: now,
        expires_at_unix: now + APPROVAL_TTL.as_secs(),
    };

    let client = reqwest::Client::new();
    let resp = client
        .post(format!("{}/api/hitl/request", pairing.relay_url))
        .json(&request)
        .timeout(Duration::from_secs(10))
        .send()
        .await
        .map_err(|e| anyhow!("Relay push failed: {e}"))?;

    if !resp.status().is_success() {
        let status = resp.status();
        let body = resp.text().await.unwrap_or_default();
        return Err(anyhow!("Relay returned {}: {}", status, body));
    }

    tracing::info!(
        "[HITL] Pushed approval request {} to relay (channel={})",
        approval_id,
        &pairing.channel_id[..8]
    );
    Ok(())
}

/// Poll the relay for a decision on a specific approval.
/// Returns None if no decision yet (still pending).
pub async fn poll_decision(data_dir: &str, approval_id: &str) -> Result<Option<HitlDecision>> {
    let config = get_config(data_dir);
    if !config.enabled {
        return Ok(None);
    }
    let pairing = config.pairing.as_ref().ok_or_else(|| {
        anyhow!("HITL enabled but no pairing configured.")
    })?;

    let client = reqwest::Client::new();
    let resp = client
        .get(format!(
            "{}/api/hitl/decision/{}",
            pairing.relay_url, approval_id
        ))
        .header("X-Channel-Id", &pairing.channel_id)
        .timeout(Duration::from_secs(10))
        .send()
        .await
        .map_err(|e| anyhow!("Relay poll failed: {e}"))?;

    if resp.status() == reqwest::StatusCode::NOT_FOUND {
        return Ok(None);
    }

    if !resp.status().is_success() {
        let status = resp.status();
        let body = resp.text().await.unwrap_or_default();
        return Err(anyhow!("Relay returned {}: {}", status, body));
    }

    let decision: HitlDecision = resp.json().await.map_err(|e| anyhow!("Parse failed: {e}"))?;
    Ok(Some(decision))
}

// ---------------------------------------------------------------------------
// Relay communication (mobile side)
// ---------------------------------------------------------------------------

/// Fetch pending approval requests for this channel (mobile polling).
pub async fn fetch_pending_requests(
    relay_url: &str,
    channel_id: &str,
) -> Result<Vec<HitlApprovalRequest>> {
    let client = reqwest::Client::new();
    let resp = client
        .get(format!("{}/api/hitl/pending/{}", relay_url, channel_id))
        .timeout(Duration::from_secs(10))
        .send()
        .await
        .map_err(|e| anyhow!("Relay fetch failed: {e}"))?;

    if !resp.status().is_success() {
        let status = resp.status();
        let body = resp.text().await.unwrap_or_default();
        return Err(anyhow!("Relay returned {}: {}", status, body));
    }

    let requests: Vec<HitlApprovalRequest> =
        resp.json().await.map_err(|e| anyhow!("Parse failed: {e}"))?;
    Ok(requests)
}

/// Submit a decision from mobile to the relay.
pub async fn submit_decision(
    relay_url: &str,
    channel_id: &str,
    approval_id: &str,
    approved: bool,
    reason: Option<&str>,
) -> Result<()> {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs();

    let decision = HitlDecision {
        approval_id: approval_id.to_string(),
        approved,
        decided_at_unix: now,
        reason: reason.map(|s| s.to_string()),
    };

    let client = reqwest::Client::new();
    let resp = client
        .post(format!("{}/api/hitl/decision", relay_url))
        .header("X-Channel-Id", channel_id)
        .json(&decision)
        .timeout(Duration::from_secs(10))
        .send()
        .await
        .map_err(|e| anyhow!("Relay submit failed: {e}"))?;

    if !resp.status().is_success() {
        let status = resp.status();
        let body = resp.text().await.unwrap_or_default();
        return Err(anyhow!("Relay returned {}: {}", status, body));
    }

    tracing::info!(
        "[HITL] Decision submitted: approval_id={}, approved={}",
        approval_id,
        approved
    );
    Ok(())
}
