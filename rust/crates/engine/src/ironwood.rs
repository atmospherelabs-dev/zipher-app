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
// Two-stage migration state machine
// ---------------------------------------------------------------------------

/// The overall phase of the automatic migration.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum MigrationPhase {
    /// Not started or cancelled.
    Idle,
    /// Phase 1: Splitting Orchard balance into standard denomination notes.
    Splitting,
    /// Phase 1 complete, waiting to start broadcasting.
    SplitsDone,
    /// Phase 2: Broadcasting pre-split notes from Orchard to Ironwood.
    Migrating,
    /// All done.
    Complete,
    /// Paused by user.
    Paused,
}

/// A single denomination target produced during the split planning phase.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SplitTarget {
    pub denomination_zat: u64,
    pub status: SplitStatus,
    /// txid of the split transaction that created this note (once broadcast).
    pub split_txid: Option<String>,
    /// txid of the migration transaction (once broadcast).
    pub migration_txid: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum SplitStatus {
    /// Waiting to be split from the main balance.
    Planned,
    /// Split transaction broadcast, awaiting confirmation.
    SplitBroadcast,
    /// Split confirmed — note is ready to migrate.
    SplitConfirmed,
    /// Migration transaction broadcast, awaiting confirmation.
    MigrationBroadcast,
    /// Migration confirmed — this denomination is in Ironwood.
    MigrationConfirmed,
}

/// The full durable state of an automatic migration.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AutoMigrationState {
    pub phase: MigrationPhase,
    /// The original Orchard balance when migration was started.
    pub original_balance_zat: u64,
    /// The list of denomination targets.
    pub targets: Vec<SplitTarget>,
    /// Randomized broadcast schedule: delays in seconds between each migration broadcast.
    pub broadcast_delays: Vec<f64>,
    /// Index of the next migration broadcast to execute.
    pub next_broadcast_idx: usize,
    /// Timestamp (unix epoch seconds) when the next broadcast should fire.
    pub next_broadcast_at: Option<u64>,
    /// Whether Tor was enabled at start.
    pub tor_enabled: bool,
    /// Total fees paid so far.
    pub total_fees_zat: u64,
    /// Created timestamp.
    pub created_at: u64,
}

impl Default for AutoMigrationState {
    fn default() -> Self {
        Self {
            phase: MigrationPhase::Idle,
            original_balance_zat: 0,
            targets: vec![],
            broadcast_delays: vec![],
            next_broadcast_idx: 0,
            next_broadcast_at: None,
            tor_enabled: false,
            total_fees_zat: 0,
            created_at: 0,
        }
    }
}

impl AutoMigrationState {
    /// Number of splits planned.
    pub fn total_splits(&self) -> usize {
        self.targets.len()
    }

    /// Number of splits confirmed (ready to migrate).
    pub fn splits_confirmed(&self) -> usize {
        self.targets.iter().filter(|t| matches!(t.status,
            SplitStatus::SplitConfirmed |
            SplitStatus::MigrationBroadcast |
            SplitStatus::MigrationConfirmed
        )).count()
    }

    /// Number of splits broadcast but not yet confirmed.
    pub fn splits_pending(&self) -> usize {
        self.targets.iter().filter(|t| t.status == SplitStatus::SplitBroadcast).count()
    }

    /// Number of migrations confirmed.
    pub fn migrations_confirmed(&self) -> usize {
        self.targets.iter().filter(|t| t.status == SplitStatus::MigrationConfirmed).count()
    }

    /// Number of migrations broadcast but not yet confirmed.
    pub fn migrations_pending(&self) -> usize {
        self.targets.iter().filter(|t| t.status == SplitStatus::MigrationBroadcast).count()
    }

    /// Total amount planned for migration (sum of all denominations).
    pub fn total_planned_zat(&self) -> u64 {
        self.targets.iter().map(|t| t.denomination_zat).sum()
    }

    /// Total amount confirmed in Ironwood.
    pub fn total_migrated_zat(&self) -> u64 {
        self.targets.iter()
            .filter(|t| t.status == SplitStatus::MigrationConfirmed)
            .map(|t| t.denomination_zat)
            .sum()
    }

    /// Whether there are still splits to execute.
    pub fn has_pending_splits(&self) -> bool {
        self.targets.iter().any(|t| t.status == SplitStatus::Planned)
    }

    /// Whether all splits are confirmed and ready to migrate.
    pub fn all_splits_confirmed(&self) -> bool {
        !self.targets.is_empty() && self.targets.iter().all(|t| matches!(t.status,
            SplitStatus::SplitConfirmed |
            SplitStatus::MigrationBroadcast |
            SplitStatus::MigrationConfirmed
        ))
    }

    /// The next target that needs a split transaction.
    pub fn next_split_target(&self) -> Option<usize> {
        self.targets.iter().position(|t| t.status == SplitStatus::Planned)
    }

    /// The next target that is ready to be migrated.
    pub fn next_migration_target(&self) -> Option<usize> {
        self.targets.iter().position(|t| t.status == SplitStatus::SplitConfirmed)
    }

    /// Is migration complete?
    pub fn is_complete(&self) -> bool {
        !self.targets.is_empty() && self.targets.iter().all(|t| t.status == SplitStatus::MigrationConfirmed)
    }
}

// ---------------------------------------------------------------------------
// Split planning: decompose balance into standard denominations
// ---------------------------------------------------------------------------

/// Plan how to split the Orchard balance into standard denominations.
///
/// Uses a greedy approach: repeatedly pick the largest bucket that fits,
/// accounting for fees at each step.
pub fn plan_splits(orchard_balance_zat: u64) -> Vec<u64> {
    let mut remaining = orchard_balance_zat;
    let mut denominations = Vec::new();

    loop {
        // Need at least: denomination + fee for the split tx + fee for eventual migration tx
        let usable = remaining.saturating_sub(MIGRATION_FEE_ZAT);
        if usable < ABANDON_THRESHOLD_ZAT {
            break;
        }

        // Find largest bucket that fits
        let bucket = match BUCKETS.iter().find(|&&b| b <= usable) {
            Some(&b) => b,
            None => break,
        };

        denominations.push(bucket);
        // Deduct the denomination plus the fee for the migration tx
        remaining = remaining.saturating_sub(bucket + MIGRATION_FEE_ZAT);
    }

    denominations
}

/// Generate the randomized broadcast schedule for the migration phase.
/// Returns a vector of delays in seconds (one per migration broadcast).
pub fn generate_broadcast_schedule(count: usize) -> Vec<f64> {
    let mut rng = rand::rngs::OsRng;
    (0..count)
        .map(|_| {
            let u: f64 = rng.gen_range(f64::MIN_POSITIVE..=1.0);
            -600.0 * u.log2() // Median 10 minutes
        })
        .collect()
}

/// Create a new automatic migration plan from the current Orchard balance.
pub fn create_auto_migration(orchard_balance_zat: u64, tor_enabled: bool) -> Result<AutoMigrationState> {
    if orchard_balance_zat < ABANDON_THRESHOLD_ZAT + MIGRATION_FEE_ZAT {
        return Err(anyhow!("Balance too low to migrate"));
    }

    let denominations = plan_splits(orchard_balance_zat);
    if denominations.is_empty() {
        return Err(anyhow!("Balance too small to produce any standard denomination"));
    }

    let targets: Vec<SplitTarget> = denominations.iter().map(|&d| SplitTarget {
        denomination_zat: d,
        status: SplitStatus::Planned,
        split_txid: None,
        migration_txid: None,
    }).collect();

    let broadcast_delays = generate_broadcast_schedule(targets.len());

    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();

    Ok(AutoMigrationState {
        phase: MigrationPhase::Splitting,
        original_balance_zat: orchard_balance_zat,
        targets,
        broadcast_delays,
        next_broadcast_idx: 0,
        next_broadcast_at: None,
        tor_enabled,
        total_fees_zat: 0,
        created_at: now,
    })
}

// ---------------------------------------------------------------------------
// State persistence
// ---------------------------------------------------------------------------

const STATE_FILE: &str = "ironwood_auto_migration.json";

/// Load automatic migration state from disk.
pub fn load_auto_state(data_dir: &str) -> Result<AutoMigrationState> {
    let path = std::path::Path::new(data_dir).join(STATE_FILE);
    if !path.exists() {
        return Ok(AutoMigrationState::default());
    }
    let raw = std::fs::read_to_string(&path)?;
    let state: AutoMigrationState =
        serde_json::from_str(&raw).map_err(|e| anyhow!("Parse auto migration state: {}", e))?;
    Ok(state)
}

/// Save automatic migration state to disk.
pub fn save_auto_state(data_dir: &str, state: &AutoMigrationState) -> Result<()> {
    let path = std::path::Path::new(data_dir).join(STATE_FILE);
    let json = serde_json::to_string_pretty(state)
        .map_err(|e| anyhow!("Serialize auto state: {}", e))?;
    std::fs::write(&path, json)?;
    Ok(())
}

/// Cancel an in-progress migration.
pub fn cancel_auto_migration(data_dir: &str) -> Result<()> {
    let path = std::path::Path::new(data_dir).join(STATE_FILE);
    if path.exists() {
        std::fs::remove_file(&path)?;
    }
    Ok(())
}

// ---------------------------------------------------------------------------
// Core algorithm functions (used by both manual and auto modes)
// ---------------------------------------------------------------------------

/// Compute the effective balance available for migration.
pub fn effective_balance(orchard_balance_zat: u64) -> u64 {
    orchard_balance_zat.saturating_sub(MIGRATION_FEE_ZAT)
}

/// Find the largest bucket <= the given balance.
fn largest_bucket_index(balance_zat: u64) -> Option<usize> {
    BUCKETS.iter().position(|&b| b <= balance_zat)
}

/// Select a migration amount using the coin-flip algorithm (for manual mode).
///
/// Start at the largest bucket <= current_balance.
/// Flip fair coins: heads = step down one bucket, tails = stop.
pub fn select_migration_amount(current_balance_zat: u64) -> Option<u64> {
    if current_balance_zat < ABANDON_THRESHOLD_ZAT {
        return None;
    }

    let start_idx = largest_bucket_index(current_balance_zat)?;
    let mut rng = rand::rngs::OsRng;
    let mut idx = start_idx;

    loop {
        if rng.gen_bool(0.5) {
            break;
        }
        if idx + 1 >= BUCKETS.len() {
            break;
        }
        idx += 1;
    }

    Some(BUCKETS[idx])
}

/// Determine what the next manual migration round should do.
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

    let note_available = largest_note_zat.saturating_sub(MIGRATION_FEE_ZAT);

    if let Some(amount) = select_migration_amount(note_available) {
        MigrationRound {
            action: RoundAction::Migrate,
            amount_zat: amount,
            consolidate_count: 0,
        }
    } else if note_count > 1 {
        let consolidate_count = note_count.min(MAX_CONSOLIDATION_NOTES);
        MigrationRound {
            action: RoundAction::Consolidate,
            amount_zat: 0,
            consolidate_count,
        }
    } else {
        MigrationRound {
            action: RoundAction::Done,
            amount_zat: 0,
            consolidate_count: 0,
        }
    }
}

/// Generate the random delay (in seconds) for the next migration round.
/// D = -600 × log₂(U) where U is uniform in (0, 1].
pub fn random_delay_seconds() -> f64 {
    let mut rng = rand::rngs::OsRng;
    let u: f64 = rng.gen_range(f64::MIN_POSITIVE..=1.0);
    -600.0 * u.log2()
}

// ---------------------------------------------------------------------------
// Types (manual mode)
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum RoundAction {
    Migrate,
    Consolidate,
    Done,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MigrationRound {
    pub action: RoundAction,
    pub amount_zat: u64,
    pub consolidate_count: usize,
}

// ---------------------------------------------------------------------------
// Legacy state persistence (for manual mode tracking)
// ---------------------------------------------------------------------------

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

pub fn save_state(data_dir: &str, state: &MigrationState) -> Result<()> {
    let path = std::path::Path::new(data_dir).join("ironwood_migration.json");
    let json =
        serde_json::to_string_pretty(state).map_err(|e| anyhow!("Serialize state: {}", e))?;
    std::fs::write(&path, json)?;
    Ok(())
}

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
        let round = plan_next_round(1_000_000, 50_000, 20);
        assert_eq!(round.action, RoundAction::Consolidate);
        assert!(round.consolidate_count <= MAX_CONSOLIDATION_NOTES);
    }

    #[test]
    fn test_plan_next_round_migrate() {
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
        assert_eq!(effective_balance(10_000), 0);
    }

    #[test]
    fn test_plan_splits_basic() {
        // 1 ZEC = 100_000_000 zat
        let splits = plan_splits(100_000_000);
        assert!(!splits.is_empty());
        // All splits should be standard denominations
        for &s in &splits {
            assert!(BUCKETS.contains(&s));
        }
        // Total should not exceed balance minus fees
        let total: u64 = splits.iter().sum();
        assert!(total <= 100_000_000);
    }

    #[test]
    fn test_plan_splits_small_balance() {
        // Just above threshold
        let splits = plan_splits(200_000);
        assert_eq!(splits.len(), 1);
        assert_eq!(splits[0], 100_000); // 0.001 ZEC
    }

    #[test]
    fn test_plan_splits_below_threshold() {
        let splits = plan_splits(50_000);
        assert!(splits.is_empty());
    }

    #[test]
    fn test_create_auto_migration() {
        let state = create_auto_migration(500_000_000, false).unwrap(); // 5 ZEC
        assert_eq!(state.phase, MigrationPhase::Splitting);
        assert!(!state.targets.is_empty());
        assert_eq!(state.broadcast_delays.len(), state.targets.len());
        // All targets should be planned
        for t in &state.targets {
            assert_eq!(t.status, SplitStatus::Planned);
            assert!(BUCKETS.contains(&t.denomination_zat));
        }
    }

    #[test]
    fn test_generate_broadcast_schedule() {
        let delays = generate_broadcast_schedule(10);
        assert_eq!(delays.len(), 10);
        for d in &delays {
            assert!(*d > 0.0);
        }
    }
}
