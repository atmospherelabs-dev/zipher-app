use std::path::Path;
use std::sync::Mutex as StdMutex;

use anyhow::Result;
use secrecy::{ExposeSecret, SecretString};
use zeroize::Zeroize;

use zcash_address::ZcashAddress;
use zcash_client_backend::data_api::wallet::{
    create_proposed_transactions, propose_standard_transfer_to_address,
    propose_shielding, ConfirmationsPolicy, SpendingKeys,
};
use zcash_client_backend::data_api::{InputSource, WalletCommitmentTrees, WalletRead};
use zcash_client_backend::data_api::wallet::TargetHeight;
use zcash_client_backend::fees::StandardFeeRule;
use zcash_client_backend::proposal::Proposal;
use zcash_client_backend::proto::service::RawTransaction;
use zcash_client_backend::wallet::OvkPolicy;
use zcash_client_sqlite::ReceivedNoteId;
use zcash_protocol::consensus::Network;
use zcash_protocol::ShieldedProtocol;
use zcash_client_sqlite::WalletDb;
use zcash_keys::address::Address;
use zcash_keys::keys::UnifiedSpendingKey;
use zcash_proofs::prover::LocalTxProver;
use zcash_protocol::value::Zatoshis;
use zcash_primitives::transaction::builder::{Builder, BuildConfig};
use zcash_transparent::builder::TransparentSigningSet;
use zcash_transparent::keys::TransparentKeyScope;

use super::wallet::connect_lwd;
use super::{open_wallet_db, ENGINE};

type DbType = WalletDb<rusqlite::Connection, Network, SystemClock, rand::rngs::OsRng>;
type ProposalType = Proposal<StandardFeeRule, ReceivedNoteId>;

use zcash_client_sqlite::util::SystemClock;

/// Holds either a real SDK proposal or the parameters for a transparent direct send.
enum PendingSend {
    SdkProposal(ProposalType),
    DirectFromTransparent {
        address: String,
        amount: u64,
        memo: Option<String>,
    },
}

/// The last proposal created by `propose_send`, awaiting confirmation.
static PENDING_SEND: StdMutex<Option<PendingSend>> = StdMutex::new(None);

/// Propose and create a standard send transaction in one step, returning the TxIds.
fn propose_and_create_send(
    db_data: &mut DbType,
    params: &Network,
    account_id: <DbType as zcash_client_backend::data_api::InputSource>::AccountId,
    to: &Address,
    amount: Zatoshis,
    memo: Option<zcash_protocol::memo::MemoBytes>,
    prover: &LocalTxProver,
    usk: UnifiedSpendingKey,
) -> Result<nonempty::NonEmpty<zcash_primitives::transaction::TxId>> {
    let proposal = propose_standard_transfer_to_address::<_, _, std::convert::Infallible>(
        db_data,
        params,
        StandardFeeRule::Zip317,
        account_id,
        ConfirmationsPolicy::MIN,
        to,
        amount,
        memo,
        None,
        ShieldedProtocol::Orchard,
    )
    .map_err(|e| anyhow::anyhow!("Proposal failed: {:?}", e))?;

    let spending_keys = SpendingKeys::from_unified_spending_key(usk);

    create_proposed_transactions::<_, _, std::convert::Infallible, _, std::convert::Infallible, _>(
        db_data,
        params,
        prover,
        prover,
        &spending_keys,
        OvkPolicy::Sender,
        &proposal,
    )
    .map_err(|e| anyhow::anyhow!("Create tx failed: {:?}", e))
}

/// Propose and create a shielding transaction in one step.
fn propose_and_create_shielding(
    db_data: &mut DbType,
    params: &Network,
    from_addrs: &[zcash_transparent::address::TransparentAddress],
    to_account: <DbType as zcash_client_backend::data_api::InputSource>::AccountId,
    prover: &LocalTxProver,
    usk: UnifiedSpendingKey,
) -> Result<nonempty::NonEmpty<zcash_primitives::transaction::TxId>> {
    let change_strategy =
        zcash_client_backend::fees::zip317::SingleOutputChangeStrategy::new(
            StandardFeeRule::Zip317,
            None,
            ShieldedProtocol::Orchard,
            zcash_client_backend::fees::DustOutputPolicy::default(),
        );
    let greedy =
        zcash_client_backend::data_api::wallet::input_selection::GreedyInputSelector::new();

    let proposal = propose_shielding::<_, _, _, _, std::convert::Infallible>(
        db_data,
        params,
        &greedy,
        &change_strategy,
        Zatoshis::from_u64(100_000).unwrap(),
        from_addrs,
        to_account,
        ConfirmationsPolicy::MIN,
    )
    .map_err(|e| anyhow::anyhow!("Shielding proposal failed: {:?}", e))?;

    let spending_keys = SpendingKeys::from_unified_spending_key(usk);

    create_proposed_transactions::<_, _, std::convert::Infallible, _, std::convert::Infallible, _>(
        db_data,
        params,
        prover,
        prover,
        &spending_keys,
        OvkPolicy::Sender,
        &proposal,
    )
    .map_err(|e| anyhow::anyhow!("Create shielding tx failed: {:?}", e))
}

fn load_prover(db_data_path: &Path) -> Result<LocalTxProver> {
    let wallet_dir = db_data_path
        .parent()
        .ok_or_else(|| anyhow::anyhow!("Cannot determine data directory"))?;

    let candidates = [
        wallet_dir.to_path_buf(),
        wallet_dir.parent().map(|p| p.to_path_buf()).unwrap_or_default(),
    ];

    for dir in &candidates {
        let spend = dir.join("sapling-spend.params");
        let output = dir.join("sapling-output.params");
        if spend.exists() && output.exists() {
            return Ok(LocalTxProver::new(&spend, &output));
        }
    }

    Err(anyhow::anyhow!(
        "Sapling params not found. Searched {:?}. Copy sapling-spend.params and sapling-output.params to the Documents directory.",
        candidates
    ))
}

/// Compute the maximum sendable amount to a given address by asking the
/// proposal engine. Returns the exact amount in zatoshis that will leave
/// the wallet empty after fees. Returns 0 if nothing is spendable.
pub async fn get_max_sendable(address: &str) -> Result<u64> {
    let engine_guard = ENGINE.lock().await;
    let engine = engine_guard
        .as_ref()
        .ok_or_else(|| anyhow::anyhow!("Engine not initialized"))?;

    let db_data_path = engine.db_data_path.clone();
    let params = engine.params;
    let db_cipher_key = engine.db_cipher_key.clone();
    drop(engine_guard);

    let mut db_data = open_wallet_db(&db_data_path, params, &db_cipher_key)?;

    let account_id = db_data
        .get_account_ids()
        .map_err(|e| anyhow::anyhow!("{:?}", e))?
        .into_iter()
        .next()
        .ok_or_else(|| anyhow::anyhow!("No accounts"))?;

    let confirmations = ConfirmationsPolicy::MIN;

    let summary = db_data
        .get_wallet_summary(confirmations)
        .map_err(|e| anyhow::anyhow!("{:?}", e))?;

    let (transparent_spendable, sapling_spendable, orchard_spendable) = match &summary {
        Some(s) => match s.account_balances().get(&account_id) {
            Some(ab) => (
                u64::from(ab.unshielded_balance().spendable_value()),
                u64::from(ab.sapling_balance().spendable_value()),
                u64::from(ab.orchard_balance().spendable_value()),
            ),
            None => (0, 0, 0),
        },
        None => (0, 0, 0),
    };

    let spendable = transparent_spendable + sapling_spendable + orchard_spendable;

    if spendable == 0 {
        return Ok(0);
    }

    let zaddr: ZcashAddress = address
        .parse()
        .map_err(|e| anyhow::anyhow!("Invalid address: {:?}", e))?;
    let to = Address::try_from_zcash_address(&params, zaddr)
        .map_err(|e| anyhow::anyhow!("Address conversion: {:?}", e))?;

    // Probe with a reduced amount to extract the exact fee from the proposal.
    let probe_amount = spendable.saturating_sub(100_000).max(1_000);
    let probe_zat = Zatoshis::from_u64(probe_amount)
        .map_err(|_| anyhow::anyhow!("Invalid probe amount"))?;

    let proposal_result = propose_standard_transfer_to_address::<_, _, std::convert::Infallible>(
        &mut db_data,
        &params,
        StandardFeeRule::Zip317,
        account_id,
        confirmations,
        &to,
        probe_zat,
        None,
        None,
        ShieldedProtocol::Orchard,
    );

    match proposal_result {
        Ok(proposal) => {
            let fee = u64::from(proposal.steps().first().balance().fee_required());
            Ok(spendable.saturating_sub(fee))
        }
        Err(e) => {
            let err_str = format!("{:?}", e);

            // When the proposal engine can't select transparent UTXOs (e.g. the
            // GreedyInputSelector skips them), fall back to a simple ZIP-317
            // fee estimate so the user isn't stuck with MAX = 0.
            if transparent_spendable > 0 && sapling_spendable == 0 && orchard_spendable == 0 {
                let is_transparent_dest = matches!(to, Address::Transparent(_));
                // ZIP-317: fee = max(grace_actions, logical_actions) × marginal_fee
                // transparent-only tx: 1 input + 1 output + (0 or 1 shielded change)
                let estimated_fee: u64 = if is_transparent_dest {
                    // t→t with no change (exact amount) or t→t + shielded change
                    20_000
                } else {
                    // t→shielded: 1 transparent input + 1 shielded output + change
                    30_000
                };
                let max = transparent_spendable.saturating_sub(estimated_fee);
                return Ok(max);
            }

            if err_str.contains("InsufficientFunds") {
                Ok(0)
            } else {
                Err(anyhow::anyhow!("Proposal error: {}", err_str))
            }
        }
    }
}

/// Step 1 of the two-step send flow.
/// Creates a proposal for the given payment, stores it, and returns the exact fee.
/// Returns (send_amount, fee, is_exact).
pub async fn propose_send(
    address: &str,
    amount: u64,
    memo: Option<String>,
) -> Result<(u64, u64, bool)> {
    let engine_guard = ENGINE.lock().await;
    let engine = engine_guard
        .as_ref()
        .ok_or_else(|| anyhow::anyhow!("Engine not initialized"))?;

    let db_data_path = engine.db_data_path.clone();
    let params = engine.params;
    let db_cipher_key = engine.db_cipher_key.clone();
    drop(engine_guard);

    let mut db_data = open_wallet_db(&db_data_path, params, &db_cipher_key)?;

    let account_id = db_data
        .get_account_ids()
        .map_err(|e| anyhow::anyhow!("{:?}", e))?
        .into_iter()
        .next()
        .ok_or_else(|| anyhow::anyhow!("No accounts"))?;

    let zaddr: ZcashAddress = address
        .parse()
        .map_err(|e| anyhow::anyhow!("Invalid address: {:?}", e))?;
    let to = Address::try_from_zcash_address(&params, zaddr)
        .map_err(|e| anyhow::anyhow!("Address conversion: {:?}", e))?;

    let is_transparent_dest = matches!(to, Address::Transparent(_));
    let send_zat = Zatoshis::from_u64(amount)
        .map_err(|_| anyhow::anyhow!("Invalid amount"))?;

    let memo_bytes = match &memo {
        Some(m) if !m.is_empty() && !is_transparent_dest => {
            use std::str::FromStr;
            use zcash_protocol::memo::{Memo, MemoBytes};
            Some(MemoBytes::from(
                &Memo::from_str(m)
                    .map_err(|e| anyhow::anyhow!("Memo error: {:?}", e))?,
            ))
        }
        _ => None,
    };

    // Check per-pool balances so we can detect transparent-only funds
    let confirmations = ConfirmationsPolicy::MIN;
    let summary = db_data
        .get_wallet_summary(confirmations)
        .map_err(|e| anyhow::anyhow!("{:?}", e))?;
    let (t_bal, s_bal, o_bal) = match &summary {
        Some(s) => match s.account_balances().get(&account_id) {
            Some(ab) => (
                u64::from(ab.unshielded_balance().spendable_value()),
                u64::from(ab.sapling_balance().spendable_value()),
                u64::from(ab.orchard_balance().spendable_value()),
            ),
            None => (0, 0, 0),
        },
        None => (0, 0, 0),
    };
    let is_transparent_only = t_bal > 0 && s_bal == 0 && o_bal == 0;

    let proposal_result = propose_standard_transfer_to_address::<_, _, std::convert::Infallible>(
        &mut db_data,
        &params,
        StandardFeeRule::Zip317,
        account_id,
        confirmations,
        &to,
        send_zat,
        memo_bytes,
        None,
        ShieldedProtocol::Orchard,
    );

    match proposal_result {
        Ok(proposal) => {
            let fee = u64::from(proposal.steps().first().balance().fee_required());
            let mut pending = PENDING_SEND.lock().unwrap();
            *pending = Some(PendingSend::SdkProposal(proposal));
            Ok((amount, fee, true))
        }
        Err(e) => {
            if is_transparent_only {
                // The SDK's GreedyInputSelector never selects transparent UTXOs
                // for regular sends. Fall back to our direct tx builder which
                // supports t→t, t→sapling, t→orchard, and t→unified.
                // Use 1-output fee (no change) — MAX sends won't produce change,
                // and for non-MAX sends the builder handles change dynamically.
                let fee = if is_transparent_dest {
                    zip317_transparent_fee(1, 1)
                } else {
                    // t→shielded: 1 transparent input + 1 shielded output
                    zip317_transparent_fee(1, 1)
                };
                let mut pending = PENDING_SEND.lock().unwrap();
                *pending = Some(PendingSend::DirectFromTransparent {
                    address: address.to_string(),
                    amount,
                    memo: memo,
                });
                Ok((amount, fee, false))
            } else {
                Err(anyhow::anyhow!("Proposal failed: {:?}", e))
            }
        }
    }
}

/// Step 2 of the two-step send flow.
/// Takes the stored proposal and creates + broadcasts the transaction.
pub async fn confirm_send(seed_phrase: &SecretString) -> Result<String> {
    let pending = {
        let mut lock = PENDING_SEND.lock().unwrap();
        lock.take()
            .ok_or_else(|| anyhow::anyhow!("No pending proposal — call propose_send first"))?
    };

    let engine_guard = ENGINE.lock().await;
    let engine = engine_guard
        .as_ref()
        .ok_or_else(|| anyhow::anyhow!("Engine not initialized"))?;

    let db_data_path = engine.db_data_path.clone();
    let params = engine.params;
    let server_url = engine.server_url.clone();
    let db_cipher_key = engine.db_cipher_key.clone();
    drop(engine_guard);

    let mnemonic =
        bip0039::Mnemonic::<bip0039::English>::from_phrase(seed_phrase.expose_secret())
            .map_err(|e| anyhow::anyhow!("Invalid seed phrase: {:?}", e))?;
    let mut seed = mnemonic.to_seed("");
    let usk_result =
        UnifiedSpendingKey::from_seed(&params, &seed, zip32::AccountId::ZERO);
    seed.zeroize();
    let usk = usk_result.map_err(|e| anyhow::anyhow!("USK derivation: {:?}", e))?;

    let mut db_data = open_wallet_db(&db_data_path, params, &db_cipher_key)?;

    let account_id = db_data
        .get_account_ids()
        .map_err(|e| anyhow::anyhow!("{:?}", e))?
        .into_iter()
        .next()
        .ok_or_else(|| anyhow::anyhow!("No accounts"))?;

    let (txid_str, tx_bytes) = match pending {
        PendingSend::SdkProposal(proposal) => {
            let prover = load_prover(&db_data_path)?;
            let spending_keys = SpendingKeys::from_unified_spending_key(usk);
            let txids = create_proposed_transactions::<
                _,
                _,
                std::convert::Infallible,
                _,
                std::convert::Infallible,
                _,
            >(
                &mut db_data,
                &params,
                &prover,
                &prover,
                &spending_keys,
                OvkPolicy::Sender,
                &proposal,
            )
            .map_err(|e| anyhow::anyhow!("Create tx failed: {:?}", e))?;

            let txid = txids.first();
            let tx = db_data
                .get_transaction(*txid)
                .map_err(|e| anyhow::anyhow!("{:?}", e))?
                .ok_or_else(|| anyhow::anyhow!("Transaction not found after creation"))?;
            let mut bytes = Vec::new();
            tx.write(&mut bytes)
                .map_err(|e| anyhow::anyhow!("Serialize tx: {:?}", e))?;
            (txid.to_string(), bytes)
        }
        PendingSend::DirectFromTransparent { address, amount, memo } => {
            let zaddr: ZcashAddress = address
                .parse()
                .map_err(|e| anyhow::anyhow!("Invalid address: {:?}", e))?;
            let to = Address::try_from_zcash_address(&params, zaddr)
                .map_err(|e| anyhow::anyhow!("Address conversion: {:?}", e))?;
            let amount_zat = Zatoshis::from_u64(amount)
                .map_err(|_| anyhow::anyhow!("Invalid amount"))?;
            let memo_bytes = match &memo {
                Some(m) if !m.is_empty() && !matches!(to, Address::Transparent(_)) => {
                    use std::str::FromStr;
                    use zcash_protocol::memo::Memo;
                    Some(zcash_protocol::memo::MemoBytes::from(
                        &Memo::from_str(m)
                            .map_err(|e| anyhow::anyhow!("Memo: {:?}", e))?,
                    ))
                }
                _ => None,
            };
            let (txid, bytes) = build_direct_tx(
                &mut db_data,
                &db_data_path,
                &params,
                account_id,
                &to,
                amount_zat,
                memo_bytes,
                &usk,
            )?;
            (txid.to_string(), bytes)
        }
    };

    // Broadcast
    let mut lwd = connect_lwd(&server_url).await?;
    let resp = lwd
        .send_transaction(RawTransaction {
            data: tx_bytes,
            height: 0,
        })
        .await
        .map_err(|e| anyhow::anyhow!("Broadcast failed: {:?}", e))?;

    let resp = resp.into_inner();
    if resp.error_code != 0 {
        return Err(anyhow::anyhow!(
            "Broadcast rejected: {} (code {})",
            resp.error_message,
            resp.error_code
        ));
    }

    Ok(txid_str)
}

/// ZIP-317 transparent-only fee: max(2, inputs + outputs) × 5000 zat.
fn zip317_transparent_fee(num_inputs: usize, num_outputs: usize) -> u64 {
    std::cmp::max(2, num_inputs + num_outputs) as u64 * 5000
}

/// Build a direct transaction from transparent UTXOs to any address type,
/// bypassing the proposal engine which cannot select transparent inputs.
/// Returns the txid and serialised transaction bytes ready for broadcast.
fn build_direct_tx(
    db_data: &mut DbType,
    db_data_path: &Path,
    params: &Network,
    account_id: <DbType as InputSource>::AccountId,
    to: &Address,
    amount: Zatoshis,
    memo: Option<zcash_protocol::memo::MemoBytes>,
    usk: &UnifiedSpendingKey,
) -> Result<(zcash_primitives::transaction::TxId, Vec<u8>)> {
    let chain_tip = db_data
        .chain_height()
        .map_err(|e| anyhow::anyhow!("{:?}", e))?
        .ok_or_else(|| anyhow::anyhow!("Chain tip unknown — sync the wallet first"))?;

    let target_height = TargetHeight::from(chain_tip + 1);

    let receivers = db_data
        .get_transparent_receivers(account_id, true, true)
        .map_err(|e| anyhow::anyhow!("get_transparent_receivers: {:?}", e))?;

    let transparent_key = usk.transparent();
    let mut signing_set = TransparentSigningSet::new();
    let mut addr_to_pk = std::collections::HashMap::new();
    let mut all_utxos = Vec::new();

    for (taddr, meta) in &receivers {
        let (scope, idx) = match (meta.scope(), meta.address_index()) {
            (Some(s), Some(i)) => (s, i),
            _ => continue,
        };
        let sk = if scope == TransparentKeyScope::EXTERNAL {
            transparent_key.derive_external_secret_key(idx)
        } else {
            transparent_key.derive_internal_secret_key(idx)
        }
        .map_err(|e| anyhow::anyhow!("Key derivation: {:?}", e))?;
        let pk = signing_set.add_key(sk);
        addr_to_pk.insert(taddr.clone(), pk);

        let utxos = db_data
            .get_spendable_transparent_outputs(
                taddr,
                target_height,
                ConfirmationsPolicy::MIN,
            )
            .map_err(|e| anyhow::anyhow!("get UTXOs: {:?}", e))?;
        for utxo in utxos {
            all_utxos.push((taddr.clone(), utxo));
        }
    }

    if all_utxos.is_empty() {
        return Err(anyhow::anyhow!("No spendable transparent UTXOs"));
    }

    // Greedy UTXO selection (largest first)
    all_utxos.sort_by(|a, b| {
        u64::from(b.1.value()).cmp(&u64::from(a.1.value()))
    });

    let amount_u64 = u64::from(amount);
    let mut selected = Vec::new();
    let mut total_in = 0u64;
    for (addr, utxo) in all_utxos {
        total_in += u64::from(utxo.value());
        selected.push((addr, utxo));
        if total_in >= amount_u64 + zip317_transparent_fee(selected.len(), 2) {
            break;
        }
    }

    let fee_no_change = zip317_transparent_fee(selected.len(), 1);

    if total_in < amount_u64 + fee_no_change {
        return Err(anyhow::anyhow!(
            "InsufficientFunds: available={}, required={}",
            total_in,
            amount_u64 + fee_no_change
        ));
    }

    let leftover = total_in - amount_u64 - fee_no_change;
    let fee_with_change = zip317_transparent_fee(selected.len(), 2);
    let change_if_added = total_in.saturating_sub(amount_u64 + fee_with_change);

    // If leftover is 0, no change needed.
    // If leftover > 0 and adding a change output leaves positive change, add it.
    // Otherwise the leftover is too small to justify a change output — absorb into fee.
    let (change, use_fixed_fee) = if leftover == 0 {
        (0u64, false)
    } else if change_if_added > 0 {
        (change_if_added, false)
    } else {
        // Leftover exists but is consumed by the higher fee for an extra output.
        // Use a fixed fee = total_in - amount so the Builder sees exact balance.
        (0u64, true)
    };

    // Sapling/Orchard bundles with outputs get padded with dummy spends,
    // and those need a real on-chain anchor to pass consensus validation.
    let needs_sapling = matches!(to, Address::Sapling(_) | Address::Unified(_));
    let sapling_anchor = if needs_sapling {
        let root = db_data
            .with_sapling_tree_mut::<_, _, anyhow::Error>(|tree| {
                Ok(tree
                    .root_at_checkpoint_depth(None)
                    .map_err(|e| anyhow::anyhow!("Sapling tree: {:?}", e))?
                    .map(|r| r.into()))
            })?;
        Some(root.unwrap_or_else(sapling_crypto::Anchor::empty_tree))
    } else {
        None
    };
    let orchard_anchor = if matches!(to, Address::Unified(_)) {
        let root = db_data
            .with_orchard_tree_mut::<_, _, anyhow::Error>(|tree| {
                Ok(tree
                    .root_at_checkpoint_depth(None)
                    .map_err(|e| anyhow::anyhow!("Orchard tree: {:?}", e))?
                    .map(|r| r.into()))
            })?;
        Some(root.unwrap_or_else(orchard::Anchor::empty_tree))
    } else {
        None
    };

    let build_config = BuildConfig::Standard {
        sapling_anchor,
        orchard_anchor,
    };
    let mut builder = Builder::new(*params, chain_tip + 1, build_config);

    for (addr, utxo) in &selected {
        let pk = addr_to_pk
            .get(addr)
            .ok_or_else(|| anyhow::anyhow!("No signing key for transparent address"))?;
        builder
            .add_transparent_input(*pk, utxo.outpoint().clone(), utxo.txout().clone())
            .map_err(|e| anyhow::anyhow!("Add transparent input: {:?}", e))?;
    }

    let memo_bytes = memo.unwrap_or_else(zcash_protocol::memo::MemoBytes::empty);

    match to {
        Address::Transparent(taddr) => {
            builder
                .add_transparent_output(taddr, amount)
                .map_err(|e| anyhow::anyhow!("Add transparent output: {:?}", e))?;
        }
        Address::Sapling(sapling_addr) => {
            let dfvk = usk.sapling().to_diversifiable_full_viewing_key();
            let ovk = dfvk.to_ovk(zip32::Scope::External);
            builder
                .add_sapling_output::<std::convert::Infallible>(
                    Some(ovk),
                    sapling_addr.clone(),
                    amount,
                    memo_bytes,
                )
                .map_err(|e| anyhow::anyhow!("Add sapling output: {:?}", e))?;
        }
        Address::Unified(ua) => {
            if let Some(orchard_addr) = ua.orchard() {
                let orchard_fvk = orchard::keys::FullViewingKey::from(usk.orchard());
                let ovk = orchard_fvk.to_ovk(orchard::keys::Scope::External);
                builder
                    .add_orchard_output::<std::convert::Infallible>(
                        Some(ovk),
                        *orchard_addr,
                        u64::from(amount),
                        memo_bytes,
                    )
                    .map_err(|e| anyhow::anyhow!("Add orchard output: {:?}", e))?;
            } else if let Some(sapling_addr) = ua.sapling() {
                let dfvk = usk.sapling().to_diversifiable_full_viewing_key();
                let ovk = dfvk.to_ovk(zip32::Scope::External);
                builder
                    .add_sapling_output::<std::convert::Infallible>(
                        Some(ovk),
                        sapling_addr.clone(),
                        amount,
                        memo_bytes,
                    )
                    .map_err(|e| anyhow::anyhow!("Add sapling output: {:?}", e))?;
            } else if let Some(taddr) = ua.transparent() {
                builder
                    .add_transparent_output(taddr, amount)
                    .map_err(|e| anyhow::anyhow!("Add transparent output: {:?}", e))?;
            } else {
                return Err(anyhow::anyhow!("Unified address has no supported receiver"));
            }
        }
        Address::Tex(_) => {
            return Err(anyhow::anyhow!("TEX addresses not supported for direct send"));
        }
    }

    if change > 0 {
        let change_zat =
            Zatoshis::from_u64(change).map_err(|_| anyhow::anyhow!("Invalid change amount"))?;
        let change_addr = &selected[0].0;
        builder
            .add_transparent_output(change_addr, change_zat)
            .map_err(|e| anyhow::anyhow!("Add change output: {:?}", e))?;
    }

    let prover = load_prover(db_data_path)?;

    let build_result = if use_fixed_fee {
        use zcash_primitives::transaction::fees::fixed::FeeRule as FixedFeeRule;
        let exact_fee = Zatoshis::from_u64(total_in - amount_u64)
            .map_err(|_| anyhow::anyhow!("Invalid fee amount"))?;
        let fixed_rule = FixedFeeRule::non_standard(exact_fee);
        builder
            .build(
                &signing_set,
                &[],
                &[],
                rand::rngs::OsRng,
                &prover,
                &prover,
                &fixed_rule,
            )
            .map_err(|e| anyhow::anyhow!("Build tx: {:?}", e))?
    } else {
        builder
            .build(
                &signing_set,
                &[],
                &[],
                rand::rngs::OsRng,
                &prover,
                &prover,
                &StandardFeeRule::Zip317,
            )
            .map_err(|e| anyhow::anyhow!("Build tx: {:?}", e))?
    };

    let tx = build_result.transaction();
    let txid = tx.txid();
    let mut tx_bytes = Vec::new();
    tx.write(&mut tx_bytes)
        .map_err(|e| anyhow::anyhow!("Serialize tx: {:?}", e))?;

    Ok((txid, tx_bytes))
}

/// Send a payment to one or more recipients.
///
/// `seed_phrase` is wrapped in `SecretString` so it is zeroed on drop.
/// The 64-byte BIP39 seed is also explicitly zeroed after key derivation.
pub async fn send_payment(
    seed_phrase: &SecretString,
    recipients: Vec<(String, u64, Option<String>)>,
) -> Result<String> {
    let engine_guard = ENGINE.lock().await;
    let engine = engine_guard
        .as_ref()
        .ok_or_else(|| anyhow::anyhow!("Engine not initialized"))?;

    let db_data_path = engine.db_data_path.clone();
    let params = engine.params;
    let server_url = engine.server_url.clone();
    let db_cipher_key = engine.db_cipher_key.clone();
    drop(engine_guard);

    let mnemonic = bip0039::Mnemonic::<bip0039::English>::from_phrase(seed_phrase.expose_secret())
        .map_err(|e| anyhow::anyhow!("Invalid seed phrase: {:?}", e))?;
    let mut seed = mnemonic.to_seed("");
    let usk_result = UnifiedSpendingKey::from_seed(
        &params,
        &seed,
        zip32::AccountId::ZERO,
    );
    seed.zeroize();
    let usk = usk_result.map_err(|e| anyhow::anyhow!("USK derivation: {:?}", e))?;

    let mut db_data = open_wallet_db(&db_data_path, params, &db_cipher_key)?;

    let account_id = db_data
        .get_account_ids()
        .map_err(|e| anyhow::anyhow!("get_account_ids: {:?}", e))?
        .into_iter()
        .next()
        .ok_or_else(|| anyhow::anyhow!("No accounts in wallet"))?;

    if recipients.len() == 1 {
        let (addr_str, amount, memo_str) = &recipients[0];
        let zaddr: ZcashAddress = addr_str
            .parse()
            .map_err(|e| anyhow::anyhow!("Invalid address: {:?}", e))?;
        let to = Address::try_from_zcash_address(&params, zaddr)
            .map_err(|e| anyhow::anyhow!("Address conversion: {:?}", e))?;
        let amount = Zatoshis::from_u64(*amount)
            .map_err(|_| anyhow::anyhow!("Invalid amount"))?;

        let is_transparent = matches!(to, Address::Transparent(_));
        let memo = match memo_str {
            Some(m) if !m.is_empty() && !is_transparent => {
                use std::str::FromStr;
                use zcash_protocol::memo::{Memo, MemoBytes};
                Some(MemoBytes::from(
                    &Memo::from_str(m)
                        .map_err(|e| anyhow::anyhow!("Memo error: {:?}", e))?,
                ))
            }
            _ => None,
        };

        let prover = load_prover(&db_data_path)?;

        // Try the standard proposal-based send first
        let proposal_result = propose_and_create_send(
            &mut db_data, &params, account_id, &to, amount, memo.clone(), &prover, usk.clone(),
        );

        let (txid_str, tx_bytes) = match proposal_result {
            Ok(txids) => {
                let txid = txids.first();
                let tx = db_data
                    .get_transaction(*txid)
                    .map_err(|e| anyhow::anyhow!("get_transaction: {:?}", e))?
                    .ok_or_else(|| anyhow::anyhow!("Transaction not found after creation"))?;
                let mut bytes = Vec::new();
                tx.write(&mut bytes)
                    .map_err(|e| anyhow::anyhow!("Serialize tx: {:?}", e))?;
                (txid.to_string(), bytes)
            }
            Err(proposal_err) => {
                // Fallback: build directly from transparent UTXOs
                let (txid, bytes) = build_direct_tx(
                    &mut db_data,
                    &db_data_path,
                    &params,
                    account_id,
                    &to,
                    amount,
                    memo,
                    &usk,
                )
                .map_err(|e| {
                    anyhow::anyhow!(
                        "Standard proposal failed ({}) and direct fallback also failed: {}",
                        proposal_err, e
                    )
                })?;
                (txid.to_string(), bytes)
            }
        };

        // Broadcast
        let mut lwd = connect_lwd(&server_url).await?;
        let resp = lwd
            .send_transaction(RawTransaction {
                data: tx_bytes,
                height: 0,
            })
            .await
            .map_err(|e| anyhow::anyhow!("Broadcast failed: {:?}", e))?;

        let resp = resp.into_inner();
        if resp.error_code != 0 {
            return Err(anyhow::anyhow!(
                "Broadcast rejected: {} (code {})",
                resp.error_message,
                resp.error_code
            ));
        }

        Ok(txid_str)
    } else {
        Err(anyhow::anyhow!(
            "Multi-recipient sends not yet implemented in the new engine"
        ))
    }
}

/// Shield transparent funds into the shielded pool.
pub async fn shield_funds(seed_phrase: &SecretString) -> Result<String> {
    let engine_guard = ENGINE.lock().await;
    let engine = engine_guard
        .as_ref()
        .ok_or_else(|| anyhow::anyhow!("Engine not initialized"))?;

    let db_data_path = engine.db_data_path.clone();
    let params = engine.params;
    let server_url = engine.server_url.clone();
    let db_cipher_key = engine.db_cipher_key.clone();
    drop(engine_guard);

    let mnemonic = bip0039::Mnemonic::<bip0039::English>::from_phrase(seed_phrase.expose_secret())
        .map_err(|e| anyhow::anyhow!("Invalid seed phrase: {:?}", e))?;
    let mut seed = mnemonic.to_seed("");
    let usk_result = UnifiedSpendingKey::from_seed(
        &params,
        &seed,
        zip32::AccountId::ZERO,
    );
    seed.zeroize();
    let usk = usk_result.map_err(|e| anyhow::anyhow!("USK derivation: {:?}", e))?;

    let mut db_data = open_wallet_db(&db_data_path, params, &db_cipher_key)?;

    let account_id = db_data
        .get_account_ids()
        .map_err(|e| anyhow::anyhow!("get_account_ids: {:?}", e))?
        .into_iter()
        .next()
        .ok_or_else(|| anyhow::anyhow!("No accounts in wallet"))?;

    // Get transparent addresses for this account
    let ua = db_data
        .get_last_generated_address_matching(
            account_id,
            zcash_keys::keys::UnifiedAddressRequest::AllAvailableKeys,
        )
        .map_err(|e| anyhow::anyhow!("get_address: {:?}", e))?
        .ok_or_else(|| anyhow::anyhow!("No address found"))?;

    let taddr = ua
        .transparent()
        .ok_or_else(|| anyhow::anyhow!("No transparent receiver in UA"))?
        .clone();

    let prover = load_prover(&db_data_path)?;

    let txids = propose_and_create_shielding(
        &mut db_data, &params, &[taddr], account_id, &prover, usk,
    )?;

    let txid = txids.first();

    let tx = db_data
        .get_transaction(*txid)
        .map_err(|e| anyhow::anyhow!("get_transaction: {:?}", e))?
        .ok_or_else(|| anyhow::anyhow!("Transaction not found after creation"))?;

    let mut tx_bytes = Vec::new();
    tx.write(&mut tx_bytes)
        .map_err(|e| anyhow::anyhow!("Serialize tx: {:?}", e))?;

    let mut lwd = connect_lwd(&server_url).await?;
    let resp = lwd
        .send_transaction(RawTransaction {
            data: tx_bytes,
            height: 0,
        })
        .await
        .map_err(|e| anyhow::anyhow!("Broadcast failed: {:?}", e))?;

    let resp = resp.into_inner();
    if resp.error_code != 0 {
        return Err(anyhow::anyhow!(
            "Broadcast rejected: {} (code {})",
            resp.error_message,
            resp.error_code
        ));
    }

    Ok(txid.to_string())
}
