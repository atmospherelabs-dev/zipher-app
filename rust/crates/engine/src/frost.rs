use std::collections::{BTreeMap, HashMap};
use std::sync::Mutex as StdMutex;

use anyhow::{anyhow, Result};
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _};
use frost_core::{
    frost::{
        self,
        keys::{
            dkg, KeyPackage, PublicKeyPackage, SigningShare, VerifyingShare,
        },
        round1::{NonceCommitment, SigningCommitments, SigningNonces},
        round2::SignatureShare,
        Identifier, SigningPackage,
    },
    Ciphersuite, Field, Group, Scalar, Signature, VerifyingKey,
};
use frost_rerandomized::RandomizedParams;
use rand::{rngs::OsRng, RngCore};
use reddsa::frost::redpallas::PallasBlake2b512;
use serde::{de::DeserializeOwned, Deserialize, Serialize};
use xeddsa::{xed25519, Sign as _, Verify as _};
use zcash_keys::keys::{UnifiedAddressRequest, UnifiedFullViewingKey};
use zcash_primitives::transaction::{
    sighash::SignableInput, sighash_v5::v5_signature_hash, txid::TxIdDigester,
};

type FrostSuite = PallasBlake2b512;
type FrostIdentifier = Identifier<FrostSuite>;
type FrostKeyPackage = KeyPackage<FrostSuite>;
type FrostPublicKeyPackage = PublicKeyPackage<FrostSuite>;
type FrostRound1Secret = dkg::round1::SecretPackage<FrostSuite>;
type FrostRound1Package = dkg::round1::Package<FrostSuite>;
type FrostRound2Secret = dkg::round2::SecretPackage<FrostSuite>;
type FrostRound2Package = dkg::round2::Package<FrostSuite>;
type FrostSigningNonces = SigningNonces<FrostSuite>;
type FrostSigningCommitments = SigningCommitments<FrostSuite>;
type FrostSigningPackage = SigningPackage<FrostSuite>;
type FrostSignatureShare = SignatureShare<FrostSuite>;
type FrostElement = <<FrostSuite as Ciphersuite>::Group as Group>::Element;

lazy_static::lazy_static! {
    static ref DKG_ROUND1_SECRETS: StdMutex<HashMap<String, (u16, FrostRound1Secret)>> =
        StdMutex::new(HashMap::new());
    static ref DKG_ROUND2_SECRETS: StdMutex<HashMap<String, (u16, FrostRound2Secret)>> =
        StdMutex::new(HashMap::new());
    static ref SIGNING_NONCES: StdMutex<HashMap<String, FrostSigningNonces>> =
        StdMutex::new(HashMap::new());
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FrostDkgRound1Result {
    pub participant_id: u16,
    /// Opaque local handle for secret DKG state. Never send to peers.
    pub secret_package: String,
    /// Broadcast package to send to every other participant.
    pub round1_package: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FrostDkgRound2Result {
    /// Opaque local handle for secret DKG state. Never send to peers.
    pub secret_package: String,
    /// Per-recipient packages. Keyed by recipient participant id.
    pub round2_packages: BTreeMap<u16, String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FrostDkgCompleteResult {
    pub participant_id: u16,
    /// Long-lived participant key share. Store in secure storage only.
    pub key_package: String,
    /// Public verification material for the whole group.
    pub public_key_package: String,
    /// Group spend authorization key (ak) as hex.
    pub group_public_key_hex: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FrostSigningRound1Result {
    pub participant_id: u16,
    /// Opaque local handle for one-use signing nonces. Never reuse.
    pub signing_nonces: String,
    /// Commitment to send to the signing coordinator.
    pub signing_commitments: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FrostRandomizerResult {
    /// Secret randomizer scalar. Coordinator keeps this until aggregate.
    pub randomizer_hex: String,
    /// Public randomizer point sent to every signer.
    pub randomizer_point_hex: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FrostAggregateResult {
    /// Final RedPallas-compatible signature bytes as hex.
    pub signature_hex: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FrostWalletView {
    pub ufvk: String,
    pub address: String,
    pub group_public_key_hex: String,
    pub orchard_fvk_hex: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FrostPcztActionRequest {
    pub action_index: usize,
    /// ZIP-244 shielded sighash shared by all shielded spends in this PCZT.
    pub sighash_hex: String,
    /// Secret spend authorization randomizer from PCZT. Coordinator-only.
    pub randomizer_hex: String,
    /// Public randomizer point to send to signing participants.
    pub randomizer_point_hex: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FrostPcztSigningRequest {
    pub orchard_actions: Vec<FrostPcztActionRequest>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FrostRelayIdentity {
    pub private_key_hex: String,
    pub public_key_hex: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FrostRelayLoginProof {
    pub pubkey_hex: String,
    pub signature_hex: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct EncodedRound1Package {
    commitments: Vec<String>,
    proof: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct EncodedRound2Package {
    secret_share: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct EncodedSigningCommitments {
    hiding: String,
    binding: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct EncodedKeyPackage {
    participant_id: u16,
    secret_share: String,
    public_share: String,
    group_public: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct EncodedPublicKeyPackage {
    signer_pubkeys: BTreeMap<u16, String>,
    group_public: String,
}

fn token(prefix: &str) -> String {
    let mut bytes = [0u8; 16];
    OsRng.fill_bytes(&mut bytes);
    format!("{prefix}_{}", hex::encode(bytes))
}

fn encode_json<T: Serialize>(value: &T) -> Result<String> {
    let bytes = serde_json::to_vec(value)?;
    Ok(URL_SAFE_NO_PAD.encode(bytes))
}

fn decode_json<T: DeserializeOwned>(encoded: &str) -> Result<T> {
    let bytes = URL_SAFE_NO_PAD
        .decode(encoded)
        .map_err(|e| anyhow!("Invalid base64url payload: {e}"))?;
    Ok(serde_json::from_slice(&bytes)?)
}

fn id_from_u16(id: u16) -> Result<FrostIdentifier> {
    FrostIdentifier::try_from(id)
        .map_err(|e| anyhow!("Invalid FROST participant id {id}: {:?}", e))
}

fn id_to_u16(id: &FrostIdentifier) -> Result<u16> {
    let bytes = id.serialize();
    let raw: &[u8] = bytes.as_ref();
    if raw.len() < 2 || raw[2..].iter().any(|b| *b != 0) {
        return Err(anyhow!("Participant id is not representable as u16"));
    }
    Ok(u16::from_le_bytes([raw[0], raw[1]]))
}

fn scalar_to_hex(s: &Scalar<FrostSuite>) -> String {
    let bytes = <<FrostSuite as Ciphersuite>::Group as Group>::Field::serialize(s);
    hex::encode(bytes.as_ref() as &[u8])
}

fn scalar_from_hex(hex_value: &str) -> Result<Scalar<FrostSuite>> {
    let bytes = hex::decode(hex_value).map_err(|e| anyhow!("Invalid scalar hex: {e}"))?;
    let ser = bytes
        .try_into()
        .map_err(|_| anyhow!("Invalid scalar byte length"))?;
    <<FrostSuite as Ciphersuite>::Group as Group>::Field::deserialize(&ser)
        .map_err(|e| anyhow!("Invalid scalar: {:?}", e))
}

fn element_to_hex(e: &FrostElement) -> String {
    let bytes = <FrostSuite as Ciphersuite>::Group::serialize(e);
    hex::encode(bytes.as_ref() as &[u8])
}

fn normalize_key_package(key: FrostKeyPackage) -> Result<FrostKeyPackage> {
    let group_hex = verifying_key_to_hex(key.group_public());
    let needs_negation = hex::decode(&group_hex)
        .map_err(|e| anyhow!("invalid group key hex: {e}"))?
        .last()
        .map(|b| b & 0x80 != 0)
        .unwrap_or(false);
    if !needs_negation {
        return Ok(key);
    }

    let secret = scalar_from_hex(&signing_share_to_hex(key.secret_share()))?;
    let neg_secret = <<FrostSuite as Ciphersuite>::Group as Group>::Field::zero() - secret;
    let secret_share = SigningShare::<FrostSuite>::deserialize(
        <<FrostSuite as Ciphersuite>::Group as Group>::Field::serialize(&neg_secret),
    )
    .map_err(|e| anyhow!("failed to normalize secret share: {:?}", e))?;
    let public = VerifyingShare::<FrostSuite>::from(secret_share);
    let group_element = element_from_hex(&group_hex)?;
    let neg_group = <FrostSuite as Ciphersuite>::Group::identity() - group_element;
    let group_public = VerifyingKey::<FrostSuite>::deserialize(
        <FrostSuite as Ciphersuite>::Group::serialize(&neg_group),
    )
    .map_err(|e| anyhow!("failed to normalize group public key: {:?}", e))?;
    Ok(FrostKeyPackage::new(
        *key.identifier(),
        secret_share,
        public,
        group_public,
    ))
}

fn normalize_public_key_package(public: FrostPublicKeyPackage) -> Result<FrostPublicKeyPackage> {
    let group_hex = verifying_key_to_hex(public.group_public());
    let needs_negation = hex::decode(&group_hex)
        .map_err(|e| anyhow!("invalid group key hex: {e}"))?
        .last()
        .map(|b| b & 0x80 != 0)
        .unwrap_or(false);
    if !needs_negation {
        return Ok(public);
    }

    let mut signer_pubkeys = HashMap::new();
    for (id, share) in public.signer_pubkeys() {
        let element = element_from_hex(&verifying_share_to_hex(share))?;
        let neg = <FrostSuite as Ciphersuite>::Group::identity() - element;
        let normalized = VerifyingShare::<FrostSuite>::deserialize(
            <FrostSuite as Ciphersuite>::Group::serialize(&neg),
        )
        .map_err(|e| anyhow!("failed to normalize verifying share: {:?}", e))?;
        signer_pubkeys.insert(*id, normalized);
    }
    let group_element = element_from_hex(&group_hex)?;
    let neg_group = <FrostSuite as Ciphersuite>::Group::identity() - group_element;
    let group_public = VerifyingKey::<FrostSuite>::deserialize(
        <FrostSuite as Ciphersuite>::Group::serialize(&neg_group),
    )
    .map_err(|e| anyhow!("failed to normalize group public key: {:?}", e))?;
    Ok(FrostPublicKeyPackage::new(signer_pubkeys, group_public))
}

fn element_from_hex(hex_value: &str) -> Result<FrostElement> {
    let bytes = hex::decode(hex_value).map_err(|e| anyhow!("Invalid point hex: {e}"))?;
    let ser = bytes
        .try_into()
        .map_err(|_| anyhow!("Invalid point byte length"))?;
    <FrostSuite as Ciphersuite>::Group::deserialize(&ser)
        .map_err(|e| anyhow!("Invalid point: {:?}", e))
}

fn signing_share_to_hex(s: &SigningShare<FrostSuite>) -> String {
    let bytes = s.serialize();
    hex::encode(bytes.as_ref() as &[u8])
}

fn signing_share_from_hex(hex_value: &str) -> Result<SigningShare<FrostSuite>> {
    let bytes = hex::decode(hex_value).map_err(|e| anyhow!("Invalid signing share hex: {e}"))?;
    let ser = bytes
        .try_into()
        .map_err(|_| anyhow!("Invalid signing share byte length"))?;
    SigningShare::<FrostSuite>::deserialize(ser)
        .map_err(|e| anyhow!("Invalid signing share: {:?}", e))
}

fn verifying_share_to_hex(v: &VerifyingShare<FrostSuite>) -> String {
    let bytes = v.serialize();
    hex::encode(bytes.as_ref() as &[u8])
}

fn verifying_share_from_hex(hex_value: &str) -> Result<VerifyingShare<FrostSuite>> {
    let bytes = hex::decode(hex_value).map_err(|e| anyhow!("Invalid verifying share hex: {e}"))?;
    let ser = bytes
        .try_into()
        .map_err(|_| anyhow!("Invalid verifying share byte length"))?;
    VerifyingShare::<FrostSuite>::deserialize(ser)
        .map_err(|e| anyhow!("Invalid verifying share: {:?}", e))
}

fn verifying_key_to_hex(v: &VerifyingKey<FrostSuite>) -> String {
    let bytes = v.serialize();
    hex::encode(bytes.as_ref() as &[u8])
}

fn verifying_key_from_hex(hex_value: &str) -> Result<VerifyingKey<FrostSuite>> {
    let bytes = hex::decode(hex_value).map_err(|e| anyhow!("Invalid verifying key hex: {e}"))?;
    let ser = bytes
        .try_into()
        .map_err(|_| anyhow!("Invalid verifying key byte length"))?;
    VerifyingKey::<FrostSuite>::deserialize(ser)
        .map_err(|e| anyhow!("Invalid verifying key: {:?}", e))
}

fn round1_to_wire(package: &FrostRound1Package) -> Result<String> {
    let commitments = package
        .commitment()
        .serialize()
        .iter()
        .map(|c| hex::encode(c.as_ref() as &[u8]))
        .collect();
    let proof = package.proof_of_knowledge().serialize();
    encode_json(&EncodedRound1Package {
        commitments,
        proof: hex::encode(proof.as_ref() as &[u8]),
    })
}

fn round1_from_wire(encoded: &str) -> Result<FrostRound1Package> {
    let wire: EncodedRound1Package = decode_json(encoded)?;
    let mut commitments = Vec::with_capacity(wire.commitments.len());
    for c in wire.commitments {
        let bytes = hex::decode(c).map_err(|e| anyhow!("Invalid commitment hex: {e}"))?;
        commitments.push(
            bytes
                .try_into()
                .map_err(|_| anyhow!("Invalid commitment byte length"))?,
        );
    }
    let commitment = frost_core::frost::keys::VerifiableSecretSharingCommitment::<FrostSuite>::deserialize(commitments)
        .map_err(|e| anyhow!("Invalid VSS commitment: {:?}", e))?;
    let sig_bytes = hex::decode(wire.proof).map_err(|e| anyhow!("Invalid proof hex: {e}"))?;
    let sig_ser = sig_bytes
        .try_into()
        .map_err(|_| anyhow!("Invalid proof byte length"))?;
    let proof = Signature::<FrostSuite>::deserialize(sig_ser)
        .map_err(|e| anyhow!("Invalid DKG proof: {:?}", e))?;
    Ok(FrostRound1Package::new(commitment, proof))
}

fn round2_to_wire(package: &FrostRound2Package) -> Result<String> {
    encode_json(&EncodedRound2Package {
        secret_share: signing_share_to_hex(package.secret_share()),
    })
}

fn round2_from_wire(encoded: &str) -> Result<FrostRound2Package> {
    let wire: EncodedRound2Package = decode_json(encoded)?;
    Ok(FrostRound2Package::new(signing_share_from_hex(
        &wire.secret_share,
    )?))
}

fn commitments_to_wire(commitments: &FrostSigningCommitments) -> Result<String> {
    let hiding = commitments.hiding().serialize();
    let binding = commitments.binding().serialize();
    encode_json(&EncodedSigningCommitments {
        hiding: hex::encode(hiding.as_ref() as &[u8]),
        binding: hex::encode(binding.as_ref() as &[u8]),
    })
}

fn commitments_from_wire(encoded: &str) -> Result<FrostSigningCommitments> {
    let wire: EncodedSigningCommitments = decode_json(encoded)?;
    let hiding = {
        let bytes = hex::decode(wire.hiding).map_err(|e| anyhow!("Invalid hiding commitment: {e}"))?;
        NonceCommitment::<FrostSuite>::deserialize(
            bytes
                .try_into()
                .map_err(|_| anyhow!("Invalid hiding commitment length"))?,
        )
        .map_err(|e| anyhow!("Invalid hiding commitment: {:?}", e))?
    };
    let binding = {
        let bytes =
            hex::decode(wire.binding).map_err(|e| anyhow!("Invalid binding commitment: {e}"))?;
        NonceCommitment::<FrostSuite>::deserialize(
            bytes
                .try_into()
                .map_err(|_| anyhow!("Invalid binding commitment length"))?,
        )
        .map_err(|e| anyhow!("Invalid binding commitment: {:?}", e))?
    };
    Ok(FrostSigningCommitments::new(hiding, binding))
}

fn key_package_to_wire(key: &FrostKeyPackage) -> Result<String> {
    encode_json(&EncodedKeyPackage {
        participant_id: id_to_u16(key.identifier())?,
        secret_share: signing_share_to_hex(key.secret_share()),
        public_share: verifying_share_to_hex(key.public()),
        group_public: verifying_key_to_hex(key.group_public()),
    })
}

fn key_package_from_wire(encoded: &str) -> Result<FrostKeyPackage> {
    let wire: EncodedKeyPackage = decode_json(encoded)?;
    Ok(FrostKeyPackage::new(
        id_from_u16(wire.participant_id)?,
        signing_share_from_hex(&wire.secret_share)?,
        verifying_share_from_hex(&wire.public_share)?,
        verifying_key_from_hex(&wire.group_public)?,
    ))
}

fn public_key_package_to_wire(public: &FrostPublicKeyPackage) -> Result<String> {
    let mut signer_pubkeys = BTreeMap::new();
    for (id, share) in public.signer_pubkeys() {
        signer_pubkeys.insert(id_to_u16(id)?, verifying_share_to_hex(share));
    }
    encode_json(&EncodedPublicKeyPackage {
        signer_pubkeys,
        group_public: verifying_key_to_hex(public.group_public()),
    })
}

fn public_key_package_from_wire(encoded: &str) -> Result<FrostPublicKeyPackage> {
    let wire: EncodedPublicKeyPackage = decode_json(encoded)?;
    let mut signer_pubkeys = HashMap::with_capacity(wire.signer_pubkeys.len());
    for (id, share) in wire.signer_pubkeys {
        signer_pubkeys.insert(id_from_u16(id)?, verifying_share_from_hex(&share)?);
    }
    Ok(FrostPublicKeyPackage::new(
        signer_pubkeys,
        verifying_key_from_hex(&wire.group_public)?,
    ))
}

pub fn frost_dkg_init(
    participant_id: u16,
    max_signers: u16,
    min_signers: u16,
) -> Result<FrostDkgRound1Result> {
    let identifier = id_from_u16(participant_id)?;
    let (secret, package) = dkg::part1::<FrostSuite, _>(identifier, max_signers, min_signers, OsRng)
        .map_err(|e| anyhow!("FROST DKG round 1 failed: {:?}", e))?;

    let handle = token("dkg1");
    DKG_ROUND1_SECRETS
        .lock()
        .unwrap()
        .insert(handle.clone(), (participant_id, secret));

    Ok(FrostDkgRound1Result {
        participant_id,
        secret_package: handle,
        round1_package: round1_to_wire(&package)?,
    })
}

pub fn frost_dkg_round2(
    secret_package: String,
    round1_packages: BTreeMap<u16, String>,
) -> Result<FrostDkgRound2Result> {
    let (participant_id, secret) = DKG_ROUND1_SECRETS
        .lock()
        .unwrap()
        .remove(&secret_package)
        .ok_or_else(|| anyhow!("Unknown or expired DKG round 1 secret handle"))?;
    let mut packages = HashMap::with_capacity(round1_packages.len());
    for (id, package) in round1_packages {
        packages.insert(id_from_u16(id)?, round1_from_wire(&package)?);
    }

    let (secret2, outbound) = dkg::part2::<FrostSuite>(secret, &packages)
        .map_err(|e| anyhow!("FROST DKG round 2 failed: {:?}", e))?;

    let handle = token("dkg2");
    DKG_ROUND2_SECRETS
        .lock()
        .unwrap()
        .insert(handle.clone(), (participant_id, secret2));

    let mut encoded = BTreeMap::new();
    for (id, package) in outbound {
        encoded.insert(id_to_u16(&id)?, round2_to_wire(&package)?);
    }

    Ok(FrostDkgRound2Result {
        secret_package: handle,
        round2_packages: encoded,
    })
}

pub fn frost_dkg_round3(
    secret_package: String,
    round1_packages: BTreeMap<u16, String>,
    round2_packages: BTreeMap<u16, String>,
) -> Result<FrostDkgCompleteResult> {
    let (participant_id, secret) = DKG_ROUND2_SECRETS
        .lock()
        .unwrap()
        .remove(&secret_package)
        .ok_or_else(|| anyhow!("Unknown or expired DKG round 2 secret handle"))?;

    let mut r1 = HashMap::with_capacity(round1_packages.len());
    for (id, package) in round1_packages {
        r1.insert(id_from_u16(id)?, round1_from_wire(&package)?);
    }

    let mut r2 = HashMap::with_capacity(round2_packages.len());
    for (id, package) in round2_packages {
        r2.insert(id_from_u16(id)?, round2_from_wire(&package)?);
    }

    let (key_package, public_key_package) = dkg::part3::<FrostSuite>(&secret, &r1, &r2)
        .map_err(|e| anyhow!("FROST DKG round 3 failed: {:?}", e))?;
    let key_package = normalize_key_package(key_package)?;
    let public_key_package = normalize_public_key_package(public_key_package)?;
    let group_public_key_hex = verifying_key_to_hex(public_key_package.group_public());

    Ok(FrostDkgCompleteResult {
        participant_id,
        key_package: key_package_to_wire(&key_package)?,
        public_key_package: public_key_package_to_wire(&public_key_package)?,
        group_public_key_hex,
    })
}

pub fn frost_sign_round1(key_package: String) -> Result<FrostSigningRound1Result> {
    let key_package = key_package_from_wire(&key_package)?;
    let (nonces, commitments) = frost::round1::commit(key_package.secret_share(), &mut OsRng);
    let handle = token("fn");
    SIGNING_NONCES.lock().unwrap().insert(handle.clone(), nonces);
    Ok(FrostSigningRound1Result {
        participant_id: id_to_u16(key_package.identifier())?,
        signing_nonces: handle,
        signing_commitments: commitments_to_wire(&commitments)?,
    })
}

pub fn frost_create_signing_package(
    message_hex: String,
    commitments: BTreeMap<u16, String>,
) -> Result<String> {
    let message = hex::decode(message_hex).map_err(|e| anyhow!("Invalid message hex: {e}"))?;
    let mut map = BTreeMap::new();
    for (id, commitment) in commitments {
        map.insert(id_from_u16(id)?, commitments_from_wire(&commitment)?);
    }
    encode_json(&EncodedSigningPackage::from_package(&FrostSigningPackage::new(
        map, &message,
    ))?)
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct EncodedSigningPackage {
    commitments: BTreeMap<u16, String>,
    message_hex: String,
}

impl EncodedSigningPackage {
    fn from_package(package: &FrostSigningPackage) -> Result<Self> {
        let mut commitments = BTreeMap::new();
        for (id, commitment) in package.signing_commitments() {
            commitments.insert(id_to_u16(id)?, commitments_to_wire(commitment)?);
        }
        Ok(Self {
            commitments,
            message_hex: hex::encode(package.message()),
        })
    }

    fn into_package(self) -> Result<FrostSigningPackage> {
        let message =
            hex::decode(self.message_hex).map_err(|e| anyhow!("Invalid message hex: {e}"))?;
        let mut commitments = BTreeMap::new();
        for (id, commitment) in self.commitments {
            commitments.insert(id_from_u16(id)?, commitments_from_wire(&commitment)?);
        }
        Ok(FrostSigningPackage::new(commitments, &message))
    }
}

fn signing_package_from_wire(encoded: &str) -> Result<FrostSigningPackage> {
    decode_json::<EncodedSigningPackage>(encoded)?.into_package()
}

pub fn frost_create_randomizer(public_key_package: String) -> Result<FrostRandomizerResult> {
    let public_key_package = public_key_package_from_wire(&public_key_package)?;
    let params = RandomizedParams::<FrostSuite>::new(&public_key_package, OsRng);
    Ok(FrostRandomizerResult {
        randomizer_hex: scalar_to_hex(params.randomizer()),
        randomizer_point_hex: element_to_hex(params.randomizer_point()),
    })
}

pub fn frost_sign_round2(
    signing_package: String,
    signing_nonces: String,
    key_package: String,
    randomizer_point_hex: String,
) -> Result<String> {
    let signing_package = signing_package_from_wire(&signing_package)?;
    let signing_nonces = SIGNING_NONCES
        .lock()
        .unwrap()
        .remove(&signing_nonces)
        .ok_or_else(|| anyhow!("Unknown or already-used signing nonce handle"))?;
    let key_package = key_package_from_wire(&key_package)?;
    let randomizer_point = element_from_hex(&randomizer_point_hex)?;
    let share =
        frost_rerandomized::sign(&signing_package, &signing_nonces, &key_package, &randomizer_point)
            .map_err(|e| anyhow!("FROST signing failed: {:?}", e))?;
    let bytes = share.serialize();
    Ok(hex::encode(bytes.as_ref() as &[u8]))
}

pub fn frost_aggregate(
    signing_package: String,
    signature_shares: BTreeMap<u16, String>,
    public_key_package: String,
    randomizer_hex: String,
) -> Result<FrostAggregateResult> {
    let signing_package = signing_package_from_wire(&signing_package)?;
    let public_key_package = public_key_package_from_wire(&public_key_package)?;
    let randomizer = scalar_from_hex(&randomizer_hex)?;
    let randomized_params =
        RandomizedParams::<FrostSuite>::from_randomizer(&public_key_package, randomizer);

    let mut shares = HashMap::with_capacity(signature_shares.len());
    for (id, share_hex) in signature_shares {
        let bytes =
            hex::decode(share_hex).map_err(|e| anyhow!("Invalid signature share hex: {e}"))?;
        let ser = bytes
            .try_into()
            .map_err(|_| anyhow!("Invalid signature share byte length"))?;
        let share = FrostSignatureShare::deserialize(ser)
            .map_err(|e| anyhow!("Invalid signature share: {:?}", e))?;
        shares.insert(id_from_u16(id)?, share);
    }

    let sig = frost_rerandomized::aggregate(
        &signing_package,
        &shares,
        &public_key_package,
        &randomized_params,
    )
    .map_err(|e| anyhow!("FROST aggregate failed: {:?}", e))?;

    Ok(FrostAggregateResult {
        signature_hex: hex::encode(sig.serialize().as_ref() as &[u8]),
    })
}

pub fn frost_pczt_signing_request(pczt_bytes: Vec<u8>) -> Result<FrostPcztSigningRequest> {
    let pczt = pczt::Pczt::parse(&pczt_bytes)
        .map_err(|e| anyhow!("Failed to parse PCZT: {:?}", e))?;
    let effects = pczt
        .clone()
        .into_effects()
        .map_err(|e| anyhow!("PCZT does not contain signable transaction effects: {:?}", e))?;
    let txid_parts = effects.digest(TxIdDigester);
    let sighash = v5_signature_hash(&effects, &SignableInput::Shielded, &txid_parts);
    let sighash_bytes: [u8; 32] = sighash
        .as_ref()
        .try_into()
        .map_err(|_| anyhow!("invalid shielded sighash length"))?;
    let sighash_hex = hex::encode(sighash_bytes);

    let pczt_json = serde_json::to_value(&pczt)?;
    let actions = pczt_json["orchard"]["actions"]
        .as_array()
        .ok_or_else(|| anyhow!("PCZT orchard actions were not encoded as an array"))?;

    let mut orchard_actions = Vec::new();
    for (idx, action) in actions.iter().enumerate() {
        if !action["spend"]["spend_auth_sig"].is_null() {
            continue;
        }
        let Some(alpha_values) = action["spend"]["alpha"].as_array() else {
            continue;
        };
        let mut alpha = Vec::with_capacity(alpha_values.len());
        for value in alpha_values {
            let b = value
                .as_u64()
                .ok_or_else(|| anyhow!("Invalid Orchard alpha byte"))?;
            if b > u8::MAX as u64 {
                return Err(anyhow!("Invalid Orchard alpha byte"));
            }
            alpha.push(b as u8);
        }
        if alpha.len() != 32 {
            return Err(anyhow!("Orchard spend auth randomizer must be 32 bytes"));
        }
        let randomizer_hex = hex::encode(alpha);
        let randomizer = scalar_from_hex(&randomizer_hex)?;
        let randomizer_point = <FrostSuite as Ciphersuite>::Group::generator() * randomizer;
        orchard_actions.push(FrostPcztActionRequest {
            action_index: idx,
            sighash_hex: sighash_hex.clone(),
            randomizer_hex,
            randomizer_point_hex: element_to_hex(&randomizer_point),
        });
    }

    Ok(FrostPcztSigningRequest { orchard_actions })
}

pub fn frost_pczt_apply_signatures(
    pczt_bytes: Vec<u8>,
    orchard_signatures: BTreeMap<usize, String>,
) -> Result<Vec<u8>> {
    let pczt = pczt::Pczt::parse(&pczt_bytes)
        .map_err(|e| anyhow!("Failed to parse PCZT: {:?}", e))?;
    let mut value = serde_json::to_value(&pczt)?;

    for (idx, sig_hex) in orchard_signatures {
        let sig_bytes = hex::decode(sig_hex).map_err(|e| anyhow!("Invalid signature hex: {e}"))?;
        if sig_bytes.len() != 64 {
            return Err(anyhow!("Orchard spend auth signature must be 64 bytes"));
        }
        value["orchard"]["actions"][idx]["spend"]["spend_auth_sig"] =
            serde_json::Value::Array(
                sig_bytes
                    .into_iter()
                    .map(|b| serde_json::Value::from(b as u64))
                    .collect(),
            );
    }

    // Shielded signatures commit to all transaction effects, so no inputs,
    // outputs, or shielded components may be modified after applying them.
    if let Some(tx_modifiable) = value["global"]["tx_modifiable"].as_u64() {
        let cleared = (tx_modifiable as u8) & !(0b0000_0001 | 0b0000_0010 | 0b1000_0000);
        value["global"]["tx_modifiable"] = serde_json::Value::from(cleared);
    }

    let signed_pczt: pczt::Pczt = serde_json::from_value(value)?;
    Ok(signed_pczt.serialize())
}

pub fn frost_create_view_from_group_key(
    group_public_key_hex: String,
    network: zcash_protocol::consensus::Network,
) -> Result<FrostWalletView> {
    let ak = hex::decode(&group_public_key_hex)
        .map_err(|e| anyhow!("Invalid group public key hex: {e}"))?;
    if ak.len() != 32 {
        return Err(anyhow!("Group public key must be 32 bytes"));
    }
    if ak[31] & 0x80 != 0 {
        return Err(anyhow!(
            "FROST group key is not normalized for Orchard ak encoding"
        ));
    }

    let mut fvk_bytes = [0u8; 96];
    fvk_bytes[0..32].copy_from_slice(&ak);
    for _ in 0..1024 {
        OsRng.fill_bytes(&mut fvk_bytes[32..64]); // nk
        OsRng.fill_bytes(&mut fvk_bytes[64..96]); // rivk
        if let Some(orchard_fvk) = orchard::keys::FullViewingKey::from_bytes(&fvk_bytes) {
            let ufvk = UnifiedFullViewingKey::from_orchard_fvk(orchard_fvk.clone())
                .map_err(|e| anyhow!("Construct UFVK: {:?}", e))?;
            let (ua, _) = ufvk
                .default_address(UnifiedAddressRequest::ORCHARD)
                .map_err(|e| anyhow!("FROST address derivation failed: {:?}", e))?;
            return Ok(FrostWalletView {
                ufvk: ufvk.encode(&network),
                address: ua.encode(&network),
                group_public_key_hex,
                orchard_fvk_hex: hex::encode(fvk_bytes),
            });
        }
    }
    Err(anyhow!("Failed to generate valid Orchard FVK viewing material"))
}

pub fn frost_derive_ufvk(group_public_key_hex: String) -> Result<String> {
    Ok(frost_create_view_from_group_key(
        group_public_key_hex,
        zcash_protocol::consensus::Network::MainNetwork,
    )?
    .ufvk)
}

pub fn frost_key_refresh(_key_package: String, _new_signer_count: u16) -> Result<String> {
    Err(anyhow!(
        "FROST key refresh is intentionally disabled until the wallet persists \
         the full repair/refresh transcript. A KeyPackage alone is not enough \
         to safely rotate shares without changing wallet spend authority."
    ))
}

pub fn frost_relay_generate_identity() -> Result<FrostRelayIdentity> {
    let builder = snow::Builder::new(
        "Noise_K_25519_ChaChaPoly_BLAKE2s"
            .parse()
            .expect("valid Noise pattern"),
    );
    let keypair = builder.generate_keypair()?;
    Ok(FrostRelayIdentity {
        private_key_hex: hex::encode(keypair.private),
        public_key_hex: hex::encode(keypair.public),
    })
}

pub fn frost_relay_sign_challenge(
    private_key_hex: String,
    public_key_hex: String,
    challenge: String,
) -> Result<FrostRelayLoginProof> {
    let priv_bytes = hex::decode(private_key_hex)
        .map_err(|e| anyhow!("Invalid relay private key hex: {e}"))?;
    let priv_arr: [u8; 32] = priv_bytes
        .try_into()
        .map_err(|_| anyhow!("Relay private key must be 32 bytes"))?;
    let private = xed25519::PrivateKey::from(&priv_arr);
    let challenge_uuid =
        uuid::Uuid::parse_str(&challenge).map_err(|e| anyhow!("Invalid challenge UUID: {e}"))?;
    let challenge_bytes = challenge_uuid.as_bytes();
    let sig: [u8; 64] = private.sign(challenge_bytes, &mut OsRng);
    let pub_bytes = hex::decode(&public_key_hex)
        .map_err(|e| anyhow!("Invalid relay public key hex: {e}"))?;
    let pub_arr: [u8; 32] = pub_bytes
        .try_into()
        .map_err(|_| anyhow!("Relay public key must be 32 bytes"))?;
    let public = xed25519::PublicKey(pub_arr);
    public
        .verify(challenge_bytes, &sig)
        .map_err(|_| anyhow!("Generated relay signature did not verify locally"))?;
    Ok(FrostRelayLoginProof {
        pubkey_hex: public_key_hex,
        signature_hex: hex::encode(sig),
    })
}

pub fn frost_relay_encrypt(
    sender_private_key_hex: String,
    recipient_public_key_hex: String,
    message_hex: String,
) -> Result<String> {
    let sender_private = hex::decode(sender_private_key_hex)
        .map_err(|e| anyhow!("Invalid relay private key hex: {e}"))?;
    let recipient_public = hex::decode(recipient_public_key_hex)
        .map_err(|e| anyhow!("Invalid recipient public key hex: {e}"))?;
    let message = hex::decode(message_hex).map_err(|e| anyhow!("Invalid message hex: {e}"))?;
    let builder = snow::Builder::new(
        "Noise_K_25519_ChaChaPoly_BLAKE2s"
            .parse()
            .expect("valid Noise pattern"),
    );
    let mut noise = builder
        .local_private_key(&sender_private)
        .remote_public_key(&recipient_public)
        .build_initiator()?;
    let mut out = vec![0u8; message.len() + 1024];
    let n = noise.write_message(&message, &mut out)?;
    out.truncate(n);
    Ok(hex::encode(out))
}

pub fn frost_relay_decrypt(
    recipient_private_key_hex: String,
    sender_public_key_hex: String,
    encrypted_hex: String,
) -> Result<String> {
    let recipient_private = hex::decode(recipient_private_key_hex)
        .map_err(|e| anyhow!("Invalid relay private key hex: {e}"))?;
    let sender_public =
        hex::decode(sender_public_key_hex).map_err(|e| anyhow!("Invalid sender public key hex: {e}"))?;
    let encrypted = hex::decode(encrypted_hex).map_err(|e| anyhow!("Invalid encrypted hex: {e}"))?;
    let builder = snow::Builder::new(
        "Noise_K_25519_ChaChaPoly_BLAKE2s"
            .parse()
            .expect("valid Noise pattern"),
    );
    let mut noise = builder
        .local_private_key(&recipient_private)
        .remote_public_key(&sender_public)
        .build_responder()?;
    let mut out = vec![0u8; encrypted.len() + 1024];
    let n = noise.read_message(&encrypted, &mut out)?;
    out.truncate(n);
    Ok(hex::encode(out))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pkg(id: u16, package: &str) -> (u16, String) {
        (id, package.to_string())
    }

    #[test]
    fn frost_2_of_3_dkg_and_signing_roundtrip() {
        let p1 = frost_dkg_init(1, 3, 2).unwrap();
        let p2 = frost_dkg_init(2, 3, 2).unwrap();
        let p3 = frost_dkg_init(3, 3, 2).unwrap();

        let r2_1 = frost_dkg_round2(
            p1.secret_package,
            BTreeMap::from([
                pkg(2, &p2.round1_package),
                pkg(3, &p3.round1_package),
            ]),
        )
        .unwrap();
        let r2_2 = frost_dkg_round2(
            p2.secret_package,
            BTreeMap::from([
                pkg(1, &p1.round1_package),
                pkg(3, &p3.round1_package),
            ]),
        )
        .unwrap();
        let r2_3 = frost_dkg_round2(
            p3.secret_package,
            BTreeMap::from([
                pkg(1, &p1.round1_package),
                pkg(2, &p2.round1_package),
            ]),
        )
        .unwrap();

        let c1 = frost_dkg_round3(
            r2_1.secret_package,
            BTreeMap::from([
                pkg(2, &p2.round1_package),
                pkg(3, &p3.round1_package),
            ]),
            BTreeMap::from([
                pkg(2, r2_2.round2_packages.get(&1).unwrap()),
                pkg(3, r2_3.round2_packages.get(&1).unwrap()),
            ]),
        )
        .unwrap();
        let c2 = frost_dkg_round3(
            r2_2.secret_package,
            BTreeMap::from([
                pkg(1, &p1.round1_package),
                pkg(3, &p3.round1_package),
            ]),
            BTreeMap::from([
                pkg(1, r2_1.round2_packages.get(&2).unwrap()),
                pkg(3, r2_3.round2_packages.get(&2).unwrap()),
            ]),
        )
        .unwrap();
        let c3 = frost_dkg_round3(
            r2_3.secret_package,
            BTreeMap::from([
                pkg(1, &p1.round1_package),
                pkg(2, &p2.round1_package),
            ]),
            BTreeMap::from([
                pkg(1, r2_1.round2_packages.get(&3).unwrap()),
                pkg(2, r2_2.round2_packages.get(&3).unwrap()),
            ]),
        )
        .unwrap();

        assert_eq!(c1.group_public_key_hex, c2.group_public_key_hex);
        assert_eq!(c2.group_public_key_hex, c3.group_public_key_hex);

        let s1 = frost_sign_round1(c1.key_package.clone()).unwrap();
        let s2 = frost_sign_round1(c2.key_package.clone()).unwrap();

        let message_hex = "ab".repeat(32);
        let signing_package = frost_create_signing_package(
            message_hex,
            BTreeMap::from([
                (1, s1.signing_commitments.clone()),
                (2, s2.signing_commitments.clone()),
            ]),
        )
        .unwrap();
        let randomizer = frost_create_randomizer(c1.public_key_package.clone()).unwrap();

        let share1 = frost_sign_round2(
            signing_package.clone(),
            s1.signing_nonces,
            c1.key_package,
            randomizer.randomizer_point_hex.clone(),
        )
        .unwrap();
        let share2 = frost_sign_round2(
            signing_package.clone(),
            s2.signing_nonces,
            c2.key_package,
            randomizer.randomizer_point_hex,
        )
        .unwrap();

        let sig = frost_aggregate(
            signing_package,
            BTreeMap::from([(1, share1), (2, share2)]),
            c1.public_key_package,
            randomizer.randomizer_hex,
        )
        .unwrap();
        assert_eq!(sig.signature_hex.len(), 128);
    }
}
