use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

use anyhow::Result;
use rusqlite::OptionalExtension;
use zcash_client_backend::proto::service::{
    compact_tx_streamer_client::CompactTxStreamerClient, RawTransaction,
};
use zcash_primitives::transaction::TxId;

use super::open_cipher_conn;

const RESUBMIT_INTERVAL_SECS: i64 = 5 * 60;

#[derive(Default, Debug)]
pub struct PendingResubmitSummary {
    pub resubmitted: u32,
    pub confirmed: u32,
    pub expired: u32,
}

fn now_secs() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or_default()
}

fn txid_display(txid: &[u8]) -> String {
    let mut display = txid.to_vec();
    display.reverse();
    hex::encode(display)
}

fn ensure_pending_table(conn: &rusqlite::Connection) -> Result<()> {
    conn.execute_batch(
        "CREATE TABLE IF NOT EXISTS zipher_pending_txs (
            txid BLOB PRIMARY KEY,
            txid_hex TEXT NOT NULL UNIQUE,
            raw_tx BLOB NOT NULL,
            target_height INTEGER NOT NULL,
            expiry_height INTEGER,
            last_resubmit_at INTEGER NOT NULL DEFAULT 0,
            created_at INTEGER NOT NULL
        )",
    )?;
    Ok(())
}

pub fn record_broadcast(
    db_data_path: &Path,
    db_cipher_key: &Option<String>,
    txid: TxId,
    raw_tx: &[u8],
) -> Result<()> {
    let conn = open_cipher_conn(db_data_path, db_cipher_key)?;
    ensure_pending_table(&conn)?;

    let txid_bytes = txid.as_ref().to_vec();
    let txid_hex = txid_display(&txid_bytes);
    let latest_height = conn
        .query_row("SELECT COALESCE(MAX(height), 0) FROM blocks", [], |row| {
            row.get::<_, u32>(0)
        })
        .unwrap_or(0);
    let expiry_height: Option<u32> = conn
        .query_row(
            "SELECT expiry_height FROM transactions WHERE txid = ?",
            rusqlite::params![txid_bytes],
            |row| row.get(0),
        )
        .optional()?
        .flatten();
    let now = now_secs();

    conn.execute(
        "INSERT OR REPLACE INTO zipher_pending_txs
            (txid, txid_hex, raw_tx, target_height, expiry_height, last_resubmit_at, created_at)
         VALUES (?, ?, ?, ?, ?, 0, ?)",
        rusqlite::params![
            txid.as_ref().to_vec(),
            txid_hex,
            raw_tx,
            latest_height.saturating_add(1),
            expiry_height,
            now
        ],
    )?;
    Ok(())
}

pub async fn resubmit_unmined(
    db_data_path: &Path,
    db_cipher_key: &Option<String>,
    lwd: &mut CompactTxStreamerClient<tonic::transport::Channel>,
    latest_height: u32,
) -> Result<PendingResubmitSummary> {
    let pending = {
        let conn = open_cipher_conn(db_data_path, db_cipher_key)?;
        ensure_pending_table(&conn)?;

        let mut stmt = conn.prepare(
            "SELECT p.txid, p.txid_hex, p.raw_tx, p.expiry_height, p.last_resubmit_at,
                    t.mined_height
             FROM zipher_pending_txs p
             LEFT JOIN transactions t ON t.txid = p.txid",
        )?;
        let rows = stmt.query_map([], |row| {
            Ok((
                row.get::<_, Vec<u8>>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, Vec<u8>>(2)?,
                row.get::<_, Option<u32>>(3)?,
                row.get::<_, i64>(4)?,
                row.get::<_, Option<u32>>(5)?,
            ))
        })?;

        let mut pending = Vec::new();
        for row in rows {
            pending.push(row?);
        }
        pending
    };

    let mut summary = PendingResubmitSummary::default();
    let now = now_secs();

    for (txid, txid_hex, raw_tx, expiry_height, last_resubmit_at, mined_height) in pending {
        if mined_height.is_some() {
            let conn = open_cipher_conn(db_data_path, db_cipher_key)?;
            conn.execute(
                "DELETE FROM zipher_pending_txs WHERE txid = ?",
                rusqlite::params![&txid],
            )?;
            summary.confirmed += 1;
            crate::sync::emit_transaction_event(txid_hex, "confirmed");
            continue;
        }

        if matches!(expiry_height, Some(expiry) if expiry > 0 && expiry < latest_height) {
            let conn = open_cipher_conn(db_data_path, db_cipher_key)?;
            conn.execute(
                "DELETE FROM zipher_pending_txs WHERE txid = ?",
                rusqlite::params![&txid],
            )?;
            summary.expired += 1;
            crate::sync::emit_transaction_event(txid_hex, "expired");
            continue;
        }

        if now.saturating_sub(last_resubmit_at) < RESUBMIT_INTERVAL_SECS {
            continue;
        }

        let resp = lwd
            .send_transaction(RawTransaction {
                data: raw_tx,
                height: 0,
            })
            .await
            .map_err(|e| anyhow::anyhow!("resubmit send_transaction: {:?}", e))?
            .into_inner();

        if resp.error_code == 0 {
            let conn = open_cipher_conn(db_data_path, db_cipher_key)?;
            conn.execute(
                "UPDATE zipher_pending_txs SET last_resubmit_at = ? WHERE txid = ?",
                rusqlite::params![now, &txid],
            )?;
            summary.resubmitted += 1;
            crate::sync::emit_transaction_event(txid_hex, "pending");
        } else {
            tracing::debug!(
                "[pending] resubmit rejected for {}: {} (code {})",
                txid_hex,
                resp.error_message,
                resp.error_code
            );
        }
    }

    Ok(summary)
}
