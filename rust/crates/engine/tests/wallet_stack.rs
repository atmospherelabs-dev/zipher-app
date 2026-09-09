//! Disposable database checks for the shared stable SDK / Zakura integration.
//! No real wallet, network connection, or spend is used here.

use secrecy::SecretVec;
use zcash_client_backend::data_api::{chain::ChainState, AccountBirthday, WalletRead, WalletWrite};
use zcash_client_sqlite::{
    pool_migration::orchard_ironwood::PoolMigrations, util::SystemClock,
    wallet::init::init_wallet_db, WalletDb,
};
use zcash_pool_migration::engine::PoolMigrationRead;
use zcash_protocol::consensus::{BlockHeight, Network};

fn open(
    path: &std::path::Path,
) -> WalletDb<rusqlite::Connection, Network, SystemClock, rand::rngs::OsRng> {
    let conn = rusqlite::Connection::open(path).unwrap();
    conn.pragma_update(None, "key", "disposable-test-key")
        .unwrap();
    rusqlite::vtab::array::load_module(&conn).unwrap();
    WalletDb::from_connection(conn, Network::TestNetwork, SystemClock, rand::rngs::OsRng)
}

#[test]
fn encrypted_wallet_reopens_and_restores_the_same_viewing_key() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("wallet.db");
    let seed = SecretVec::new(vec![42; 32]);
    let birthday = AccountBirthday::from_parts(
        ChainState::empty(
            BlockHeight::from_u32(2_000_000),
            zcash_primitives::block::BlockHash([0; 32]),
        ),
        None,
    );
    let mut wallet = open(&path);
    init_wallet_db(&mut wallet, None).unwrap();
    let (account, _) = wallet
        .create_account("test", &seed, &birthday, None)
        .unwrap();
    let encoded =
        wallet.get_unified_full_viewing_keys().unwrap()[&account].encode(&Network::TestNetwork);
    drop(wallet);

    // Re-running migrations on an existing encrypted database is idempotent.
    let mut reopened = open(&path);
    init_wallet_db(&mut reopened, Some(SecretVec::new(vec![42; 32]))).unwrap();
    assert_eq!(reopened.get_account_ids().unwrap(), vec![account]);
    assert_eq!(
        reopened.get_account_birthday(account).unwrap(),
        birthday.height()
    );
    assert_eq!(
        reopened.get_unified_full_viewing_keys().unwrap()[&account].encode(&Network::TestNetwork),
        encoded
    );
    drop(reopened);
    assert!(!std::fs::read(&path)
        .unwrap()
        .starts_with(b"SQLite format 3"));

    let mut restored = open(&dir.path().join("restored.db"));
    init_wallet_db(&mut restored, None).unwrap();
    let (restored_account, _) = restored
        .create_account("restored", &seed, &birthday, None)
        .unwrap();
    assert_eq!(
        restored.get_unified_full_viewing_keys().unwrap()[&restored_account]
            .encode(&Network::TestNetwork),
        encoded
    );

    // Ironwood storage remains present, scoped to this account, and supports
    // idempotent cancellation even before the first migration is committed.
    let conn = rusqlite::Connection::open(&path).unwrap();
    conn.pragma_update(None, "key", "disposable-test-key")
        .unwrap();
    let mut migrations =
        PoolMigrations::for_account(Network::TestNetwork, SystemClock, conn, account).unwrap();
    assert!(migrations.get_migration().unwrap().is_none());
    migrations.cancel_migration().unwrap();
    migrations.cancel_migration().unwrap();
    assert!(migrations.get_migration().unwrap().is_none());
}
