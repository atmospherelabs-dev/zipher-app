//! The wallet database is SQLCipher. Upgrading the bundled SQLCipher must keep
//! opening databases written by the previous release with the same key.

use std::path::PathBuf;

use rusqlite::Connection;

const KEY: &str = "fixture-key-not-a-wallet-secret";

fn fixture() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("testdata/sqlcipher-4.6-sqlite-3.46.1.db")
}

fn open(path: &std::path::Path, key: &str) -> rusqlite::Result<Connection> {
    // Same pragmas, in the same order, as the engine's open_cipher_conn.
    let conn = Connection::open(path)?;
    conn.pragma_update(None, "key", key)?;
    conn.pragma_update(None, "journal_mode", "WAL")?;
    Ok(conn)
}

/// Run against the previous release to regenerate the fixture:
/// ZIPHER_WRITE_SQLCIPHER_FIXTURE=1 cargo test -p zipher-engine --test sqlcipher_compatibility -- --ignored
#[test]
#[ignore]
fn write_fixture_with_the_current_build() {
    if std::env::var_os("ZIPHER_WRITE_SQLCIPHER_FIXTURE").is_none() {
        return;
    }
    let path = fixture();
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    let _ = std::fs::remove_file(&path);
    let conn = open(&path, KEY).unwrap();
    conn.execute_batch(
        "CREATE TABLE notes (id INTEGER PRIMARY KEY, value INTEGER NOT NULL, memo TEXT);
         INSERT INTO notes (value, memo) VALUES (150000000, 'one'), (51099391, 'change');",
    )
    .unwrap();
    // Leave a single self-contained file in the repository.
    conn.pragma_update(None, "journal_mode", "DELETE").unwrap();
}

#[test]
fn opens_a_database_written_by_the_previous_sqlcipher() {
    let dir = tempfile::tempdir().unwrap();
    let copy = dir.path().join("wallet.db");
    std::fs::copy(fixture(), &copy).unwrap();

    let conn = open(&copy, KEY).unwrap();
    let total: i64 = conn
        .query_row("SELECT SUM(value) FROM notes", [], |row| row.get(0))
        .unwrap();
    assert_eq!(total, 201_099_391);
    let ok: Vec<String> = conn
        .prepare("PRAGMA cipher_integrity_check")
        .unwrap()
        .query_map([], |row| row.get(0))
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap();
    assert!(ok.is_empty(), "cipher integrity: {ok:?}");

    // Writes after the upgrade stay readable on reopen.
    conn.execute("INSERT INTO notes (value, memo) VALUES (1, 'after')", []).unwrap();
    drop(conn);
    let conn = open(&copy, KEY).unwrap();
    let rows: i64 = conn.query_row("SELECT COUNT(*) FROM notes", [], |row| row.get(0)).unwrap();
    assert_eq!(rows, 3);
}

#[test]
fn a_wrong_key_cannot_read_it() {
    let dir = tempfile::tempdir().unwrap();
    let copy = dir.path().join("wallet.db");
    std::fs::copy(fixture(), &copy).unwrap();
    let read = open(&copy, "wrong-key")
        .and_then(|conn| conn.query_row("SELECT COUNT(*) FROM notes", [], |row| row.get::<_, i64>(0)));
    assert!(read.is_err());
}

#[test]
fn bundles_the_fixed_sqlite_and_sqlcipher() {
    let conn = Connection::open_in_memory().unwrap();
    let sqlite: String = conn.query_row("SELECT sqlite_version()", [], |row| row.get(0)).unwrap();
    assert_eq!(sqlite, "3.54.1");
    let cipher: String = conn
        .query_row("PRAGMA cipher_version", [], |row| row.get(0))
        .unwrap();
    assert!(cipher.starts_with("4.20.0"), "{cipher}");
}
