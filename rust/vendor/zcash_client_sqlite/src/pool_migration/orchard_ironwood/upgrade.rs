//! Authoritative retirement of a presigned migration's ended consensus branch.
//!
//! This adapter is deliberately scoped to the wallet database and the released
//! mainnet/testnet parameters. A server rejection or an unknown transaction is
//! insufficient: every old-branch block, and the first new-branch block, must
//! have been fully scanned before any unmined transaction can release inputs.
//! Raw transactions and spend links are retained so a reorg can discover an
//! earlier inclusion through the normal scanner.

use rusqlite::{params, Connection, OptionalExtension};
use zcash_pool_migration::engine::{MigrationStatus, MigrationTxState, PoolMigrationRead};
use zcash_primitives::transaction::Transaction;
use zcash_protocol::consensus::{BranchId, Network};

use super::{Error, PoolMigrations};
use crate::{util::SystemClock, AccountUuid};

/// A durable receipt for a run stopped by an actual, fully scanned upgrade.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct UpgradeStop {
    /// The first block of the new branch, already fully scanned by the wallet.
    pub activation_height: u32,
    /// Unmined old-branch transactions whose wallet metadata was retired.
    pub invalidated_transactions: u32,
}

/// Stops only the latest active migration of `account`, atomically with freeing
/// its old-branch unmined inputs. Returns `None` until the wallet's own scan
/// establishes that the branch ended, or when no old-branch work remains.
///
/// The transaction uses a database snapshot for migration identity, inclusion,
/// full scan coverage and input ownership. Another process cannot race a new
/// run into the middle of the operation. No submitted signature is changed.
pub fn stop_invalidated_migration(
    connection: &mut Connection,
    network: &Network,
    account: AccountUuid,
) -> Result<Option<UpgradeStop>, Error> {
    let view = connection.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
    let Some(scanned) = crate::wallet::fully_scanned_height(&view)? else {
        return Ok(None);
    };
    let scanned = u32::from(scanned);
    let state = {
        let conn: &Connection = &view;
        let store = PoolMigrations::for_account(*network, SystemClock, conn, account)?;
        match store.get_migration()? {
            Some(state) => state,
            None => return Ok(None),
        }
    };
    let migration_id: i64 = view.query_row(
        "SELECT m.id FROM orchard_ironwood_migrations m
         JOIN accounts a ON a.id = m.account_id
         WHERE a.uuid = ? AND m.status = ? ORDER BY m.id DESC LIMIT 1",
        params![account.expose_uuid(), state.status().wire_name()],
        |row| row.get(0),
    )?;
    let mut invalidated = Vec::new();
    let mut mined = Vec::new();
    for part in state.transactions() {
        let pczt = pczt::Pczt::parse(part.pczt())
            .map_err(|_| Error::Corrupt("migration PCZT during upgrade recovery"))?;
        let effecting_txid = zcash_pool_migration::pczt_txid::pczt_txid(&pczt)
            .map_err(|_| Error::Corrupt("migration PCZT identity during upgrade recovery"))?;
        if effecting_txid != part.txid() {
            return Err(Error::Corrupt(
                "cached migration identity during upgrade recovery",
            ));
        }
        let signed_branch = BranchId::try_from(*pczt.global().consensus_branch_id())
            .map_err(|_| Error::Corrupt("migration branch during upgrade recovery"))?;
        let record: Option<(Option<u32>, Option<Vec<u8>>)> = view
            .query_row(
                "SELECT mined_height, raw FROM transactions WHERE txid = ?",
                params![part.txid().as_ref()],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .optional()?;
        if let Some((Some(height), _)) = record.as_ref() {
            if *height > scanned {
                // Enhancement may know an inclusion ahead of scanning. Wait
                // for the corresponding nullifier and reorg evidence as well.
                return Ok(None);
            }
            mined.push((u32::from(part.id()), *height));
            continue;
        }
        if matches!(part.state(), MigrationTxState::Mined { .. }) {
            // A rewind must reconcile this record before it can be stopped.
            return Ok(None);
        }
        let Some((_, Some(activation))) = signed_branch.height_bounds(network) else {
            // A still-live or future branch cannot be retired merely because
            // another part belongs to an ended branch.
            return Ok(None);
        };
        let activation = u32::from(activation);
        if scanned < activation {
            return Ok(None);
        }
        if let Some((_, raw)) = record {
            let raw = raw.ok_or(Error::Corrupt("missing raw migration transaction"))?;
            let mut remaining = raw.as_slice();
            let tx = Transaction::read(&mut remaining, signed_branch)
                .map_err(|_| Error::Corrupt("raw migration transaction during upgrade recovery"))?;
            if !remaining.is_empty()
                || tx.consensus_branch_id() != signed_branch
                || tx.txid() != part.txid()
            {
                return Err(Error::Corrupt(
                    "migration transaction identity during upgrade recovery",
                ));
            }
        } else if matches!(part.state(), MigrationTxState::Broadcast { .. }) {
            return Err(Error::Corrupt(
                "broadcast migration has no wallet transaction",
            ));
        }
        invalidated.push((part.txid(), part.lock_owner(), activation));
    }
    if invalidated.is_empty() {
        return Ok(None);
    }
    // Mark chain-backed inclusion first. A terminal receipt must still report
    // every part that moved before activation, including an accepted-but-not-
    // recorded submission that remained Proved when the app stopped.
    for (id, height) in mined {
        view.execute(
            "UPDATE orchard_ironwood_migration_transactions
             SET state = 'mined', mined_height = ?
             WHERE migration_id = ? AND transfer_id = ?",
            params![height, migration_id, id],
        )?;
    }
    for (txid, owner, activation) in &invalidated {
        let branch_end = activation.saturating_sub(1);
        // This is wallet metadata, never the signed transaction's bytes. Its
        // effective last mineable height is the ended branch's last block.
        // Keep all spend links and raw bytes for ordinary reorg re-discovery.
        view.execute(
            "UPDATE transactions SET expiry_height = CASE
                WHEN expiry_height IS NULL OR expiry_height = 0 OR expiry_height > ? THEN ?
                ELSE expiry_height END, confirmed_unmined_at_height = ?
             WHERE txid = ? AND mined_height IS NULL",
            params![branch_end, branch_end, scanned, txid.as_ref()],
        )?;
        if let Some(owner) = owner {
            view.execute(
                "UPDATE orchard_received_notes SET lock_expiry_height = NULL, lock_owner = NULL
                 WHERE lock_owner = ? AND account_id = (SELECT id FROM accounts WHERE uuid = ?)",
                params![owner.as_bytes(), account.expose_uuid()],
            )?;
        }
    }
    let activation_height = invalidated
        .iter()
        .map(|(_, _, a)| *a)
        .max()
        .ok_or(Error::Corrupt("empty migration invalidation set"))?;
    view.execute_batch(
        "CREATE TABLE IF NOT EXISTS orchard_ironwood_migration_upgrade_stops (
            migration_id INTEGER PRIMARY KEY REFERENCES orchard_ironwood_migrations(id) ON DELETE CASCADE,
            activation_height INTEGER NOT NULL,
            invalidated_transactions INTEGER NOT NULL
        )",
    )?;
    let receipt = UpgradeStop {
        activation_height,
        invalidated_transactions: invalidated.len() as u32,
    };
    view.execute(
        "INSERT INTO orchard_ironwood_migration_upgrade_stops
         (migration_id, activation_height, invalidated_transactions) VALUES (?, ?, ?)",
        params![
            migration_id,
            receipt.activation_height,
            receipt.invalidated_transactions
        ],
    )?;
    view.execute(
        "UPDATE orchard_ironwood_migrations SET status = ? WHERE id = ?",
        params![MigrationStatus::Superseded.wire_name(), migration_id],
    )?;
    view.commit()?;
    Ok(Some(receipt))
}

/// The latest run's upgrade-stop receipt. Read-only and safe before this
/// optional extension has ever been needed in an existing wallet database.
pub fn latest_upgrade_stop(
    connection: &Connection,
    account: AccountUuid,
) -> Result<Option<UpgradeStop>, Error> {
    let installed: bool = connection.query_row(
        "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type = 'table'
         AND name = 'orchard_ironwood_migration_upgrade_stops')",
        [],
        |row| row.get(0),
    )?;
    if !installed {
        return Ok(None);
    }
    Ok(connection.query_row(
        "SELECT s.activation_height, s.invalidated_transactions
         FROM orchard_ironwood_migration_upgrade_stops s
         JOIN orchard_ironwood_migrations m ON m.id = s.migration_id
         JOIN accounts a ON a.id = m.account_id
         WHERE a.uuid = ? AND m.id = (
            SELECT MAX(latest.id) FROM orchard_ironwood_migrations latest WHERE latest.account_id = a.id
         )",
        params![account.expose_uuid()],
        |row| Ok(UpgradeStop { activation_height: row.get(0)?, invalidated_transactions: row.get(1)? }),
    ).optional()?)
}
