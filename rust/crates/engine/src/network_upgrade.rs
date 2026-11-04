//! Transaction and migration policy at consensus branch boundaries.
//!
//! The hold windows and branch-end expiry policy follow Vizor v0.0.63's
//! `wallet/network_upgrade.rs` and `docs/network-upgrades.md`. Chain parameters
//! and normal expiry durations come from the linked protocol/Common release.
//! No wallet or server hint is allowed to extend a signed transaction's branch.

use anyhow::{bail, Context, Result};
use zcash_client_backend::proto::service::{
    compact_tx_streamer_client::CompactTxStreamerClient, ChainSpec, Empty, RawTransaction,
    SendResponse,
};
use zcash_primitives::transaction::{builder::default_tx_expiry_delta, Transaction, TxVersion};
use zcash_protocol::consensus::{BlockHeight, BranchId, Network, Parameters};

#[cfg(test)]
#[path = "network_upgrade_test_server.rs"]
pub(crate) mod test_server;

pub(crate) const MIGRATION_HOLD_BLOCKS: u32 = 10;
pub(crate) const EXPIRING_SOON_BLOCKS: u32 = 3;
pub(crate) const SEND_HOLD_MESSAGE: &str =
    "NETWORK_UPGRADE_HOLD: Payments are paused for the network upgrade. Review again after it activates.";
pub(crate) const MIGRATION_HOLD_MESSAGE: &str =
    "NETWORK_UPGRADE_HOLD: Migration is paused for the network upgrade. No new transaction was submitted.";

pub(crate) fn branch_at<P: Parameters>(params: &P, height: u32) -> BranchId {
    BranchId::for_height(params, BlockHeight::from_u32(height))
}

pub(crate) fn next_activation<P: Parameters>(params: &P, height: u32) -> Option<u32> {
    branch_at(params, height)
        .height_bounds(params)
        .and_then(|(_, next)| next.map(u32::from))
}

pub(crate) fn cap_expiry<P: Parameters>(params: &P, target: u32, expiry: u32) -> BlockHeight {
    let capped = next_activation(params, target).map_or(expiry, |activation| {
        expiry.min(activation.saturating_sub(1))
    });
    BlockHeight::from_u32(capped.max(target))
}

/// The ordinary send expiry, with no crossing of the target's consensus branch.
/// Canonical ZIP 318 migration expiry must use the migration SDK instead.
pub(crate) fn ensure_send_target<P: Parameters>(params: &P, target: u32) -> Result<BlockHeight> {
    let delta = default_tx_expiry_delta(params, BlockHeight::from_u32(target));
    let expiry = cap_expiry(params, target, target.saturating_add(delta));
    if u32::from(expiry) < target.saturating_add(EXPIRING_SOON_BLOCKS) {
        bail!(SEND_HOLD_MESSAGE);
    }
    Ok(expiry)
}

pub(crate) fn ensure_same_branch<P: Parameters>(
    params: &P,
    reviewed: u32,
    live: u32,
) -> Result<()> {
    if branch_at(params, reviewed) != branch_at(params, live) {
        bail!("NETWORK_UPGRADE_REVIEW: The network changed since this payment was reviewed. Create and review a new proposal.");
    }
    Ok(())
}

/// Hold a presigned migration through the last old-branch tip. A stale server
/// that stopped at activation-minus-one must not receive an old signature.
pub(crate) fn migration_held<P: Parameters>(params: &P, signed_branch: BranchId, tip: u32) -> bool {
    signed_branch
        != branch_at(
            params,
            tip.saturating_add(1).saturating_add(MIGRATION_HOLD_BLOCKS),
        )
}

pub(crate) fn ensure_migration_can_start<P: Parameters>(params: &P, target: u32) -> Result<()> {
    if migration_held(params, branch_at(params, target), target.saturating_sub(1)) {
        bail!(MIGRATION_HOLD_MESSAGE);
    }
    Ok(())
}

pub(crate) fn ensure_endpoint_network(params: &Network, chain_name: &str) -> Result<()> {
    let matches = match params {
        Network::MainNetwork => matches!(chain_name.trim(), "main" | "mainnet"),
        Network::TestNetwork => matches!(chain_name.trim(), "test" | "testnet"),
    };
    if !matches {
        bail!("Submission server reports a different or unknown Zcash network");
    }
    Ok(())
}

/// Read the submission connection itself immediately before spending work.
/// Any missing/invalid network or height is a hard refusal, never a cached-tip
/// fallback. The caller can combine this with its independently observed tip.
pub(crate) async fn endpoint_tip(
    lwd: &mut CompactTxStreamerClient<tonic::transport::Channel>,
    params: &Network,
) -> Result<u32> {
    let info = lwd
        .get_lightd_info(Empty {})
        .await
        .context("Read submission server network before broadcast")?
        .into_inner();
    ensure_endpoint_network(params, &info.chain_name)?;
    let tip = lwd
        .get_latest_block(ChainSpec {})
        .await
        .context("Read fresh submission server height before broadcast")?
        .into_inner();
    let height = u32::try_from(tip.height.max(info.block_height))
        .context("Submission server height exceeds the supported range")?;
    if height == 0 {
        bail!("Submission server has no usable chain tip");
    }
    Ok(height)
}

fn validate_signed_metadata<P: Parameters>(
    params: &P,
    version: TxVersion,
    signed_branch: BranchId,
    expiry: u32,
    tip: u32,
) -> Result<()> {
    let target = tip
        .checked_add(1)
        .context("Submission target height overflow")?;
    let expected = branch_at(params, target);
    if !version.valid_in_branch(expected) {
        bail!("NETWORK_UPGRADE_REVIEW: This transaction version is no longer accepted. Create and review a new payment.");
    }
    if signed_branch != expected {
        bail!("NETWORK_UPGRADE_REVIEW: This transaction was signed for a different network upgrade. Create and review a new payment.");
    }
    if expiry != 0 && expiry < target.saturating_add(EXPIRING_SOON_BLOCKS) {
        if target <= expiry && next_activation(params, target) == expiry.checked_add(1) {
            bail!(SEND_HOLD_MESSAGE);
        }
        bail!("TRANSACTION_EXPIRED: This transaction expired or is too close to expiry. Create and review a new payment.");
    }
    Ok(())
}

pub(crate) fn validate_raw_transaction<P: Parameters>(
    params: &P,
    raw: &[u8],
    tip: u32,
) -> Result<()> {
    let target = tip
        .checked_add(1)
        .context("Submission target height overflow")?;
    let mut remaining = raw;
    let tx = Transaction::read(&mut remaining, branch_at(params, target))
        .context("Read signed transaction before broadcast")?;
    if !remaining.is_empty() {
        bail!("Signed transaction has trailing data");
    }
    validate_signed_metadata(
        params,
        tx.version(),
        tx.consensus_branch_id(),
        u32::from(tx.expiry_height()),
        tip,
    )
}

/// Standalone endpoint harness. Production callers must bind a wallet session
/// through submit_transaction_with_generation.
#[cfg(test)]
pub(crate) async fn submit_transaction(
    lwd: &mut CompactTxStreamerClient<tonic::transport::Channel>,
    params: &Network,
    raw_tx: Vec<u8>,
    known_tip: u32,
) -> Result<SendResponse> {
    submit_transaction_with_generation(lwd, params, raw_tx, known_tip, None).await
}

/// Engine callers pass the generation captured before async preparation. The
/// lifecycle read permit is acquired after fresh endpoint reads, then retained
/// across the bounded send. ENGINE is held only for the short identity check:
/// concurrent peers can submit while close/reopen and route changes must wait.
pub(crate) async fn submit_transaction_with_generation(
    lwd: &mut CompactTxStreamerClient<tonic::transport::Channel>,
    params: &Network,
    raw_tx: Vec<u8>,
    known_tip: u32,
    expected_generation: Option<u64>,
) -> Result<SendResponse> {
    let tip = endpoint_tip(lwd, params).await?.max(known_tip);
    validate_raw_transaction(params, &raw_tx, tip)?;
    let _submission_lifecycle = crate::SUBMISSION_LIFECYCLE.read().await;
    if let Some(expected) = expected_generation {
        let guard = crate::ENGINE.lock().await;
        let engine = guard.as_ref().context("Wallet closed before submission")?;
        if engine.generation != expected || engine.params != *params {
            bail!("Wallet session changed before submission; review again");
        }
        engine.tor_transport()?;
    }
    let response = tokio::time::timeout(
        std::time::Duration::from_secs(20),
        lwd.send_transaction(RawTransaction {
            data: raw_tx,
            height: 0,
        }),
    )
    .await
    .context("Submission timed out; reconcile this transaction before another payment")?
    .context("Submit transaction after fresh branch and expiry checks")?
    .into_inner();
    Ok(response)
}

#[cfg(test)]
mod tests {
    use super::*;
    use zcash_protocol::consensus::NetworkUpgrade;

    fn activation(params: &Network) -> u32 {
        u32::from(
            params
                .activation_height(NetworkUpgrade::Nu7)
                .expect("released NU7 schedule"),
        )
    }

    fn raw_transaction(branch: BranchId, expiry: u32) -> Vec<u8> {
        let tx = zcash_primitives::transaction::TransactionData::<
            zcash_primitives::transaction::Authorized,
        >::from_parts_v6(
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
        let mut raw = Vec::new();
        tx.write(&mut raw).unwrap();
        raw
    }

    #[tokio::test]
    async fn submission_rechecks_each_peer_and_respects_a_newer_known_tip() {
        use std::sync::atomic::Ordering;
        let params = Network::TestNetwork;
        let a = activation(&params);
        let old = branch_at(&params, a - 1);
        let new = branch_at(&params, a);
        let mut earlier = test_server::start("test", a - 5).await;
        let mut later = test_server::start("test", a).await;
        let raw = raw_transaction(old, a - 1);
        assert_eq!(
            submit_transaction(&mut earlier.client, &params, raw.clone(), a - 5)
                .await
                .unwrap()
                .error_code,
            0
        );
        assert!(
            submit_transaction(&mut later.client, &params, raw.clone(), a - 5)
                .await
                .is_err()
        );
        assert_eq!(later.state.submission_count.load(Ordering::SeqCst), 0);
        // A stale peer must not accept an ended-branch transaction after this
        // wallet independently observed the new branch on another connection.
        assert!(submit_transaction(&mut earlier.client, &params, raw, a)
            .await
            .is_err());
        assert_eq!(earlier.state.submission_count.load(Ordering::SeqCst), 1);
        assert!(
            submit_transaction(&mut later.client, &params, raw_transaction(new, a + 120), a)
                .await
                .is_ok()
        );
        assert_eq!(later.state.submission_count.load(Ordering::SeqCst), 1);
    }

    #[tokio::test]
    async fn failed_live_tip_and_wrong_network_never_reach_send_transaction() {
        use std::sync::atomic::Ordering;
        let params = Network::TestNetwork;
        let a = activation(&params);
        let raw = raw_transaction(branch_at(&params, a), a + 120);
        let mut server = test_server::start("main", a).await;
        assert!(
            submit_transaction(&mut server.client, &params, raw.clone(), a)
                .await
                .is_err()
        );
        *server.state.chain.lock().unwrap() = "test".into();
        server.state.fail_tip.store(true, Ordering::SeqCst);
        assert!(submit_transaction(&mut server.client, &params, raw, a)
            .await
            .is_err());
        assert_eq!(server.state.submission_count.load(Ordering::SeqCst), 0);
    }

    #[tokio::test]
    async fn wallet_reopened_during_fresh_tip_read_cannot_submit_old_review() {
        let _engine_test = crate::ENGINE_TEST_MUTEX.lock().await;
        use std::sync::atomic::Ordering;
        let params = Network::TestNetwork;
        let a = activation(&params);
        let original = crate::ENGINE.lock().await.take();
        let generation = crate::next_engine_generation();
        *crate::ENGINE.lock().await = Some(crate::ZipherEngine {
            generation,
            db_data_path: std::path::PathBuf::from("/disposable/same-wallet-path"),
            params,
            server_url: "http://127.0.0.1".into(),
            birthday: BlockHeight::from_u32(a),
            db_cipher_key: None,
            tor_required: false,
            tor_client: None,
        });
        let mut server = test_server::start("test", a).await;
        *server.state.after_tip_read.lock().unwrap() = Some(Box::new(|| {
            // A fresh instance at the same path is still a different session.
            crate::ENGINE
                .try_lock()
                .unwrap()
                .as_mut()
                .unwrap()
                .generation = crate::next_engine_generation();
        }));
        let result = submit_transaction_with_generation(
            &mut server.client,
            &params,
            raw_transaction(branch_at(&params, a), a + 120),
            a,
            Some(generation),
        )
        .await;
        *crate::ENGINE.lock().await = original;
        assert!(result.unwrap_err().to_string().contains("session changed"));
        assert_eq!(server.state.submission_count.load(Ordering::SeqCst), 0);
    }

    #[tokio::test]
    async fn a_stalled_submission_does_not_starve_a_healthy_peer() {
        use std::{sync::atomic::Ordering, time::Duration};
        let _engine_test = crate::ENGINE_TEST_MUTEX.lock().await;
        let params = Network::TestNetwork;
        let a = activation(&params);
        let generation = crate::next_engine_generation();
        let original = {
            let _lifecycle = crate::SUBMISSION_LIFECYCLE.write().await;
            crate::ENGINE.lock().await.replace(crate::ZipherEngine {
                generation,
                db_data_path: std::path::PathBuf::from("/disposable/concurrent-submit"),
                params,
                server_url: "http://127.0.0.1".into(),
                birthday: BlockHeight::from_u32(a),
                db_cipher_key: None,
                tor_required: false,
                tor_client: None,
            })
        };
        let stalled = test_server::start("test", a).await;
        stalled.state.stall_submission.store(true, Ordering::SeqCst);
        let healthy = test_server::start("test", a).await;
        let raw = raw_transaction(branch_at(&params, a), a + 120);
        let mut slow_client = stalled.client.clone();
        let slow_raw = raw.clone();
        let mut slow = tokio::spawn(async move {
            submit_transaction_with_generation(
                &mut slow_client,
                &params,
                slow_raw,
                a,
                Some(generation),
            )
            .await
        });
        let started = tokio::time::timeout(
            Duration::from_secs(5),
            stalled.state.submission_started.notified(),
        )
        .await
        .is_ok();
        // Actual sends pin lifecycle state without occupying the ENGINE mutex.
        let engine_available = crate::ENGINE.try_lock().is_ok();
        let lifecycle_mutation_blocked = crate::SUBMISSION_LIFECYCLE.try_write().is_err();
        let mut healthy_client = healthy.client.clone();
        let healthy_result = tokio::time::timeout(
            Duration::from_secs(5),
            submit_transaction_with_generation(
                &mut healthy_client,
                &params,
                raw,
                a,
                Some(generation),
            ),
        )
        .await;
        let slow_still_pending = !slow.is_finished();
        // Release regardless of the assertions so a failed regression does not
        // leave a live request or a pinned lifecycle permit behind.
        stalled.state.release_submission.notify_one();
        let slow_result = tokio::time::timeout(Duration::from_secs(5), &mut slow).await;
        if slow_result.is_err() {
            slow.abort();
            let _ = slow.await;
        }
        {
            let _lifecycle = crate::SUBMISSION_LIFECYCLE.write().await;
            *crate::ENGINE.lock().await = original;
        }
        assert!(started);
        assert!(engine_available);
        assert!(lifecycle_mutation_blocked);
        assert!(healthy_result.is_ok_and(|result| result.is_ok()));
        assert!(slow_still_pending);
        assert!(slow_result.is_ok_and(|result| result.is_ok_and(|result| result.is_ok())));
        assert_eq!(healthy.state.submission_count.load(Ordering::SeqCst), 1);
        assert_eq!(stalled.state.submission_count.load(Ordering::SeqCst), 1);
    }

    #[test]
    fn normal_expiry_preserves_time_and_caps_at_branch_end() {
        for params in [Network::MainNetwork, Network::TestNetwork] {
            let a = activation(&params);
            assert_eq!(
                a,
                if params == Network::MainNetwork {
                    3_543_405
                } else {
                    4_465_026
                }
            );
            assert_ne!(u32::from(branch_at(&params, a - 1)), 0x7719_0ad9);
            assert_eq!(u32::from(branch_at(&params, a)), 0x7719_0ad9);
            assert_eq!(u32::from(branch_at(&params, a + 1)), 0x7719_0ad9);
            assert_eq!(
                u32::from(ensure_send_target(&params, a - 50).unwrap()),
                a - 10
            );
            assert_eq!(
                u32::from(ensure_send_target(&params, a - 5).unwrap()),
                a - 1
            );
            for target in a - 3..a {
                assert!(ensure_send_target(&params, target)
                    .unwrap_err()
                    .to_string()
                    .contains("NETWORK_UPGRADE_HOLD"));
            }
            assert_eq!(u32::from(ensure_send_target(&params, a).unwrap()), a + 120);
            assert!(ensure_same_branch(&params, a - 1, a).is_err());
        }
    }

    #[test]
    fn migration_holds_through_stale_last_old_branch_tip() {
        let params = Network::TestNetwork;
        let a = activation(&params);
        let old = branch_at(&params, a - 1);
        assert!(!migration_held(&params, old, a - 12));
        for tip in a - 11..=a {
            assert!(migration_held(&params, old, tip));
        }
        assert!(ensure_migration_can_start(&params, a - 10).is_err());
        // A newly reviewed plan can target the new branch at tip A-1.
        assert!(ensure_migration_can_start(&params, a).is_ok());
        assert!(ensure_migration_can_start(&params, a + 1).is_ok());
    }

    #[test]
    fn all_v4_shapes_and_old_branch_signatures_are_refused_at_activation() {
        let params = Network::MainNetwork;
        let a = activation(&params);
        let old = branch_at(&params, a - 1);
        let new = branch_at(&params, a);
        // The version rule is independent of whether v4 contains Sprout,
        // Sapling, or only transparent components.
        assert!(validate_signed_metadata(&params, TxVersion::V4, new, a + 100, a - 1).is_err());
        assert!(validate_signed_metadata(&params, TxVersion::V6, old, a + 100, a - 1).is_err());
        for version in [TxVersion::V5, TxVersion::V6] {
            assert!(validate_signed_metadata(&params, version, new, a + 100, a - 1).is_ok());
        }
    }

    #[test]
    fn submission_refuses_expiring_soon_without_changing_the_signed_expiry() {
        let params = Network::TestNetwork;
        let a = activation(&params);
        let old = branch_at(&params, a - 1);
        assert!(validate_signed_metadata(&params, TxVersion::V6, old, a - 1, a - 5).is_ok());
        assert!(
            validate_signed_metadata(&params, TxVersion::V6, old, a - 1, a - 4)
                .unwrap_err()
                .to_string()
                .contains("NETWORK_UPGRADE_HOLD")
        );
        assert!(validate_signed_metadata(&params, TxVersion::V6, old, a - 1, a - 1).is_err());
        assert!(validate_signed_metadata(&params, TxVersion::V6, old, 0, a - 10).is_ok());
        assert!(validate_raw_transaction(&params, &[], a).is_err());
    }

    #[test]
    fn wrong_or_unknown_submission_network_is_refused() {
        assert!(ensure_endpoint_network(&Network::MainNetwork, "main").is_ok());
        assert!(ensure_endpoint_network(&Network::TestNetwork, "test").is_ok());
        assert!(ensure_endpoint_network(&Network::MainNetwork, "test").is_err());
        assert!(ensure_endpoint_network(&Network::TestNetwork, "").is_err());
    }
}
