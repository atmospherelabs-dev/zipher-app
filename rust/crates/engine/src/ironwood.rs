use anyhow::{anyhow, Result};
use serde::{Deserialize, Serialize};
use tracing::info;

// ---------------------------------------------------------------------------
// Constants (provisional per ZIP 318, pending ratification)
// ---------------------------------------------------------------------------

/// Maximum denomination: 100 ZEC (10_000_000_000 zatoshis).
const _DENOM_CAP_ZAT: u64 = 100 * 100_000_000;

/// Minimum denomination below which funds are left unmigrated.
const DUST_FLOOR_ZAT: u64 = 1_000; // 0.00001 ZEC

/// Anchor-height bucket modulus (~5.3h at 75s/block).
pub const BUCKET_MODULUS: u32 = 256;

/// Maximum parts a single wallet contributes to one cohort.
const K_MAX: usize = 8;

/// Target signing sessions for typical balances.
const TARGET_SESSIONS: usize = 6;

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

/// A canonical power-of-ten denomination in zatoshis.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct Denomination(pub u64);

impl Denomination {
    pub fn zec_str(&self) -> String {
        let zec = self.0 as f64 / 100_000_000.0;
        if zec >= 1.0 {
            format!("{} ZEC", zec as u64)
        } else {
            format!("{:.8} ZEC", zec).trim_end_matches('0').trim_end_matches('.').to_string()
        }
    }
}

/// Status of a single migration part.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum PartStatus {
    Pending,
    Signed,
    Broadcast,
    Confirmed,
    Invalidated,
}

/// A single migration transaction in the schedule.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MigrationPart {
    pub id: u32,
    pub denomination: Denomination,
    pub bucket_height: u32,
    pub status: PartStatus,
    pub tx_bytes: Option<Vec<u8>>,
    pub txid: Option<String>,
}

/// Overall status of the pool transfer.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum TransferStatus {
    Proposed,
    Splitting,
    Active,
    Complete,
    Paused,
}

/// The full pool transfer schedule (Orchard -> Ironwood).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TransferSchedule {
    pub status: TransferStatus,
    pub parts: Vec<MigrationPart>,
    pub created_at_height: u32,
    pub tor_enabled: bool,
}

impl TransferSchedule {
    pub fn total_parts(&self) -> usize {
        self.parts.len()
    }

    pub fn confirmed_parts(&self) -> usize {
        self.parts.iter().filter(|p| p.status == PartStatus::Confirmed).count()
    }

    pub fn pending_parts(&self) -> Vec<&MigrationPart> {
        self.parts.iter().filter(|p| matches!(p.status, PartStatus::Pending | PartStatus::Signed)).collect()
    }

    pub fn next_broadcast_height(&self) -> Option<u32> {
        self.parts
            .iter()
            .filter(|p| matches!(p.status, PartStatus::Pending | PartStatus::Signed))
            .map(|p| p.bucket_height)
            .min()
    }

    pub fn total_fee_zat(&self) -> u64 {
        self.parts.len() as u64 * 10_000
    }

    pub fn estimated_duration_hours(&self) -> f64 {
        let num_buckets = self.parts.iter()
            .map(|p| p.bucket_height)
            .collect::<std::collections::HashSet<_>>()
            .len();
        num_buckets as f64 * (BUCKET_MODULUS as f64 * 75.0 / 3600.0)
    }
}

/// Summary returned to UI/CLI for display before confirmation.
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

/// Grouped denominations for display (e.g. "4x 0.1 ZEC").
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DenominationGroup {
    pub denomination_zat: u64,
    pub count: usize,
    pub label: String,
}

// ---------------------------------------------------------------------------
// Core logic
// ---------------------------------------------------------------------------

/// Decompose a balance (in zatoshis) into canonical power-of-ten denominations.
///
/// Per ZIP 318: decimal digit expansion, capped at DENOM_CAP, down to DUST_FLOOR.
pub fn decompose_balance(balance_zat: u64) -> (Vec<Denomination>, u64) {
    if balance_zat < DUST_FLOOR_ZAT {
        return (vec![], balance_zat);
    }

    let mut remaining = balance_zat;
    let mut parts = Vec::new();

    let denominations: Vec<u64> = vec![
        10_000_000_000, // 100 ZEC
        1_000_000_000,  // 10 ZEC
        100_000_000,    // 1 ZEC
        10_000_000,     // 0.1 ZEC
        1_000_000,      // 0.01 ZEC
        100_000,        // 0.001 ZEC
        10_000,         // 0.0001 ZEC
        1_000,          // 0.00001 ZEC (DUST_FLOOR)
    ];

    for denom in &denominations {
        while remaining >= *denom {
            parts.push(Denomination(*denom));
            remaining -= denom;
        }
    }

    (parts, remaining)
}

/// Assign denominations to anchor-height buckets, respecting K_MAX per cohort.
pub fn assign_buckets(parts: &[Denomination], current_height: u32) -> Vec<u32> {
    let next_boundary = ((current_height / BUCKET_MODULUS) + 1) * BUCKET_MODULUS;

    let mut assignments = Vec::with_capacity(parts.len());
    let mut bucket = next_boundary;
    let mut count_in_bucket = 0;

    for _ in parts {
        if count_in_bucket >= K_MAX {
            bucket += BUCKET_MODULUS;
            count_in_bucket = 0;
        }
        assignments.push(bucket);
        count_in_bucket += 1;
    }

    assignments
}

/// Build the full transfer plan for user confirmation.
pub fn plan_pool_transfer(orchard_balance_zat: u64, current_height: u32) -> Result<TransferPlan> {
    if orchard_balance_zat == 0 {
        return Err(anyhow!("No Orchard balance to transfer"));
    }

    let (denominations, dust) = decompose_balance(orchard_balance_zat);

    if denominations.is_empty() {
        return Err(anyhow!(
            "Balance {} zat is below dust floor ({} zat)",
            orchard_balance_zat,
            DUST_FLOOR_ZAT
        ));
    }

    let buckets = assign_buckets(&denominations, current_height);
    let num_distinct_buckets = buckets.iter().collect::<std::collections::HashSet<_>>().len();
    let estimated_sessions = num_distinct_buckets.min(TARGET_SESSIONS).max(1);

    let mut group_map: std::collections::BTreeMap<u64, usize> = std::collections::BTreeMap::new();
    for d in &denominations {
        *group_map.entry(d.0).or_insert(0) += 1;
    }
    let groups: Vec<DenominationGroup> = group_map
        .into_iter()
        .rev()
        .map(|(zat, count)| {
            let d = Denomination(zat);
            DenominationGroup {
                denomination_zat: zat,
                count,
                label: format!("{}x {}", count, d.zec_str()),
            }
        })
        .collect();

    Ok(TransferPlan {
        orchard_balance_zat,
        denominations: groups,
        total_parts: denominations.len(),
        total_fee_zat: denominations.len() as u64 * 10_000,
        estimated_sessions,
        estimated_duration_hours: num_distinct_buckets as f64 * (BUCKET_MODULUS as f64 * 75.0 / 3600.0),
        dust_remaining_zat: dust,
    })
}

/// Create the full transfer schedule (called after user confirms the plan).
pub fn create_transfer_schedule(
    orchard_balance_zat: u64,
    current_height: u32,
    tor_enabled: bool,
) -> Result<TransferSchedule> {
    let (denominations, _dust) = decompose_balance(orchard_balance_zat);

    if denominations.is_empty() {
        return Err(anyhow!("Nothing to transfer"));
    }

    let buckets = assign_buckets(&denominations, current_height);

    let parts: Vec<MigrationPart> = denominations
        .iter()
        .zip(buckets.iter())
        .enumerate()
        .map(|(i, (denom, bucket))| MigrationPart {
            id: i as u32,
            denomination: *denom,
            bucket_height: *bucket,
            status: PartStatus::Pending,
            tx_bytes: None,
            txid: None,
        })
        .collect();

    info!(
        "[PoolTransfer] Schedule created: {} parts across {} buckets, tor={}",
        parts.len(),
        buckets.iter().collect::<std::collections::HashSet<_>>().len(),
        tor_enabled,
    );

    Ok(TransferSchedule {
        status: TransferStatus::Proposed,
        parts,
        created_at_height: current_height,
        tor_enabled,
    })
}

/// Reconcile a schedule against current chain state.
pub fn reconcile_schedule(
    schedule: &mut TransferSchedule,
    current_height: u32,
    confirmed_txids: &[String],
) -> Vec<u32> {
    let mut invalidated = Vec::new();

    for part in &mut schedule.parts {
        match part.status {
            PartStatus::Broadcast => {
                if let Some(ref txid) = part.txid {
                    if confirmed_txids.contains(txid) {
                        part.status = PartStatus::Confirmed;
                    }
                }
            }
            PartStatus::Signed | PartStatus::Pending => {
                if current_height > part.bucket_height + BUCKET_MODULUS {
                    part.status = PartStatus::Invalidated;
                    invalidated.push(part.id);
                }
            }
            _ => {}
        }
    }

    if schedule.parts.iter().all(|p| p.status == PartStatus::Confirmed) {
        schedule.status = TransferStatus::Complete;
    }

    invalidated
}

/// Get parts that are due for broadcast (their bucket has arrived).
pub fn due_for_broadcast(schedule: &TransferSchedule, current_height: u32) -> Vec<&MigrationPart> {
    schedule
        .parts
        .iter()
        .filter(|p| {
            matches!(p.status, PartStatus::Signed)
                && current_height >= p.bucket_height
        })
        .collect()
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_decompose_123_45_zec() {
        let (parts, dust) = decompose_balance(12_345_000_000);
        let values: Vec<u64> = parts.iter().map(|d| d.0).collect();
        assert_eq!(values.iter().sum::<u64>(), 12_345_000_000);
        assert_eq!(dust, 0);
        assert_eq!(values[0], 10_000_000_000);
    }

    #[test]
    fn test_decompose_small() {
        let (parts, dust) = decompose_balance(500_000);
        let total: u64 = parts.iter().map(|d| d.0).sum();
        assert_eq!(total + dust, 500_000);
    }

    #[test]
    fn test_decompose_below_dust() {
        let (parts, dust) = decompose_balance(500);
        assert!(parts.is_empty());
        assert_eq!(dust, 500);
    }

    #[test]
    fn test_decompose_540_zec() {
        let (parts, _dust) = decompose_balance(540 * 100_000_000);
        assert_eq!(parts.iter().filter(|d| d.0 == 10_000_000_000).count(), 5);
        assert_eq!(parts.iter().filter(|d| d.0 == 1_000_000_000).count(), 4);
    }

    #[test]
    fn test_bucket_assignment_k_max() {
        let parts = vec![Denomination(10_000_000_000); 20];
        let buckets = assign_buckets(&parts, 4_131_700);
        let next_boundary = ((4_131_700 / 256) + 1) * 256;
        assert_eq!(buckets[0], next_boundary);
        assert_eq!(buckets[7], next_boundary);
        assert_eq!(buckets[8], next_boundary + 256);
        assert_eq!(buckets[16], next_boundary + 512);
    }

    #[test]
    fn test_plan_50_zec() {
        let plan = plan_pool_transfer(5_000_000_000, 4_131_700).unwrap();
        assert_eq!(plan.orchard_balance_zat, 5_000_000_000);
        assert_eq!(plan.total_parts, 5);
        assert_eq!(plan.dust_remaining_zat, 0);
    }

    #[test]
    fn test_plan_1_zec() {
        let plan = plan_pool_transfer(100_000_000, 4_131_700).unwrap();
        assert_eq!(plan.total_parts, 1);
    }
}

// ---------------------------------------------------------------------------
// Background tick — called periodically by scheduler (Flutter/CLI/MCP)
// ---------------------------------------------------------------------------

/// Result of a single background tick.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TickResult {
    pub parts_broadcast: u32,
    pub parts_confirmed: u32,
    pub parts_invalidated: u32,
    pub is_complete: bool,
    pub next_broadcast_height: Option<u32>,
}

/// Perform one scheduling tick.
///
/// Reads the schedule from disk, reconciles against chain state, broadcasts
/// any due parts, and persists the updated schedule. Designed to be called
/// from BGTaskScheduler (iOS), WorkManager (Android), a CLI daemon loop,
/// or on app foreground.
pub fn tick(
    data_dir: &str,
    current_height: u32,
    confirmed_txids: &[String],
) -> Result<TickResult> {
    let schedule_path = std::path::Path::new(data_dir).join("ironwood_schedule.json");
    if !schedule_path.exists() {
        return Err(anyhow!("No active transfer schedule"));
    }

    let raw = std::fs::read_to_string(&schedule_path)?;
    let mut schedule: TransferSchedule = serde_json::from_str(&raw)
        .map_err(|e| anyhow!("Parse schedule: {}", e))?;

    if schedule.status == TransferStatus::Paused || schedule.status == TransferStatus::Complete {
        return Ok(TickResult {
            parts_broadcast: 0,
            parts_confirmed: 0,
            parts_invalidated: 0,
            is_complete: schedule.status == TransferStatus::Complete,
            next_broadcast_height: None,
        });
    }

    let invalidated = reconcile_schedule(&mut schedule, current_height, confirmed_txids);
    let parts_confirmed = schedule.parts.iter()
        .filter(|p| p.status == PartStatus::Confirmed)
        .count() as u32;

    let ready_count = schedule.parts.iter()
        .filter(|p| p.status == PartStatus::Signed && current_height >= p.bucket_height)
        .count() as u32;

    // Mark pending parts as signable when their bucket arrives
    let mut newly_signable = 0u32;
    for part in &mut schedule.parts {
        if part.status == PartStatus::Pending && current_height >= part.bucket_height {
            part.status = PartStatus::Signed;
            newly_signable += 1;
        }
    }

    if schedule.parts.iter().all(|p| p.status == PartStatus::Confirmed) {
        schedule.status = TransferStatus::Complete;
        info!("[PoolTransfer] All parts confirmed — transfer complete!");
    } else if schedule.status == TransferStatus::Proposed {
        schedule.status = TransferStatus::Active;
    }

    let updated_json = serde_json::to_string_pretty(&schedule)
        .map_err(|e| anyhow!("Serialize: {}", e))?;
    std::fs::write(&schedule_path, updated_json)?;

    Ok(TickResult {
        parts_broadcast: ready_count + newly_signable,
        parts_confirmed,
        parts_invalidated: invalidated.len() as u32,
        is_complete: schedule.status == TransferStatus::Complete,
        next_broadcast_height: schedule.next_broadcast_height(),
    })
}

/// Load the current schedule from disk (if any).
pub fn load_schedule(data_dir: &str) -> Result<Option<TransferSchedule>> {
    let schedule_path = std::path::Path::new(data_dir).join("ironwood_schedule.json");
    if !schedule_path.exists() {
        return Ok(None);
    }
    let raw = std::fs::read_to_string(&schedule_path)?;
    let schedule: TransferSchedule = serde_json::from_str(&raw)
        .map_err(|e| anyhow!("Parse schedule: {}", e))?;
    Ok(Some(schedule))
}

/// Save the schedule back to disk.
pub fn save_schedule(data_dir: &str, schedule: &TransferSchedule) -> Result<()> {
    let schedule_path = std::path::Path::new(data_dir).join("ironwood_schedule.json");
    let json = serde_json::to_string_pretty(schedule)
        .map_err(|e| anyhow!("Serialize: {}", e))?;
    std::fs::write(&schedule_path, json)?;
    Ok(())
}
