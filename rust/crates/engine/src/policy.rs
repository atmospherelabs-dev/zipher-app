use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use anyhow::Result;
use serde::{Deserialize, Serialize};

// ---------------------------------------------------------------------------
// Policy config (persisted as TOML)
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SpendingPolicy {
    /// Maximum zatoshis per single transaction (0 = unlimited)
    #[serde(default)]
    pub max_per_tx: u64,

    /// Rolling 24-hour spending cap in zatoshis (0 = unlimited)
    #[serde(default)]
    pub daily_limit: u64,

    /// Minimum milliseconds between consecutive confirm_send calls
    #[serde(default)]
    pub min_spend_interval_ms: u64,

    /// If true, every propose_send must include a context_id
    #[serde(default)]
    pub require_context_id: bool,

    /// Amount in zatoshis above which APPROVAL_REQUIRED is returned
    /// (0 = no approval threshold)
    #[serde(default)]
    pub approval_threshold: u64,

    /// If non-empty, only these destination addresses are permitted
    #[serde(default)]
    pub allowlist: Vec<String>,
}

impl Default for SpendingPolicy {
    fn default() -> Self {
        Self {
            max_per_tx: 0,
            daily_limit: 0,
            min_spend_interval_ms: 0,
            require_context_id: false,
            approval_threshold: 0,
            allowlist: Vec::new(),
        }
    }
}

// ---------------------------------------------------------------------------
// Policy error codes (deterministic, agent-consumable)
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize)]
pub enum PolicyViolation {
    PerTxExceeded { max: u64, requested: u64 },
    DailyLimitExceeded { limit: u64, spent_today: u64, requested: u64 },
    AddressNotAllowed { address: String },
    ContextRequired,
    ApprovalRequired { amount: u64, threshold: u64 },
    RateLimited { min_interval_ms: u64, elapsed_ms: u64 },
}

impl std::fmt::Display for PolicyViolation {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::PerTxExceeded { max, requested } =>
                write!(f, "POLICY_EXCEEDED: amount {} exceeds per-tx cap {}", requested, max),
            Self::DailyLimitExceeded { limit, spent_today, requested } =>
                write!(f, "POLICY_EXCEEDED: {} + today's {} exceeds daily limit {}", requested, spent_today, limit),
            Self::AddressNotAllowed { address } =>
                write!(f, "ADDRESS_NOT_ALLOWED: {} is not in the allowlist", address),
            Self::ContextRequired =>
                write!(f, "CONTEXT_REQUIRED: policy requires a context_id for every spend"),
            Self::ApprovalRequired { amount, threshold } =>
                write!(f, "APPROVAL_REQUIRED: amount {} exceeds approval threshold {}", amount, threshold),
            Self::RateLimited { min_interval_ms, elapsed_ms } =>
                write!(f, "RATE_LIMITED: {}ms since last send, minimum is {}ms", elapsed_ms, min_interval_ms),
        }
    }
}

// ---------------------------------------------------------------------------
// Rate limiter state (in-memory)
// ---------------------------------------------------------------------------

static LAST_CONFIRM: Mutex<Option<Instant>> = Mutex::new(None);

pub fn record_confirm() {
    *LAST_CONFIRM.lock().unwrap() = Some(Instant::now());
}

// ---------------------------------------------------------------------------
// Pending approval (HITL)
// ---------------------------------------------------------------------------

const APPROVAL_TTL: Duration = Duration::from_secs(300); // 5 minutes

#[derive(Debug, Clone, Serialize)]
pub struct PendingApproval {
    pub id: String,
    pub address: String,
    pub amount: u64,
    pub memo: Option<String>,
    pub context_id: Option<String>,
    #[serde(skip)]
    pub created_at: Instant,
    /// Seconds remaining before this approval expires.
    pub expires_in_secs: u64,
}

impl PendingApproval {
    pub fn is_expired(&self) -> bool {
        self.created_at.elapsed() > APPROVAL_TTL
    }

    pub fn remaining_secs(&self) -> u64 {
        APPROVAL_TTL.as_secs().saturating_sub(self.created_at.elapsed().as_secs())
    }
}

static PENDING_APPROVAL: Mutex<Option<PendingApproval>> = Mutex::new(None);

/// Store a pending approval for a transaction that exceeded the approval threshold.
/// Returns the generated approval ID.
pub fn store_pending_approval(
    address: &str,
    amount: u64,
    memo: Option<String>,
    context_id: Option<String>,
) -> String {
    let id = format!("apr_{:08x}", rand::random::<u32>());
    let pending = PendingApproval {
        id: id.clone(),
        address: address.to_string(),
        amount,
        memo,
        context_id,
        created_at: Instant::now(),
        expires_in_secs: APPROVAL_TTL.as_secs(),
    };
    *PENDING_APPROVAL.lock().unwrap() = Some(pending);
    id
}

/// Take a pending approval by ID (consuming it). Returns None if expired or wrong ID.
pub fn take_pending_approval(approval_id: &str) -> Option<PendingApproval> {
    let mut guard = PENDING_APPROVAL.lock().unwrap();
    match guard.as_ref() {
        Some(p) if p.id == approval_id && !p.is_expired() => guard.take(),
        Some(p) if p.is_expired() => {
            *guard = None;
            None
        }
        _ => None,
    }
}

/// Peek at the current pending approval without consuming it.
pub fn get_pending_approval() -> Option<PendingApproval> {
    let guard = PENDING_APPROVAL.lock().unwrap();
    match guard.as_ref() {
        Some(p) if !p.is_expired() => {
            let mut snapshot = p.clone();
            snapshot.expires_in_secs = p.remaining_secs();
            Some(snapshot)
        }
        Some(_) => None,
        None => None,
    }
}

/// Clear any pending approval (e.g. on policy change or manual cancel).
pub fn clear_pending_approval() {
    *PENDING_APPROVAL.lock().unwrap() = None;
}

// ---------------------------------------------------------------------------
// Policy file I/O
// ---------------------------------------------------------------------------

fn policy_path(data_dir: &str) -> PathBuf {
    Path::new(data_dir).join("policy.toml")
}

pub fn load_policy(data_dir: &str) -> SpendingPolicy {
    let path = policy_path(data_dir);
    if !path.exists() {
        return SpendingPolicy::default();
    }
    match std::fs::read_to_string(&path) {
        Ok(contents) => toml::from_str(&contents).unwrap_or_default(),
        Err(_) => SpendingPolicy::default(),
    }
}

pub fn save_policy(data_dir: &str, policy: &SpendingPolicy) -> Result<()> {
    let path = policy_path(data_dir);
    let contents = toml::to_string_pretty(policy)?;
    std::fs::write(&path, contents)?;
    Ok(())
}

// ---------------------------------------------------------------------------
// Policy enforcement
// ---------------------------------------------------------------------------

/// Check a proposed send against policy. Returns Ok(()) or the violation.
pub fn check_proposal(
    policy: &SpendingPolicy,
    address: &str,
    amount: u64,
    context_id: &Option<String>,
    daily_spent: u64,
) -> std::result::Result<(), PolicyViolation> {
    if policy.require_context_id {
        match context_id {
            None => return Err(PolicyViolation::ContextRequired),
            Some(id) if id.trim().is_empty() => return Err(PolicyViolation::ContextRequired),
            _ => {}
        }
    }

    if policy.max_per_tx > 0 && amount > policy.max_per_tx {
        return Err(PolicyViolation::PerTxExceeded {
            max: policy.max_per_tx,
            requested: amount,
        });
    }

    if policy.daily_limit > 0 && (daily_spent + amount) > policy.daily_limit {
        return Err(PolicyViolation::DailyLimitExceeded {
            limit: policy.daily_limit,
            spent_today: daily_spent,
            requested: amount,
        });
    }

    if !policy.allowlist.is_empty() && !policy.allowlist.iter().any(|a| a == address) {
        return Err(PolicyViolation::AddressNotAllowed {
            address: address.to_string(),
        });
    }

    if policy.approval_threshold > 0 && amount > policy.approval_threshold {
        return Err(PolicyViolation::ApprovalRequired {
            amount,
            threshold: policy.approval_threshold,
        });
    }

    Ok(())
}

/// Check rate limiting before a confirm_send.
pub fn check_rate_limit(policy: &SpendingPolicy) -> std::result::Result<(), PolicyViolation> {
    if policy.min_spend_interval_ms == 0 {
        return Ok(());
    }

    let guard = LAST_CONFIRM.lock().unwrap();
    if let Some(last) = *guard {
        let elapsed = last.elapsed().as_millis() as u64;
        if elapsed < policy.min_spend_interval_ms {
            return Err(PolicyViolation::RateLimited {
                min_interval_ms: policy.min_spend_interval_ms,
                elapsed_ms: elapsed,
            });
        }
    }
    Ok(())
}
