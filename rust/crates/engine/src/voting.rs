use std::sync::Arc;

use anyhow::{anyhow, Result};
use ff::PrimeField;
use incrementalmerkletree::Position;
use orchard::{
    keys::{Diversifier, FullViewingKey as OrchardFvk, SpendingKey as OrchardSk},
    note::{ExtractedNoteCommitment, Note, RandomSeed, Rho},
    tree::MerkleHashOrchard,
    value::NoteValue,
};
use pasta_curves::pallas;
use tracing::info;
use zcash_client_backend::data_api::{Account, WalletRead};
use zcash_keys::keys::UnifiedFullViewingKey;
use zcash_protocol::consensus::{BlockHeight, BranchId, Network as ZcashNetwork};
use zip32::Scope;

use zcash_voting::types::{
    DelegationProofResult, GovernancePczt, VoteCommitmentBundle, WitnessData, WireEncryptedShare,
};
use zcash_voting::HyperTransport;

use crate::{open_cipher_conn, open_wallet_db, wallet::fetch_tree_state, ENGINE};

pub use zcash_voting::types::{
    CastVoteSignature, ChunkResult, NoteInfo, SharePayload, VotingHotkey, VotingRoundParams,
};

// =========================================================================
// Foundational helpers (unchanged from scaffolding)
// =========================================================================

/// Pre-warm the proving key caches for ZKP1 (delegation) and ZKP2 (vote commitment).
/// Takes ~30s on device; call from a background thread at app startup.
pub fn warm_proving_caches() {
    ensure_rustls_provider();
    zcash_voting::warm_proving_caches();
}

/// Install the rustls ring crypto provider (required before any HTTPS transport).
/// Safe to call multiple times -- subsequent calls are no-ops.
fn ensure_rustls_provider() {
    let _ = rustls::crypto::ring::default_provider().install_default();
}

/// Derive a voting hotkey from a 32+ byte seed.
pub fn derive_hotkey(seed: &[u8]) -> Result<VotingHotkey> {
    zcash_voting::hotkey::generate_hotkey(seed).map_err(|e| anyhow!("{}", e))
}

/// Derive a deterministic 32-byte voting seed from the wallet's BIP-39 seed.
/// Uses Blake2b with a distinct personalization so the voting seed is
/// stable across reinstalls without requiring separate backup.
pub fn derive_voting_seed(wallet_seed: &[u8]) -> [u8; 32] {
    let hash = blake2b_simd::Params::new()
        .hash_length(32)
        .personal(b"ZipherVotingSeed")
        .hash(wallet_seed);
    let mut out = [0u8; 32];
    out.copy_from_slice(hash.as_bytes());
    out
}

/// Derive the 43-byte Orchard raw address for the voting hotkey.
/// The PCZT builder and ZKP1 prover both require a proper Orchard address
/// (11-byte diversifier + 32-byte pk_d), not the truncated sv1 placeholder.
fn derive_hotkey_orchard_address(voting_seed: &[u8; 32]) -> Result<Vec<u8>> {
    let sk = OrchardSk::from_bytes(*voting_seed)
        .into_option()
        .ok_or_else(|| anyhow!("voting seed is not a valid Orchard SpendingKey"))?;
    let fvk = OrchardFvk::from(&sk);
    let addr = fvk.address_at(0u32, Scope::External);
    Ok(addr.to_raw_address_bytes().to_vec())
}

/// Extract unspent Orchard notes from the wallet DB at or below `snapshot_height`.
pub async fn get_eligible_notes(snapshot_height: u64) -> Result<Vec<NoteInfo>> {
    let engine = ENGINE.lock().await;
    let eng = engine
        .as_ref()
        .ok_or_else(|| anyhow!("Engine not initialized"))?;

    let db = open_wallet_db(&eng.db_data_path, eng.params, &eng.db_cipher_key)?;
    let account_ids = db
        .get_account_ids()
        .map_err(|e| anyhow!("get_account_ids: {:?}", e))?;
    if account_ids.is_empty() {
        return Ok(vec![]);
    }

    let mut ufvk_strings = Vec::new();
    for account_id in &account_ids {
        let account = db
            .get_account(*account_id)
            .map_err(|e| anyhow!("get_account: {:?}", e))?;
        if let Some(acct) = account {
            if let Some(ufvk) = acct.ufvk() {
                ufvk_strings.push(ufvk.encode(&eng.params));
            }
        }
    }

    let ufvk_str = ufvk_strings.first().cloned().unwrap_or_default();

    let conn = open_cipher_conn(&eng.db_data_path, &eng.db_cipher_key)?;

    // Diagnostic: count notes in both pools for troubleshooting
    let orchard_total: i64 = conn.query_row(
        "SELECT COUNT(*) FROM orchard_received_notes", [], |r| r.get(0),
    ).unwrap_or(0);
    let orchard_unspent: i64 = conn.query_row(
        "SELECT COUNT(*) FROM orchard_received_notes n
         LEFT JOIN orchard_received_note_spends s ON s.orchard_received_note_id = n.id
         WHERE s.orchard_received_note_id IS NULL", [], |r| r.get(0),
    ).unwrap_or(0);
    let orchard_at_snap: i64 = conn.query_row(
        "SELECT COUNT(*) FROM orchard_received_notes n
         JOIN transactions t ON n.transaction_id = t.id_tx
         LEFT JOIN orchard_received_note_spends s ON s.orchard_received_note_id = n.id
         WHERE s.orchard_received_note_id IS NULL
           AND n.commitment_tree_position IS NOT NULL
           AND t.block IS NOT NULL AND t.block <= ?1",
        rusqlite::params![snapshot_height as i64], |r| r.get(0),
    ).unwrap_or(0);
    let sapling_total: i64 = conn.query_row(
        "SELECT COUNT(*) FROM sapling_received_notes", [], |r| r.get(0),
    ).unwrap_or(0);
    let sapling_unspent: i64 = conn.query_row(
        "SELECT COUNT(*) FROM sapling_received_notes n
         LEFT JOIN sapling_received_note_spends s ON s.sapling_received_note_id = n.id
         WHERE s.sapling_received_note_id IS NULL", [], |r| r.get(0),
    ).unwrap_or(0);
    let sapling_value: i64 = conn.query_row(
        "SELECT COALESCE(SUM(n.value), 0) FROM sapling_received_notes n
         LEFT JOIN sapling_received_note_spends s ON s.sapling_received_note_id = n.id
         WHERE s.sapling_received_note_id IS NULL", [], |r| r.get(0),
    ).unwrap_or(0);
    let orchard_value: i64 = conn.query_row(
        "SELECT COALESCE(SUM(n.value), 0) FROM orchard_received_notes n
         LEFT JOIN orchard_received_note_spends s ON s.orchard_received_note_id = n.id
         WHERE s.orchard_received_note_id IS NULL", [], |r| r.get(0),
    ).unwrap_or(0);
    info!(
        "[Vote] DB diagnostics: orchard_total={} orchard_unspent={} orchard_at_snap={} \
         orchard_value={} zat, sapling_total={} sapling_unspent={} sapling_value={} zat",
        orchard_total, orchard_unspent, orchard_at_snap,
        orchard_value, sapling_total, sapling_unspent, sapling_value,
    );

    let ufvk = UnifiedFullViewingKey::decode(&eng.params, &ufvk_str)
        .map_err(|e| anyhow!("UFVK decode: {}", e))?;
    let orchard_fvk = ufvk
        .orchard()
        .ok_or_else(|| anyhow!("No Orchard key in UFVK"))?;

    let mut stmt = conn.prepare(
        "SELECT n.value, n.commitment_tree_position,
                n.diversifier, n.rho, n.rseed,
                n.nf, n.recipient_key_scope
         FROM orchard_received_notes n
         JOIN transactions t ON n.transaction_id = t.id_tx
         LEFT JOIN orchard_received_note_spends s ON s.orchard_received_note_id = n.id
         WHERE n.commitment_tree_position IS NOT NULL
           AND s.orchard_received_note_id IS NULL
           AND t.block IS NOT NULL
           AND t.block <= ?1
         ORDER BY n.value DESC",
    )?;

    let mut notes = Vec::new();
    let mut rows = stmt.query(rusqlite::params![snapshot_height as i64])?;
    while let Some(row) = rows.next()? {
        let value: i64 = row.get(0)?;
        let position: i64 = row.get(1)?;
        let diversifier_bytes: Vec<u8> = row.get(2)?;
        let rho_bytes: Vec<u8> = row.get(3)?;
        let rseed_bytes: Vec<u8> = row.get(4)?;
        let nullifier: Vec<u8> = row.get(5)?;
        let scope_code: Option<i64> = row.get(6)?;

        let scope = match scope_code.unwrap_or(0) {
            1 => Scope::Internal,
            _ => Scope::External,
        };

        let mut div_arr = [0u8; 11];
        if diversifier_bytes.len() == 11 {
            div_arr.copy_from_slice(&diversifier_bytes);
        }
        let diversifier = Diversifier::from_bytes(div_arr);
        let recipient = orchard_fvk
            .to_ivk(scope)
            .address(diversifier);

        let rho = {
            let mut arr = [0u8; 32];
            arr.copy_from_slice(&rho_bytes);
            Rho::from_bytes(&arr)
        };
        let rho = Option::from(rho)
            .ok_or_else(|| anyhow!("Invalid rho for position {}", position))?;

        let rseed = {
            let mut arr = [0u8; 32];
            arr.copy_from_slice(&rseed_bytes);
            RandomSeed::from_bytes(arr, &rho)
        };
        let rseed = Option::from(rseed)
            .ok_or_else(|| anyhow!("Invalid rseed for position {}", position))?;

        let note = Note::from_parts(
            recipient,
            NoteValue::from_raw(value as u64),
            rho,
            rseed,
        );
        let note: Note = Option::from(note)
            .ok_or_else(|| anyhow!("Invalid Orchard note at position {}", position))?;

        let cmx = ExtractedNoteCommitment::from(note.commitment());
        let commitment = cmx.to_bytes().to_vec();

        notes.push(NoteInfo {
            commitment,
            nullifier,
            value: value as u64,
            position: position as u64,
            diversifier: diversifier_bytes,
            rho: rho_bytes,
            rseed: rseed_bytes,
            scope: scope_code.unwrap_or(0) as u32,
            ufvk_str: ufvk_str.clone(),
        });
    }

    info!(
        "Found {} eligible Orchard notes at height {}",
        notes.len(),
        snapshot_height
    );
    Ok(notes)
}

/// Bundle eligible notes into groups of up to 5 for delegation.
pub fn bundle_notes(notes: &[NoteInfo]) -> ChunkResult {
    zcash_voting::types::chunk_notes(notes)
}

/// Check voting eligibility. Returns (eligible_weight_zatoshi, note_count, bundle_count).
pub async fn check_eligibility(snapshot_height: u64) -> Result<(u64, usize, usize)> {
    let notes = get_eligible_notes(snapshot_height).await?;
    if notes.is_empty() {
        return Ok((0, 0, 0));
    }
    let chunks = bundle_notes(&notes);
    Ok((chunks.eligible_weight, notes.len(), chunks.bundles.len()))
}

/// Compute SHA-256 hash of proposals JSON for config verification.
pub fn compute_proposals_hash(proposals_json: &str) -> [u8; 32] {
    use sha2::{Digest, Sha256};
    let mut hasher = Sha256::new();
    hasher.update(proposals_json.as_bytes());
    let result = hasher.finalize();
    let mut hash = [0u8; 32];
    hash.copy_from_slice(&result);
    hash
}

// =========================================================================
// Orchard note Merkle witness generation
// =========================================================================

/// Generate Merkle witnesses for notes at given positions from the wallet's
/// Orchard commitment tree at the voting snapshot height.
///
/// Uses `WalletDb::generate_orchard_witnesses_at_historical_height` -- the
/// official API from `zcash_client_sqlite 0.20` designed specifically for
/// coinholder voting. It builds an ephemeral in-memory tree from stored shard
/// BLOBs + the frontier from lightwalletd, never mutating the live tree.
pub async fn generate_note_witnesses(
    note_positions: &[u64],
    snapshot_height: u64,
) -> Result<Vec<WitnessData>> {
    let engine = ENGINE.lock().await;
    let eng = engine
        .as_ref()
        .ok_or_else(|| anyhow!("Engine not initialized"))?;

    let checkpoint_height = BlockHeight::from_u32(snapshot_height as u32);

    let positions: Vec<Position> = note_positions
        .iter()
        .map(|p| Position::from(*p))
        .collect();

    // Fetch the Orchard tree frontier at the snapshot height from lightwalletd.
    info!(
        "[WITNESS] Fetching tree state at height {} from {}",
        snapshot_height, &eng.server_url
    );
    let tree_state = fetch_tree_state(&eng.server_url, snapshot_height).await?;
    let chain_state = tree_state
        .to_chain_state()
        .map_err(|e| anyhow!("parse tree state at height {}: {:?}", snapshot_height, e))?;
    let frontier = chain_state
        .final_orchard_tree()
        .clone()
        .take()
        .ok_or_else(|| anyhow!("empty Orchard tree at snapshot height {}", snapshot_height))?;

    info!(
        "[WITNESS] Frontier at height {}: tree_size={}",
        snapshot_height,
        u64::from(frontier.position()) + 1
    );

    // Use the official API: builds an in-memory tree from shard BLOBs, inserts
    // the frontier as a single checkpoint, and computes witnesses. Read-only on
    // the wallet's live tree.
    let db = open_wallet_db(&eng.db_data_path, eng.params, &eng.db_cipher_key)?;
    let merkle_paths = db
        .generate_orchard_witnesses_at_historical_height(
            &positions,
            frontier.clone(),
            checkpoint_height,
        )
        .map_err(|e| anyhow!("historical witness generation failed: {:?}", e))?;

    info!(
        "[WITNESS] Generated {} Merkle paths at height {}",
        merkle_paths.len(),
        snapshot_height
    );

    // Compute the root from the frontier for verification and WitnessData
    let root = {
        use incrementalmerkletree::Level;
        frontier.root(Some(Level::from(orchard::NOTE_COMMITMENT_TREE_DEPTH as u8)))
    };
    let root_bytes = root.to_bytes().to_vec();

    // Build WitnessData from MerklePaths, computing note commitments for each position
    let account_ids = db
        .get_account_ids()
        .map_err(|e| anyhow!("get_account_ids: {:?}", e))?;
    let account = db
        .get_account(account_ids[0])
        .map_err(|e| anyhow!("get_account: {:?}", e))?
        .ok_or_else(|| anyhow!("no account"))?;
    let ufvk = account.ufvk().ok_or_else(|| anyhow!("no UFVK"))?;
    let ofvk = ufvk
        .orchard()
        .ok_or_else(|| anyhow!("no Orchard FVK"))?
        .clone();

    let conn = open_cipher_conn(&eng.db_data_path, &eng.db_cipher_key)?;
    let mut witnesses = Vec::with_capacity(merkle_paths.len());

    for (i, merkle_path) in merkle_paths.iter().enumerate() {
        let pos = positions[i];
        let pos_i64 = u64::from(pos) as i64;

        let (div_b, val, rho_b, rseed_b, scope_code): (Vec<u8>, i64, Vec<u8>, Vec<u8>, Option<i64>) =
            conn.query_row(
                "SELECT n.diversifier, n.value, n.rho, n.rseed, n.recipient_key_scope
                 FROM orchard_received_notes n
                 WHERE n.commitment_tree_position = ?1",
                rusqlite::params![pos_i64],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?, row.get(4)?)),
            ).map_err(|e| anyhow!("note query at pos {}: {}", pos_i64, e))?;

        let scope = match scope_code.unwrap_or(0) { 1 => Scope::Internal, _ => Scope::External };
        let mut d = [0u8; 11];
        d.copy_from_slice(&div_b);
        let recipient = ofvk.to_ivk(scope).address(Diversifier::from_bytes(d));

        let mut r = [0u8; 32];
        r.copy_from_slice(&rho_b);
        let rho = Option::from(Rho::from_bytes(&r))
            .ok_or_else(|| anyhow!("invalid rho at pos {}", pos_i64))?;
        let mut rs = [0u8; 32];
        rs.copy_from_slice(&rseed_b);
        let rseed = Option::from(RandomSeed::from_bytes(rs, &rho))
            .ok_or_else(|| anyhow!("invalid rseed at pos {}", pos_i64))?;

        let note: Note = Option::from(Note::from_parts(recipient, NoteValue::from_raw(val as u64), rho, rseed))
            .ok_or_else(|| anyhow!("invalid note at pos {}", pos_i64))?;
        let cmx = ExtractedNoteCommitment::from(note.commitment());
        let cmx_hash = MerkleHashOrchard::from_cmx(&cmx);
        let cmx_bytes = cmx.to_bytes().to_vec();

        // Local verification: the Merkle path must authenticate this leaf to the frontier root.
        let path_root = merkle_path.root(cmx_hash);
        if path_root != root {
            return Err(anyhow!(
                "Merkle path verification FAILED for note at position {}. \
                 path.root(cmx) = {} but expected = {}. \
                 The note commitment doesn't match what's in the tree at this position.",
                pos_i64,
                hex::encode(path_root.to_bytes()),
                hex::encode(root.to_bytes()),
            ));
        }
        info!(
            "[WITNESS] Position {} verified: path.root(cmx) matches frontier root",
            pos_i64
        );

        let auth_path: Vec<Vec<u8>> = merkle_path
            .path_elems()
            .iter()
            .map(|h| h.to_bytes().to_vec())
            .collect();

        witnesses.push(WitnessData {
            note_commitment: cmx_bytes,
            position: u64::from(pos),
            root: root_bytes.clone(),
            auth_path,
        });
    }

    info!(
        "[WITNESS] Built {} WitnessData entries, root={}",
        witnesses.len(),
        hex::encode(&root_bytes[..8])
    );
    Ok(witnesses)
}

// =========================================================================
// Governance PCZT + delegation signing
// =========================================================================

/// Build a governance PCZT for one bundle of notes.
pub async fn build_governance_pczt_for_bundle(
    bundle_notes: &[NoteInfo],
    params: &VotingRoundParams,
    hotkey_address_bytes: &[u8],
    network_id: u32,
) -> Result<GovernancePczt> {
    let engine = ENGINE.lock().await;
    let eng = engine
        .as_ref()
        .ok_or_else(|| anyhow!("Engine not initialized"))?;

    let db = open_wallet_db(&eng.db_data_path, eng.params, &eng.db_cipher_key)?;
    let account_ids = db
        .get_account_ids()
        .map_err(|e| anyhow!("get_account_ids: {:?}", e))?;
    let account = db
        .get_account(account_ids[0])
        .map_err(|e| anyhow!("get_account: {:?}", e))?
        .ok_or_else(|| anyhow!("no account found"))?;
    let ufvk = account
        .ufvk()
        .ok_or_else(|| anyhow!("no UFVK for account"))?;
    let orchard_fvk = ufvk
        .orchard()
        .ok_or_else(|| anyhow!("no Orchard component in UFVK"))?;
    let fvk_bytes = orchard_fvk.to_bytes();

    let network = match network_id {
        0 => ZcashNetwork::TestNetwork,
        1 => ZcashNetwork::MainNetwork,
        _ => return Err(anyhow!("invalid network_id {}", network_id)),
    };
    let snapshot_bh = BlockHeight::from_u32(params.snapshot_height as u32);
    let branch_id = u32::from(BranchId::for_height(&network, snapshot_bh));
    let coin_type: u32 = match network_id {
        0 => 1,
        _ => 133,
    };

    let seed_fp = [0u8; 32]; // placeholder — not needed for software signing path

    let pczt = zcash_voting::action::build_governance_pczt(
        bundle_notes,
        params,
        &fvk_bytes,
        hotkey_address_bytes,
        branch_id,
        coin_type,
        &seed_fp,
        0,
        "zipher-vote",
    )
    .map_err(|e| anyhow!("build_governance_pczt: {}", e))?;

    Ok(pczt)
}

/// Sign a delegation sighash using the wallet's Orchard spend auth key.
/// Returns the 64-byte SpendAuth signature.
pub fn sign_delegation_sighash(
    wallet_seed: &[u8],
    sighash: &[u8],
    alpha_bytes: &[u8],
    network_id: u32,
) -> Result<Vec<u8>> {
    use zcash_keys::keys::UnifiedSpendingKey;
    use zcash_protocol::consensus::{MAIN_NETWORK, TEST_NETWORK};
    use zip32::AccountId;

    let account = AccountId::try_from(0u32).map_err(|_| anyhow!("invalid account"))?;
    let usk = match network_id {
        0 => UnifiedSpendingKey::from_seed(&TEST_NETWORK, wallet_seed, account),
        1 => UnifiedSpendingKey::from_seed(&MAIN_NETWORK, wallet_seed, account),
        _ => return Err(anyhow!("invalid network_id {}", network_id)),
    }
    .map_err(|e| anyhow!("derive USK: {}", e))?;

    let ask = orchard::keys::SpendAuthorizingKey::from(usk.orchard());

    let alpha_arr: [u8; 32] = alpha_bytes
        .try_into()
        .map_err(|_| anyhow!("alpha must be 32 bytes"))?;
    let alpha: pallas::Scalar = Option::from(pallas::Scalar::from_repr(alpha_arr))
        .ok_or_else(|| anyhow!("alpha is not a valid scalar"))?;

    let rsk = ask.randomize(&alpha);

    let sighash_arr: [u8; 32] = sighash
        .try_into()
        .map_err(|_| anyhow!("sighash must be 32 bytes"))?;

    let mut rng = rand::rngs::OsRng;
    let sig = rsk.sign(&mut rng, &sighash_arr);
    let sig_bytes: [u8; 64] = (&sig).into();
    Ok(sig_bytes.to_vec())
}

// =========================================================================
// PIR proof fetching
// =========================================================================

/// Validated + converted PIR proof bundle ready for ZKP1.
pub struct PirProofBundle {
    /// Converted proofs for real notes (in `voting_circuits` IMT format).
    pub real_proofs: Vec<ConvertedImtProof>,
    /// Converted proofs for padded dummy notes, keyed by nullifier bytes.
    pub extra_proofs: Vec<([u8; 32], ConvertedImtProof)>,
}

/// Opaque wrapper around the circuit-level IMT proof (voting_circuits type).
/// We store the raw fields so we can pass them to `build_and_prove_delegation`.
pub struct ConvertedImtProof {
    pub root: pallas::Base,
    pub nf_bounds: [pallas::Base; 3],
    pub leaf_pos: u32,
    pub path: [pallas::Base; 29],
}

/// Fetch PIR non-membership proofs for note nullifiers and any padded dummy nullifiers.
/// Validates each proof against the expected IMT root and converts to circuit format.
pub async fn fetch_pir_proofs(
    nullifier_bytes: &[Vec<u8>],
    dummy_nullifier_bytes: &[Vec<u8>],
    pir_url: &str,
    expected_imt_root: &[u8],
) -> Result<PirProofBundle> {
    ensure_rustls_provider();
    let transport = Arc::new(HyperTransport::new());

    info!("[PIR] Connecting to {}", pir_url);
    let pir_client = zcash_voting::PirClient::with_transport(pir_url, transport)
        .await
        .map_err(|e| anyhow!("PIR connect failed: {}", e))?;

    let expected_root_arr: [u8; 32] = expected_imt_root
        .try_into()
        .map_err(|_| anyhow!("IMT root must be 32 bytes"))?;
    let expected_root: pallas::Base = Option::from(pallas::Base::from_repr(expected_root_arr))
        .ok_or_else(|| anyhow!("IMT root is not a valid field element"))?;

    let mut all_nfs: Vec<pallas::Base> = Vec::new();
    for nf in nullifier_bytes {
        let arr: [u8; 32] = nf.as_slice().try_into().map_err(|_| anyhow!("nf 32 bytes"))?;
        all_nfs.push(
            Option::from(pallas::Base::from_repr(arr))
                .ok_or_else(|| anyhow!("nullifier not valid Fp"))?,
        );
    }
    let real_count = all_nfs.len();

    for dnf in dummy_nullifier_bytes {
        let arr: [u8; 32] = dnf
            .as_slice()
            .try_into()
            .map_err(|_| anyhow!("dummy nf 32 bytes"))?;
        all_nfs.push(
            Option::from(pallas::Base::from_repr(arr))
                .ok_or_else(|| anyhow!("dummy nullifier not valid Fp"))?,
        );
    }

    info!(
        "[PIR] Fetching {} proofs ({} real + {} dummy)",
        all_nfs.len(),
        real_count,
        dummy_nullifier_bytes.len()
    );
    let all_proofs = pir_client
        .fetch_proofs(&all_nfs)
        .await
        .map_err(|e| anyhow!("PIR fetch failed: {}", e))?;

    // CRITICAL: the chain verifies ZKP1 with `nf_imt_root = round.NullifierImtRoot`,
    // pinned from the round's snapshot state. See vote-sdk
    // x/vote/ante/validate.go (verifyDelegation): `VerifyDelegation` pulls
    // `NullifierImtRoot` from `round`, NOT from the submitted message. The proof
    // therefore MUST be generated against the round's snapshot IMT root.
    //
    // If the PIR server's live tree has advanced past the snapshot its root no
    // longer matches, and any proof we build against it is rejected on-chain as
    // "invalid zero-knowledge proof" after the full ~120s verify. Fail fast with
    // an actionable error instead of silently producing an unverifiable proof.
    if let Some(first) = all_proofs.first() {
        let server_root = first.root;
        info!(
            "[PIR] server IMT root={} round snapshot IMT root={}",
            hex::encode(server_root.to_repr()),
            hex::encode(expected_root.to_repr()),
        );
        if server_root != expected_root {
            return Err(anyhow!(
                "PIR server nullifier IMT root does not match the vote round's \
                 snapshot nullifier_imt_root (server={} round={}). The chain pins \
                 nf_imt_root from the round snapshot, so a proof built against the \
                 PIR server's current root would be rejected as an invalid \
                 zero-knowledge proof. The PIR server and the vote round are out of \
                 sync: the PIR tree has advanced past the round snapshot.",
                hex::encode(server_root.to_repr()),
                hex::encode(expected_root.to_repr()),
            ));
        }
    }

    // All proofs are validated/converted against the round's pinned snapshot root.
    let mut real_proofs = Vec::with_capacity(real_count);
    for (i, proof) in all_proofs[..real_count].iter().enumerate() {
        let converted = zcash_voting::zkp1::validate_and_convert_pir_proof(
            proof.clone(),
            all_nfs[i],
            expected_root,
        )
        .map_err(|e| anyhow!("PIR proof validation failed for note {}: {}", i, e))?;
        real_proofs.push(ConvertedImtProof {
            root: converted.root,
            nf_bounds: converted.nf_bounds,
            leaf_pos: converted.leaf_pos,
            path: converted.path,
        });
    }

    let mut extra_proofs = Vec::new();
    for (i, proof) in all_proofs[real_count..].iter().enumerate() {
        let nf_idx = real_count + i;
        let converted = zcash_voting::zkp1::validate_and_convert_pir_proof(
            proof.clone(),
            all_nfs[nf_idx],
            expected_root,
        )
        .map_err(|e| anyhow!("PIR proof validation failed for dummy {}: {}", i, e))?;
        let arr: [u8; 32] = dummy_nullifier_bytes[i]
            .as_slice()
            .try_into()
            .expect("validated above");
        extra_proofs.push((
            arr,
            ConvertedImtProof {
                root: converted.root,
                nf_bounds: converted.nf_bounds,
                leaf_pos: converted.leaf_pos,
                path: converted.path,
            },
        ));
    }

    info!("[PIR] All {} proofs validated and converted", all_proofs.len());
    Ok(PirProofBundle {
        real_proofs,
        extra_proofs,
    })
}

// =========================================================================
// ZKP1 delegation proof
// =========================================================================

struct LogProgressReporter;
impl zcash_voting::types::ProofProgressReporter for LogProgressReporter {
    fn on_progress(&self, progress: f64) {
        info!("[ZKP1] proof progress: {:.0}%", progress * 100.0);
    }
}

/// Build the ZKP1 delegation proof. CPU-intensive (~30s).
/// Must be called from a blocking context (spawn_blocking).
pub fn build_delegation_proof(
    bundle_notes: &[NoteInfo],
    hotkey_raw_address: &[u8],
    alpha: &[u8],
    van_comm_rand: &[u8],
    vote_round_id: &[u8],
    witnesses: &[WitnessData],
    pir_bundle: &PirProofBundle,
    network_id: u32,
) -> Result<DelegationProofResult> {
    use voting_circuits::delegation::ImtProofData;

    let imt_proofs: Vec<ImtProofData> = pir_bundle
        .real_proofs
        .iter()
        .map(|p| ImtProofData {
            root: p.root,
            nf_bounds: p.nf_bounds,
            leaf_pos: p.leaf_pos,
            path: p.path,
        })
        .collect();

    let extra_imt: Vec<([u8; 32], ImtProofData)> = pir_bundle
        .extra_proofs
        .iter()
        .map(|(k, p)| {
            (
                *k,
                ImtProofData {
                    root: p.root,
                    nf_bounds: p.nf_bounds,
                    leaf_pos: p.leaf_pos,
                    path: p.path,
                },
            )
        })
        .collect();

    let reporter = LogProgressReporter;
    info!(
        "[ZKP1] Starting delegation proof for {} notes",
        bundle_notes.len()
    );

    let result = zcash_voting::zkp1::build_and_prove_delegation(
        bundle_notes,
        hotkey_raw_address,
        alpha,
        van_comm_rand,
        vote_round_id,
        witnesses,
        &imt_proofs,
        &extra_imt,
        network_id,
        &reporter,
        None,
    )
    .map_err(|e| anyhow!("delegation proof failed: {}", e))?;

    info!("[ZKP1] Proof generated: {} bytes", result.proof.len());
    Ok(result)
}

// =========================================================================
// Delegation submission assembly
// =========================================================================

/// Assemble delegation submission sighash from PCZT fields.
/// Blake2b-256 of domain || nf_signed || rk || cmx_new || van_comm || gov_nullifiers || vote_round_id.
pub fn compute_delegation_sighash(pczt: &GovernancePczt, vote_round_id: &[u8]) -> Result<Vec<u8>> {
    const SIGHASH_DOMAIN: &[u8] = b"SVOTE_DELEG_SIGHASH_V0";
    let mut preimage = Vec::new();
    preimage.extend_from_slice(SIGHASH_DOMAIN);
    extend_padded32(&mut preimage, &pczt.nf_signed);
    extend_padded32(&mut preimage, &pczt.rk);
    extend_padded32(&mut preimage, &pczt.cmx_new);
    extend_padded32(&mut preimage, &pczt.van);
    for gn in &pczt.gov_nullifiers {
        extend_padded32(&mut preimage, gn);
    }
    extend_padded32(&mut preimage, vote_round_id);

    let hash = blake2b_simd::Params::new()
        .hash_length(32)
        .hash(&preimage);
    Ok(hash.as_bytes().to_vec())
}

fn extend_padded32(out: &mut Vec<u8>, b: &[u8]) {
    let mut buf = [0u8; 32];
    let n = b.len().min(32);
    buf[..n].copy_from_slice(&b[..n]);
    out.extend_from_slice(&buf);
}

// =========================================================================
// Full delegation pipeline
// =========================================================================

/// Result of a single bundle delegation.
#[derive(Clone, Debug)]
pub struct BundleDelegationResult {
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

/// Perform full delegation for all bundles. Returns submission-ready data.
pub async fn perform_delegation(
    wallet_seed: &[u8],
    params: VotingRoundParams,
    pir_url: &str,
    network_id: u32,
) -> Result<Vec<BundleDelegationResult>> {
    info!("[DELEGATION] Starting full delegation flow");

    // Gate: refuse to proceed if the wallet hasn't synced through the snapshot height
    {
        let engine = ENGINE.lock().await;
        let eng = engine
            .as_ref()
            .ok_or_else(|| anyhow!("Engine not initialized"))?;
        let db = open_wallet_db(&eng.db_data_path, eng.params, &eng.db_cipher_key)?;
        let chain_state = db
            .chain_height()
            .map_err(|e| anyhow!("chain_height query: {:?}", e))?;
        let fully_scanned = chain_state
            .ok_or_else(|| anyhow!("wallet has no scanned blocks"))?;
        let snapshot_bh = BlockHeight::from_u32(params.snapshot_height as u32);
        if fully_scanned < snapshot_bh {
            return Err(anyhow!(
                "Wallet not synced through snapshot height: scanned {} < snapshot {}. \
                 Please wait for sync to complete.",
                u32::from(fully_scanned),
                params.snapshot_height,
            ));
        }
        info!(
            "[DELEGATION] Sync check passed: fully_scanned={} >= snapshot={}",
            u32::from(fully_scanned),
            params.snapshot_height
        );
    }

    // 1. Get eligible notes and bundle them
    let notes = get_eligible_notes(params.snapshot_height).await?;
    if notes.is_empty() {
        return Err(anyhow!("No eligible notes at snapshot height {}", params.snapshot_height));
    }
    let chunks = bundle_notes(&notes);
    info!(
        "[DELEGATION] {} notes in {} bundles, weight {}",
        notes.len(),
        chunks.bundles.len(),
        chunks.eligible_weight
    );

    // 2. Derive voting seed + hotkey Orchard address (43 bytes)
    let voting_seed = derive_voting_seed(wallet_seed);
    let hotkey_addr_bytes = derive_hotkey_orchard_address(&voting_seed)?;
    info!(
        "[DELEGATION] Hotkey address: {} bytes, crates: zcash_voting=0.10.1 voting-circuits=0.6.0",
        hotkey_addr_bytes.len(),
    );

    let vote_round_id_bytes = hex::decode(&params.vote_round_id)
        .map_err(|e| anyhow!("invalid vote_round_id hex: {}", e))?;
    info!(
        "[DELEGATION] Round id={}, snapshot={}, nc_root={}, nf_imt={}",
        &params.vote_round_id[..16.min(params.vote_round_id.len())],
        params.snapshot_height,
        hex::encode(&params.nc_root[..8.min(params.nc_root.len())]),
        hex::encode(&params.nullifier_imt_root[..8.min(params.nullifier_imt_root.len())]),
    );

    let mut results = Vec::new();

    for (bi, bundle) in chunks.bundles.iter().enumerate() {
        info!("[DELEGATION] Processing bundle {}/{}", bi + 1, chunks.bundles.len());

        // 3. Build governance PCZT
        let pczt = build_governance_pczt_for_bundle(
            bundle,
            &params,
            &hotkey_addr_bytes,
            network_id,
        )
        .await?;
        info!("[DELEGATION] PCZT built: rk={} bytes, alpha={} bytes", pczt.rk.len(), pczt.alpha.len());

        // 4. Compute sighash and sign
        let sighash = compute_delegation_sighash(&pczt, &vote_round_id_bytes)?;
        let spend_auth_sig =
            sign_delegation_sighash(wallet_seed, &sighash, &pczt.alpha, network_id)?;
        info!("[DELEGATION] Sighash signed: {} bytes", spend_auth_sig.len());

        // 5. Get note nullifiers for PIR
        let real_nullifiers: Vec<Vec<u8>> = bundle.iter().map(|n| n.nullifier.clone()).collect();
        let dummy_nullifiers: Vec<Vec<u8>> = pczt.dummy_nullifiers.clone();

        // 6. Fetch PIR proofs
        let pir_bundle = fetch_pir_proofs(
            &real_nullifiers,
            &dummy_nullifiers,
            pir_url,
            &params.nullifier_imt_root,
        )
        .await?;
        info!(
            "[DELEGATION] PIR proofs fetched: {} real, {} extra",
            pir_bundle.real_proofs.len(),
            pir_bundle.extra_proofs.len()
        );

        // 7. Generate Orchard note Merkle witnesses
        let positions: Vec<u64> = bundle.iter().map(|n| n.position).collect();
        let witnesses = generate_note_witnesses(&positions, params.snapshot_height).await?;
        info!(
            "[DELEGATION] Merkle witnesses generated: {}",
            witnesses.len()
        );

        // 7b. Pre-verify: witness root must match the chain's nc_root.
        // Catches tree state mismatches before the 30s proof generation.
        if let Some(first_witness) = witnesses.first() {
            if first_witness.root != params.nc_root {
                return Err(anyhow!(
                    "nc_root mismatch: witness root {} != chain nc_root {}. \
                     Tree state at snapshot may be inconsistent.",
                    hex::encode(&first_witness.root),
                    hex::encode(&params.nc_root),
                ));
            }
            info!(
                "[DELEGATION] nc_root verified OK: {} (auth_path len={})",
                hex::encode(&first_witness.root[..8]),
                first_witness.auth_path.len()
            );
        }

        // 8. Build ZKP1 proof (CPU-intensive — run on blocking thread)
        let proof_notes = bundle.clone();
        let proof_hotkey = hotkey_addr_bytes.clone();
        let proof_alpha = pczt.alpha.clone();
        let proof_van_rand = pczt.van_comm_rand.clone();
        let proof_round_id = vote_round_id_bytes.clone();
        let proof_witnesses = witnesses;

        let proof_result = tokio::task::spawn_blocking(move || {
            build_delegation_proof(
                &proof_notes,
                &proof_hotkey,
                &proof_alpha,
                &proof_van_rand,
                &proof_round_id,
                &proof_witnesses,
                &pir_bundle,
                network_id,
            )
        })
        .await
        .map_err(|e| anyhow!("proof task panicked: {}", e))??;

        let total_value: u64 = bundle.iter().map(|n| n.value).sum();
        info!(
            "[DELEGATION] ZKP1 proof generated: {} bytes, rk={}, nf_signed={}, cmx_new={}, van={}",
            proof_result.proof.len(),
            hex::encode(&proof_result.rk[..8.min(proof_result.rk.len())]),
            hex::encode(&proof_result.nf_signed[..8.min(proof_result.nf_signed.len())]),
            hex::encode(&proof_result.cmx_new[..8.min(proof_result.cmx_new.len())]),
            hex::encode(&proof_result.van_comm[..8.min(proof_result.van_comm.len())]),
        );
        info!(
            "[DELEGATION] Bundle {} value={} ZAT ({} ZEC), gov_nullifiers={}",
            bi + 1, total_value, total_value as f64 / 100_000_000.0, proof_result.gov_nullifiers.len()
        );

        results.push(BundleDelegationResult {
            proof: proof_result.proof,
            rk: proof_result.rk,
            nf_signed: proof_result.nf_signed,
            cmx_new: proof_result.cmx_new,
            van_comm: proof_result.van_comm,
            van_comm_rand: pczt.van_comm_rand.clone(),
            gov_nullifiers: proof_result.gov_nullifiers,
            spend_auth_sig,
            sighash,
            vote_round_id: params.vote_round_id.clone(),
            total_value,
            action_bytes: pczt.action_bytes.clone(),
        });

        info!("[DELEGATION] Bundle {} complete", bi + 1);
    }

    info!("[DELEGATION] All {} bundles delegated", results.len());
    Ok(results)
}

// =========================================================================
// Vote commitment (ZKP2) + cast-vote signing
// =========================================================================

struct VoteProgressReporter;
impl zcash_voting::types::ProofProgressReporter for VoteProgressReporter {
    fn on_progress(&self, progress: f64) {
        info!("[ZKP2] vote proof progress: {:.0}%", progress * 100.0);
    }
}

/// Build vote commitment + ZKP2 proof for a single proposal.
pub fn build_vote_commitment_for_proposal(
    voting_seed: &[u8],
    network_id: u32,
    total_note_value: u64,
    gov_comm_rand: &[u8],
    voting_round_id: &[u8],
    ea_pk: &[u8],
    proposal_id: u32,
    choice: u32,
    num_options: u32,
    van_auth_path: Vec<Vec<u8>>,
    van_position: u32,
    anchor_height: u32,
    proposal_authority: u64,
    single_share: bool,
) -> Result<VoteCommitmentBundle> {
    let auth_path_arrays: Vec<[u8; 32]> = van_auth_path
        .iter()
        .map(|b| {
            b.as_slice()
                .try_into()
                .map_err(|_| anyhow!("auth_path element must be 32 bytes"))
        })
        .collect::<Result<Vec<[u8; 32]>>>()?;

    info!(
        "[ZKP2] Building vote commitment: proposal={}, choice={}, value={}",
        proposal_id, choice, total_note_value
    );

    let bundle = zcash_voting::zkp2::build_vote_commitment(
        voting_seed,
        network_id,
        0, // address_index
        total_note_value,
        gov_comm_rand,
        voting_round_id,
        ea_pk,
        proposal_id,
        choice,
        num_options,
        &auth_path_arrays,
        van_position,
        anchor_height,
        proposal_authority,
        single_share,
        &VoteProgressReporter,
    )
    .map_err(|e| anyhow!("vote commitment failed: {}", e))?;

    info!("[ZKP2] Vote commitment built: proof={} bytes", bundle.proof.len());
    Ok(bundle)
}

/// Sign a cast-vote transaction.
pub fn sign_cast_vote_tx(
    voting_seed: &[u8],
    network_id: u32,
    bundle: &VoteCommitmentBundle,
) -> Result<CastVoteSignature> {
    let sig = zcash_voting::vote_commitment::sign_cast_vote(
        voting_seed,
        network_id,
        &bundle.vote_round_id,
        &bundle.r_vpk_bytes,
        &bundle.van_nullifier,
        &bundle.vote_authority_note_new,
        &bundle.vote_commitment,
        bundle.proposal_id,
        bundle.anchor_height,
        &bundle.alpha_v,
    )
    .map_err(|e| anyhow!("sign_cast_vote failed: {}", e))?;

    info!("[VOTE] Cast-vote signed: {} bytes", sig.vote_auth_sig.len());
    Ok(sig)
}

// =========================================================================
// Share payloads
// =========================================================================

/// Build share payloads for helper server submission.
pub fn build_vote_share_payloads(
    commitment: &VoteCommitmentBundle,
    vote_decision: u32,
    num_options: u32,
    vc_tree_position: u64,
    single_share: bool,
) -> Result<Vec<SharePayload>> {
    let wire_shares: Vec<WireEncryptedShare> = commitment
        .enc_shares
        .iter()
        .map(WireEncryptedShare::from)
        .collect();

    let payloads = zcash_voting::vote_commitment::build_share_payloads(
        &wire_shares,
        commitment,
        vote_decision,
        num_options,
        vc_tree_position,
        single_share,
    )
    .map_err(|e| anyhow!("build_share_payloads failed: {}", e))?;

    info!("[SHARES] Built {} share payloads", payloads.len());
    Ok(payloads)
}

// =========================================================================
// FFI-friendly thin wrappers (avoid exposing zcash_voting types to FFI crate)
// =========================================================================

/// Reference wrapper to avoid constructing a full VoteCommitmentBundle for signing.
pub struct VoteCommitmentBundleRef<'a> {
    pub van_nullifier: &'a [u8],
    pub vote_authority_note_new: &'a [u8],
    pub vote_commitment: &'a [u8],
    pub vote_round_id: &'a str,
    pub r_vpk_bytes: &'a [u8],
    pub alpha_v: &'a [u8],
    pub proposal_id: u32,
    pub anchor_height: u32,
}

/// Sign cast-vote TX using raw fields (FFI-friendly).
pub fn sign_cast_vote_tx_raw(
    voting_seed: &[u8],
    network_id: u32,
    bundle: &VoteCommitmentBundleRef,
) -> Result<Vec<u8>> {
    let sig = zcash_voting::vote_commitment::sign_cast_vote(
        voting_seed,
        network_id,
        bundle.vote_round_id,
        bundle.r_vpk_bytes,
        bundle.van_nullifier,
        bundle.vote_authority_note_new,
        bundle.vote_commitment,
        bundle.proposal_id,
        bundle.anchor_height,
        bundle.alpha_v,
    )
    .map_err(|e| anyhow!("sign_cast_vote: {}", e))?;

    Ok(sig.vote_auth_sig)
}

/// Build share payloads from raw field arrays (FFI-friendly).
/// Returns tuples: (shares_hash, proposal_id, vote_decision, c1, c2, share_index, tree_position, primary_blind).
#[allow(clippy::type_complexity)]
pub fn build_vote_share_payloads_raw(
    shares_hash: &[u8],
    proposal_id: u32,
    vote_decision: u32,
    num_options: u32,
    vc_tree_position: u64,
    enc_c1: &[Vec<u8>],
    enc_c2: &[Vec<u8>],
    enc_indices: &[u32],
    share_blinds: &[Vec<u8>],
    share_comms: &[Vec<u8>],
    single_share: bool,
) -> Result<Vec<(Vec<u8>, u32, u32, Vec<u8>, Vec<u8>, u32, u64, Vec<u8>)>> {
    let wire_shares: Vec<WireEncryptedShare> = enc_c1
        .iter()
        .zip(enc_c2.iter())
        .zip(enc_indices.iter())
        .map(|((c1, c2), &idx)| WireEncryptedShare {
            c1: c1.clone(),
            c2: c2.clone(),
            share_index: idx,
        })
        .collect();

    let commitment = VoteCommitmentBundle {
        van_nullifier: vec![],
        vote_authority_note_new: vec![],
        vote_commitment: vec![],
        proposal_id,
        proof: vec![],
        enc_shares: vec![],
        anchor_height: 0,
        vote_round_id: String::new(),
        shares_hash: shares_hash.to_vec(),
        share_blinds: share_blinds.to_vec(),
        share_comms: share_comms.to_vec(),
        r_vpk_bytes: vec![],
        alpha_v: vec![],
    };

    let payloads = zcash_voting::vote_commitment::build_share_payloads(
        &wire_shares,
        &commitment,
        vote_decision,
        num_options,
        vc_tree_position,
        single_share,
    )
    .map_err(|e| anyhow!("build_share_payloads: {}", e))?;

    Ok(payloads
        .into_iter()
        .map(|p| {
            (
                p.shares_hash,
                p.proposal_id,
                p.vote_decision,
                p.enc_share.c1,
                p.enc_share.c2,
                p.enc_share.share_index,
                p.tree_position,
                p.primary_blind,
            )
        })
        .collect())
}

// =========================================================================
// Vote commitment tree sync + VAN witness generation
// =========================================================================

use std::sync::OnceLock;

static VOTE_TREE_SYNC: OnceLock<zcash_voting::tree_sync::VoteTreeSync> = OnceLock::new();

fn get_vote_tree_sync() -> &'static zcash_voting::tree_sync::VoteTreeSync {
    VOTE_TREE_SYNC.get_or_init(zcash_voting::tree_sync::VoteTreeSync::new)
}

/// VAN witness result for a single bundle.
#[derive(Clone, Debug)]
pub struct VanWitnessResult {
    pub auth_path: Vec<Vec<u8>>,
    pub position: u32,
    pub anchor_height: u32,
}

/// Sync the vote commitment tree and generate VAN witnesses for all bundles.
///
/// Creates a temporary in-memory VotingDb with the round and bundle state,
/// syncs the tree from the chain node, and returns a witness per bundle.
///
/// `van_positions`: one VAN leaf position per bundle (from delegation TX response).
pub fn sync_tree_and_witness(
    node_url: &str,
    round_id: &str,
    round_params: &VotingRoundParams,
    van_positions: &[u32],
) -> Result<Vec<VanWitnessResult>> {
    ensure_rustls_provider();
    use zcash_voting::storage::{queries, VotingDb};

    let db = VotingDb::open(":memory:")
        .map_err(|e| anyhow!("voting db init: {}", e))?;
    db.set_wallet_id("zipher");

    let conn = db.conn();
    queries::insert_round(&conn, "zipher", round_params, None)
        .map_err(|e| anyhow!("insert round: {}", e))?;

    for (i, &pos) in van_positions.iter().enumerate() {
        queries::insert_bundle(&conn, round_id, "zipher", i as u32, &[])
            .map_err(|e| anyhow!("insert bundle {}: {}", i, e))?;
        queries::store_van_position(&conn, round_id, "zipher", i as u32, pos)
            .map_err(|e| anyhow!("store van position {}: {}", i, e))?;
    }
    drop(conn);

    let tree_sync = get_vote_tree_sync();

    // Reset any stale tree state for this round before syncing
    tree_sync.reset(round_id)
        .map_err(|e| anyhow!("tree reset: {}", e))?;

    let anchor_height = tree_sync
        .sync(&db, round_id, node_url)
        .map_err(|e| anyhow!("vote tree sync: {}", e))?;
    info!("[TREE] Vote commitment tree synced to height {}", anchor_height);

    let mut witnesses = Vec::with_capacity(van_positions.len());
    for i in 0..van_positions.len() {
        let witness = tree_sync
            .generate_van_witness(&db, round_id, i as u32, anchor_height)
            .map_err(|e| anyhow!("VAN witness bundle {}: {}", i, e))?;
        info!(
            "[TREE] VAN witness {}: position={}, anchor={}",
            i, witness.position, witness.anchor_height
        );
        witnesses.push(VanWitnessResult {
            auth_path: witness.auth_path.iter().map(|h| h.to_vec()).collect(),
            position: witness.position,
            anchor_height: witness.anchor_height,
        });
    }

    Ok(witnesses)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_derive_voting_seed_deterministic() {
        let wallet_seed = [0x42u8; 64];
        let s1 = derive_voting_seed(&wallet_seed);
        let s2 = derive_voting_seed(&wallet_seed);
        assert_eq!(s1, s2);
    }

    #[test]
    fn test_derive_voting_seed_different_inputs() {
        let s1 = derive_voting_seed(&[0x01; 64]);
        let s2 = derive_voting_seed(&[0x02; 64]);
        assert_ne!(s1, s2);
    }

    #[test]
    fn test_derive_hotkey_from_voting_seed() {
        let vs = derive_voting_seed(&[0xAB; 64]);
        let hk = derive_hotkey(&vs).unwrap();
        assert_eq!(hk.secret_key.len(), 32);
        assert_eq!(hk.public_key.len(), 32);
        assert!(hk.address.starts_with("sv1"));
    }

    #[test]
    fn test_bundle_notes_empty() {
        let result = bundle_notes(&[]);
        assert!(result.bundles.is_empty());
        assert_eq!(result.eligible_weight, 0);
    }

    #[test]
    fn test_compute_proposals_hash() {
        let json = r#"[{"id":1,"title":"Approve","options":[{"index":0,"label":"Support"},{"index":1,"label":"Oppose"}]}]"#;
        let hash = compute_proposals_hash(json);
        assert_eq!(hash.len(), 32);
        assert_eq!(hash, compute_proposals_hash(json));
    }
}
