//! Upgrade recovery against the real wallet schema and public SDK adapters.
//! Fixtures model scan/inclusion records; no real money, node or proof is used.

use rusqlite::{params, Connection};
use secrecy::SecretVec;
use zcash_client_backend::data_api::{chain::ChainState, AccountBirthday, WalletWrite};
use zcash_client_sqlite::{
    pool_migration::orchard_ironwood::{upgrade, PoolMigrations},
    util::SystemClock,
    wallet::init::init_wallet_db,
    AccountUuid, WalletDb,
};
use zcash_pool_migration::{
    denomination::DenominationPlan,
    engine::{
        MigrationLockOwner, MigrationState, MigrationStatus, MigrationTransaction,
        MigrationTransferId, MigrationTxKind, MigrationTxState, PoolMigrationRead,
        PoolMigrationWrite,
    },
    preparation::PreparationPlan,
    satisfiability::ReplanThreshold,
    scheduling::AnchorBucketInterval,
};
use zcash_primitives::transaction::{Authorized, TransactionData};
use zcash_protocol::{
    consensus::{BlockHeight, BranchId, Network, NetworkUpgrade, Parameters},
    value::Zatoshis,
    TxId,
};

struct Fixture {
    _directory: tempfile::TempDir,
    connection: Connection,
    account: AccountUuid,
    activation: u32,
    raw: Vec<u8>,
    txid: TxId,
    owner: [u8; 32],
}

fn fixture() -> Fixture {
    let network = Network::TestNetwork;
    let activation = u32::from(network.activation_height(NetworkUpgrade::Nu7).unwrap());
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("wallet.sqlite");
    let conn = Connection::open(&path).unwrap();
    rusqlite::vtab::array::load_module(&conn).unwrap();
    let mut wallet = WalletDb::from_connection(conn, network, SystemClock, rand::rngs::OsRng);
    init_wallet_db(&mut wallet, None).unwrap();
    let birthday = AccountBirthday::from_parts(
        ChainState::empty(
            BlockHeight::from_u32(activation - 10),
            zcash_primitives::block::BlockHash([0; 32]),
        ),
        None,
    );
    let (account, _) = wallet
        .create_account("disposable", &SecretVec::new(vec![42; 32]), &birthday, None)
        .unwrap();
    drop(wallet);
    let connection = Connection::open(path).unwrap();
    let branch = BranchId::for_height(&network, BlockHeight::from_u32(activation - 1));
    let expiry = activation + 100_000;
    let tx = TransactionData::<Authorized>::from_parts_v6(
        branch,
        0,
        BlockHeight::from_u32(expiry),
        None,
        None,
        None,
        None,
    )
    .freeze()
    .unwrap();
    let txid = tx.txid();
    let mut raw = Vec::new();
    tx.write(&mut raw).unwrap();
    let pczt = pczt::roles::creator::Creator::new(u32::from(branch), expiry, 1, None, None)
        .unwrap()
        .build()
        .unwrap()
        .serialize()
        .unwrap();
    assert_eq!(
        zcash_pool_migration::pczt_txid::stored_pczt_txid(&pczt).unwrap(),
        txid
    );
    let owner = [9; 32];
    let part = MigrationTransaction::from_parts(
        MigrationTransferId::new(0),
        MigrationTxKind::Transfer { crossing: 0 },
        pczt,
        vec![],
        BlockHeight::from_u32(activation - 5),
        BlockHeight::from_u32(expiry),
        None,
        txid,
        MigrationTxState::Broadcast { txid },
        Some(MigrationLockOwner::from_bytes(owner)),
        None,
        vec![[1; 32]],
        None,
    );
    let state = MigrationState::from_parts(
        MigrationStatus::InProgress,
        DenominationPlan::from_stored_parts(
            vec![],
            Zatoshis::ZERO,
            None,
            Zatoshis::ZERO,
            Zatoshis::ZERO,
            Zatoshis::ZERO,
        )
        .unwrap(),
        PreparationPlan::from_parts(vec![], vec![]),
        vec![part],
        AnchorBucketInterval::ZIP_318,
        ReplanThreshold::DEFAULT,
    );
    let mut connection = connection;
    {
        let mut store =
            PoolMigrations::for_account(network, SystemClock, &mut connection, account).unwrap();
        store.replace_migration(&state).unwrap();
    }
    let account_id: i64 = connection
        .query_row(
            "SELECT id FROM accounts WHERE uuid = ?",
            params![account.expose_uuid()],
            |r| r.get(0),
        )
        .unwrap();
    connection
        .execute(
            "INSERT INTO transactions (id_tx,txid,raw,expiry_height,min_observed_height) VALUES (100,?, ?, ?, ?)",
            params![txid.as_ref(), raw, expiry, activation - 5],
        )
        .unwrap();
    connection
        .execute(
            "INSERT INTO transactions (id_tx,txid,min_observed_height) VALUES (101,?,?)",
            params![&[4u8; 32][..], activation - 9],
        )
        .unwrap();
    for (id, token) in [(200, owner), (201, [8; 32])] {
        connection.execute(
            "INSERT INTO orchard_received_notes
             (id,transaction_id,action_index,account_id,diversifier,value,rho,rseed,nf,is_change,lock_expiry_height,lock_owner)
             VALUES (?,101,?,?,?,100000,?,?,?,0,?,?)",
            params![id,id,account_id,&[0u8;11][..],&[1u8;32][..],&[2u8;32][..],&[id as u8;32][..],expiry,&token[..]],
        ).unwrap();
    }
    connection.execute("INSERT INTO orchard_received_note_spends (orchard_received_note_id,transaction_id) VALUES (200,100)", []).unwrap();
    let mut fixture = Fixture {
        _directory: directory,
        connection,
        account,
        activation,
        raw,
        txid,
        owner,
    };
    set_scan_height(&mut fixture, activation - 1);
    fixture
}

fn set_scan_height(f: &mut Fixture, height: u32) {
    f.connection.execute("DELETE FROM scan_queue", []).unwrap();
    f.connection
        .execute(
            "INSERT INTO scan_queue (block_range_start,block_range_end,priority) VALUES (?,?,10)",
            params![f.activation - 9, height + 1],
        )
        .unwrap();
}

#[test]
fn server_absence_and_old_branch_tip_cannot_release_a_migration() {
    let mut f = fixture();
    assert!(upgrade::stop_invalidated_migration(
        &mut f.connection,
        &Network::TestNetwork,
        f.account
    )
    .unwrap()
    .is_none());
    let owner: Option<Vec<u8>> = f
        .connection
        .query_row(
            "SELECT lock_owner FROM orchard_received_notes WHERE id=200",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(owner, Some(f.owner.to_vec()));
    assert!(upgrade::latest_upgrade_stop(&f.connection, f.account)
        .unwrap()
        .is_none());
}

#[test]
fn scanned_upgrade_stops_exact_old_transactions_and_retains_reorg_evidence() {
    let mut f = fixture();
    let activation = f.activation;
    set_scan_height(&mut f, activation);
    let stopped =
        upgrade::stop_invalidated_migration(&mut f.connection, &Network::TestNetwork, f.account)
            .unwrap()
            .unwrap();
    assert_eq!(stopped.activation_height, activation);
    assert_eq!(stopped.invalidated_transactions, 1);
    let row: (u32, Option<u32>, Vec<u8>) = f
        .connection
        .query_row(
            "SELECT expiry_height,mined_height,raw FROM transactions WHERE id_tx=100",
            [],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
        )
        .unwrap();
    assert_eq!(row, (activation - 1, None, f.raw.clone()));
    let own: Option<Vec<u8>> = f
        .connection
        .query_row(
            "SELECT lock_owner FROM orchard_received_notes WHERE id=200",
            [],
            |r| r.get(0),
        )
        .unwrap();
    let unrelated: Option<Vec<u8>> = f
        .connection
        .query_row(
            "SELECT lock_owner FROM orchard_received_notes WHERE id=201",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert!(own.is_none());
    assert_eq!(unrelated, Some(vec![8; 32]));
    let links: i64 = f
        .connection
        .query_row(
            "SELECT COUNT(*) FROM orchard_received_note_spends WHERE transaction_id=100",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(links, 1, "hard spend links survive for reorg re-inclusion");
    let store =
        PoolMigrations::for_account(Network::TestNetwork, SystemClock, &f.connection, f.account)
            .unwrap();
    assert!(store.get_migration().unwrap().is_none());
    assert_eq!(
        store.latest_migration().unwrap().unwrap().status(),
        MigrationStatus::Superseded
    );
    drop(store);
    assert_eq!(
        upgrade::latest_upgrade_stop(&f.connection, f.account).unwrap(),
        Some(stopped)
    );
    assert!(
        upgrade::stop_invalidated_migration(&mut f.connection, &Network::TestNetwork, f.account)
            .unwrap()
            .is_none(),
        "idempotent after restart"
    );
    // Model a rewind and discovery of an earlier inclusion through the SDK's
    // transaction-status API. Raw bytes and spend links let inclusion win over
    // the prior unmined-expired metadata rather than losing the transaction.
    set_scan_height(&mut f, activation - 2);
    let wallet_connection = Connection::open(f._directory.path().join("wallet.sqlite")).unwrap();
    let mut wallet = WalletDb::from_connection(
        wallet_connection,
        Network::TestNetwork,
        SystemClock,
        rand::rngs::OsRng,
    );
    wallet
        .set_transaction_status(
            f.txid,
            zcash_client_backend::data_api::TransactionStatus::Mined(BlockHeight::from_u32(
                activation - 3,
            )),
        )
        .unwrap();
    let mined: Option<u32> = f
        .connection
        .query_row(
            "SELECT mined_height FROM transactions WHERE id_tx=100",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(mined, Some(activation - 3));
}

#[test]
fn ahead_of_scan_inclusion_and_corrupt_bytes_fail_closed() {
    let mut f = fixture();
    let activation = f.activation;
    set_scan_height(&mut f, activation);
    f.connection
        .execute(
            "UPDATE transactions SET mined_height=? WHERE id_tx=100",
            params![activation + 1],
        )
        .unwrap();
    assert!(upgrade::stop_invalidated_migration(
        &mut f.connection,
        &Network::TestNetwork,
        f.account
    )
    .unwrap()
    .is_none());
    f.connection
        .execute(
            "UPDATE transactions SET mined_height=NULL,raw=x'00' WHERE id_tx=100",
            [],
        )
        .unwrap();
    assert!(upgrade::stop_invalidated_migration(
        &mut f.connection,
        &Network::TestNetwork,
        f.account
    )
    .is_err());
    let owner: Option<Vec<u8>> = f
        .connection
        .query_row(
            "SELECT lock_owner FROM orchard_received_notes WHERE id=200",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(owner, Some(f.owner.to_vec()));
    assert!(upgrade::latest_upgrade_stop(&f.connection, f.account)
        .unwrap()
        .is_none());
}

#[test]
fn a_part_mined_before_activation_is_preserved_in_the_stopped_receipt() {
    let mut f = fixture();
    let activation = f.activation;
    set_scan_height(&mut f, activation);
    let branch = BranchId::for_height(&Network::TestNetwork, BlockHeight::from_u32(activation - 1));
    let pczt =
        pczt::roles::creator::Creator::new(u32::from(branch), activation + 100_001, 1, None, None)
            .unwrap()
            .build()
            .unwrap()
            .serialize()
            .unwrap();
    let txid = zcash_pool_migration::pczt_txid::stored_pczt_txid(&pczt).unwrap();
    f.connection
        .execute(
            "INSERT INTO transactions (id_tx,txid,mined_height,min_observed_height) VALUES (102,?,?,?)",
            params![txid.as_ref(), activation - 2, activation - 5],
        )
        .unwrap();
    // Model the app stopping after the node accepted a second part but before
    // its migration-row broadcast marker persisted. The scanner did observe
    // the exact txid mined, so that evidence takes precedence over Proved.
    f.connection.execute(
        "INSERT INTO orchard_ironwood_migration_transactions
         (migration_id,transfer_id,kind,kind_crossing,pczt,scheduled_height,expiry_height,state,txid)
         SELECT migration_id,1,kind,1,?,scheduled_height,expiry_height,'proved',?
         FROM orchard_ironwood_migration_transactions WHERE transfer_id=0",
        params![pczt,txid.as_ref()],
    ).unwrap();
    f.connection.execute(
        "INSERT INTO orchard_ironwood_migration_spend_nullifiers
         (migration_id,transfer_id,ordinal,nullifier)
         SELECT migration_id,1,0,? FROM orchard_ironwood_migration_transactions WHERE transfer_id=0",
        params![&[6u8;32][..]],
    ).unwrap();
    let stopped =
        upgrade::stop_invalidated_migration(&mut f.connection, &Network::TestNetwork, f.account)
            .unwrap()
            .unwrap();
    assert_eq!(stopped.invalidated_transactions, 1);
    let row: (String,Option<u32>) = f.connection.query_row(
        "SELECT state,mined_height FROM orchard_ironwood_migration_transactions WHERE transfer_id=1",
        [], |r| Ok((r.get(0)?,r.get(1)?)),
    ).unwrap();
    assert_eq!(row, ("mined".into(), Some(activation - 2)));
    let height: Option<u32> = f
        .connection
        .query_row(
            "SELECT mined_height FROM transactions WHERE id_tx=102",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(height, Some(activation - 2));
}
