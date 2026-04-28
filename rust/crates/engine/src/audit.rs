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
         CREATE INDEX IF NOT EXISTS idx_audit_ts ON audit_log(timestamp);",
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

pub fn query_log(
    data_dir: &str,
    limit: usize,
    since: Option<&str>,
) -> Result<Vec<AuditEntry>> {
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

/// Sum of amounts from all successful spend actions in the last 24 hours.
pub fn daily_spent(data_dir: &str) -> Result<u64> {
    let conn = open_audit_db(data_dir)?;
    let total: i64 = conn.query_row(
        "SELECT COALESCE(SUM(amount), 0) FROM audit_log
         WHERE action IN ('confirm_send', 'pay_url', 'pay_x402', 'swap_execute', 'session_open')
         AND error IS NULL
         AND amount > 0
         AND timestamp >= strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-1 day')",
        [],
        |r| r.get(0),
    )?;
    Ok(total as u64)
}
