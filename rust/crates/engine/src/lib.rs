pub mod types;
pub mod wallet;
pub mod query;
pub mod sync;
pub mod send;
pub mod policy;
pub mod audit;

use std::path::{Path, PathBuf};

use anyhow::Result;
use rusqlite::Connection;
use tokio::sync::Mutex;
use zcash_client_sqlite::util::SystemClock;
use zcash_client_sqlite::WalletDb;
use zcash_protocol::consensus::{BlockHeight, Network};

lazy_static::lazy_static! {
    pub(crate) static ref ENGINE: Mutex<Option<ZipherEngine>> = Mutex::new(None);
}

/// Core wallet engine built on zcash_client_sqlite + zcash_client_backend.
///
/// Stores database paths and network config. WalletDb instances are created
/// on demand from the stored path — this avoids complex generic type parameters
/// in the singleton while keeping SQLite connections short-lived and safe.
pub struct ZipherEngine {
    pub(crate) db_data_path: PathBuf,
    pub(crate) db_cache_path: PathBuf,
    pub(crate) params: Network,
    pub(crate) server_url: String,
    pub(crate) birthday: BlockHeight,
    pub(crate) db_cipher_key: Option<String>,
}

pub(crate) fn db_paths(data_dir: &str) -> (PathBuf, PathBuf) {
    let base = PathBuf::from(data_dir);
    (
        base.join("zipher-data.sqlite"),
        base.join("zipher-cache.sqlite"),
    )
}

/// Open a raw `rusqlite::Connection` with optional SQLCipher encryption.
/// PRAGMA key must be the very first statement on an encrypted database.
pub(crate) fn open_cipher_conn(path: &Path, key: &Option<String>) -> Result<Connection> {
    let conn = Connection::open(path)?;
    if let Some(k) = key {
        conn.pragma_update(None, "key", k)?;
    }
    conn.busy_timeout(std::time::Duration::from_secs(10))?;
    conn.pragma_update(None, "journal_mode", "WAL")?;
    Ok(conn)
}

/// Open a `WalletDb` with optional SQLCipher encryption via `from_connection`.
pub(crate) fn open_wallet_db(
    path: &Path,
    params: Network,
    key: &Option<String>,
) -> Result<WalletDb<Connection, Network, SystemClock, rand::rngs::OsRng>> {
    let conn = open_cipher_conn(path, key)?;
    rusqlite::vtab::array::load_module(&conn)?;
    Ok(WalletDb::from_connection(conn, params, SystemClock, rand::rngs::OsRng))
}

/// Migrate an existing unencrypted database to SQLCipher encryption.
/// Returns Ok(true) if migration was performed, Ok(false) if already encrypted or no key.
pub(crate) fn migrate_to_encrypted(path: &Path, key: &str) -> Result<bool> {
    {
        let conn = Connection::open(path)?;
        conn.pragma_update(None, "key", key)?;
        if conn.query_row("SELECT count(*) FROM sqlite_master", [], |r| r.get::<_, i64>(0)).is_ok() {
            return Ok(false);
        }
    }

    let plain_conn = Connection::open(path)?;
    let check = plain_conn.query_row(
        "SELECT count(*) FROM sqlite_master",
        [],
        |r| r.get::<_, i64>(0),
    );
    if check.is_err() {
        return Err(anyhow::anyhow!("Database at {:?} is neither plain nor validly encrypted", path));
    }

    let enc_path = path.with_extension("sqlite.enc_tmp");
    plain_conn.execute_batch(&format!(
        "ATTACH DATABASE '{}' AS encrypted KEY '{}';
         SELECT sqlcipher_export('encrypted');
         DETACH DATABASE encrypted;",
        enc_path.display(),
        key.replace('\'', "''"),
    ))?;
    drop(plain_conn);

    std::fs::rename(&enc_path, path)?;

    println!("[engine] migrated {:?} to encrypted", path);
    Ok(true)
}
