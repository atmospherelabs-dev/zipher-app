use std::convert::Infallible;

use zcash_client_backend::{
    data_api::chain::{error::Error, BlockSource},
    proto::compact_formats::CompactBlock,
};
use zcash_protocol::consensus::BlockHeight;

/// One validated, ordered batch. The SDK reads it twice (trial decryption,
/// then wallet/tree updates), so each traversal must return the same blocks.
/// This avoids serializing, encrypting, writing, reading, and deleting a
/// temporary SQLite cache for every batch. Wallet persistence stays in the SDK.
pub(super) struct MemoryBlockSource {
    blocks: Vec<CompactBlock>,
}

impl MemoryBlockSource {
    pub(super) fn new(blocks: Vec<CompactBlock>) -> Self {
        Self { blocks }
    }
}

impl BlockSource for MemoryBlockSource {
    type Error = Infallible;

    fn with_blocks<F, WalletErrT>(
        &self,
        from_height: Option<BlockHeight>,
        limit: Option<usize>,
        mut with_block: F,
    ) -> Result<(), Error<WalletErrT, Self::Error>>
    where
        F: FnMut(CompactBlock) -> Result<(), Error<WalletErrT, Self::Error>>,
    {
        let from = from_height.map(u64::from).unwrap_or(0);
        for block in self
            .blocks
            .iter()
            .skip_while(|block| block.height < from)
            .take(limit.unwrap_or(usize::MAX))
        {
            with_block(block.clone())?;
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use prost::Message;

    #[test]
    fn repeated_reads_match_the_sqlite_source_contract() {
        let blocks: Vec<_> = (100..105)
            .map(|height| CompactBlock {
                height,
                hash: vec![height as u8; 32],
                ..Default::default()
            })
            .collect();
        let source = MemoryBlockSource::new(blocks.clone());
        let conn = rusqlite::Connection::open_in_memory().unwrap();
        conn.execute_batch("CREATE TABLE compactblocks (height INTEGER PRIMARY KEY, data BLOB)")
            .unwrap();
        for block in blocks {
            conn.execute(
                "INSERT INTO compactblocks VALUES (?, ?)",
                rusqlite::params![block.height, block.encode_to_vec()],
            )
            .unwrap();
        }
        for from in [None, Some(99), Some(102), Some(105)] {
            for limit in [None, Some(0), Some(1), Some(10)] {
                let expected: Vec<Vec<u8>> = conn
                    .prepare(
                        "SELECT data FROM compactblocks WHERE height >= ? ORDER BY height LIMIT ?",
                    )
                    .unwrap()
                    .query_map(
                        rusqlite::params![from.unwrap_or(0), limit.unwrap_or(i64::MAX)],
                        |row| row.get(0),
                    )
                    .unwrap()
                    .collect::<Result<_, _>>()
                    .unwrap();
                for _ in 0..2 {
                    let mut actual = Vec::new();
                    source
                        .with_blocks::<_, Infallible>(
                            from.map(BlockHeight::from_u32),
                            limit.map(|n| n as usize),
                            |block| {
                                actual.push(block.encode_to_vec());
                                Ok(())
                            },
                        )
                        .unwrap();
                    assert_eq!(actual, expected);
                }
            }
        }
    }

    #[test]
    fn callback_errors_stop_traversal() {
        let source = MemoryBlockSource::new(vec![CompactBlock::default(); 3]);
        let mut calls = 0;
        let result = source.with_blocks(None, None, |_| {
            calls += 1;
            Err(Error::Wallet("stop"))
        });
        assert!(matches!(result, Err(Error::Wallet("stop"))));
        assert_eq!(calls, 1);
    }

    #[test]
    fn sdk_scans_and_rewinds_in_memory_batches() {
        use secrecy::SecretVec;
        use zcash_client_backend::data_api::{
            chain::{scan_cached_blocks, ChainState},
            AccountBirthday, WalletRead, WalletWrite,
        };
        use zcash_primitives::block::BlockHash;
        use zcash_protocol::consensus::Network;

        let dir = tempfile::tempdir().unwrap();
        let network = Network::TestNetwork;
        let mut db = crate::open_wallet_db(
            &dir.path().join("wallet.db"),
            network,
            &Some("disposable-scan-test".to_string()),
        )
        .unwrap();
        zcash_client_sqlite::wallet::init::init_wallet_db(&mut db, None).unwrap();
        let start = BlockHeight::from_u32(2_000_000);
        let state = ChainState::empty(start, BlockHash([0; 32]));
        let birthday = AccountBirthday::from_parts(state.clone(), None);
        db.create_account("test", &SecretVec::new(vec![42; 32]), &birthday, None)
            .unwrap();
        db.update_chain_tip(start + 3).unwrap();
        let assert_height = |db: &mut crate::sync::DbType, expected: u32| {
            let full = db.get_wallet_summary(zcash_client_backend::data_api::wallet::ConfirmationsPolicy::MIN)
                .unwrap();
            assert_eq!(crate::sync::wallet_fully_scanned_height(db), Some(expected));
            if let Some(full) = full {
                assert_eq!(u32::from(full.fully_scanned_height()), expected);
            }
        };
        assert_height(&mut db, u32::from(start));
        let blocks: Vec<_> = (1u8..=3)
            .map(|offset| CompactBlock {
                height: u64::from(u32::from(start)) + u64::from(offset),
                hash: vec![offset; 32],
                prev_hash: vec![offset - 1; 32],
                chain_metadata: Some(Default::default()),
                ..Default::default()
            })
            .collect();
        let source = MemoryBlockSource::new(blocks.clone());
        let summary = scan_cached_blocks(&network, &source, &mut db, start + 1, &state, 3).unwrap();
        assert_eq!(summary.scanned_range(), (start + 1..start + 4));
        assert!(db.block_metadata(start + 3).unwrap().is_some());
        assert_height(&mut db, u32::from(start + 3));

        db.truncate_to_height(start + 1).unwrap();
        assert!(db.block_metadata(start + 3).unwrap().is_none());
        assert_height(&mut db, u32::from(start + 1));
        let state = ChainState::empty(start + 1, BlockHash([1; 32]));
        let source = MemoryBlockSource::new(blocks[1..].to_vec());
        let summary = scan_cached_blocks(&network, &source, &mut db, start + 2, &state, 2).unwrap();
        assert_eq!(summary.scanned_range(), (start + 2..start + 4));
        assert!(db.block_metadata(start + 3).unwrap().is_some());
        assert_height(&mut db, u32::from(start + 3));
    }

    /// Measures staging overhead only, excluding network, decryption, and wallet writes.
    #[test]
    #[ignore = "manual synthetic staging benchmark"]
    fn benchmark_block_staging() {
        use std::{hint::black_box, time::Instant};
        use zcash_client_backend::proto::compact_formats::{CompactSaplingOutput, CompactTx};

        let blocks: Vec<_> = (100..1_100)
            .map(|height| CompactBlock {
                height,
                hash: vec![1; 32],
                prev_hash: vec![2; 32],
                vtx: vec![CompactTx {
                    outputs: vec![
                        CompactSaplingOutput {
                            cmu: vec![3; 32],
                            ephemeral_key: vec![4; 32],
                            ciphertext: vec![5; 52],
                        };
                        8
                    ],
                    ..Default::default()
                }],
                ..Default::default()
            })
            .collect();
        let source = MemoryBlockSource::new(blocks.clone());
        let dir = tempfile::tempdir().unwrap();
        let conn = crate::open_cipher_conn(
            &dir.path().join("cache.db"),
            &Some("disposable-benchmark-key".to_string()),
        )
        .unwrap();
        conn.execute_batch(
            "CREATE TABLE compactblocks (height INTEGER PRIMARY KEY, data BLOB NOT NULL)",
        )
        .unwrap();

        let rounds = 20;
        let started = Instant::now();
        for _ in 0..rounds {
            let tx = conn.unchecked_transaction().unwrap();
            {
                let mut insert = conn
                    .prepare_cached("INSERT OR REPLACE INTO compactblocks VALUES (?, ?)")
                    .unwrap();
                for block in &blocks {
                    insert
                        .execute(rusqlite::params![block.height, block.encode_to_vec()])
                        .unwrap();
                }
            }
            tx.commit().unwrap();
            for _ in 0..2 {
                let mut select = conn
                    .prepare_cached(
                        "SELECT data FROM compactblocks WHERE height >= ? ORDER BY height LIMIT ?",
                    )
                    .unwrap();
                let rows = select
                    .query_map(rusqlite::params![100, 1000], |row| row.get::<_, Vec<u8>>(0))
                    .unwrap();
                for data in rows {
                    black_box(CompactBlock::decode(data.unwrap().as_slice()).unwrap());
                }
            }
            conn.execute(
                "DELETE FROM compactblocks WHERE height >= ? AND height < ?",
                rusqlite::params![100, 1100],
            )
            .unwrap();
        }
        let sqlite_ms = started.elapsed().as_secs_f64() * 1000.0;
        let started = Instant::now();
        for _ in 0..rounds {
            for _ in 0..2 {
                source
                    .with_blocks::<_, Infallible>(
                        Some(BlockHeight::from_u32(100)),
                        Some(1000),
                        |block| {
                            black_box(block);
                            Ok(())
                        },
                    )
                    .unwrap();
            }
        }
        println!("staging only: rounds={rounds} blocks_per_round=1000 encrypted_sqlite_ms={sqlite_ms:.3} memory_ms={:.3}",
            started.elapsed().as_secs_f64() * 1000.0);
    }
}
