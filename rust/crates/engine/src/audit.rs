use std::path::{Path, PathBuf};

use anyhow::Result;
use rusqlite::Connection;
use serde::Serialize;

// ---------------------------------------------------------------------------
// Audit log entry
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize)]
pub struct AuditEntry {
    pub id: i64,
    pub timestamp: String,
    pub action: String,
    pub address: Option<String>,
    pub amount: Option<u64>,
    pub fee: Option<u64>,
    pub context_id: Option<String>,
    pub txid: Option<String>,
    pub error: Option<String>,
}

// ---------------------------------------------------------------------------
// Database helpers
// ---------------------------------------------------------------------------

fn audit_db_path(data_dir: &str) -> PathBuf {
    Path::new(data_dir).join("audit.sqlite")
}

fn open_audit_db(data_dir: &str) -> Result<Connection> {
    let path = audit_db_path(data_dir);
    let conn = Connection::open(&path)?;
    conn.execute_batch(
        "PRAGMA journal_mode = WAL;
         PRAGMA busy_timeout = 5000;
         CREATE TABLE IF NOT EXISTS audit_log (
             id         INTEGER PRIMARY KEY AUTOINCREMENT,
             timestamp  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
             action     TEXT NOT NULL,
             address    TEXT,
             amount     INTEGER,
             fee        INTEGER,
             context_id TEXT,
             txid       TEXT,
             error      TEXT
         );
         CREATE INDEX IF NOT EXISTS idx_audit_ts ON audit_log(timestamp);
         CREATE TABLE IF NOT EXISTS spend_reservations (
             id INTEGER PRIMARY KEY AUTOINCREMENT,
             timestamp TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
             address TEXT NOT NULL, amount INTEGER NOT NULL, fee INTEGER NOT NULL,
             context_id TEXT, txid TEXT
         );",
    )?;
    Ok(conn)
}

// ---------------------------------------------------------------------------
// Write
// ---------------------------------------------------------------------------

pub fn log_event(
    data_dir: &str,
    action: &str,
    address: Option<&str>,
    amount: Option<u64>,
    fee: Option<u64>,
    context_id: Option<&str>,
    txid: Option<&str>,
    error: Option<&str>,
) -> Result<()> {
    let conn = open_audit_db(data_dir)?;
    conn.execute(
        "INSERT INTO audit_log (action, address, amount, fee, context_id, txid, error)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
        rusqlite::params![action, address, amount, fee, context_id, txid, error],
    )?;
    Ok(())
}

// ---------------------------------------------------------------------------
// Read
// ---------------------------------------------------------------------------

pub fn query_log(data_dir: &str, limit: usize, since: Option<&str>) -> Result<Vec<AuditEntry>> {
    let conn = open_audit_db(data_dir)?;

    let (sql, params): (String, Vec<Box<dyn rusqlite::types::ToSql>>) = match since {
        Some(ts) => (
            "SELECT id, timestamp, action, address, amount, fee, context_id, txid, error
             FROM audit_log WHERE timestamp >= ?1
             ORDER BY id DESC LIMIT ?2"
                .into(),
            vec![Box::new(ts.to_string()), Box::new(limit as i64)],
        ),
        None => (
            "SELECT id, timestamp, action, address, amount, fee, context_id, txid, error
             FROM audit_log ORDER BY id DESC LIMIT ?1"
                .into(),
            vec![Box::new(limit as i64)],
        ),
    };

    let mut stmt = conn.prepare(&sql)?;
    let params_refs: Vec<&dyn rusqlite::types::ToSql> = params.iter().map(|p| p.as_ref()).collect();
    let rows = stmt.query_map(params_refs.as_slice(), |row| {
        Ok(AuditEntry {
            id: row.get(0)?,
            timestamp: row.get(1)?,
            action: row.get(2)?,
            address: row.get(3)?,
            amount: row.get(4)?,
            fee: row.get(5)?,
            context_id: row.get(6)?,
            txid: row.get(7)?,
            error: row.get(8)?,
        })
    })?;

    let mut entries = Vec::new();
    for row in rows {
        entries.push(row?);
    }
    Ok(entries)
}

/// Includes unresolved reservations; uncertain broadcasts cannot free budget.
pub fn daily_spent(data_dir: &str) -> Result<u64> {
    let conn = open_audit_db(data_dir)?;
    spent_on(&conn)
}

fn spent_on(conn: &Connection) -> Result<u64> {
    let unknown: bool = conn.query_row(
        "SELECT EXISTS(SELECT 1 FROM audit_log WHERE
          action IN ('confirm_send','approve_send','pay_url','pay_x402','x402_pay','swap_execute','session_open')
          AND error IS NULL AND amount IS NULL AND txid IS NOT NULL
          AND timestamp >= strftime('%Y-%m-%dT%H:%M:%fZ','now','-1 day'))",
        [], |r| r.get(0))?;
    anyhow::ensure!(!unknown, "POLICY_EXCEEDED: historical spend amount is unknown; reconcile the audit log before spending");
    let total: i64 = conn.query_row(
        "SELECT COALESCE(SUM(total),0) FROM (
          SELECT amount + COALESCE(fee,0) AS total FROM audit_log a
          WHERE action IN ('confirm_send','approve_send','pay_url','pay_x402','x402_pay','swap_execute','session_open')
          AND error IS NULL AND amount >= 0
          AND timestamp >= strftime('%Y-%m-%dT%H:%M:%fZ','now','-1 day')
          AND NOT EXISTS(SELECT 1 FROM spend_reservations r WHERE r.txid = a.txid)
          UNION ALL
          SELECT amount + fee FROM spend_reservations
          WHERE timestamp >= strftime('%Y-%m-%dT%H:%M:%fZ','now','-1 day')
        )", [], |r| r.get(0))?;
    Ok(u64::try_from(total)?)
}

/// Atomically check policy and reserve amount + fee BEFORE signing.
pub fn reserve_spend(data_dir: &str, address: &str, amount: u64, fee: u64,
    context_id: &Option<String>, policy: &crate::policy::SpendingPolicy) -> Result<i64> {
    let total = amount.checked_add(fee).ok_or_else(|| anyhow::anyhow!("Amount overflow"))?;
    let _ = i64::try_from(total)?;
    let mut conn = open_audit_db(data_dir)?;
    let tx = conn.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
    let spent = spent_on(&tx)?;
    crate::policy::check_proposal(policy, address, total, context_id, spent)
        .map_err(|e| anyhow::anyhow!("{e}"))?;
    tx.execute("INSERT INTO spend_reservations(address, amount, fee, context_id) VALUES (?1,?2,?3,?4)",
        rusqlite::params![address, amount, fee, context_id])?;
    let id = tx.last_insert_rowid();
    tx.commit()?;
    Ok(id)
}

pub fn settle_spend(data_dir: &str, reservation: i64, txid: &str) -> Result<()> {
    let conn = open_audit_db(data_dir)?;
    let changed = conn.execute("UPDATE spend_reservations SET txid=?1 WHERE id=?2 AND txid IS NULL",
        rusqlite::params![txid, reservation])?;
    anyhow::ensure!(changed == 1, "Spend reservation was not found or already settled");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    fn dir() -> std::path::PathBuf {
        let p = std::env::temp_dir().join(format!("zipher-audit-test-{}-{}",std::process::id(),rand::random::<u64>()));
        std::fs::create_dir_all(&p).unwrap(); p
    }
    #[test]
    fn accounts_for_all_spends_and_does_not_double_count_reservations() {
        let path=dir(); let d=path.to_str().unwrap();
        log_event(d,"approve_send",Some("a"),Some(20),Some(2),None,Some("old"),None).unwrap();
        log_event(d,"x402_pay",Some("a"),Some(5),Some(1),None,Some("x"),None).unwrap();
        assert_eq!(daily_spent(d).unwrap(),28);
        let policy=crate::policy::SpendingPolicy{daily_limit:100,..Default::default()};
        let id=reserve_spend(d,"a",60,2,&None,&policy).unwrap();
        assert_eq!(daily_spent(d).unwrap(),90);
        assert!(reserve_spend(d,"a",10,1,&None,&policy).is_err());
        settle_spend(d,id,"new").unwrap();
        log_event(d,"confirm_send",Some("a"),Some(60),Some(2),None,Some("new"),None).unwrap();
        assert_eq!(daily_spent(d).unwrap(),90);
        std::fs::remove_dir_all(path).unwrap();
    }
    #[test]
    fn unknown_historical_amount_fails_closed() {
        let path=dir(); let d=path.to_str().unwrap();
        log_event(d,"confirm_send",None,None,None,None,Some("old"),None).unwrap();
        assert!(daily_spent(d).is_err());
        std::fs::remove_dir_all(path).unwrap();
    }
    #[test]
    fn concurrent_reservations_cannot_exceed_daily_budget() {
        let path=dir();
        open_audit_db(path.to_str().unwrap()).unwrap();
        let workers:Vec<_>=(0..4).map(|_| {let p=path.clone();std::thread::spawn(move || {
            reserve_spend(p.to_str().unwrap(),"a",60,1,&None,
                &crate::policy::SpendingPolicy{daily_limit:100,..Default::default()}).is_ok()
        })}).collect();
        assert_eq!(workers.into_iter().filter_map(|t|t.join().ok()).filter(|ok|*ok).count(),1);
        assert_eq!(daily_spent(path.to_str().unwrap()).unwrap(),61);
        std::fs::remove_dir_all(path).unwrap();
    }
}
