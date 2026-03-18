use std::collections::BTreeMap;
use std::path::Path;
use std::sync::Mutex as StdMutex;

use anyhow::Result;
use secrecy::{ExposeSecret, SecretString};
use tracing::{info, warn, error};
use zeroize::Zeroize;

use zcash_address::ZcashAddress;
use zcash_client_backend::data_api::wallet::{
    create_proposed_transactions, propose_send_max_transfer, propose_standard_transfer_to_address,
    propose_shielding, ConfirmationsPolicy, SpendingKeys, TargetHeight,
};
use zcash_client_backend::data_api::{InputSource, MaxSpendMode, WalletRead, WalletUtxo};
use zcash_client_backend::fees::{StandardFeeRule, TransactionBalance};
use zcash_client_backend::proposal::Proposal;
use zcash_client_backend::proto::service::RawTransaction;
use zcash_client_backend::wallet::OvkPolicy;
use zcash_client_backend::zip321::{Payment, TransactionRequest};
use zcash_client_sqlite::ReceivedNoteId;
use zcash_keys::address::Address;
use zcash_keys::keys::UnifiedSpendingKey;
use zcash_proofs::prover::LocalTxProver;
use zcash_protocol::consensus::{self, Network};
use zcash_protocol::value::Zatoshis;
use zcash_protocol::{PoolType, ShieldedProtocol};
use zcash_client_sqlite::WalletDb;
use super::wallet::connect_lwd;
use super::{open_wallet_db, ENGINE};

type DbType = WalletDb<rusqlite::Connection, Network, SystemClock, rand::rngs::OsRng>;
type ProposalType = Proposal<StandardFeeRule, ReceivedNoteId>;

use zcash_client_sqlite::util::SystemClock;

// ---------------------------------------------------------------------------
// Pending proposal state — always an SDK Proposal now
// ---------------------------------------------------------------------------

static PENDING_SEND: StdMutex<Option<ProposalType>> = StdMutex::new(None);

// ---------------------------------------------------------------------------
// Propose / confirm (two-step send flow)
// ---------------------------------------------------------------------------

/// Step 1: Create a proposal, store it, return (send_amount, fee, is_exact).
///
/// When `is_max` is true the SDK's `propose_send_max_transfer` is used and
/// `amount` is ignored — the returned `send_amount` is computed by the SDK.
///
/// Transparent-only funds:
///   - to transparent dest → manually constructed Proposal with transparent inputs
///   - to shielded dest   → error asking the user to shield first
pub async fn propose_send(
    address: &str,
    amount: u64,
    memo: Option<String>,
    is_max: bool,
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
    let to = Address::try_from_zcash_address(&params, zaddr.clone())
        .map_err(|e| anyhow::anyhow!("Address conversion: {:?}", e))?;

    let is_transparent_dest = matches!(to, Address::Transparent(_));

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

    // Per-pool balances to detect transparent-only funds
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

    info!("[PROPOSE] address={}, amount={}, is_max={}", address, amount, is_max);
    info!("[PROPOSE] balances: transparent={}, sapling={}, orchard={}", t_bal, s_bal, o_bal);
    info!("[PROPOSE] is_transparent_only={}, is_transparent_dest={}", is_transparent_only, is_transparent_dest);

    // Transparent-only → shielded dest: must shield first
    if is_transparent_only && !is_transparent_dest {
        return Err(anyhow::anyhow!(
            "Your funds are in the transparent pool. \
             Use the Shield button on the home screen to move them \
             to the shielded pool before sending."
        ));
    }

    if is_max {
        propose_max_inner(
            &mut db_data, &params, account_id, &to, &zaddr,
            memo_bytes, confirmations, is_transparent_only, is_transparent_dest,
            t_bal, address,
        )
    } else {
        propose_regular_inner(
            &mut db_data, &params, account_id, &to,
            amount, memo_bytes, confirmations,
            is_transparent_only, is_transparent_dest, address,
        )
    }
}

/// MAX send proposal.
fn propose_max_inner(
    db_data: &mut DbType,
    params: &Network,
    account_id: <DbType as InputSource>::AccountId,
    _to: &Address,
    zaddr: &ZcashAddress,
    memo_bytes: Option<zcash_protocol::memo::MemoBytes>,
    confirmations: ConfirmationsPolicy,
    is_transparent_only: bool,
    is_transparent_dest: bool,
    _t_bal: u64,
    raw_address: &str,
) -> Result<(u64, u64, bool)> {
    if is_transparent_only && is_transparent_dest {
        info!("[PROPOSE_MAX] Taking t→t MAX path");
        let proposal = create_transparent_proposal(
            db_data, params, account_id, raw_address, None, // None = MAX
        )?;
        let fee = u64::from(proposal.steps().first().balance().fee_required());
        let send_amount: u64 = proposal
            .steps()
            .first()
            .transaction_request()
            .payments()
            .values()
            .map(|p| u64::from(p.amount()))
            .next()
            .unwrap_or(0);
        *PENDING_SEND.lock().unwrap() = Some(proposal);
        return Ok((send_amount, fee, true));
    }

    info!("[PROPOSE_MAX] Taking shielded MAX path (SDK)");
    let proposal = propose_send_max_transfer::<_, _, _, std::convert::Infallible>(
        db_data,
        params,
        account_id,
        &[ShieldedProtocol::Sapling, ShieldedProtocol::Orchard],
        &StandardFeeRule::Zip317,
        zaddr.clone(),
        memo_bytes,
        MaxSpendMode::MaxSpendable,
        confirmations,
    )
    .map_err(|e| anyhow::anyhow!("Proposal failed: {:?}", e))?;

    let fee = u64::from(proposal.steps().first().balance().fee_required());
    let send_amount: u64 = proposal
        .steps()
        .first()
        .transaction_request()
        .payments()
        .values()
        .map(|p| u64::from(p.amount()))
        .sum();

    *PENDING_SEND.lock().unwrap() = Some(proposal);
    Ok((send_amount, fee, true))
}

/// Regular (non-MAX) send proposal.
fn propose_regular_inner(
    db_data: &mut DbType,
    params: &Network,
    account_id: <DbType as InputSource>::AccountId,
    to: &Address,
    amount: u64,
    memo_bytes: Option<zcash_protocol::memo::MemoBytes>,
    confirmations: ConfirmationsPolicy,
    is_transparent_only: bool,
    is_transparent_dest: bool,
    raw_address: &str,
) -> Result<(u64, u64, bool)> {
    let send_zat = Zatoshis::from_u64(amount)
        .map_err(|_| anyhow::anyhow!("Invalid amount"))?;

    info!("[PROPOSE_REG] Trying SDK propose_standard_transfer_to_address...");
    let proposal_result = propose_standard_transfer_to_address::<_, _, std::convert::Infallible>(
        db_data,
        params,
        StandardFeeRule::Zip317,
        account_id,
        confirmations,
        to,
        send_zat,
        memo_bytes,
        None,
        ShieldedProtocol::Orchard,
    );

    match proposal_result {
        Ok(proposal) => {
            let fee = u64::from(proposal.steps().first().balance().fee_required());
            info!("[PROPOSE_REG] SDK proposal OK. fee={}", fee);
            *PENDING_SEND.lock().unwrap() = Some(proposal);
            Ok((amount, fee, true))
        }
        Err(e) => {
            warn!("[PROPOSE_REG] SDK proposal failed: {:?}", e);
            if is_transparent_only && is_transparent_dest {
                info!("[PROPOSE_REG] Falling back to transparent proposal for t→t");
                let proposal = create_transparent_proposal(
                    db_data, params, account_id, raw_address, Some(amount),
                )?;
                let fee = u64::from(proposal.steps().first().balance().fee_required());
                info!("[PROPOSE_REG] Transparent proposal OK. fee={}", fee);
                *PENDING_SEND.lock().unwrap() = Some(proposal);
                Ok((amount, fee, true))
            } else {
                Err(anyhow::anyhow!("Proposal failed: {:?}", e))
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Transparent proposal builder
// ---------------------------------------------------------------------------

/// ZIP-317 fee for transparent-only tx, computed from actual byte sizes.
/// P2PKH input = 148 bytes, P2PKH scriptPubKey = 25 bytes.
fn transparent_zip317_fee(n_inputs: usize, n_output_scripts_total_bytes: usize) -> u64 {
    let input_actions = (n_inputs * 148 + 149) / 150; // ceil(n*148/150)
    let output_actions = (n_output_scripts_total_bytes + 33) / 34; // ceil(bytes/34)
    let logical_actions = std::cmp::max(input_actions, output_actions);
    std::cmp::max(2, logical_actions) as u64 * 5000
}

/// Create a Proposal with transparent inputs for a t→t send.
/// When `amount` is None, this is a MAX send (spend everything minus fee).
/// The returned Proposal can be built by `create_proposed_transactions`.
fn create_transparent_proposal(
    db_data: &mut DbType,
    params: &Network,
    account_id: <DbType as InputSource>::AccountId,
    recipient_addr: &str,
    amount: Option<u64>,
) -> Result<ProposalType> {
    let chain_tip = db_data
        .chain_height()
        .map_err(|e| anyhow::anyhow!("{:?}", e))?
        .ok_or_else(|| anyhow::anyhow!("Chain tip unknown — sync the wallet first"))?;

    // Match the SDK: use chain_tip directly, NOT chain_tip + 1
    let target_height = TargetHeight::from(chain_tip);

    let branch_id = consensus::BranchId::for_height(params, chain_tip);
    info!("[T_PROPOSAL] chain_tip={}, target_height={}, branch_id={:?}, network={:?}",
        u32::from(chain_tip), u32::from(chain_tip), branch_id, params);
    info!("[T_PROPOSAL] recipient={}, amount={:?} (None=MAX)", recipient_addr, amount);

    let recipient_zaddr: ZcashAddress = recipient_addr
        .parse()
        .map_err(|e| anyhow::anyhow!("Invalid address: {:?}", e))?;

    // Collect UTXOs and a change address
    let receivers = db_data
        .get_transparent_receivers(account_id, true, true)
        .map_err(|e| anyhow::anyhow!("get_transparent_receivers: {:?}", e))?;

    let mut all_utxos = Vec::new();
    let mut change_taddr: Option<zcash_transparent::address::TransparentAddress> = None;

    for (taddr, meta) in &receivers {
        info!("[T_PROPOSAL] receiver addr={:?}, scope={:?}, idx={:?}",
            taddr, meta.scope(), meta.address_index());
        let utxos: Vec<WalletUtxo> = db_data
            .get_spendable_transparent_outputs(taddr, target_height, ConfirmationsPolicy::MIN)
            .map_err(|e| anyhow::anyhow!("get UTXOs: {:?}", e))?;
        info!("[T_PROPOSAL]   found {} UTXOs for this address", utxos.len());
        if !utxos.is_empty() && change_taddr.is_none() {
            change_taddr = Some(taddr.clone());
        }
        for u in utxos {
            info!("[T_PROPOSAL]   UTXO outpoint={}:{}, value={}, mined_height={:?}",
                hex::encode(u.outpoint().hash()), u.outpoint().n(),
                u64::from(u.txout().value()),
                u.mined_height());
            all_utxos.push(u.into_wallet_output());
        }
    }

    info!("[T_PROPOSAL] total UTXOs collected: {}", all_utxos.len());
    if all_utxos.is_empty() {
        return Err(anyhow::anyhow!("No spendable transparent UTXOs"));
    }

    // Verify address metadata for each UTXO (same check create_proposed_transactions will do)
    for utxo in &all_utxos {
        let addr = utxo.recipient_address();
        match db_data.get_transparent_address_metadata(account_id, addr) {
            Ok(Some(meta)) => {
                info!("[T_PROPOSAL] UTXO addr metadata OK: addr={:?}, source={:?}", addr, meta.source());
            }
            Ok(None) => {
                error!("[T_PROPOSAL] UTXO addr metadata MISSING: addr={:?} — signing will fail!", addr);
            }
            Err(e) => {
                error!("[T_PROPOSAL] UTXO addr metadata ERROR: addr={:?}, err={:?}", addr, e);
            }
        }
    }

    // Sort largest first for greedy selection
    all_utxos.sort_by(|a, b| u64::from(b.txout().value()).cmp(&u64::from(a.txout().value())));

    // P2PKH scriptPubKey = 25 bytes
    const P2PKH_SCRIPT: usize = 25;

    match amount {
        None => {
            // MAX: select all UTXOs, single output, no change
            let total_in: u64 = all_utxos.iter().map(|u| u64::from(u.txout().value())).sum();
            let fee = transparent_zip317_fee(all_utxos.len(), P2PKH_SCRIPT);
            info!("[T_PROPOSAL] MAX: total_in={}, fee={}, n_inputs={}, output_script_bytes={}",
                total_in, fee, all_utxos.len(), P2PKH_SCRIPT);
            let send_amount = total_in
                .checked_sub(fee)
                .ok_or_else(|| anyhow::anyhow!("Balance too low to cover the network fee"))?;
            if send_amount == 0 {
                return Err(anyhow::anyhow!("Balance too low to cover the network fee"));
            }

            let send_zat = Zatoshis::from_u64(send_amount)
                .map_err(|_| anyhow::anyhow!("Invalid amount"))?;
            let fee_zat = Zatoshis::from_u64(fee)
                .map_err(|_| anyhow::anyhow!("Invalid fee"))?;

            let payment = Payment::new(
                recipient_zaddr, send_zat, None, None, None, vec![],
            )
            .ok_or_else(|| anyhow::anyhow!("Cannot create payment for this address"))?;

            let request = TransactionRequest::new(vec![payment])
                .map_err(|e| anyhow::anyhow!("TransactionRequest: {:?}", e))?;

            let mut payment_pools = BTreeMap::new();
            payment_pools.insert(0, PoolType::TRANSPARENT);

            let balance = TransactionBalance::new(vec![], fee_zat)
                .map_err(|_| anyhow::anyhow!("TransactionBalance error"))?;

            info!("[T_PROPOSAL] MAX Proposal: send_amount={}, fee={}, n_utxos={}, 1 payment, 0 change",
                send_amount, fee, all_utxos.len());

            let proposal = Proposal::single_step(
                request,
                payment_pools,
                all_utxos,
                None,
                balance,
                StandardFeeRule::Zip317,
                target_height,
                false,
            )
            .map_err(|e| anyhow::anyhow!("Proposal: {:?}", e))?;

            info!("[T_PROPOSAL] Proposal created successfully");
            Ok(proposal)
        }
        Some(amount_u64) => {
            let send_zat = Zatoshis::from_u64(amount_u64)
                .map_err(|_| anyhow::anyhow!("Invalid amount"))?;

            // Select enough UTXOs to cover amount + fee (worst-case: with change)
            let mut selected = Vec::new();
            let mut total_in = 0u64;
            for utxo in all_utxos {
                total_in += u64::from(utxo.txout().value());
                selected.push(utxo);
                let est_fee = transparent_zip317_fee(selected.len(), P2PKH_SCRIPT * 2);
                if total_in >= amount_u64 + est_fee {
                    break;
                }
            }

            let fee_1 = transparent_zip317_fee(selected.len(), P2PKH_SCRIPT);
            if total_in < amount_u64 + fee_1 {
                return Err(anyhow::anyhow!(
                    "InsufficientFunds: available={}, required={}",
                    total_in, amount_u64 + fee_1
                ));
            }

            let leftover = total_in - amount_u64 - fee_1;

            if leftover == 0 {
                // Exact: single payment, no change
                let fee_zat = Zatoshis::from_u64(fee_1)
                    .map_err(|_| anyhow::anyhow!("Invalid fee"))?;

                let payment = Payment::new(
                    recipient_zaddr, send_zat, None, None, None, vec![],
                )
                .ok_or_else(|| anyhow::anyhow!("Cannot create payment for this address"))?;

                let request = TransactionRequest::new(vec![payment])
                    .map_err(|e| anyhow::anyhow!("TransactionRequest: {:?}", e))?;

                let mut payment_pools = BTreeMap::new();
                payment_pools.insert(0, PoolType::TRANSPARENT);

                let balance = TransactionBalance::new(vec![], fee_zat)
                    .map_err(|_| anyhow::anyhow!("TransactionBalance error"))?;

                Proposal::single_step(
                    request, payment_pools, selected, None, balance,
                    StandardFeeRule::Zip317, target_height, false,
                )
                .map_err(|e| anyhow::anyhow!("Proposal: {:?}", e))
            } else {
                // Has change — add change as a second transparent payment
                let fee_2 = transparent_zip317_fee(selected.len(), P2PKH_SCRIPT * 2);
                let change = total_in.saturating_sub(amount_u64 + fee_2);

                let (fee, change_amount) = if change > 0 {
                    (fee_2, change)
                } else {
                    // Edge case: leftover consumed by marginal output cost.
                    // Use 1-output fee and absorb dust into fee.
                    (total_in - amount_u64, 0u64)
                };

                let fee_zat = Zatoshis::from_u64(fee)
                    .map_err(|_| anyhow::anyhow!("Invalid fee"))?;

                let mut payments = vec![
                    Payment::new(
                        recipient_zaddr, send_zat, None, None, None, vec![],
                    )
                    .ok_or_else(|| anyhow::anyhow!("Cannot create payment"))?,
                ];
                let mut payment_pools = BTreeMap::new();
                payment_pools.insert(0, PoolType::TRANSPARENT);

                if change_amount > 0 {
                    let change_addr = change_taddr
                        .ok_or_else(|| anyhow::anyhow!("No change address"))?;
                    let change_zaddr =
                        Address::Transparent(change_addr).to_zcash_address(params);
                    let change_zat = Zatoshis::from_u64(change_amount)
                        .map_err(|_| anyhow::anyhow!("Invalid change"))?;
                    payments.push(
                        Payment::new(
                            change_zaddr, change_zat, None, None, None, vec![],
                        )
                        .ok_or_else(|| anyhow::anyhow!("Cannot create change payment"))?,
                    );
                    payment_pools.insert(1, PoolType::TRANSPARENT);
                }

                let request = TransactionRequest::new(payments)
                    .map_err(|e| anyhow::anyhow!("TransactionRequest: {:?}", e))?;

                let balance = TransactionBalance::new(vec![], fee_zat)
                    .map_err(|_| anyhow::anyhow!("TransactionBalance error"))?;

                Proposal::single_step(
                    request, payment_pools, selected, None, balance,
                    StandardFeeRule::Zip317, target_height, false,
                )
                .map_err(|e| anyhow::anyhow!("Proposal: {:?}", e))
            }
        }
    }
}

/// Step 2: Build + broadcast from the stored proposal.
pub async fn confirm_send(seed_phrase: &SecretString) -> Result<String> {
    info!("[CONFIRM] ====== confirm_send START ======");

    let proposal = {
        let mut lock = PENDING_SEND.lock().unwrap();
        lock.take()
            .ok_or_else(|| anyhow::anyhow!("No pending proposal — call propose_send first"))?
    };

    // Log proposal details
    let step = proposal.steps().first();
    info!("[CONFIRM] Proposal: target_height={}, fee_rule={:?}",
        u32::from(proposal.min_target_height()), proposal.fee_rule());
    info!("[CONFIRM] Proposal step: n_transparent_inputs={}, n_payments={}, fee_required={}, is_shielding={}",
        step.transparent_inputs().len(),
        step.transaction_request().payments().len(),
        u64::from(step.balance().fee_required()),
        step.is_shielding());
    for (idx, payment) in step.transaction_request().payments() {
        info!("[CONFIRM]   payment[{}]: addr={}, amount={}", idx,
            payment.recipient_address(), u64::from(payment.amount()));
    }
    for (i, utxo) in step.transparent_inputs().iter().enumerate() {
        info!("[CONFIRM]   t_input[{}]: outpoint={}:{}, value={}", i,
            hex::encode(utxo.outpoint().hash()), utxo.outpoint().n(),
            u64::from(utxo.txout().value()));
    }
    info!("[CONFIRM]   involves transparent={}, sapling={}, orchard={}",
        step.involves(PoolType::TRANSPARENT),
        step.involves(PoolType::Shielded(ShieldedProtocol::Sapling)),
        step.involves(PoolType::Shielded(ShieldedProtocol::Orchard)));

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
    let usk_result = UnifiedSpendingKey::from_seed(&params, &seed, zip32::AccountId::ZERO);
    seed.zeroize();
    let usk = usk_result.map_err(|e| anyhow::anyhow!("USK derivation: {:?}", e))?;

    // Log transparent key derivation info
    {
        use zcash_transparent::keys::NonHardenedChildIndex;
        let t_key = usk.transparent();
        match t_key.derive_external_secret_key(NonHardenedChildIndex::ZERO) {
            Ok(sk) => {
                let sk_bytes = sk.secret_bytes();
                info!("[CONFIRM] USK external[0] secret key first 4 bytes: {}",
                    hex::encode(&sk_bytes[..4]));
            }
            Err(e) => {
                error!("[CONFIRM] Failed to derive external key[0]: {:?}", e);
            }
        }
        // Also derive via the unified method to verify
        match t_key.derive_secret_key(
            zcash_transparent::keys::TransparentKeyScope::EXTERNAL,
            NonHardenedChildIndex::ZERO,
        ) {
            Ok(sk) => {
                let sk_bytes = sk.secret_bytes();
                info!("[CONFIRM] USK derive_secret_key(EXTERNAL, 0) first 4 bytes: {}",
                    hex::encode(&sk_bytes[..4]));
            }
            Err(e) => {
                error!("[CONFIRM] derive_secret_key(EXTERNAL, 0) failed: {:?}", e);
            }
        }
    }

    info!("[CONFIRM] USK derived OK, loading wallet DB...");
    let mut db_data = open_wallet_db(&db_data_path, params, &db_cipher_key)?;

    let prover = load_prover_from_path(&db_data_path)?;
    info!("[CONFIRM] Prover loaded OK. Calling create_proposed_transactions...");
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
    .map_err(|e| {
        error!("[CONFIRM] create_proposed_transactions FAILED: {:?}", e);
        anyhow::anyhow!("Create tx failed: {:?}", e)
    })?;

    let txid = txids.first();
    info!("[CONFIRM] Transaction created OK. txid={}", txid);

    // Get the transaction and serialize to bytes
    let tx = db_data
        .get_transaction(*txid)
        .map_err(|e| anyhow::anyhow!("{:?}", e))?
        .ok_or_else(|| anyhow::anyhow!("Transaction not found after creation"))?;
    let mut tx_bytes = Vec::new();
    tx.write(&mut tx_bytes)
        .map_err(|e| anyhow::anyhow!("Serialize tx: {:?}", e))?;
    info!("[CONFIRM] Serialized tx: {} bytes", tx_bytes.len());

    // Log first 20 bytes (header info) and last 10 bytes for diagnostics
    if tx_bytes.len() >= 20 {
        info!("[CONFIRM] tx header (first 20 bytes): {}", hex::encode(&tx_bytes[..20]));
    }
    if tx_bytes.len() >= 10 {
        let start = tx_bytes.len() - 10;
        info!("[CONFIRM] tx tail (last 10 bytes): {}", hex::encode(&tx_bytes[start..]));
    }

    // Parse header: bytes 0-3 = version+overwintered, 4-7 = versionGroupId, 8-11 = branchId
    if tx_bytes.len() >= 12 {
        let version = u32::from_le_bytes([tx_bytes[0], tx_bytes[1], tx_bytes[2], tx_bytes[3]]);
        let vg_id = u32::from_le_bytes([tx_bytes[4], tx_bytes[5], tx_bytes[6], tx_bytes[7]]);
        let branch = u32::from_le_bytes([tx_bytes[8], tx_bytes[9], tx_bytes[10], tx_bytes[11]]);
        info!("[CONFIRM] tx version=0x{:08x}, versionGroupId=0x{:08x}, consensusBranchId=0x{:08x}",
            version, vg_id, branch);

        // NU5 = 0xC2D6D0B4, NU6 check
        let expected_branch = consensus::BranchId::for_height(
            &params,
            zcash_protocol::consensus::BlockHeight::from_u32(u32::from(proposal.min_target_height())),
        );
        info!("[CONFIRM] expected branch for target height: {:?}", expected_branch);
    }

    // Also log the full tx hex for offline analysis (truncated if very large)
    if tx_bytes.len() <= 2000 {
        info!("[CONFIRM] FULL TX HEX: {}", hex::encode(&tx_bytes));
    } else {
        info!("[CONFIRM] TX HEX (truncated, {} bytes total): {}...",
            tx_bytes.len(), hex::encode(&tx_bytes[..500]));
    }

    // Broadcast
    info!("[CONFIRM] Broadcasting to {}...", server_url);
    let mut lwd = connect_lwd(&server_url).await?;
    let resp = lwd
        .send_transaction(RawTransaction {
            data: tx_bytes,
            height: 0,
        })
        .await
        .map_err(|e| {
            error!("[CONFIRM] Broadcast gRPC call FAILED: {:?}", e);
            anyhow::anyhow!("Broadcast failed: {:?}", e)
        })?;

    let resp = resp.into_inner();
    info!("[CONFIRM] Broadcast response: error_code={}, error_message='{}'",
        resp.error_code, resp.error_message);

    if resp.error_code != 0 {
        error!("[CONFIRM] BROADCAST REJECTED: code={}, msg={}", resp.error_code, resp.error_message);
        return Err(anyhow::anyhow!(
            "Broadcast rejected: {} (code {})",
            resp.error_message,
            resp.error_code
        ));
    }

    info!("[CONFIRM] ====== confirm_send SUCCESS txid={} ======", txid);
    Ok(txid.to_string())
}


// ---------------------------------------------------------------------------
// Max sendable (for the send page balance display)
// ---------------------------------------------------------------------------

/// Compute the maximum sendable amount to a given address.
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

    let spendable = t_bal + s_bal + o_bal;
    if spendable == 0 {
        return Ok(0);
    }

    let zaddr: ZcashAddress = address
        .parse()
        .map_err(|e| anyhow::anyhow!("Invalid address: {:?}", e))?;
    let to = Address::try_from_zcash_address(&params, zaddr.clone())
        .map_err(|e| anyhow::anyhow!("Address conversion: {:?}", e))?;
    let is_transparent_dest = matches!(to, Address::Transparent(_));
    let is_transparent_only = t_bal > 0 && s_bal == 0 && o_bal == 0;

    if is_transparent_only {
        if is_transparent_dest {
            let fee = transparent_zip317_fee(1, 25);
            return Ok(t_bal.saturating_sub(fee));
        } else {
            return Ok(0);
        }
    }

    // Shielded: use SDK
    let proposal_result =
        propose_send_max_transfer::<_, _, _, std::convert::Infallible>(
            &mut db_data,
            &params,
            account_id,
            &[ShieldedProtocol::Sapling, ShieldedProtocol::Orchard],
            &StandardFeeRule::Zip317,
            zaddr,
            None,
            MaxSpendMode::MaxSpendable,
            confirmations,
        );

    match proposal_result {
        Ok(proposal) => {
            let send_amount: u64 = proposal
                .steps()
                .first()
                .transaction_request()
                .payments()
                .values()
                .map(|p| u64::from(p.amount()))
                .sum();
            Ok(send_amount)
        }
        Err(e) => {
            let err_str = format!("{:?}", e);
            if err_str.contains("InsufficientFunds") {
                Ok(0)
            } else {
                Err(anyhow::anyhow!("Proposal error: {}", err_str))
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Legacy single-step send (kept for compatibility)
// ---------------------------------------------------------------------------

fn propose_and_create_send(
    db_data: &mut DbType,
    params: &Network,
    account_id: <DbType as InputSource>::AccountId,
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

fn propose_and_create_shielding(
    db_data: &mut DbType,
    params: &Network,
    from_addrs: &[zcash_transparent::address::TransparentAddress],
    to_account: <DbType as InputSource>::AccountId,
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

fn load_prover_from_path(db_data_path: &Path) -> Result<LocalTxProver> {
    let wallet_dir = db_data_path
        .parent()
        .ok_or_else(|| anyhow::anyhow!("Cannot determine data directory"))?;

    let candidates = [
        wallet_dir.to_path_buf(),
        wallet_dir
            .parent()
            .map(|p| p.to_path_buf())
            .unwrap_or_default(),
    ];

    for dir in &candidates {
        let spend = dir.join("sapling-spend.params");
        let output = dir.join("sapling-output.params");
        if spend.exists() && output.exists() {
            return Ok(LocalTxProver::new(&spend, &output));
        }
    }

    Err(anyhow::anyhow!(
        "Sapling params not found. Searched {:?}.",
        candidates
    ))
}

/// Send a payment to one or more recipients (legacy single-step path).
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

    let mnemonic =
        bip0039::Mnemonic::<bip0039::English>::from_phrase(seed_phrase.expose_secret())
            .map_err(|e| anyhow::anyhow!("Invalid seed phrase: {:?}", e))?;
    let mut seed = mnemonic.to_seed("");
    let usk_result = UnifiedSpendingKey::from_seed(&params, &seed, zip32::AccountId::ZERO);
    seed.zeroize();
    let usk = usk_result.map_err(|e| anyhow::anyhow!("USK derivation: {:?}", e))?;

    let mut db_data = open_wallet_db(&db_data_path, params, &db_cipher_key)?;

    let account_id = db_data
        .get_account_ids()
        .map_err(|e| anyhow::anyhow!("get_account_ids: {:?}", e))?
        .into_iter()
        .next()
        .ok_or_else(|| anyhow::anyhow!("No accounts in wallet"))?;

    if recipients.len() != 1 {
        return Err(anyhow::anyhow!(
            "Multi-recipient sends not yet implemented in the new engine"
        ));
    }

    let (addr_str, amount, memo_str) = &recipients[0];
    let zaddr: ZcashAddress = addr_str
        .parse()
        .map_err(|e| anyhow::anyhow!("Invalid address: {:?}", e))?;
    let to = Address::try_from_zcash_address(&params, zaddr)
        .map_err(|e| anyhow::anyhow!("Address conversion: {:?}", e))?;
    let amount = Zatoshis::from_u64(*amount).map_err(|_| anyhow::anyhow!("Invalid amount"))?;

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

    let prover = load_prover_from_path(&db_data_path)?;

    let txids = propose_and_create_send(
        &mut db_data, &params, account_id, &to, amount, memo, &prover, usk,
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

// ---------------------------------------------------------------------------
// Shield transparent funds
// ---------------------------------------------------------------------------

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

    let mnemonic =
        bip0039::Mnemonic::<bip0039::English>::from_phrase(seed_phrase.expose_secret())
            .map_err(|e| anyhow::anyhow!("Invalid seed phrase: {:?}", e))?;
    let mut seed = mnemonic.to_seed("");
    let usk_result = UnifiedSpendingKey::from_seed(&params, &seed, zip32::AccountId::ZERO);
    seed.zeroize();
    let usk = usk_result.map_err(|e| anyhow::anyhow!("USK derivation: {:?}", e))?;

    let mut db_data = open_wallet_db(&db_data_path, params, &db_cipher_key)?;

    let account_id = db_data
        .get_account_ids()
        .map_err(|e| anyhow::anyhow!("get_account_ids: {:?}", e))?
        .into_iter()
        .next()
        .ok_or_else(|| anyhow::anyhow!("No accounts in wallet"))?;

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

    let prover = load_prover_from_path(&db_data_path)?;

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
