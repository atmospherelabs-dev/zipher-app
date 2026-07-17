use anyhow::{anyhow, Result};
use rand::Rng;
use serde::{Deserialize, Serialize};
use tracing::info;

// ---------------------------------------------------------------------------
// Constants (per Shielded Labs "Security issues in migrating user funds"
// by Zooko Wilcox and Taylor Hornby, 2026-07-15)
// ---------------------------------------------------------------------------

/// Per-note marginal fee: 50 μZEC (5000 zatoshis).
const NOTE_FEE_ZAT: u64 = 5_000;

/// Per-transaction base fee: 100 μZEC (10000 zatoshis).
const TX_FEE_ZAT: u64 = 10_000;

/// Total fee for a single-note migration: note fee + tx fee = 150 μZEC.
const MIGRATION_FEE_ZAT: u64 = NOTE_FEE_ZAT + TX_FEE_ZAT;

/// Abandon residual balance below this threshold (0.001 ZEC).
const ABANDON_THRESHOLD_ZAT: u64 = 100_000;

/// Maximum notes to consolidate in one round.
const MAX_CONSOLIDATION_NOTES: usize = 60;

// ---------------------------------------------------------------------------
// Bucket system: {1, 2, 5} × 10^k for k >= -3
// ---------------------------------------------------------------------------

/// All migration buckets in descending order (in zatoshis).
/// {1,2,5} × 10^k ZEC for k = 4,3,2,1,0,-1,-2,-3
const BUCKETS: &[u64] = &[
    500_000_000_000, // 5000 ZEC
    200_000_000_000, // 2000 ZEC
    100_000_000_000, // 1000 ZEC
    50_000_000_000,  // 500 ZEC
    20_000_000_000,  // 200 ZEC
    10_000_000_000,  // 100 ZEC
    5_000_000_000,   // 50 ZEC
    2_000_000_000,   // 20 ZEC
    1_000_000_000,   // 10 ZEC
    500_000_000,     // 5 ZEC
    200_000_000,     // 2 ZEC
    100_000_000,     // 1 ZEC
    50_000_000,      // 0.5 ZEC
    20_000_000,      // 0.2 ZEC
    10_000_000,      // 0.1 ZEC
    5_000_000,       // 0.05 ZEC
    2_000_000,       // 0.02 ZEC
    1_000_000,       // 0.01 ZEC
    500_000,         // 0.005 ZEC
    200_000,         // 0.002 ZEC
    100_000,         // 0.001 ZEC
];

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

/// The type of action to perform in one migration round.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum RoundAction {
    /// Migrate `amount_zat` through the turnstile (1 Orchard spend → 1 Ironwood output + 1 Orchard change).
    Migrate,
    /// Consolidate notes without migrating (send-to-self in Orchard to combine notes).
    Consolidate,
    /// Migration complete — balance below abandon threshold.
    Done,
}

/// Result of selecting the next migration round.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MigrationRound {
    pub action: RoundAction,
    /// Amount to migrate (only meaningful for Migrate action).
    pub amount_zat: u64,
    /// Number of notes to consolidate (only meaningful for Consolidate action).
    pub consolidate_count: usize,
}

/// Persistent migration state saved to disk.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MigrationState {
    pub started: bool,
    pub rounds_completed: u32,
    pub total_migrated_zat: u64,
    pub total_fees_zat: u64,
    pub last_round_height: Option<u32>,
    pub tor_enabled: bool,
}

impl Default for MigrationState {
    fn default() -> Self {
        Self {
            started: false,
            rounds_completed: 0,
            total_migrated_zat: 0,
            total_fees_zat: 0,
            last_round_height: None,
            tor_enabled: false,
        }
    }
}

// ---------------------------------------------------------------------------
// Core algorithm (Shielded Labs spec)
// ---------------------------------------------------------------------------

/// Compute the effective current_balance available for migration.
///
/// For each note: effective_value = max(0, note_value - NOTE_FEE_ZAT)
/// Then subtract TX_FEE_ZAT for the migration transaction itself.
///
/// For simplicity when we don't have per-note granularity, we approximate:
/// current_balance = total_orchard_balance - MIGRATION_FEE_ZAT
pub fn effective_balance(orchard_balance_zat: u64) -> u64 {
    orchard_balance_zat.saturating_sub(MIGRATION_FEE_ZAT)
}

/// Find the largest bucket <= the given balance.
/// Returns the index into BUCKETS, or None if balance < smallest bucket.
fn largest_bucket_index(balance_zat: u64) -> Option<usize> {
    BUCKETS.iter().position(|&b| b <= balance_zat)
}

/// Select the migration amount using the coin-flip algorithm.
///
/// Start at the largest bucket <= current_balance.
/// Flip fair coins: heads = step down one bucket, tails = stop.
/// If we reach the smallest bucket, stop.
///
/// Uses OsRng (CSPRNG) as required by the spec.
pub fn select_migration_amount(current_balance_zat: u64) -> Option<u64> {
    if current_balance_zat < ABANDON_THRESHOLD_ZAT {
        return None;
    }

    let start_idx = largest_bucket_index(current_balance_zat)?;
    let mut rng = rand::rngs::OsRng;
    let mut idx = start_idx;

    loop {
        // Flip: tails (true) = stop, heads (false) = step down
        if rng.gen_bool(0.5) {
            break;
        }
        // Step down
        if idx + 1 >= BUCKETS.len() {
            break; // Already at smallest bucket
        }
        idx += 1;
    }

    Some(BUCKETS[idx])
}

/// Determine what the next migration round should do.
///
/// - If balance < ABANDON_THRESHOLD: Done
/// - If there's a single note >= largest_bucket + fee: Migrate (with coin-flip amount)
/// - Otherwise: Consolidate (combine notes so next round can migrate)
///
/// `largest_note_zat`: the value of the largest single Orchard note in the wallet.
/// `note_count`: total number of Orchard notes.
/// `orchard_balance_zat`: total Orchard balance.
pub fn plan_next_round(
    orchard_balance_zat: u64,
    largest_note_zat: u64,
    note_count: usize,
) -> MigrationRound {
    let current_balance = effective_balance(orchard_balance_zat);

    if current_balance < ABANDON_THRESHOLD_ZAT {
        return MigrationRound {
            action: RoundAction::Done,
            amount_zat: 0,
            consolidate_count: 0,
        };
    }

    // Check if we can migrate: need a single note >= amount + fee
    let note_available = largest_note_zat.saturating_sub(MIGRATION_FEE_ZAT);

    if let Some(amount) = select_migration_amount(note_available) {
        MigrationRound {
            action: RoundAction::Migrate,
            amount_zat: amount,
            consolidate_count: 0,
        }
    } else if note_count > 1 {
        // Can't migrate with any single note — consolidate
        let consolidate_count = note_count.min(MAX_CONSOLIDATION_NOTES);
        MigrationRound {
            action: RoundAction::Consolidate,
            amount_zat: 0,
            consolidate_count,
        }
    } else {
        // Single note but too small to hit any bucket — we're done
        MigrationRound {
            action: RoundAction::Done,
            amount_zat: 0,
            consolidate_count: 0,
        }
    }
}

/// Generate the random delay (in seconds) for the next migration round.
///
/// D = -600 × log₂(U) where U is uniform in (0, 1].
/// Median delay = 10 minutes. ~12.5% chance of triggering within 2 minutes.
///
/// Uses OsRng (CSPRNG) as required by the spec.
pub fn random_delay_seconds() -> f64 {
    let mut rng = rand::rngs::OsRng;
    let u: f64 = rng.gen_range(f64::MIN_POSITIVE..=1.0);
    -600.0 * u.log2()
}

// ---------------------------------------------------------------------------
// State persistence
// ---------------------------------------------------------------------------

/// Load migration state from disk.
pub fn load_state(data_dir: &str) -> Result<MigrationState> {
    let path = std::path::Path::new(data_dir).join("ironwood_migration.json");
    if !path.exists() {
        return Ok(MigrationState::default());
    }
    let raw = std::fs::read_to_string(&path)?;
    let state: MigrationState =
        serde_json::from_str(&raw).map_err(|e| anyhow!("Parse migration state: {}", e))?;
    Ok(state)
}

/// Save migration state to disk.
pub fn save_state(data_dir: &str, state: &MigrationState) -> Result<()> {
    let path = std::path::Path::new(data_dir).join("ironwood_migration.json");
    let json =
        serde_json::to_string_pretty(state).map_err(|e| anyhow!("Serialize state: {}", e))?;
    std::fs::write(&path, json)?;
    Ok(())
}

/// Record a completed migration round.
pub fn record_round(
    data_dir: &str,
    amount_zat: u64,
    fee_zat: u64,
    height: u32,
) -> Result<MigrationState> {
    let mut state = load_state(data_dir)?;
    state.rounds_completed += 1;
    state.total_migrated_zat += amount_zat;
    state.total_fees_zat += fee_zat;
    state.last_round_height = Some(height);
    save_state(data_dir, &state)?;
    info!(
        "[Ironwood] Round {} complete: migrated {:.8} ZEC (total {:.8} ZEC across {} rounds)",
        state.rounds_completed,
        amount_zat as f64 / 1e8,
        state.total_migrated_zat as f64 / 1e8,
        state.rounds_completed,
    );
    Ok(state)
}

// ---------------------------------------------------------------------------
// Legacy API compatibility (kept for existing FFI bindings)
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TransferPlan {
    pub orchard_balance_zat: u64,
    pub denominations: Vec<DenominationGroup>,
    pub total_parts: usize,
    pub total_fee_zat: u64,
    pub estimated_sessions: usize,
    pub estimated_duration_hours: f64,
    pub dust_remaining_zat: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DenominationGroup {
    pub denomination_zat: u64,
    pub count: usize,
    pub label: String,
}

/// Legacy plan function — now estimates based on the new algorithm.
pub fn plan_pool_transfer(orchard_balance_zat: u64, _current_height: u32) -> Result<TransferPlan> {
    if orchard_balance_zat == 0 {
        return Err(anyhow!("No Orchard balance to transfer"));
    }

    let current_balance = effective_balance(orchard_balance_zat);
    if current_balance < ABANDON_THRESHOLD_ZAT {
        return Err(anyhow!(
            "Balance {} zat is below abandon threshold ({} zat)",
            orchard_balance_zat,
            ABANDON_THRESHOLD_ZAT
        ));
    }

    // Estimate ~25 rounds for a typical balance (per the Shielded Labs example)
    let estimated_rounds = estimate_rounds(current_balance);
    let estimated_fees = estimated_rounds as u64 * MIGRATION_FEE_ZAT;

    Ok(TransferPlan {
        orchard_balance_zat,
        denominations: vec![],
        total_parts: estimated_rounds,
        total_fee_zat: estimated_fees,
        estimated_sessions: 1,
        estimated_duration_hours: estimate_duration_hours(estimated_rounds),
        dust_remaining_zat: orchard_balance_zat.min(ABANDON_THRESHOLD_ZAT),
    })
}

/// Rough estimate of how many rounds a balance will need.
fn estimate_rounds(balance_zat: u64) -> usize {
    if balance_zat == 0 {
        return 0;
    }
    // Each round migrates on average ~half the remaining balance (geometric decrease).
    // log2(balance / abandon_threshold) gives a rough upper bound.
    let ratio = balance_zat as f64 / ABANDON_THRESHOLD_ZAT as f64;
    (ratio.log2().ceil() as usize).max(1).min(50)
}

/// Estimate total duration assuming median 10-min delays between rounds.
fn estimate_duration_hours(rounds: usize) -> f64 {
    rounds as f64 * 10.0 / 60.0
}

// ---------------------------------------------------------------------------
// Legacy types kept for FFI compatibility
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum TransferStatus {
    Proposed,
    Splitting,
    Active,
    Complete,
    Paused,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TransferSchedule {
    pub status: TransferStatus,
    pub parts: Vec<MigrationPart>,
    pub created_at_height: u32,
    pub tor_enabled: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum PartStatus {
    Pending,
    Signed,
    Broadcast,
    Confirmed,
    Invalidated,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MigrationPart {
    pub id: u32,
    pub denomination: Denomination,
    pub bucket_height: u32,
    pub status: PartStatus,
    pub tx_bytes: Option<Vec<u8>>,
    pub txid: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct Denomination(pub u64);

impl Denomination {
    pub fn zec_str(&self) -> String {
        let zec = self.0 as f64 / 100_000_000.0;
        if zec >= 1.0 {
            format!("{} ZEC", zec as u64)
        } else {
            format!("{:.8} ZEC", zec)
                .trim_end_matches('0')
                .trim_end_matches('.')
                .to_string()
        }
    }
}

pub fn create_transfer_schedule(
    orchard_balance_zat: u64,
    _current_height: u32,
    tor_enabled: bool,
) -> Result<TransferSchedule> {
    if orchard_balance_zat < ABANDON_THRESHOLD_ZAT {
        return Err(anyhow!("Nothing to transfer"));
    }
    Ok(TransferSchedule {
        status: TransferStatus::Active,
        parts: vec![],
        created_at_height: _current_height,
        tor_enabled,
    })
}

pub fn reconcile_schedule(
    schedule: &mut TransferSchedule,
    _current_height: u32,
    _confirmed_txids: &[String],
) -> Vec<u32> {
    vec![]
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TickResult {
    pub parts_broadcast: u32,
    pub parts_confirmed: u32,
    pub parts_invalidated: u32,
    pub is_complete: bool,
    pub next_broadcast_height: Option<u32>,
}

pub fn tick(
    data_dir: &str,
    _current_height: u32,
    _confirmed_txids: &[String],
) -> Result<TickResult> {
    let state = load_state(data_dir)?;
    Ok(TickResult {
        parts_broadcast: 0,
        parts_confirmed: state.rounds_completed,
        parts_invalidated: 0,
        is_complete: !state.started,
        next_broadcast_height: None,
    })
}

pub fn load_schedule(_data_dir: &str) -> Result<Option<TransferSchedule>> {
    Ok(None)
}

pub fn save_schedule(_data_dir: &str, _schedule: &TransferSchedule) -> Result<()> {
    Ok(())
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_buckets_descending() {
        for i in 1..BUCKETS.len() {
            assert!(BUCKETS[i - 1] > BUCKETS[i], "Buckets must be descending");
        }
    }

    #[test]
    fn test_largest_bucket_index() {
        assert_eq!(largest_bucket_index(200_000_000_000), Some(1)); // 2000 ZEC
        assert_eq!(largest_bucket_index(100_000), Some(20)); // 0.001 ZEC
        assert_eq!(largest_bucket_index(50_000), None); // Below smallest bucket
    }

    #[test]
    fn test_select_amount_always_valid() {
        for _ in 0..100 {
            let amount = select_migration_amount(5_000_000_000); // 50 ZEC balance
            if let Some(a) = amount {
                assert!(a <= 5_000_000_000);
                assert!(BUCKETS.contains(&a));
            }
        }
    }

    #[test]
    fn test_select_amount_below_threshold() {
        assert_eq!(select_migration_amount(50_000), None);
    }

    #[test]
    fn test_plan_next_round_done() {
        let round = plan_next_round(50_000, 50_000, 1);
        assert_eq!(round.action, RoundAction::Done);
    }

    #[test]
    fn test_plan_next_round_consolidate() {
        // Many small notes, none big enough for any bucket
        let round = plan_next_round(1_000_000, 50_000, 20);
        assert_eq!(round.action, RoundAction::Consolidate);
        assert!(round.consolidate_count <= MAX_CONSOLIDATION_NOTES);
    }

    #[test]
    fn test_plan_next_round_migrate() {
        // Single large note
        let round = plan_next_round(10_000_000_000, 10_000_000_000, 1);
        assert_eq!(round.action, RoundAction::Migrate);
        assert!(round.amount_zat > 0);
        assert!(BUCKETS.contains(&round.amount_zat));
    }

    #[test]
    fn test_random_delay_positive() {
        for _ in 0..100 {
            let d = random_delay_seconds();
            assert!(d > 0.0);
        }
    }

    #[test]
    fn test_effective_balance() {
        assert_eq!(effective_balance(1_000_000), 1_000_000 - MIGRATION_FEE_ZAT);
        assert_eq!(effective_balance(10_000), 0); // Less than fee
    }
}
