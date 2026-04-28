use anyhow::Result;

use zcash_client_backend::data_api::wallet::ConfirmationsPolicy;
use zcash_client_backend::data_api::{Account, WalletRead};
use zcash_keys::keys::UnifiedAddressRequest;
use zcash_protocol::consensus::NetworkType;

use crate::types::{AddressInfo, EngineTransactionRecord, WalletBalance};

use super::{open_wallet_db, open_cipher_conn, ENGINE};

fn network_type(params: &zcash_protocol::consensus::Network) -> NetworkType {
    match params {
        zcash_protocol::consensus::Network::MainNetwork => NetworkType::Main,
        zcash_protocol::consensus::Network::TestNetwork => NetworkType::Test,
    }
}

// ---------------------------------------------------------------------------
// Addresses
// ---------------------------------------------------------------------------

pub async fn get_addresses() -> Result<Vec<AddressInfo>> {
    let guard = ENGINE.lock().await;
    let engine = guard
        .as_ref()
        .ok_or_else(|| anyhow::anyhow!("Engine not initialized"))?;

    let db = open_wallet_db(&engine.db_data_path, engine.params, &engine.db_cipher_key)?;

    let account_ids = db
        .get_account_ids()
        .map_err(|e| anyhow::anyhow!("{:?}", e))?;
    let account_id = account_ids
        .first()
        .ok_or_else(|| anyhow::anyhow!("No accounts"))?;

    let request = UnifiedAddressRequest::AllAvailableKeys;

    let address = db
        .get_last_generated_address_matching(*account_id, request)
        .map_err(|e| anyhow::anyhow!("{:?}", e))?;

    match address {
        Some(ua) => {
            let encoded = ua.encode(&engine.params);
            Ok(vec![AddressInfo {
                address: encoded,
                has_transparent: ua.transparent().is_some(),
                has_sapling: ua.sapling().is_some(),
                has_orchard: ua.has_orchard(),
            }])
        }
        None => Ok(vec![]),
    }
}

pub async fn get_transparent_addresses() -> Result<Vec<String>> {
    let guard = ENGINE.lock().await;
    let engine = guard
        .as_ref()
        .ok_or_else(|| anyhow::anyhow!("Engine not initialized"))?;

    let db = open_wallet_db(&engine.db_data_path, engine.params, &engine.db_cipher_key)?;

    let account_ids = db
        .get_account_ids()
        .map_err(|e| anyhow::anyhow!("{:?}", e))?;
    let account_id = account_ids
        .first()
        .ok_or_else(|| anyhow::anyhow!("No accounts"))?;

    let request = UnifiedAddressRequest::AllAvailableKeys;

    let address = db
        .get_last_generated_address_matching(*account_id, request)
        .map_err(|e| anyhow::anyhow!("{:?}", e))?;

    match address {
        Some(ua) => {
            if let Some(taddr) = ua.transparent() {
                let net = network_type(&engine.params);
                let encoded = taddr.to_zcash_address(net).encode();
                Ok(vec![encoded])
            } else {
                Ok(vec![])
            }
        }
        None => Ok(vec![]),
    }
}

// ---------------------------------------------------------------------------
// Balance
// ---------------------------------------------------------------------------

pub async fn get_wallet_balance() -> Result<WalletBalance> {
    let guard = ENGINE.lock().await;
    let engine = guard
        .as_ref()
        .ok_or_else(|| anyhow::anyhow!("Engine not initialized"))?;

    let db = open_wallet_db(&engine.db_data_path, engine.params, &engine.db_cipher_key)?;

    // catch_unwind guards against a known zcash_client_sqlite panic in
    // subtree_scan_progress on freshly created wallets with no scanned blocks.
    let summary = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        db.get_wallet_summary(ConfirmationsPolicy::MIN)
    }))
    .map_err(|_| anyhow::anyhow!("wallet summary not yet available (scan progress panic)"))?
    .map_err(|e| anyhow::anyhow!("{:?}", e))?;

    // IMPORTANT: do NOT silently return all-zero balances here. Returning
    // `Ok(WalletBalance::default())` from any of these "no data yet" branches
    // causes the mobile UI to overwrite a known-good balance with 0 — which
    // looks to a user mid-send like their funds disappeared. Surface them as
    // explicit errors so Dart `updateBalance` can preserve the last balance.
    let summary = summary.ok_or_else(|| {
        anyhow::anyhow!("wallet summary not yet available (sync in progress)")
    })?;

    let account_ids = db
        .get_account_ids()
        .map_err(|e| anyhow::anyhow!("{:?}", e))?;
    let account_id = account_ids
        .first()
        .ok_or_else(|| anyhow::anyhow!("wallet has no accounts"))?;

    let ab = summary.account_balances().get(account_id).ok_or_else(|| {
        anyhow::anyhow!("account balance entry missing for account {:?}", account_id)
    })?;

    Ok(WalletBalance {
        transparent: u64::from(ab.unshielded_balance().spendable_value()),
        sapling: u64::from(ab.sapling_balance().spendable_value()),
        orchard: u64::from(ab.orchard_balance().spendable_value()),
        unconfirmed_sapling: u64::from(ab.sapling_balance().value_pending_spendability()),
        unconfirmed_orchard: u64::from(ab.orchard_balance().value_pending_spendability()),
        unconfirmed_transparent: u64::from(ab.unshielded_balance().value_pending_spendability()),
        total_transparent: u64::from(ab.unshielded_balance().total()),
        total_sapling: u64::from(ab.sapling_balance().total()),
        total_orchard: u64::from(ab.orchard_balance().total()),
    })
}

// ---------------------------------------------------------------------------
// Misc queries
// ---------------------------------------------------------------------------

pub async fn get_birthday() -> Result<u32> {
    let guard = ENGINE.lock().await;
    let engine = guard
        .as_ref()
        .ok_or_else(|| anyhow::anyhow!("Engine not initialized"))?;
    Ok(u32::from(engine.birthday))
}

pub async fn get_synced_height() -> Result<u32> {
    let progress = super::sync::get_progress().await;
    if progress.is_syncing && progress.synced_height > 0 {
        return Ok(progress.synced_height);
    }

    let guard = ENGINE.lock().await;
    let engine = guard
        .as_ref()
        .ok_or_else(|| anyhow::anyhow!("Engine not initialized"))?;

    let db = open_wallet_db(&engine.db_data_path, engine.params, &engine.db_cipher_key)?;

    let summary = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        db.get_wallet_summary(ConfirmationsPolicy::default())
    }))
    .ok()
    .and_then(|r| r.ok())
    .flatten();

    if let Some(s) = summary {
        Ok(u32::from(s.fully_scanned_height()))
    } else {
        Ok(u32::from(engine.birthday))
    }
}

pub async fn has_spending_key() -> Result<bool> {
    let guard = ENGINE.lock().await;
    let engine = guard
        .as_ref()
        .ok_or_else(|| anyhow::anyhow!("Engine not initialized"))?;

    let db = open_wallet_db(&engine.db_data_path, engine.params, &engine.db_cipher_key)?;

    let account_ids = db
        .get_account_ids()
        .map_err(|e| anyhow::anyhow!("{:?}", e))?;
    let Some(account_id) = account_ids.first() else {
        return Ok(false);
    };

    let account = db
        .get_account(*account_id)
        .map_err(|e| anyhow::anyhow!("{:?}", e))?;

    match account {
        Some(acct) => Ok(acct.source().key_derivation().is_some()),
        None => Ok(false),
    }
}

// ---------------------------------------------------------------------------
// Transaction history
// ---------------------------------------------------------------------------

pub async fn get_transactions() -> Result<Vec<EngineTransactionRecord>> {
    let guard = ENGINE.lock().await;
    let engine = guard
        .as_ref()
        .ok_or_else(|| anyhow::anyhow!("Engine not initialized"))?;

    let conn = open_cipher_conn(&engine.db_data_path, &engine.db_cipher_key)?;

    let mut stmt = conn.prepare(
        "SELECT
            txid,
            COALESCE(mined_height, 0) AS height,
            COALESCE(block_time, CAST(strftime('%s', 'now') AS INTEGER)) AS block_time,
            account_balance_delta AS delta,
            fee_paid,
            sent_note_count,
            received_note_count,
            has_change,
            is_shielding,
            expired_unmined
        FROM v_transactions
        ORDER BY mined_height IS NOT NULL, mined_height DESC, tx_index DESC",
    )?;

    let rows = stmt.query_map([], |row| {
        let txid_bytes: Vec<u8> = row.get(0)?;
        let height: u32 = row.get(1)?;
        let block_time: u32 = row.get(2)?;
        let delta: i64 = row.get(3)?;
        let fee_paid: Option<i64> = row.get(4)?;
        let sent_count: i64 = row.get(5)?;
        let received_count: i64 = row.get(6)?;
        let has_change: bool = row.get(7)?;
        let is_shielding: bool = row.get(8)?;
        let expired: bool = row.get(9)?;

        let mut txid_display = txid_bytes.clone();
        txid_display.reverse();
        let txid_hex = hex::encode(&txid_display);

        let kind = if is_shielding {
            "shielding"
        } else if sent_count > 0 && has_change {
            "sent"
        } else if received_count > 0 && sent_count == 0 {
            "received"
        } else if sent_count > 0 {
            "sent"
        } else if delta < 0 || fee_paid.is_some() {
            "sent"
        } else {
            "unknown"
        };

        tracing::info!(
            "[TX] txid={} h={} delta={} fee={:?} sent={} recv={} expired={} kind={}",
            &txid_hex[..12], height, delta, fee_paid, sent_count, received_count, expired, kind
        );

        Ok(EngineTransactionRecord {
            txid: txid_hex,
            height,
            timestamp: block_time,
            value: delta,
            kind: kind.to_string(),
            fee: fee_paid.map(|f| f as u64),
            memo: None,
            expired_unmined: expired,
        })
    })?;

    let mut txs = Vec::new();
    let mut seen_txids = std::collections::HashSet::new();
    for row in rows {
        let tx = row?;
        if seen_txids.insert(tx.txid.clone()) {
            txs.push(tx);
        } else {
            tracing::info!("[TX] skipping duplicate txid={}", tx.txid);
        }
    }

    for tx in &mut txs {
        let mut txid_bytes = hex::decode(&tx.txid).unwrap_or_default();
        txid_bytes.reverse();
        let memo: Option<Vec<u8>> = conn
            .query_row(
                "SELECT memo FROM v_tx_outputs
                 WHERE txid = ? AND memo IS NOT NULL AND memo != X'F6'
                 LIMIT 1",
                rusqlite::params![txid_bytes],
                |row| row.get(0),
            )
            .ok();
        if let Some(memo_bytes) = memo {
            if let Ok(memo_obj) = zcash_protocol::memo::MemoBytes::from_bytes(&memo_bytes) {
                if let Ok(zcash_protocol::memo::Memo::Text(t)) =
                    zcash_protocol::memo::Memo::try_from(memo_obj)
                {
                    tx.memo = Some(String::from(t));
                }
            }
        }
    }

    Ok(txs)
}

pub async fn export_ufvk() -> Result<Option<String>> {
    let guard = ENGINE.lock().await;
    let engine = guard
        .as_ref()
        .ok_or_else(|| anyhow::anyhow!("Engine not initialized"))?;

    let db = open_wallet_db(&engine.db_data_path, engine.params, &engine.db_cipher_key)?;

    let account_ids = db
        .get_account_ids()
        .map_err(|e| anyhow::anyhow!("{:?}", e))?;
    let Some(account_id) = account_ids.first() else {
        return Ok(None);
    };

    let account = db
        .get_account(*account_id)
        .map_err(|e| anyhow::anyhow!("{:?}", e))?;

    match account {
        Some(acct) => {
            let ufvk = acct.ufvk().map(|k| k.encode(&engine.params));
            Ok(ufvk)
        }
        None => Ok(None),
    }
}

pub async fn export_uivk() -> Result<Option<String>> {
    let guard = ENGINE.lock().await;
    let engine = guard
        .as_ref()
        .ok_or_else(|| anyhow::anyhow!("Engine not initialized"))?;

    let db = open_wallet_db(&engine.db_data_path, engine.params, &engine.db_cipher_key)?;

    let account_ids = db
        .get_account_ids()
        .map_err(|e| anyhow::anyhow!("{:?}", e))?;
    let Some(account_id) = account_ids.first() else {
        return Ok(None);
    };

    let account = db
        .get_account(*account_id)
        .map_err(|e| anyhow::anyhow!("{:?}", e))?;

    match account {
        Some(acct) => {
            let uivk = acct
                .ufvk()
                .map(|k| k.to_unified_incoming_viewing_key().encode(&engine.params));
            Ok(uivk)
        }
        None => Ok(None),
    }
}
