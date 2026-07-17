//! FFI bindings for the Zipher wallet engine built on zcash_client_backend.

use anyhow::Result;
use std::collections::BTreeMap;
use zcash_protocol::consensus::Network;

use super::wallet::{AddressInfo, AddressValidation, ChainType, WalletBalance};
use crate::engine;
use crate::frb_generated::StreamSink;

fn to_network(ct: ChainType) -> Network {
    match ct {
        ChainType::Mainnet => Network::MainNetwork,
        ChainType::Testnet => Network::TestNetwork,
    }
}

// ---------------------------------------------------------------------------
// Wallet lifecycle
// ---------------------------------------------------------------------------

/// Create a new wallet. Returns the 24-word seed phrase.
pub async fn engine_create_wallet(
    data_dir: String,
    server_url: String,
    chain_type: ChainType,
    chain_height: u32,
    db_cipher_key: Option<String>,
) -> Result<String> {
    engine::wallet::create(
        &data_dir,
        &server_url,
        to_network(chain_type),
        chain_height,
        db_cipher_key,
        None,
    )
    .await
}

/// Restore a wallet from a BIP39 seed phrase.
pub async fn engine_restore_from_seed(
    data_dir: String,
    server_url: String,
    chain_type: ChainType,
    seed_phrase: String,
    birthday: u32,
    db_cipher_key: Option<String>,
) -> Result<()> {
    engine::wallet::restore(
        &data_dir,
        &server_url,
        to_network(chain_type),
        &seed_phrase,
        birthday,
        db_cipher_key,
        None,
    )
    .await
}

/// Restore a watch-only wallet from a UFVK.
pub async fn engine_restore_from_ufvk(
    data_dir: String,
    server_url: String,
    chain_type: ChainType,
    ufvk: String,
    birthday: u32,
    db_cipher_key: Option<String>,
) -> Result<()> {
    engine::wallet::restore_from_ufvk(
        &data_dir,
        &server_url,
        to_network(chain_type),
        &ufvk,
        birthday,
        db_cipher_key,
    )
    .await
}

/// Open an existing wallet from disk.
pub async fn engine_open_wallet(
    data_dir: String,
    server_url: String,
    chain_type: ChainType,
    db_cipher_key: Option<String>,
) -> Result<()> {
    engine::wallet::open(
        &data_dir,
        &server_url,
        to_network(chain_type),
        db_cipher_key,
    )
    .await
}

/// Close the current wallet.
pub async fn engine_close_wallet() -> Result<()> {
    engine::wallet::close().await;
    Ok(())
}

/// Delete wallet database files from disk.
pub async fn engine_delete_wallet_data(data_dir: String) -> Result<()> {
    engine::wallet::delete(&data_dir)
}

// ---------------------------------------------------------------------------
// Addresses
// ---------------------------------------------------------------------------

pub async fn engine_get_addresses() -> Result<Vec<AddressInfo>> {
    let addrs = engine::query::get_addresses().await?;
    Ok(addrs.into_iter().map(|a| a.into()).collect())
}

pub async fn engine_get_transparent_addresses() -> Result<Vec<String>> {
    engine::query::get_transparent_addresses().await
}

// ---------------------------------------------------------------------------
// Balance
// ---------------------------------------------------------------------------

pub async fn engine_get_wallet_balance() -> Result<WalletBalance> {
    let balance = engine::query::get_wallet_balance().await?;
    Ok(balance.into())
}

/// Returns the maximum amount (in zatoshis) that can be sent to the given
/// address after accounting for the exact ZIP-317 fee.
pub async fn engine_get_max_sendable(address: String) -> Result<u64> {
    engine::send::get_max_sendable(&address).await
}

// ---------------------------------------------------------------------------
// Misc
// ---------------------------------------------------------------------------

pub async fn engine_get_birthday() -> Result<u32> {
    engine::query::get_birthday().await
}

pub async fn engine_get_wallet_synced_height() -> Result<u32> {
    engine::query::get_synced_height().await
}

// ---------------------------------------------------------------------------
// EVM queries (all via reqwest — bypasses Dart HTTP issues on iOS)
// ---------------------------------------------------------------------------

/// Native balance in raw wei as decimal string.
pub async fn engine_get_native_balance(rpc_url: String, address: String) -> Result<String> {
    let raw = engine::evm::get_native_balance(&rpc_url, &address).await?;
    Ok(raw.to_string())
}

/// ERC-20 balance in raw token units as decimal string.
pub async fn engine_get_erc20_balance(
    rpc_url: String,
    token_contract: String,
    owner_address: String,
) -> Result<String> {
    let raw = engine::evm::get_erc20_balance(&rpc_url, &token_contract, &owner_address).await?;
    Ok(raw.to_string())
}

/// Pending nonce for an address.
pub async fn engine_get_nonce(rpc_url: String, address: String) -> Result<u64> {
    engine::evm::get_nonce(&rpc_url, &address).await
}

/// Suggested EIP-1559 gas fees. Returns (maxPriorityFeePerGas, maxFeePerGas) in wei.
pub async fn engine_suggest_eip1559_fees(rpc_url: String, chain_id: u64) -> Result<EvmFees> {
    let fees = engine::evm::suggest_eip1559_fees(&rpc_url, chain_id).await?;
    Ok(EvmFees {
        max_priority_fee_per_gas: fees.max_priority_fee_per_gas,
        max_fee_per_gas: fees.max_fee_per_gas,
    })
}

/// ERC-20 approve: sign + broadcast + wait. Returns tx hash.
pub async fn engine_approve_erc20(
    rpc_url: String,
    seed_phrase: String,
    owner_address: String,
    token_address: String,
    spender_address: String,
    amount_raw: String,
    chain_id: u64,
) -> Result<String> {
    let amount: u128 = amount_raw
        .parse()
        .map_err(|e| anyhow::anyhow!("Invalid amount: {e}"))?;
    let fees = engine::evm::suggest_eip1559_fees(&rpc_url, chain_id).await?;
    engine::evm::approve_erc20(
        &rpc_url,
        &seed_phrase,
        &owner_address,
        &token_address,
        &spender_address,
        amount,
        chain_id,
        &fees,
    )
    .await
}

/// Wait for a tx receipt. Returns (success, block_number).
pub async fn engine_wait_for_receipt(rpc_url: String, tx_hash: String) -> Result<EvmReceipt> {
    let r = engine::evm::wait_for_receipt(&rpc_url, &tx_hash, 90).await?;
    Ok(EvmReceipt {
        success: r.status,
        block_number: r.block_number,
        gas_used: r.gas_used,
        tx_hash: r.tx_hash,
    })
}

/// ERC-1155 isApprovedForAll check.
pub async fn engine_erc1155_is_approved_for_all(
    rpc_url: String,
    owner: String,
    token_contract: String,
    operator: String,
) -> Result<bool> {
    engine::evm::erc1155_is_approved_for_all(&rpc_url, &owner, &token_contract, &operator).await
}

/// ERC-1155 setApprovalForAll: sign + broadcast + wait. Returns tx hash.
pub async fn engine_erc1155_set_approval_for_all(
    rpc_url: String,
    seed_phrase: String,
    owner_address: String,
    token_contract: String,
    operator: String,
    approved: bool,
    chain_id: u64,
) -> Result<String> {
    let fees = engine::evm::suggest_eip1559_fees(&rpc_url, chain_id).await?;
    engine::evm::erc1155_set_approval_for_all(
        &rpc_url,
        &seed_phrase,
        &owner_address,
        &token_contract,
        &operator,
        approved,
        chain_id,
        &fees,
    )
    .await
}

pub async fn engine_has_spending_key() -> Result<bool> {
    engine::query::has_spending_key().await
}

pub async fn engine_export_ufvk() -> Result<Option<String>> {
    engine::query::export_ufvk().await
}

pub fn engine_validate_address(address: String) -> AddressValidation {
    match address.parse::<zcash_address::ZcashAddress>() {
        Ok(addr) => {
            let addr_type = format!("{:?}", addr);
            AddressValidation {
                is_valid: true,
                address_type: Some(addr_type),
            }
        }
        Err(_) => AddressValidation {
            is_valid: false,
            address_type: None,
        },
    }
}

pub fn engine_validate_seed(seed: String) -> bool {
    bip0039::Mnemonic::<bip0039::English>::from_phrase(&seed).is_ok()
}

pub async fn engine_get_latest_block_height(server_url: String) -> Result<u32> {
    let height = engine::wallet::fetch_latest_height(&server_url).await?;
    Ok(height as u32)
}

// ---------------------------------------------------------------------------
// Sync
// ---------------------------------------------------------------------------

pub async fn engine_start_sync() -> Result<()> {
    engine::sync::start().await
}

pub async fn engine_stop_sync() -> Result<()> {
    engine::sync::stop().await;
    Ok(())
}

pub async fn engine_set_server(server_url: String) -> Result<()> {
    engine::wallet::set_server(&server_url).await
}

/// Rescan the wallet from its birthday height by truncating and restarting sync.
pub async fn engine_rescan_from_birthday() -> Result<()> {
    let birthday = engine::query::get_birthday().await?;
    engine::sync::rescan_from(birthday).await
}

pub async fn engine_get_sync_progress() -> Result<EngineSyncProgress> {
    let p = engine::sync::get_progress().await;
    Ok(EngineSyncProgress {
        synced_height: p.synced_height,
        latest_height: p.latest_height,
        is_syncing: p.is_syncing,
        connection_error: p.connection_error,
        maintenance_error: p.maintenance_error,
        phase: p.phase,
        scanning_up_to: p.scanning_up_to,
        maintenance_queue_len: p.maintenance_queue_len,
        scan_progress_num: p.scan_progress_num,
        scan_progress_den: p.scan_progress_den,
        recovery_progress_num: p.recovery_progress_num,
        recovery_progress_den: p.recovery_progress_den,
        blocks_scanned: p.blocks_scanned,
        blocks_total: p.blocks_total,
    })
}

pub fn engine_sync_events(sink: StreamSink<EngineSyncEvent>) -> Result<()> {
    let mut receiver = engine::sync::subscribe_events();
    // Send a definitive startup marker so Dart can confirm the event pipeline
    // is actually wired up end-to-end in the binary the user is running.
    let _ = sink.add(EngineSyncEvent {
        event_type: "engine_log".to_string(),
        phase: None,
        synced_height: 0,
        latest_height: 0,
        maintenance_queue_len: 0,
        txid: None,
        status: None,
        scope: None,
        message: Some(format!(
            "engine_sync_events subscribed at {}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_secs())
                .unwrap_or(0)
        )),
        scan_progress_num: 0,
        scan_progress_den: 0,
        recovery_progress_num: 0,
        recovery_progress_den: 0,
        blocks_scanned: 0,
        blocks_total: 0,
    });
    // Use a dedicated OS thread + blocking_recv. tokio::spawn from a sync
    // FRB function has no current runtime, so the async task would never
    // execute. A plain std::thread + broadcast::Receiver::blocking_recv
    // works regardless of FRB's threading model.
    std::thread::spawn(move || {
        let mut forwarded: u64 = 0;
        let mut lagged_total: u64 = 0;
        loop {
            match receiver.blocking_recv() {
                Ok(event) => {
                    forwarded += 1;
                    let _ = sink.add(EngineSyncEvent {
                        event_type: event.event_type,
                        phase: event.phase,
                        synced_height: event.synced_height,
                        latest_height: event.latest_height,
                        maintenance_queue_len: event.maintenance_queue_len,
                        txid: event.txid,
                        status: event.status,
                        scope: event.scope,
                        message: event.message,
                        scan_progress_num: event.scan_progress_num,
                        scan_progress_den: event.scan_progress_den,
                        recovery_progress_num: event.recovery_progress_num,
                        recovery_progress_den: event.recovery_progress_den,
                        blocks_scanned: event.blocks_scanned,
                        blocks_total: event.blocks_total,
                    });
                    if forwarded % 200 == 0 {
                        let _ = sink.add(EngineSyncEvent {
                            event_type: "engine_log".to_string(),
                            phase: None,
                            synced_height: 0,
                            latest_height: 0,
                            maintenance_queue_len: 0,
                            txid: None,
                            status: None,
                            scope: None,
                            message: Some(format!(
                                "event pipeline: forwarded={} lagged={}",
                                forwarded, lagged_total
                            )),
                            scan_progress_num: 0,
                            scan_progress_den: 0,
                            recovery_progress_num: 0,
                            recovery_progress_den: 0,
                            blocks_scanned: 0,
                            blocks_total: 0,
                        });
                    }
                }
                Err(tokio::sync::broadcast::error::RecvError::Lagged(n)) => {
                    lagged_total += n;
                    let _ = sink.add(EngineSyncEvent {
                        event_type: "engine_log".to_string(),
                        phase: None,
                        synced_height: 0,
                        latest_height: 0,
                        maintenance_queue_len: 0,
                        txid: None,
                        status: None,
                        scope: None,
                        message: Some(format!(
                            "event pipeline: lagged, dropped={} (total lagged={})",
                            n, lagged_total
                        )),
                        scan_progress_num: 0,
                        scan_progress_den: 0,
                        recovery_progress_num: 0,
                        recovery_progress_den: 0,
                        blocks_scanned: 0,
                        blocks_total: 0,
                    });
                    continue;
                }
                Err(tokio::sync::broadcast::error::RecvError::Closed) => break,
            }
        }
    });
    Ok(())
}

pub async fn engine_enhance_transaction(txid: String) -> Result<()> {
    engine::sync::enhance_transaction(&txid).await
}

/// Sync progress reported to Dart.
pub struct EngineSyncProgress {
    pub synced_height: u32,
    pub latest_height: u32,
    pub is_syncing: bool,
    pub connection_error: Option<String>,
    pub maintenance_error: Option<String>,
    pub phase: String,
    pub scanning_up_to: u32,
    pub maintenance_queue_len: u32,
    pub scan_progress_num: u64,
    pub scan_progress_den: u64,
    pub recovery_progress_num: u64,
    pub recovery_progress_den: u64,
    /// Blocks scanned this session across every priority (ChainTip,
    /// Historic, FoundNote, Verify). Together with `blocks_total` this is
    /// the user-facing progress signal — it advances smoothly through
    /// ChainTip pre-scan, when `synced_height` is still pinned at the
    /// wallet birthday.
    pub blocks_scanned: u64,
    pub blocks_total: u64,
}

pub struct EngineSyncEvent {
    pub event_type: String,
    pub phase: Option<String>,
    pub synced_height: u32,
    pub latest_height: u32,
    pub maintenance_queue_len: u32,
    pub txid: Option<String>,
    pub status: Option<String>,
    pub scope: Option<String>,
    pub message: Option<String>,
    pub scan_progress_num: u64,
    pub scan_progress_den: u64,
    pub recovery_progress_num: u64,
    pub recovery_progress_den: u64,
    pub blocks_scanned: u64,
    pub blocks_total: u64,
}

// ---------------------------------------------------------------------------
// Background sync for inactive wallets
// ---------------------------------------------------------------------------

pub async fn engine_register_inactive_wallet(data_dir: String) -> Result<()> {
    engine::sync::register_inactive_wallet(&data_dir).await;
    Ok(())
}

pub async fn engine_unregister_inactive_wallet(data_dir: String) -> Result<()> {
    engine::sync::unregister_inactive_wallet(&data_dir).await;
    Ok(())
}

pub async fn engine_clear_inactive_wallets() -> Result<()> {
    engine::sync::clear_inactive_wallets().await;
    Ok(())
}

// ---------------------------------------------------------------------------
// Send
// ---------------------------------------------------------------------------

/// Step 1: Create a proposal and return exact fee info.
/// When `is_max` is true, `amount` is ignored and the SDK computes the max sendable.
/// When `priority` is true, a 4x marginal fee is applied for faster confirmation.
pub async fn engine_propose_send(
    address: String,
    amount: u64,
    memo: Option<String>,
    is_max: bool,
    priority: bool,
) -> Result<ProposalResult> {
    let (send_amount, fee, is_exact) =
        engine::send::propose_send(&address, amount, memo, is_max, priority).await?;
    Ok(ProposalResult {
        send_amount,
        fee,
        is_exact,
    })
}

/// Proposal result returned to Dart.
pub struct ProposalResult {
    pub send_amount: u64,
    pub fee: u64,
    pub is_exact: bool,
}

/// Create a proved PCZT from the pending proposal.
///
/// This consumes the same pending proposal created by [`engine_propose_send`],
/// but stops before signing so a hardware signer or FROST ceremony can add
/// spend authorization signatures.
pub async fn engine_create_pczt() -> Result<Vec<u8>> {
    engine::send::create_pczt().await
}

/// Create a proved PCZT for transparent -> shielded funds.
pub async fn engine_create_shield_pczt() -> Result<Vec<u8>> {
    engine::send::create_shield_pczt().await
}

/// Store a fully signed PCZT back into the wallet DB and return the txid.
pub async fn engine_store_signed_pczt(signed_pczt_bytes: Vec<u8>) -> Result<String> {
    engine::send::store_signed_pczt(&signed_pczt_bytes).await
}

// ---------------------------------------------------------------------------
// FROST threshold signing
// ---------------------------------------------------------------------------

pub struct EngineFrostDkgRound1Result {
    pub participant_id: u16,
    pub secret_package: String,
    pub round1_package: String,
}

impl From<zipher_engine::frost::FrostDkgRound1Result> for EngineFrostDkgRound1Result {
    fn from(v: zipher_engine::frost::FrostDkgRound1Result) -> Self {
        Self {
            participant_id: v.participant_id,
            secret_package: v.secret_package,
            round1_package: v.round1_package,
        }
    }
}

pub struct EngineFrostParticipantPackage {
    pub participant_id: u16,
    pub package: String,
}

fn packages_to_map(packages: Vec<EngineFrostParticipantPackage>) -> BTreeMap<u16, String> {
    packages
        .into_iter()
        .map(|p| (p.participant_id, p.package))
        .collect()
}

fn packages_from_map(map: BTreeMap<u16, String>) -> Vec<EngineFrostParticipantPackage> {
    map.into_iter()
        .map(|(participant_id, package)| EngineFrostParticipantPackage {
            participant_id,
            package,
        })
        .collect()
}

pub struct EngineFrostDkgRound2Result {
    pub secret_package: String,
    pub round2_packages: Vec<EngineFrostParticipantPackage>,
}

impl From<zipher_engine::frost::FrostDkgRound2Result> for EngineFrostDkgRound2Result {
    fn from(v: zipher_engine::frost::FrostDkgRound2Result) -> Self {
        Self {
            secret_package: v.secret_package,
            round2_packages: packages_from_map(v.round2_packages),
        }
    }
}

pub struct EngineFrostDkgCompleteResult {
    pub participant_id: u16,
    pub key_package: String,
    pub public_key_package: String,
    pub group_public_key_hex: String,
}

impl From<zipher_engine::frost::FrostDkgCompleteResult> for EngineFrostDkgCompleteResult {
    fn from(v: zipher_engine::frost::FrostDkgCompleteResult) -> Self {
        Self {
            participant_id: v.participant_id,
            key_package: v.key_package,
            public_key_package: v.public_key_package,
            group_public_key_hex: v.group_public_key_hex,
        }
    }
}

pub struct EngineFrostSigningRound1Result {
    pub participant_id: u16,
    pub signing_nonces: String,
    pub signing_commitments: String,
}

impl From<zipher_engine::frost::FrostSigningRound1Result> for EngineFrostSigningRound1Result {
    fn from(v: zipher_engine::frost::FrostSigningRound1Result) -> Self {
        Self {
            participant_id: v.participant_id,
            signing_nonces: v.signing_nonces,
            signing_commitments: v.signing_commitments,
        }
    }
}

pub struct EngineFrostRandomizerResult {
    pub randomizer_hex: String,
    pub randomizer_point_hex: String,
}

impl From<zipher_engine::frost::FrostRandomizerResult> for EngineFrostRandomizerResult {
    fn from(v: zipher_engine::frost::FrostRandomizerResult) -> Self {
        Self {
            randomizer_hex: v.randomizer_hex,
            randomizer_point_hex: v.randomizer_point_hex,
        }
    }
}

pub struct EngineFrostAggregateResult {
    pub signature_hex: String,
}

impl From<zipher_engine::frost::FrostAggregateResult> for EngineFrostAggregateResult {
    fn from(v: zipher_engine::frost::FrostAggregateResult) -> Self {
        Self {
            signature_hex: v.signature_hex,
        }
    }
}

pub struct EngineFrostWalletView {
    pub ufvk: String,
    pub address: String,
    pub group_public_key_hex: String,
    pub orchard_fvk_hex: String,
}

pub struct EngineFrostRelayIdentity {
    pub private_key_hex: String,
    pub public_key_hex: String,
}

impl From<zipher_engine::frost::FrostRelayIdentity> for EngineFrostRelayIdentity {
    fn from(v: zipher_engine::frost::FrostRelayIdentity) -> Self {
        Self {
            private_key_hex: v.private_key_hex,
            public_key_hex: v.public_key_hex,
        }
    }
}

pub struct EngineFrostRelayLoginProof {
    pub pubkey_hex: String,
    pub signature_hex: String,
}

impl From<zipher_engine::frost::FrostRelayLoginProof> for EngineFrostRelayLoginProof {
    fn from(v: zipher_engine::frost::FrostRelayLoginProof) -> Self {
        Self {
            pubkey_hex: v.pubkey_hex,
            signature_hex: v.signature_hex,
        }
    }
}

impl From<zipher_engine::frost::FrostWalletView> for EngineFrostWalletView {
    fn from(v: zipher_engine::frost::FrostWalletView) -> Self {
        Self {
            ufvk: v.ufvk,
            address: v.address,
            group_public_key_hex: v.group_public_key_hex,
            orchard_fvk_hex: v.orchard_fvk_hex,
        }
    }
}

pub struct EngineFrostPcztActionRequest {
    pub action_index: u32,
    pub sighash_hex: String,
    pub randomizer_hex: String,
    pub randomizer_point_hex: String,
}

pub struct EngineFrostPcztSigningRequest {
    pub orchard_actions: Vec<EngineFrostPcztActionRequest>,
}

impl From<zipher_engine::frost::FrostPcztSigningRequest> for EngineFrostPcztSigningRequest {
    fn from(v: zipher_engine::frost::FrostPcztSigningRequest) -> Self {
        Self {
            orchard_actions: v
                .orchard_actions
                .into_iter()
                .map(|a| EngineFrostPcztActionRequest {
                    action_index: a.action_index as u32,
                    sighash_hex: a.sighash_hex,
                    randomizer_hex: a.randomizer_hex,
                    randomizer_point_hex: a.randomizer_point_hex,
                })
                .collect(),
        }
    }
}

pub struct EngineFrostActionSignature {
    pub action_index: u32,
    pub signature_hex: String,
}

pub fn engine_frost_dkg_init(
    participant_id: u16,
    max_signers: u16,
    min_signers: u16,
) -> Result<EngineFrostDkgRound1Result> {
    Ok(zipher_engine::frost::frost_dkg_init(participant_id, max_signers, min_signers)?.into())
}

pub fn engine_frost_dkg_round2(
    secret_package: String,
    round1_packages: Vec<EngineFrostParticipantPackage>,
) -> Result<EngineFrostDkgRound2Result> {
    Ok(
        zipher_engine::frost::frost_dkg_round2(secret_package, packages_to_map(round1_packages))?
            .into(),
    )
}

pub fn engine_frost_dkg_round3(
    secret_package: String,
    round1_packages: Vec<EngineFrostParticipantPackage>,
    round2_packages: Vec<EngineFrostParticipantPackage>,
) -> Result<EngineFrostDkgCompleteResult> {
    Ok(zipher_engine::frost::frost_dkg_round3(
        secret_package,
        packages_to_map(round1_packages),
        packages_to_map(round2_packages),
    )?
    .into())
}

pub fn engine_frost_sign_round1(key_package: String) -> Result<EngineFrostSigningRound1Result> {
    Ok(zipher_engine::frost::frost_sign_round1(key_package)?.into())
}

pub fn engine_frost_create_signing_package(
    message_hex: String,
    commitments: Vec<EngineFrostParticipantPackage>,
) -> Result<String> {
    zipher_engine::frost::frost_create_signing_package(message_hex, packages_to_map(commitments))
}

pub fn engine_frost_create_randomizer(
    public_key_package: String,
) -> Result<EngineFrostRandomizerResult> {
    Ok(zipher_engine::frost::frost_create_randomizer(public_key_package)?.into())
}

pub fn engine_frost_sign_round2(
    signing_package: String,
    signing_nonces: String,
    key_package: String,
    randomizer_point_hex: String,
) -> Result<String> {
    zipher_engine::frost::frost_sign_round2(
        signing_package,
        signing_nonces,
        key_package,
        randomizer_point_hex,
    )
}

pub fn engine_frost_aggregate(
    signing_package: String,
    signature_shares: Vec<EngineFrostParticipantPackage>,
    public_key_package: String,
    randomizer_hex: String,
) -> Result<EngineFrostAggregateResult> {
    Ok(zipher_engine::frost::frost_aggregate(
        signing_package,
        packages_to_map(signature_shares),
        public_key_package,
        randomizer_hex,
    )?
    .into())
}

pub fn engine_frost_pczt_signing_request(
    pczt_bytes: Vec<u8>,
) -> Result<EngineFrostPcztSigningRequest> {
    Ok(zipher_engine::frost::frost_pczt_signing_request(pczt_bytes)?.into())
}

pub fn engine_frost_pczt_apply_signatures(
    pczt_bytes: Vec<u8>,
    orchard_signatures: Vec<EngineFrostActionSignature>,
) -> Result<Vec<u8>> {
    let signatures = orchard_signatures
        .into_iter()
        .map(|s| (s.action_index as usize, s.signature_hex))
        .collect();
    zipher_engine::frost::frost_pczt_apply_signatures(pczt_bytes, signatures)
}

pub fn engine_frost_derive_ufvk(group_public_key_hex: String) -> Result<String> {
    zipher_engine::frost::frost_derive_ufvk(group_public_key_hex)
}

pub fn engine_frost_key_refresh(key_package: String, new_signer_count: u16) -> Result<String> {
    zipher_engine::frost::frost_key_refresh(key_package, new_signer_count)
}

pub fn engine_frost_create_view_from_group_key(
    group_public_key_hex: String,
    chain_type: ChainType,
) -> Result<EngineFrostWalletView> {
    Ok(zipher_engine::frost::frost_create_view_from_group_key(
        group_public_key_hex,
        to_network(chain_type),
    )?
    .into())
}

pub fn engine_frost_relay_generate_identity() -> Result<EngineFrostRelayIdentity> {
    Ok(zipher_engine::frost::frost_relay_generate_identity()?.into())
}

pub fn engine_frost_relay_sign_challenge(
    private_key_hex: String,
    public_key_hex: String,
    challenge: String,
) -> Result<EngineFrostRelayLoginProof> {
    Ok(zipher_engine::frost::frost_relay_sign_challenge(
        private_key_hex,
        public_key_hex,
        challenge,
    )?
    .into())
}

pub fn engine_frost_relay_encrypt(
    sender_private_key_hex: String,
    recipient_public_key_hex: String,
    message_hex: String,
) -> Result<String> {
    zipher_engine::frost::frost_relay_encrypt(
        sender_private_key_hex,
        recipient_public_key_hex,
        message_hex,
    )
}

pub fn engine_frost_relay_decrypt(
    recipient_private_key_hex: String,
    sender_public_key_hex: String,
    encrypted_hex: String,
) -> Result<String> {
    zipher_engine::frost::frost_relay_decrypt(
        recipient_private_key_hex,
        sender_public_key_hex,
        encrypted_hex,
    )
}

/// Step 2: Confirm and broadcast the previously proposed transaction.
pub async fn engine_confirm_send(seed_phrase: String) -> Result<String> {
    use secrecy::SecretString;
    let secret_seed = SecretString::new(seed_phrase);
    engine::send::confirm_send(&secret_seed).await
}

/// Legacy single-step send (still used for multi-recipient or fallback).
pub async fn engine_send_payment(
    seed_phrase: String,
    address: String,
    amount: u64,
    memo: Option<String>,
) -> Result<String> {
    use secrecy::SecretString;
    let secret_seed = SecretString::new(seed_phrase);
    engine::send::send_payment(&secret_seed, vec![(address, amount, memo)]).await
}

/// Shield transparent funds into the shielded pool.
pub async fn engine_shield_funds(seed_phrase: String) -> Result<String> {
    use secrecy::SecretString;
    let secret_seed = SecretString::new(seed_phrase);
    engine::send::shield_funds(&secret_seed).await
}

// ---------------------------------------------------------------------------
// Transaction history
// ---------------------------------------------------------------------------

pub async fn engine_get_transactions() -> Result<Vec<EngineTransactionRecord>> {
    let txs = engine::query::get_transactions().await?;
    Ok(txs.into_iter().map(|t| t.into()).collect())
}

pub struct EngineTransactionRecord {
    pub txid: String,
    pub height: u32,
    pub timestamp: u32,
    pub value: i64,
    pub kind: String,
    pub fee: Option<u64>,
    pub memo: Option<String>,
    pub expired_unmined: bool,
}

impl From<zipher_engine::types::EngineTransactionRecord> for EngineTransactionRecord {
    fn from(t: zipher_engine::types::EngineTransactionRecord) -> Self {
        Self {
            txid: t.txid,
            height: t.height,
            timestamp: t.timestamp,
            value: t.value,
            kind: t.kind,
            fee: t.fee,
            memo: t.memo,
            expired_unmined: t.expired_unmined,
        }
    }
}

// ---------------------------------------------------------------------------
// EVM / OWS — On-device EVM signing via ows-signer
// ---------------------------------------------------------------------------

/// Derive the EVM (BSC/ETH) address from the wallet's BIP-39 seed phrase.
/// Uses the standard BIP-44 path m/44'/60'/0'/0/0.
pub fn engine_derive_evm_address(seed_phrase: String) -> Result<String> {
    zipher_engine::ows::derive_evm_address(&seed_phrase)
}

/// Derive addresses for EVM, Solana, and Bitcoin from a single seed phrase.
/// All derivation is CPU-only (no network calls).
pub fn engine_derive_multi_chain_addresses(
    seed_phrase: String,
) -> Result<EngineMultiChainAddresses> {
    let addrs = zipher_engine::ows::derive_all_addresses(&seed_phrase)?;
    Ok(EngineMultiChainAddresses {
        evm: addrs.evm,
        solana: addrs.solana,
        bitcoin: addrs.bitcoin,
    })
}

/// Multi-chain addresses returned to Dart.
pub struct EngineMultiChainAddresses {
    pub evm: String,
    pub solana: String,
    pub bitcoin: String,
}

/// Sign an unsigned EVM transaction and return the broadcast-ready signed bytes.
pub fn engine_sign_evm_tx(seed_phrase: String, unsigned_tx_hex: String) -> Result<String> {
    let unsigned_bytes =
        hex::decode(&unsigned_tx_hex).map_err(|e| anyhow::anyhow!("Invalid hex: {}", e))?;
    let signed_bytes = zipher_engine::ows::sign_evm_tx(&seed_phrase, &unsigned_bytes)?;
    Ok(hex::encode(signed_bytes))
}

/// Sign an unsigned EVM transaction, broadcast it via JSON-RPC, and return the tx hash.
pub async fn engine_sign_and_broadcast_evm_tx(
    seed_phrase: String,
    unsigned_tx_hex: String,
    rpc_url: String,
) -> Result<String> {
    let unsigned_bytes =
        hex::decode(&unsigned_tx_hex).map_err(|e| anyhow::anyhow!("Invalid hex: {}", e))?;
    zipher_engine::ows::sign_and_broadcast_evm_tx(&seed_phrase, &unsigned_bytes, &rpc_url).await
}

// ---------------------------------------------------------------------------
// On-device LLM — candle-based GGUF inference
// ---------------------------------------------------------------------------

/// Load a GGUF model and tokenizer from the given file paths.
/// Must be called before `engine_llm_infer`. Blocks while loading (~1-5s).
pub fn engine_llm_load(model_path: String, tokenizer_path: String) -> Result<()> {
    zipher_engine::llm::load_model(&model_path, &tokenizer_path)
}

/// Unload the LLM from memory.
pub fn engine_llm_unload() -> Result<()> {
    zipher_engine::llm::unload_model()
}

/// Check if an LLM model is currently loaded.
pub fn engine_llm_is_loaded() -> bool {
    zipher_engine::llm::is_model_loaded()
}

/// Run LLM inference on a raw prompt. Returns the generated text.
pub fn engine_llm_infer(prompt: String, max_tokens: u32, temperature: f64) -> Result<String> {
    zipher_engine::llm::infer(&prompt, max_tokens, temperature)
}

/// Build an intent-classification prompt from the user's natural language input.
/// The returned prompt is ready to pass to `engine_llm_infer`.
pub fn engine_llm_build_intent_prompt(user_input: String) -> String {
    zipher_engine::llm::build_intent_prompt(&user_input)
}

/// Get the recommended model filename, display name, and expected size in bytes.
pub fn engine_llm_recommended_model() -> EngineLlmModelInfo {
    let (filename, name, size) = zipher_engine::llm::recommended_model();
    EngineLlmModelInfo {
        filename: filename.to_string(),
        display_name: name.to_string(),
        size_bytes: size,
    }
}

/// Info about the recommended LLM model.
pub struct EngineLlmModelInfo {
    pub filename: String,
    pub display_name: String,
    pub size_bytes: u64,
}

// ---------------------------------------------------------------------------
// Polymarket — EIP-712 signing for CLOB orders and auth
// ---------------------------------------------------------------------------

/// Sign the CLOB L1 auth message to derive API credentials.
/// Returns (polygon_address, eip712_signature_hex).
pub fn engine_polymarket_sign_auth(
    seed_phrase: String,
    timestamp: u64,
    nonce: u64,
) -> Result<PolymarketAuthResult> {
    let (address, signature) =
        zipher_engine::polymarket::sign_clob_auth(&seed_phrase, timestamp, nonce)?;
    Ok(PolymarketAuthResult { address, signature })
}

pub struct PolymarketAuthResult {
    pub address: String,
    pub signature: String,
}

/// Sign a Polymarket CLOB V2 order with EIP-712.
/// Returns the hex-encoded signature.
pub fn engine_polymarket_sign_order(
    seed_phrase: String,
    salt: String,
    maker: String,
    signer: String,
    token_id: String,
    maker_amount: String,
    taker_amount: String,
    side: u8,
    signature_type: u8,
    timestamp: String,
    metadata: String,
    builder: String,
    neg_risk: bool,
) -> Result<String> {
    let order = zipher_engine::polymarket::PolymarketOrder {
        salt,
        maker,
        signer,
        token_id,
        maker_amount,
        taker_amount,
        side,
        signature_type,
        timestamp,
        metadata,
        builder,
    };
    zipher_engine::polymarket::sign_order(&seed_phrase, &order, neg_risk)
}

/// Whether one Gamma `/markets` or nested event market object passes the default
/// tradability filter (same rules as `zipher-cli polymarket list`). Pure JSON — no wallet.
pub fn engine_polymarket_gamma_market_passes_quality_filter(
    market_json: String,
    relaxed: bool,
) -> bool {
    match serde_json::from_str::<zipher_engine::polymarket::PolymarketMarket>(&market_json) {
        Ok(m) => zipher_engine::polymarket::polymarket_market_passes_quality(&m, relaxed),
        Err(_) => false,
    }
}

/// Polymarket discovery: Gamma events + Rust grouping/quality (same as CLI `polymarket list`).
/// Returns JSON `PolymarketDiscoverySummary`.
pub async fn engine_polymarket_discover(keyword: Option<String>, limit: u32) -> Result<String> {
    let summary =
        zipher_engine::polymarket::polymarket_discover(keyword.as_deref(), limit, false).await?;
    Ok(serde_json::to_string(&summary)?)
}

/// Polymarket open positions for `user` (0x + 40 hex) via public Data API.
/// Returns JSON array of `PolymarketPosition`.
pub async fn engine_polymarket_get_positions(address: String) -> Result<String> {
    let positions = zipher_engine::polymarket::polymarket_get_positions(&address).await?;
    Ok(serde_json::to_string(&positions)?)
}

// ---------------------------------------------------------------------------
// EVM shared types
// ---------------------------------------------------------------------------

pub struct EvmFees {
    pub max_priority_fee_per_gas: u64,
    pub max_fee_per_gas: u64,
}

pub struct EvmReceipt {
    pub success: bool,
    pub block_number: u64,
    pub gas_used: u64,
    pub tx_hash: String,
}

// ---------------------------------------------------------------------------
// EVM Swap — same-chain token swaps via ParaSwap (DEX aggregator)
// ---------------------------------------------------------------------------

/// Quote result returned to Dart.
pub struct EvmSwapQuoteResult {
    pub src_token: String,
    pub src_amount: String,
    pub src_decimals: u32,
    pub dest_token: String,
    pub dest_amount: String,
    pub dest_decimals: u32,
    /// Serialized JSON of the priceRoute (opaque to Dart, passed back to execute).
    pub price_route_json: String,
    pub token_transfer_proxy: String,
}

/// Get a ParaSwap quote for a same-chain EVM swap.
pub async fn engine_evm_swap_quote(
    chain_id: u64,
    src_token: String,
    src_decimals: u32,
    dest_token: String,
    dest_decimals: u32,
    amount_raw: String,
    user_address: String,
) -> Result<EvmSwapQuoteResult> {
    let quote = zipher_engine::evm_swap::get_quote(
        chain_id,
        &src_token,
        src_decimals,
        &dest_token,
        dest_decimals,
        &amount_raw,
        &user_address,
    )
    .await?;

    Ok(EvmSwapQuoteResult {
        src_token: quote.src_token,
        src_amount: quote.src_amount,
        src_decimals: quote.src_decimals,
        dest_token: quote.dest_token,
        dest_amount: quote.dest_amount,
        dest_decimals: quote.dest_decimals,
        price_route_json: serde_json::to_string(&quote.price_route_json)?,
        token_transfer_proxy: quote.token_transfer_proxy,
    })
}

/// Swap execution result returned to Dart.
pub struct EvmSwapExecuteResult {
    pub tx_hash: String,
    pub success: bool,
    pub block_number: u64,
    pub gas_used: u64,
    pub src_amount: String,
    pub dest_amount_expected: String,
}

/// Execute a full same-chain EVM swap: quote -> approve (if ERC-20) -> build -> sign -> broadcast -> wait.
/// All RLP encoding, signing, and broadcasting happens in Rust.
pub async fn engine_evm_swap_execute(
    rpc_url: String,
    seed_phrase: String,
    chain_id: u64,
    user_address: String,
    src_token: String,
    src_decimals: u32,
    dest_token: String,
    dest_decimals: u32,
    amount_raw: String,
    slippage_bps: u32,
) -> Result<EvmSwapExecuteResult> {
    let params = zipher_engine::evm_swap::SwapParams {
        rpc_url,
        seed_phrase,
        chain_id,
        user_address,
        src_token,
        src_decimals,
        dest_token,
        dest_decimals,
        amount_raw,
        slippage_bps,
    };

    let result = zipher_engine::evm_swap::execute_swap(&params).await?;

    Ok(EvmSwapExecuteResult {
        tx_hash: result.tx_hash,
        success: result.receipt.status,
        block_number: result.receipt.block_number,
        gas_used: result.receipt.gas_used,
        src_amount: result.src_amount,
        dest_amount_expected: result.dest_amount_expected,
    })
}

// ---------------------------------------------------------------------------
// CipherPay invoices (customer-side; merchant create stays off mobile FFI)
// ---------------------------------------------------------------------------

/// A CipherPay invoice as the customer sees it.
///
/// Returned by [`engine_check_invoice`]. Read-only — does not touch the seed
/// and only requires a single anonymous GET to `api.cipherpay.app`.
pub struct EngineInvoice {
    /// CipherPay invoice UUID.
    pub id: String,
    /// `"pending" | "detected" | "confirmed" | "expired" | "cancelled"`.
    pub status: String,
    /// Amount priced in ZEC at invoice creation time.
    pub price_zec: f64,
    /// Same amount priced in EUR (CipherPay backs invoices with EUR rates).
    pub price_eur: f64,
    /// Shielded ZEC address the buyer must pay.
    pub payment_address: String,
    /// Memo code in the form `CP-XXXXXXXX`. Buyer's tx must carry this memo
    /// to be auto-detected by CipherPay.
    pub memo_code: String,
    /// ZEC actually received (set once the tx is detected).
    pub received_zec: Option<f64>,
    /// Mainnet txid that paid the invoice, once detected.
    pub detected_txid: Option<String>,
    /// ISO-8601 expiry timestamp.
    pub expires_at: String,
    /// ISO-8601 creation timestamp.
    pub created_at: String,
    /// Merchant-supplied product name. May be empty for ad-hoc invoices.
    pub product_name: Option<String>,
}

/// Fetch a CipherPay invoice by UUID or memo code (e.g. `CP-A7F3B2C1`).
///
/// SAFETY/PRIVACY: the customer's IP is exposed to `api.cipherpay.app` for the
/// duration of this call. Callers should only invoke this in response to an
/// explicit user action (scanning a QR, tapping a checkout link, manually
/// pasting an invoice id). Never poll silently in the background.
pub async fn engine_check_invoice(id_or_memo: String) -> Result<EngineInvoice> {
    let invoice = zipher_engine::cipherpay::check_invoice(&id_or_memo).await?;
    Ok(EngineInvoice {
        id: invoice.id,
        status: invoice.status,
        price_zec: invoice.price_zec,
        price_eur: invoice.price_eur,
        payment_address: invoice.payment_address,
        memo_code: invoice.memo_code,
        received_zec: invoice.received_zec,
        detected_txid: invoice.detected_txid,
        expires_at: invoice.expires_at,
        created_at: invoice.created_at,
        product_name: invoice.product_name,
    })
}

// ---------------------------------------------------------------------------
// Shielded voting
// ---------------------------------------------------------------------------
// TEMPORARILY DISABLED for Ironwood (NU6.3): zcash_voting pins orchard 0.14
// which conflicts with the required orchard 0.15.0-pre.1.
// All voting FFI functions return errors until zcash_voting is updated.

/// Warm the proving key caches for voting ZKPs. Takes ~30s.
/// Call once from a background isolate at app startup.
pub fn engine_vote_warm_caches() {
    // no-op while voting is disabled
}

/// Derive the voting seed from raw BIP-39 seed bytes (deterministic).
pub fn engine_vote_derive_seed(_wallet_seed: Vec<u8>) -> Vec<u8> {
    vec![]
}

/// Derive the voting seed from a BIP-39 mnemonic phrase.
pub fn engine_vote_derive_seed_from_phrase(_seed_phrase: String) -> Result<Vec<u8>> {
    Err(anyhow::anyhow!("Voting is temporarily disabled during the Ironwood (NU6.3) upgrade"))
}

/// Derive a voting hotkey from a 32-byte voting seed.
pub fn engine_vote_derive_hotkey(
    _voting_seed: Vec<u8>,
) -> Result<EngineVotingHotkey> {
    Err(anyhow::anyhow!("Voting is temporarily disabled during the Ironwood (NU6.3) upgrade"))
}

#[derive(Debug, Clone)]
pub struct EngineVotingHotkey {
    pub secret_key: Vec<u8>,
    pub public_key: Vec<u8>,
    pub address: String,
}

/// Check voting eligibility at a given snapshot height.
pub async fn engine_vote_check_eligibility(
    _snapshot_height: u64,
) -> Result<EngineVotingEligibility> {
    Err(anyhow::anyhow!("Voting is temporarily disabled during the Ironwood (NU6.3) upgrade"))
}

#[derive(Debug, Clone)]
pub struct EngineVotingEligibility {
    /// Total voting weight in zatoshis.
    pub eligible_weight: u64,
    /// Number of unspent Orchard notes at snapshot.
    pub note_count: u32,
    /// Number of delegation bundles (max 5 notes each).
    pub bundle_count: u32,
}

/// Compute the proposals hash for vote config verification.
pub fn engine_vote_proposals_hash(_proposals_json: String) -> Vec<u8> {
    vec![]
}

/// Perform full delegation flow.
pub async fn engine_vote_delegate(
    _seed_phrase: String,
    _vote_round_id: String,
    _snapshot_height: u64,
    _ea_pk: Vec<u8>,
    _nc_root: Vec<u8>,
    _nf_imt_root: Vec<u8>,
    _pir_url: String,
    _network_id: u32,
) -> Result<Vec<EngineDelegationResult>> {
    Err(anyhow::anyhow!("Voting is temporarily disabled during the Ironwood (NU6.3) upgrade"))
}

#[derive(Debug, Clone)]
pub struct EngineDelegationResult {
    pub proof: Vec<u8>,
    pub rk: Vec<u8>,
    pub nf_signed: Vec<u8>,
    pub cmx_new: Vec<u8>,
    pub van_comm: Vec<u8>,
    pub van_comm_rand: Vec<u8>,
    pub gov_nullifiers: Vec<Vec<u8>>,
    pub spend_auth_sig: Vec<u8>,
    pub sighash: Vec<u8>,
    pub vote_round_id: String,
    pub total_value: u64,
    pub action_bytes: Vec<u8>,
}

/// Build vote commitment (ZKP2) for a single proposal.
pub fn engine_vote_build_commitment(
    _voting_seed: Vec<u8>,
    _network_id: u32,
    _total_note_value: u64,
    _gov_comm_rand: Vec<u8>,
    _voting_round_id: Vec<u8>,
    _ea_pk: Vec<u8>,
    _proposal_id: u32,
    _choice: u32,
    _num_options: u32,
    _van_auth_path: Vec<Vec<u8>>,
    _van_position: u32,
    _anchor_height: u32,
    _proposal_authority: u64,
    _single_share: bool,
) -> Result<EngineVoteCommitment> {
    Err(anyhow::anyhow!("Voting is temporarily disabled during the Ironwood (NU6.3) upgrade"))
}

#[derive(Debug, Clone)]
pub struct EngineVoteCommitment {
    pub van_nullifier: Vec<u8>,
    pub vote_authority_note_new: Vec<u8>,
    pub vote_commitment: Vec<u8>,
    pub proposal_id: u32,
    pub proof: Vec<u8>,
    pub enc_shares: Vec<EngineEncryptedShare>,
    pub anchor_height: u32,
    pub vote_round_id: String,
    pub shares_hash: Vec<u8>,
    pub share_blinds: Vec<Vec<u8>>,
    pub share_comms: Vec<Vec<u8>>,
    pub r_vpk_bytes: Vec<u8>,
    pub alpha_v: Vec<u8>,
}

#[derive(Debug, Clone)]
pub struct EngineEncryptedShare {
    pub c1: Vec<u8>,
    pub c2: Vec<u8>,
    pub share_index: u32,
}

// ---------------------------------------------------------------------------
// Ironwood pool transfer (ZIP 318)
// ---------------------------------------------------------------------------

/// Propose an Orchard -> Ironwood pool transfer with SpendPolicy restriction.
/// Only spends Orchard notes. Sends to own UA (routed to Ironwood post-NU6.3).
/// Returns (send_amount, fee). Use engine_confirm_send to finalize.
pub async fn engine_propose_pool_transfer(
    amount: u64,
    is_max: bool,
) -> Result<ProposalResult> {
    let (amount_zat, fee_zat) = engine::send::propose_pool_transfer(amount, is_max).await?;
    Ok(ProposalResult { send_amount: amount_zat, fee: fee_zat, is_exact: !is_max })
}

/// Determine the next migration round action per the Shielded Labs algorithm.
///
/// Returns the action type ("migrate", "consolidate", or "done"),
/// the amount to migrate (if applicable), and consolidation note count.
///
/// Callers: pass the wallet's largest single Orchard note value and total note count.
pub fn engine_migration_next_round(
    orchard_balance_zat: u64,
    largest_note_zat: u64,
    note_count: u32,
) -> Result<MigrationRoundResult> {
    let round = engine::ironwood::plan_next_round(
        orchard_balance_zat,
        largest_note_zat,
        note_count as usize,
    );
    let action = match round.action {
        engine::ironwood::RoundAction::Migrate => "migrate".to_string(),
        engine::ironwood::RoundAction::Consolidate => "consolidate".to_string(),
        engine::ironwood::RoundAction::Done => "done".to_string(),
    };
    Ok(MigrationRoundResult {
        action,
        amount_zat: round.amount_zat,
        consolidate_count: round.consolidate_count as u32,
    })
}

#[derive(Debug, Clone)]
pub struct MigrationRoundResult {
    pub action: String,
    pub amount_zat: u64,
    pub consolidate_count: u32,
}

/// Generate a cryptographically random delay (in seconds) for the next round.
/// Uses exponential distribution: D = -600 * log2(U), median = 10 minutes.
pub fn engine_migration_random_delay() -> f64 {
    engine::ironwood::random_delay_seconds()
}

/// Record a completed migration round to persistent state.
pub fn engine_migration_record_round(
    data_dir: String,
    amount_zat: u64,
    fee_zat: u64,
    height: u32,
) -> Result<MigrationProgress> {
    let state = engine::ironwood::record_round(&data_dir, amount_zat, fee_zat, height)?;
    Ok(MigrationProgress {
        rounds_completed: state.rounds_completed,
        total_migrated_zat: state.total_migrated_zat,
        total_fees_zat: state.total_fees_zat,
    })
}

#[derive(Debug, Clone)]
pub struct MigrationProgress {
    pub rounds_completed: u32,
    pub total_migrated_zat: u64,
    pub total_fees_zat: u64,
}

/// Plan an Orchard -> Ironwood pool transfer per ZIP 318.
/// Returns a summary with denominations, fees, and duration for user confirmation.
pub fn engine_ironwood_plan(orchard_balance_zat: u64, current_height: u32) -> Result<IronwoodPlan> {
    let plan = engine::ironwood::plan_pool_transfer(orchard_balance_zat, current_height)?;
    Ok(IronwoodPlan {
        orchard_balance_zat: plan.orchard_balance_zat,
        denominations: plan.denominations.into_iter().map(|g| IronwoodDenomGroup {
            denomination_zat: g.denomination_zat,
            count: g.count as u32,
            label: g.label,
        }).collect(),
        total_parts: plan.total_parts as u32,
        total_fee_zat: plan.total_fee_zat,
        estimated_sessions: plan.estimated_sessions as u32,
        estimated_duration_hours: plan.estimated_duration_hours,
        dust_remaining_zat: plan.dust_remaining_zat,
    })
}

/// Confirm and create the transfer schedule. Returns serialized schedule JSON.
pub fn engine_ironwood_confirm(
    orchard_balance_zat: u64,
    current_height: u32,
    tor_enabled: bool,
) -> Result<String> {
    let schedule = engine::ironwood::create_transfer_schedule(
        orchard_balance_zat,
        current_height,
        tor_enabled,
    )?;
    serde_json::to_string(&schedule).map_err(|e| anyhow::anyhow!("Serialize: {}", e))
}

/// Reconcile an in-progress schedule against chain state.
/// Takes the serialized schedule JSON, returns updated JSON + list of invalidated part IDs.
pub fn engine_ironwood_reconcile(
    schedule_json: String,
    current_height: u32,
    confirmed_txids: Vec<String>,
) -> Result<IronwoodReconcileResult> {
    let mut schedule: engine::ironwood::TransferSchedule =
        serde_json::from_str(&schedule_json).map_err(|e| anyhow::anyhow!("Parse: {}", e))?;
    let invalidated = engine::ironwood::reconcile_schedule(&mut schedule, current_height, &confirmed_txids);
    let updated_json = serde_json::to_string(&schedule).map_err(|e| anyhow::anyhow!("Serialize: {}", e))?;
    Ok(IronwoodReconcileResult {
        schedule_json: updated_json,
        invalidated_ids: invalidated,
        is_complete: schedule.status == engine::ironwood::TransferStatus::Complete,
    })
}

/// Background tick: reconcile + advance schedule. Called from Flutter BGTask or on-foreground.
pub fn engine_ironwood_tick(
    data_dir: String,
    current_height: u32,
    confirmed_txids: Vec<String>,
) -> Result<IronwoodTickResult> {
    let result = engine::ironwood::tick(&data_dir, current_height, &confirmed_txids)?;
    Ok(IronwoodTickResult {
        parts_broadcast: result.parts_broadcast,
        parts_confirmed: result.parts_confirmed,
        parts_invalidated: result.parts_invalidated,
        is_complete: result.is_complete,
        next_broadcast_height: result.next_broadcast_height,
    })
}

#[derive(Debug, Clone)]
pub struct IronwoodTickResult {
    pub parts_broadcast: u32,
    pub parts_confirmed: u32,
    pub parts_invalidated: u32,
    pub is_complete: bool,
    pub next_broadcast_height: Option<u32>,
}

#[derive(Debug, Clone)]
pub struct IronwoodPlan {
    pub orchard_balance_zat: u64,
    pub denominations: Vec<IronwoodDenomGroup>,
    pub total_parts: u32,
    pub total_fee_zat: u64,
    pub estimated_sessions: u32,
    pub estimated_duration_hours: f64,
    pub dust_remaining_zat: u64,
}

#[derive(Debug, Clone)]
pub struct IronwoodDenomGroup {
    pub denomination_zat: u64,
    pub count: u32,
    pub label: String,
}

#[derive(Debug, Clone)]
pub struct IronwoodReconcileResult {
    pub schedule_json: String,
    pub invalidated_ids: Vec<u32>,
    pub is_complete: bool,
}

/// Sign a cast-vote transaction using the voting hotkey.
pub fn engine_vote_sign_cast(
    _voting_seed: Vec<u8>,
    _network_id: u32,
    _vote_round_id_hex: String,
    _r_vpk_bytes: Vec<u8>,
    _van_nullifier: Vec<u8>,
    _vote_authority_note_new: Vec<u8>,
    _vote_commitment: Vec<u8>,
    _proposal_id: u32,
    _anchor_height: u32,
    _alpha_v: Vec<u8>,
) -> Result<Vec<u8>> {
    Err(anyhow::anyhow!("Voting is temporarily disabled during the Ironwood (NU6.3) upgrade"))
}

/// Build share payloads for helper server submission.
pub fn engine_vote_build_shares(
    _shares_hash: Vec<u8>,
    _proposal_id: u32,
    _vote_decision: u32,
    _num_options: u32,
    _vc_tree_position: u64,
    _enc_shares_c1: Vec<Vec<u8>>,
    _enc_shares_c2: Vec<Vec<u8>>,
    _enc_shares_indices: Vec<u32>,
    _share_blinds: Vec<Vec<u8>>,
    _share_comms: Vec<Vec<u8>>,
    _single_share: bool,
) -> Result<Vec<EngineSharePayload>> {
    Err(anyhow::anyhow!("Voting is temporarily disabled during the Ironwood (NU6.3) upgrade"))
}

#[derive(Debug, Clone)]
pub struct EngineSharePayload {
    pub shares_hash: Vec<u8>,
    pub proposal_id: u32,
    pub vote_decision: u32,
    pub enc_share_c1: Vec<u8>,
    pub enc_share_c2: Vec<u8>,
    pub enc_share_index: u32,
    pub tree_position: u64,
    pub primary_blind: Vec<u8>,
}

/// Sync the vote commitment tree and generate VAN witnesses for ZKP2.
pub fn engine_vote_sync_tree_and_witness(
    _node_url: String,
    _vote_round_id: String,
    _snapshot_height: u64,
    _ea_pk: Vec<u8>,
    _nc_root: Vec<u8>,
    _nf_imt_root: Vec<u8>,
    _van_positions: Vec<u32>,
) -> Result<Vec<EngineVanWitness>> {
    Err(anyhow::anyhow!("Voting is temporarily disabled during the Ironwood (NU6.3) upgrade"))
}

#[derive(Debug, Clone)]
pub struct EngineVanWitness {
    pub auth_path: Vec<Vec<u8>>,
    pub position: u32,
    pub anchor_height: u32,
}
