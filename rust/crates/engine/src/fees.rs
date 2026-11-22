//! A fee recommendation is fetched once and travels with the reviewed proposal.
//! There is deliberately no global cache shared by wallets, networks or endpoints.

use std::{
    path::PathBuf,
    time::{Duration, Instant},
};

use anyhow::{bail, Context, Result};
use tonic::Code;
use zcash_client_backend::proto::service::compact_tx_streamer_client::CompactTxStreamerClient;
use zcash_client_backend::proto::service::{Empty, StandardFee};
use zcash_primitives::transaction::fees::zip317;
use zcash_protocol::{consensus::Network, value::Zatoshis};

use crate::{
    wallet::{connect_lwd, connect_lwd_tor},
    ZipherEngine, ENGINE,
};

pub(crate) const PRIORITY_MULTIPLIER: u64 = 10;
// A relay is a fee hint, not authority to spend an unbounded network fee.
const MAX_STANDARD_MARGINAL_FEE: u64 = 100_000;
const QUOTE_LIFETIME: Duration = Duration::from_secs(120);
const REQUEST_TIMEOUT: Duration = Duration::from_secs(20);

#[derive(Clone, PartialEq, Eq)]
struct FeeContext {
    generation: u64,
    wallet_path: PathBuf,
    network: Network,
    server_url: String,
    tor_required: bool,
}

impl FeeContext {
    fn from_engine(engine: &ZipherEngine) -> Self {
        Self {
            generation: engine.generation,
            wallet_path: engine.db_data_path.clone(),
            network: engine.params,
            server_url: engine.server_url.clone(),
            tor_required: engine.tor_required,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum FeeSource {
    Relay {
        estimator_version: u32,
    },
    /// Older relays cannot yet report the serving node's recommendation.
    /// Retain the previously accepted 5,000-zat policy rather than guessing a
    /// lower post-upgrade fee while serving implementations differ.
    LegacyUnsupported,
}

#[derive(Clone)]
pub(crate) struct FeeSnapshot {
    context: FeeContext,
    fetched_at: Instant,
    marginal_fee: u64,
    target_height: u32,
    pub(crate) source: FeeSource,
}

impl FeeSnapshot {
    fn from_response(
        context: FeeContext,
        response: Result<StandardFee, tonic::Status>,
        priority: bool,
        target_height: u32,
    ) -> Result<Self> {
        let (standard_fee, source) = match response {
            Ok(response) => (
                response.fee_zat,
                FeeSource::Relay {
                    estimator_version: response.estimator_version,
                },
            ),
            Err(status) if status.code() == Code::Unimplemented => {
                tracing::warn!("Fee relay unsupported; retaining the legacy 5,000-zat marginal fee until this server supports GetStandardFee");
                (5_000, FeeSource::LegacyUnsupported)
            }
            // A transient outage must not silently substitute a potentially
            // stale or lower recommendation, and server error text is untrusted.
            Err(status) => bail!(
                "Cannot obtain the standard network fee ({:?}); retry before reviewing a payment",
                status.code()
            ),
        };
        if standard_fee == 0 || standard_fee > MAX_STANDARD_MARGINAL_FEE {
            bail!("The server returned an invalid or excessive standard network fee");
        }
        let marginal_fee = standard_fee
            .checked_mul(if priority { PRIORITY_MULTIPLIER } else { 1 })
            .ok_or_else(|| anyhow::anyhow!("Network fee overflow"))?;
        Zatoshis::from_u64(marginal_fee).context("Network fee outside the monetary range")?;
        Ok(Self {
            context,
            fetched_at: Instant::now(),
            marginal_fee,
            target_height,
            source,
        })
    }

    pub(crate) fn fee_rule(&self) -> Result<zip317::FeeRule> {
        zip317::FeeRule::non_standard(
            Zatoshis::from_u64(self.marginal_fee()).context("Invalid network fee")?,
            zip317::GRACE_ACTIONS,
            zip317::P2PKH_STANDARD_INPUT_SIZE,
            zip317::P2PKH_STANDARD_OUTPUT_SIZE,
        )
        .ok_or_else(|| anyhow::anyhow!("Invalid fee rule parameters"))
    }

    pub(crate) fn marginal_fee(&self) -> u64 {
        self.marginal_fee
    }

    pub(crate) fn generation(&self) -> u64 {
        self.context.generation
    }

    /// Consensus identity of the actual proposal target, bound to the network
    /// and era observed by its fee quote. Reading it does not refresh the quote.
    pub(crate) fn review_branch(&self, reviewed_target: u32) -> Result<u32> {
        crate::network_upgrade::ensure_same_branch(
            &self.context.network,
            reviewed_target,
            self.target_height,
        )?;
        Ok(u32::from(crate::network_upgrade::branch_at(
            &self.context.network,
            reviewed_target,
        )))
    }

    pub(crate) fn expiry_at_review(
        &self,
        reviewed_target: u32,
    ) -> Result<zcash_protocol::consensus::BlockHeight> {
        self.review_branch(reviewed_target)?;
        crate::network_upgrade::ensure_send_target(&self.context.network, self.target_height)?;
        let expiry =
            crate::network_upgrade::ensure_send_target(&self.context.network, reviewed_target)?;
        if u32::from(expiry)
            < self
                .target_height
                .saturating_add(crate::network_upgrade::EXPIRING_SOON_BLOCKS)
        {
            bail!("The wallet must finish syncing before this payment can be reviewed");
        }
        Ok(expiry)
    }

    /// Refresh branch/expiry validity without fetching or changing the reviewed fee.
    pub(crate) async fn fresh_expiry(
        &self,
        reviewed_target: u32,
    ) -> Result<zcash_protocol::consensus::BlockHeight> {
        let tor = {
            let guard = ENGINE.lock().await;
            let engine = guard
                .as_ref()
                .ok_or_else(|| anyhow::anyhow!("Wallet closed"))?;
            self.validate_engine(engine)?;
            engine.tor_transport()?
        };
        let request = async {
            let mut client = match tor.as_ref() {
                Some(tor) => connect_lwd_tor(tor, &self.context.server_url).await?,
                None => connect_lwd(&self.context.server_url).await?,
            };
            crate::network_upgrade::endpoint_tip(&mut client, &self.context.network).await
        };
        let tip = tokio::time::timeout(REQUEST_TIMEOUT, request)
            .await
            .context("Payment validity check timed out; retry with a new review")??;
        let target = tip
            .checked_add(1)
            .context("Payment target height overflow")?;
        crate::network_upgrade::ensure_same_branch(&self.context.network, reviewed_target, target)?;
        crate::network_upgrade::ensure_send_target(&self.context.network, target)?;
        let expiry = self.expiry_at_review(reviewed_target)?;
        if u32::from(expiry) < target.saturating_add(crate::network_upgrade::EXPIRING_SOON_BLOCKS) {
            bail!("The reviewed payment is too close to expiry; review a new payment");
        }
        let guard = ENGINE.lock().await;
        self.validate_engine(
            guard
                .as_ref()
                .ok_or_else(|| anyhow::anyhow!("Wallet closed"))?,
        )?;
        Ok(expiry)
    }

    pub(crate) fn validate_engine(&self, engine: &ZipherEngine) -> Result<()> {
        self.validate_context(&FeeContext::from_engine(engine), self.fetched_at.elapsed())?;
        // Required Tor that has become unavailable cannot become a direct route.
        engine.tor_transport()?;
        Ok(())
    }

    /// After proving, check scope without ageing out a transaction already stored
    /// by the builder. Review age is checked before building; signed validity is
    /// checked again by the common broadcast guard.
    pub(crate) async fn validate_current(&self) -> Result<()> {
        self.broadcast_transport().await.map(|_| ())
    }

    /// Capture the permitted route in the same critical section as the scope
    /// check; a later close cannot turn a private submission into a direct one.
    pub(crate) async fn broadcast_transport(
        &self,
    ) -> Result<Option<zcash_client_backend::tor::Client>> {
        let guard = ENGINE.lock().await;
        let engine = guard
            .as_ref()
            .ok_or_else(|| anyhow::anyhow!("Wallet closed"))?;
        self.validate_context(&FeeContext::from_engine(engine), Duration::ZERO)?;
        engine.tor_transport()
    }

    fn validate_context(&self, context: &FeeContext, age: Duration) -> Result<()> {
        if self.context != *context {
            bail!("Wallet, network, server or privacy setting changed; review a new payment");
        }
        if age > QUOTE_LIFETIME {
            bail!("The reviewed network fee has expired; review a new payment");
        }
        Ok(())
    }
}

/// Network identity, tip and fee are all read over the caller's captured route.
async fn lookup_on_connection(
    client: &mut CompactTxStreamerClient<tonic::transport::Channel>,
    context: FeeContext,
    priority: bool,
) -> Result<FeeSnapshot> {
    let tip = crate::network_upgrade::endpoint_tip(client, &context.network).await?;
    let target = tip
        .checked_add(1)
        .context("Payment target height overflow")?;
    crate::network_upgrade::ensure_send_target(&context.network, target)?;
    let response = client
        .get_standard_fee(Empty {})
        .await
        .map(|r| r.into_inner());
    FeeSnapshot::from_response(context, response, priority, target)
}

pub(crate) async fn snapshot(priority: bool) -> Result<FeeSnapshot> {
    let (context, tor) = {
        let guard = ENGINE.lock().await;
        let engine = guard
            .as_ref()
            .ok_or_else(|| anyhow::anyhow!("Engine not initialized"))?;
        (FeeContext::from_engine(engine), engine.tor_transport()?)
    };
    let request = async {
        let mut client = match tor.as_ref() {
            Some(tor) => connect_lwd_tor(tor, &context.server_url).await?,
            None => connect_lwd(&context.server_url).await?,
        };
        lookup_on_connection(&mut client, context, priority).await
    };
    let snapshot = tokio::time::timeout(REQUEST_TIMEOUT, request)
        .await
        .context(
            "The standard network fee request timed out; retry before reviewing a payment",
        )??;
    let guard = ENGINE.lock().await;
    snapshot.validate_engine(
        guard
            .as_ref()
            .ok_or_else(|| anyhow::anyhow!("Wallet closed during fee lookup"))?,
    )?;
    tracing::debug!(source = ?snapshot.source, "Network fee policy captured");
    Ok(snapshot)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::Ordering;
    use zcash_primitives::transaction::fees::FeeRule;

    fn context() -> FeeContext {
        FeeContext {
            generation: 1,
            wallet_path: "/test/wallet.sqlite".into(),
            network: Network::MainNetwork,
            server_url: "https://lightwalletd.example:443".into(),
            tor_required: false,
        }
    }
    fn quote(fee_zat: u64, priority: bool) -> Result<FeeSnapshot> {
        FeeSnapshot::from_response(
            context(),
            Ok(StandardFee {
                fee_zat,
                estimator_version: 3,
            }),
            priority,
            3_543_405,
        )
    }

    #[test]
    fn relay_fee_and_priority_drive_the_entire_builder_rule() {
        for standard in [1_000, 5_000, 12_345] {
            for actions in [2, 3, 8] {
                let fee = |priority| {
                    quote(standard, priority)
                        .unwrap()
                        .fee_rule()
                        .unwrap()
                        .fee_required(
                            &Network::MainNetwork,
                            3_543_405u32.into(),
                            [],
                            [],
                            0,
                            0,
                            actions,
                            0,
                        )
                        .unwrap()
                };
                assert_eq!(u64::from(fee(false)), standard * actions as u64);
                assert_eq!(
                    u64::from(fee(true)),
                    PRIORITY_MULTIPLIER * u64::from(fee(false))
                );
            }
        }
        assert_eq!(
            quote(1_000, false).unwrap().source,
            FeeSource::Relay {
                estimator_version: 3
            }
        );
    }

    #[test]
    fn only_an_unsupported_relay_permits_the_conservative_fallback() {
        for priority in [false, true] {
            let fee = FeeSnapshot::from_response(
                context(),
                Err(tonic::Status::unimplemented("unsupported")),
                priority,
                3_543_405,
            )
            .unwrap();
            assert_eq!(fee.marginal_fee(), 5_000 * if priority { 10 } else { 1 });
            assert_eq!(fee.source, FeeSource::LegacyUnsupported);
        }
        for code in [
            Code::Unavailable,
            Code::DeadlineExceeded,
            Code::Internal,
            Code::Unauthenticated,
        ] {
            assert!(FeeSnapshot::from_response(
                context(),
                Err(tonic::Status::new(code, "private untrusted text")),
                false,
                3_543_405
            )
            .is_err());
        }
    }

    #[test]
    fn malformed_or_absurd_fee_hints_are_rejected_without_fallback() {
        for value in [0, MAX_STANDARD_MARGINAL_FEE + 1, u64::MAX] {
            assert!(quote(value, false).is_err());
            assert!(quote(value, true).is_err());
        }
        assert!(quote(MAX_STANDARD_MARGINAL_FEE, true).is_ok());
    }

    #[test]
    fn review_is_bound_to_its_wallet_network_server_transport_and_age() {
        let fee = quote(5_000, false).unwrap();
        assert!(fee.validate_context(&context(), Duration::ZERO).is_ok());
        let mut other = context();
        other.generation += 1;
        assert!(fee.validate_context(&other, Duration::ZERO).is_err());
        let mut other = context();
        other.wallet_path = "/test/other.sqlite".into();
        assert!(fee.validate_context(&other, Duration::ZERO).is_err());
        let mut other = context();
        other.network = Network::TestNetwork;
        assert!(fee.validate_context(&other, Duration::ZERO).is_err());
        let mut other = context();
        other.server_url = "https://another.example".into();
        assert!(fee.validate_context(&other, Duration::ZERO).is_err());
        let mut other = context();
        other.tor_required = true;
        assert!(fee.validate_context(&other, Duration::ZERO).is_err());
        assert!(fee
            .validate_context(&context(), QUOTE_LIFETIME + Duration::from_secs(1))
            .is_err());
    }

    #[test]
    fn fee_review_cannot_be_reused_across_activation_or_for_an_expiring_proposal() {
        use zcash_protocol::consensus::{NetworkUpgrade, Parameters};
        for network in [Network::MainNetwork, Network::TestNetwork] {
            let activation = u32::from(network.activation_height(NetworkUpgrade::Nu7).unwrap());
            let mut context = context();
            context.network = network;
            let response = || {
                Ok(StandardFee {
                    fee_zat: 1_000,
                    estimator_version: 0,
                })
            };
            let old =
                FeeSnapshot::from_response(context.clone(), response(), false, activation - 10)
                    .unwrap();
            assert_eq!(
                u32::from(old.expiry_at_review(activation - 10).unwrap()),
                activation - 1
            );
            assert!(old.expiry_at_review(activation).is_err());
            let new =
                FeeSnapshot::from_response(context.clone(), response(), false, activation).unwrap();
            assert_ne!(
                old.review_branch(activation - 10).unwrap(),
                new.review_branch(activation).unwrap()
            );
            assert_eq!(new.review_branch(activation).unwrap(), 0x7719_0ad9);
            assert!(old.review_branch(activation).is_err());
            assert!(new.review_branch(activation - 1).is_err());
            assert!(new.expiry_at_review(activation - 1).is_err());
            assert_eq!(
                u32::from(new.expiry_at_review(activation).unwrap()),
                activation + 120
            );
            let hold =
                FeeSnapshot::from_response(context, response(), false, activation - 2).unwrap();
            assert!(hold.expiry_at_review(activation - 2).is_err());
            assert_eq!(old.marginal_fee(), new.marginal_fee());
        }
    }

    #[tokio::test]
    async fn grpc_relay_updates_new_reviews_without_changing_the_reviewed_fee() {
        let server = crate::network_upgrade::test_server::start("main", 3_543_410).await;
        server.state.standard_fee.store(1_234, Ordering::SeqCst);
        server.state.estimator_version.store(7, Ordering::SeqCst);
        let mut client = server.client.clone();
        let first = lookup_on_connection(&mut client, context(), false)
            .await
            .unwrap();
        assert_eq!(first.marginal_fee(), 1_234);
        assert_eq!(
            first.source,
            FeeSource::Relay {
                estimator_version: 7
            }
        );
        server.state.standard_fee.store(9_000, Ordering::SeqCst);
        server.state.estimator_version.store(8, Ordering::SeqCst);
        let second = lookup_on_connection(&mut client, context(), true)
            .await
            .unwrap();
        assert_eq!(second.marginal_fee(), 90_000);
        assert_eq!(
            second.source,
            FeeSource::Relay {
                estimator_version: 8
            }
        );
        assert_eq!(first.marginal_fee(), 1_234);
        assert_eq!(server.state.fee_request_count.load(Ordering::SeqCst), 2);
        assert_eq!(server.state.submission_count.load(Ordering::SeqCst), 0);
    }

    #[tokio::test]
    async fn grpc_unsupported_is_distinct_from_transient_or_malformed_replies() {
        let server = crate::network_upgrade::test_server::start("main", 3_543_410).await;
        let mut client = server.client.clone();
        server
            .state
            .fee_error_code
            .store(Code::Unimplemented as i32, Ordering::SeqCst);
        let legacy = lookup_on_connection(&mut client, context(), true)
            .await
            .unwrap();
        assert_eq!(legacy.marginal_fee(), 50_000);
        assert_eq!(legacy.source, FeeSource::LegacyUnsupported);
        server
            .state
            .fee_error_code
            .store(Code::Unavailable as i32, Ordering::SeqCst);
        assert!(lookup_on_connection(&mut client, context(), false)
            .await
            .is_err());
        server.state.fee_error_code.store(0, Ordering::SeqCst);
        server.state.standard_fee.store(0, Ordering::SeqCst);
        assert!(lookup_on_connection(&mut client, context(), false)
            .await
            .is_err());
        server.state.standard_fee.store(u64::MAX, Ordering::SeqCst);
        assert!(lookup_on_connection(&mut client, context(), false)
            .await
            .is_err());
        assert_eq!(server.state.submission_count.load(Ordering::SeqCst), 0);
    }

    #[tokio::test]
    async fn grpc_fee_lookup_requires_the_requested_network_and_a_fresh_tip() {
        let server = crate::network_upgrade::test_server::start("test", 4_465_030).await;
        let mut client = server.client.clone();
        assert!(lookup_on_connection(&mut client, context(), false)
            .await
            .is_err());
        assert_eq!(server.state.fee_request_count.load(Ordering::SeqCst), 0);
        *server.state.chain.lock().unwrap() = "main".into();
        server.state.fail_tip.store(true, Ordering::SeqCst);
        server
            .state
            .fee_error_code
            .store(Code::Unimplemented as i32, Ordering::SeqCst);
        assert!(lookup_on_connection(&mut client, context(), false)
            .await
            .is_err());
        assert_eq!(server.state.fee_request_count.load(Ordering::SeqCst), 0);
    }
}
