//! Zipher HITL relay protocol v1: pairing, end-to-end encrypted approval
//! requests and phone-signed decisions. See `docs/hitl-relay-protocol.md`.
//!
//! The relay only ever sees `channel_id`, token hashes and opaque ciphertexts.
//! An agent signs a transaction only after it has verified a phone signature
//! over a proposal hash that it computed itself.

use anyhow::{anyhow, bail, ensure, Result};
use base64::engine::general_purpose::URL_SAFE_NO_PAD as B64;
use base64::Engine as _;
use chacha20poly1305::aead::{Aead, KeyInit, Payload};
use chacha20poly1305::{XChaCha20Poly1305, XNonce};
use ed25519_dalek::{Signature, Signer, SigningKey, VerifyingKey};
use hkdf::Hkdf;
use hmac::{Hmac, Mac};
use rand::RngCore;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use subtle::ConstantTimeEq;
use x25519_dalek::{PublicKey, StaticSecret};
use zeroize::Zeroizing;

pub const PROTOCOL: &str = "zipher-hitl-v1";
/// Longest lifetime a request may claim, in seconds.
pub const MAX_REQUEST_TTL_SECS: u64 = 600;
pub const MAX_ADDRESS_LEN: usize = 256;
pub const MAX_MEMO_BYTES: usize = 512;
pub const MAX_CONTEXT_LEN: usize = 128;
pub const MAX_TOOL_LEN: usize = 64;
pub const MAX_AGENT_NAME_LEN: usize = 64;

const PAIR_CHECK_PERSONAL: &[u8; 16] = b"ZipherHitlPairCk";
const PROPOSAL_PERSONAL: &[u8; 16] = b"ZipherHitlApprv1";
const DECISION_DOMAIN: &[u8] = b"zipher-hitl-decision-v1";
const PAIR_MAC_DOMAIN: &[u8] = b"zipher-hitl-pair-v1";

pub type ChannelId = [u8; 16];

pub fn b64(bytes: &[u8]) -> String {
    B64.encode(bytes)
}

pub fn unb64<const N: usize>(s: &str) -> Result<[u8; N]> {
    let v = B64.decode(s.as_bytes()).map_err(|_| anyhow!("invalid base64"))?;
    v.try_into().map_err(|_| anyhow!("wrong length"))
}

fn random<const N: usize>() -> [u8; N] {
    let mut out = [0u8; N];
    rand::rngs::OsRng.fill_bytes(&mut out);
    out
}

/// SHA-256 of a bearer token; the relay stores only this.
pub fn token_hash(token: &[u8; 32]) -> [u8; 32] {
    Sha256::digest(token).into()
}

/// Constant-time comparison of a presented token against a stored hash.
pub fn token_matches(token: &[u8], stored_hash: &[u8; 32]) -> bool {
    let h: [u8; 32] = Sha256::digest(token).into();
    h.ct_eq(stored_hash).into()
}

fn hkdf32(salt: &[u8], ikm: &[u8], info: &[u8]) -> Zeroizing<[u8; 32]> {
    let mut out = Zeroizing::new([0u8; 32]);
    Hkdf::<Sha256>::new(Some(salt), ikm)
        .expand(info, out.as_mut())
        .expect("32 bytes is a valid HKDF-SHA256 length");
    out
}

/// Bearer tokens for each side, derived from the pairing secret.
pub struct ChannelTokens {
    pub agent: Zeroizing<[u8; 32]>,
    pub phone: Zeroizing<[u8; 32]>,
}

pub fn derive_tokens(channel_id: &ChannelId, pair_secret: &[u8; 32]) -> ChannelTokens {
    ChannelTokens {
        agent: hkdf32(channel_id, pair_secret, b"zipher-hitl-v1 agent-token"),
        phone: hkdf32(channel_id, pair_secret, b"zipher-hitl-v1 phone-token"),
    }
}

// ---------------------------------------------------------------------------
// Pairing
// ---------------------------------------------------------------------------

/// What the agent shows as a QR code. It contains the pairing secret, so it
/// must only be displayed locally and never sent to the relay.
#[derive(Clone)]
pub struct PairingOffer {
    pub relay_url: String,
    pub channel_id: ChannelId,
    pub agent_public: [u8; 32],
    pub pair_secret: Zeroizing<[u8; 32]>,
    pub agent_name: String,
}

/// The agent's long-lived X25519 secret.
pub struct AgentSecret(StaticSecret);

impl AgentSecret {
    pub fn generate() -> Self {
        Self(StaticSecret::from(random::<32>()))
    }
    pub fn from_bytes(bytes: [u8; 32]) -> Self {
        Self(StaticSecret::from(bytes))
    }
    pub fn to_bytes(&self) -> Zeroizing<[u8; 32]> {
        Zeroizing::new(self.0.to_bytes())
    }
    pub fn public(&self) -> [u8; 32] {
        PublicKey::from(&self.0).to_bytes()
    }
}

/// Validate a relay URL: HTTPS, or plain HTTP only to a loopback host.
pub fn validate_relay_url(url: &str) -> Result<()> {
    ensure!(url.len() <= 200, "relay URL too long");
    ensure!(!url.chars().any(|c| c.is_whitespace() || c.is_control()), "invalid relay URL");
    if let Some(rest) = url.strip_prefix("https://") {
        ensure!(!rest.is_empty() && !rest.contains('@'), "invalid relay URL");
        return Ok(());
    }
    if let Some(rest) = url.strip_prefix("http://") {
        let host = rest.split(['/', ':']).next().unwrap_or("");
        ensure!(
            matches!(host, "localhost" | "127.0.0.1" | "[::1]"),
            "relay must use https"
        );
        return Ok(());
    }
    bail!("relay must use https")
}

fn validate_agent_name(name: &str) -> Result<()> {
    ensure!(!name.trim().is_empty(), "agent name is empty");
    ensure!(name.chars().count() <= MAX_AGENT_NAME_LEN, "agent name too long");
    ensure!(!name.chars().any(char::is_control), "agent name has control characters");
    Ok(())
}

fn pct_encode(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for b in s.bytes() {
        if b.is_ascii_alphanumeric() || b"-._~".contains(&b) {
            out.push(b as char);
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}

fn pct_decode(s: &str) -> Result<String> {
    let bytes = s.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' {
            let hex = s.get(i + 1..i + 3).ok_or_else(|| anyhow!("bad escape"))?;
            out.push(u8::from_str_radix(hex, 16).map_err(|_| anyhow!("bad escape"))?);
            i += 3;
        } else {
            out.push(bytes[i]);
            i += 1;
        }
    }
    String::from_utf8(out).map_err(|_| anyhow!("invalid UTF-8"))
}

impl PairingOffer {
    pub fn new(relay_url: &str, agent_name: &str, agent: &AgentSecret) -> Result<Self> {
        validate_relay_url(relay_url)?;
        validate_agent_name(agent_name)?;
        Ok(Self {
            relay_url: relay_url.trim_end_matches('/').to_string(),
            channel_id: random(),
            agent_public: agent.public(),
            pair_secret: Zeroizing::new(random()),
            agent_name: agent_name.to_string(),
        })
    }

    pub fn tokens(&self) -> ChannelTokens {
        derive_tokens(&self.channel_id, &self.pair_secret)
    }

    /// Six-digit code shown by both the agent and the phone.
    pub fn check_code(&self) -> String {
        let h = blake2b_simd::Params::new()
            .hash_length(32)
            .personal(PAIR_CHECK_PERSONAL)
            .to_state()
            .update(&self.channel_id)
            .update(&self.agent_public)
            .finalize();
        let n = u64::from_le_bytes(h.as_bytes()[..8].try_into().unwrap()) % 1_000_000;
        format!("{n:06}")
    }

    pub fn to_uri(&self) -> String {
        format!(
            "zipher://pair?v=1&r={}&c={}&k={}&s={}&n={}",
            pct_encode(&self.relay_url),
            b64(&self.channel_id),
            b64(&self.agent_public),
            b64(self.pair_secret.as_ref()),
            pct_encode(&self.agent_name),
        )
    }

    pub fn from_uri(uri: &str) -> Result<Self> {
        let query = uri
            .strip_prefix("zipher://pair?")
            .ok_or_else(|| anyhow!("not a Zipher pairing link"))?;
        let (mut v, mut r, mut c, mut k, mut s, mut n) = (None, None, None, None, None, None);
        for part in query.split('&') {
            let (key, value) = part.split_once('=').ok_or_else(|| anyhow!("malformed pairing link"))?;
            let slot = match key {
                "v" => &mut v,
                "r" => &mut r,
                "c" => &mut c,
                "k" => &mut k,
                "s" => &mut s,
                "n" => &mut n,
                _ => continue,
            };
            ensure!(slot.is_none(), "duplicate pairing parameter");
            *slot = Some(value.to_string());
        }
        ensure!(v.as_deref() == Some("1"), "unsupported pairing version; update Zipher");
        let relay_url = pct_decode(&r.ok_or_else(|| anyhow!("missing relay"))?)?;
        validate_relay_url(&relay_url)?;
        let agent_name = pct_decode(&n.ok_or_else(|| anyhow!("missing agent name"))?)?;
        validate_agent_name(&agent_name)?;
        Ok(Self {
            relay_url,
            channel_id: unb64(&c.ok_or_else(|| anyhow!("missing channel"))?)?,
            agent_public: unb64(&k.ok_or_else(|| anyhow!("missing agent key"))?)?,
            pair_secret: Zeroizing::new(unb64(&s.ok_or_else(|| anyhow!("missing secret"))?)?),
            agent_name,
        })
    }

    fn transcript_mac(&self, phone: &PhonePublic) -> [u8; 32] {
        let mut mac = <Hmac<Sha256> as Mac>::new_from_slice(self.pair_secret.as_ref())
            .expect("HMAC accepts any key length");
        mac.update(PAIR_MAC_DOMAIN);
        mac.update(&self.channel_id);
        mac.update(&self.agent_public);
        mac.update(&phone.x25519);
        mac.update(&phone.ed25519);
        mac.finalize().into_bytes().into()
    }
}

/// The phone's keys: X25519 for encryption and Ed25519 for signing decisions.
/// Both belong in platform secure storage.
pub struct PhoneKeys {
    x: StaticSecret,
    sign: SigningKey,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PhonePublic {
    pub x25519: [u8; 32],
    pub ed25519: [u8; 32],
}

impl PhoneKeys {
    pub fn generate() -> Self {
        Self {
            x: StaticSecret::from(random::<32>()),
            sign: SigningKey::from_bytes(&random::<32>()),
        }
    }
    /// 64 bytes: X25519 secret followed by the Ed25519 seed.
    pub fn to_bytes(&self) -> Zeroizing<[u8; 64]> {
        let mut out = Zeroizing::new([0u8; 64]);
        out[..32].copy_from_slice(&self.x.to_bytes());
        out[32..].copy_from_slice(&self.sign.to_bytes());
        out
    }
    pub fn from_bytes(bytes: &[u8]) -> Result<Self> {
        ensure!(bytes.len() == 64, "phone key must be 64 bytes");
        let x: [u8; 32] = bytes[..32].try_into().unwrap();
        let s: [u8; 32] = bytes[32..].try_into().unwrap();
        Ok(Self { x: StaticSecret::from(x), sign: SigningKey::from_bytes(&s) })
    }
    pub fn public(&self) -> PhonePublic {
        PhonePublic {
            x25519: PublicKey::from(&self.x).to_bytes(),
            ed25519: self.sign.verifying_key().to_bytes(),
        }
    }
}

/// Sent by the phone to the relay, read by the agent.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct PairResponse {
    pub phone_x25519: String,
    pub phone_ed25519: String,
    pub mac: String,
}

pub fn make_pair_response(offer: &PairingOffer, phone: &PhoneKeys) -> PairResponse {
    let public = phone.public();
    PairResponse {
        phone_x25519: b64(&public.x25519),
        phone_ed25519: b64(&public.ed25519),
        mac: b64(&offer.transcript_mac(&public)),
    }
}

/// Verify the phone's response with the pairing secret and return the keys to pin.
pub fn verify_pair_response(offer: &PairingOffer, resp: &PairResponse) -> Result<PhonePublic> {
    let public = PhonePublic {
        x25519: unb64(&resp.phone_x25519)?,
        ed25519: unb64(&resp.phone_ed25519)?,
    };
    VerifyingKey::from_bytes(&public.ed25519).map_err(|_| anyhow!("invalid phone signing key"))?;
    let got: [u8; 32] = unb64(&resp.mac)?;
    let want = offer.transcript_mac(&public);
    ensure!(bool::from(got.ct_eq(&want)), "pairing response failed verification");
    Ok(public)
}

// ---------------------------------------------------------------------------
// Encrypted messages
// ---------------------------------------------------------------------------

#[derive(Clone, Copy)]
enum Direction {
    AgentToPhone,
    PhoneToAgent,
}

impl Direction {
    fn info(self) -> &'static [u8] {
        match self {
            Self::AgentToPhone => b"zipher-hitl-v1 agent->phone",
            Self::PhoneToAgent => b"zipher-hitl-v1 phone->agent",
        }
    }
    fn kind(self) -> &'static [u8] {
        match self {
            Self::AgentToPhone => b"request",
            Self::PhoneToAgent => b"decision",
        }
    }
}

fn message_key(
    secret: &StaticSecret,
    peer: &[u8; 32],
    channel_id: &ChannelId,
    dir: Direction,
) -> Result<Zeroizing<[u8; 32]>> {
    let shared = secret.diffie_hellman(&PublicKey::from(*peer));
    ensure!(shared.was_contributory(), "invalid peer key");
    Ok(hkdf32(channel_id, shared.as_bytes(), dir.info()))
}

fn aad(dir: Direction, channel_id: &ChannelId, approval_id: &str) -> Vec<u8> {
    let mut a = Vec::with_capacity(64);
    a.extend_from_slice(PROTOCOL.as_bytes());
    a.push(0);
    a.extend_from_slice(dir.kind());
    a.push(0);
    a.extend_from_slice(channel_id);
    a.extend_from_slice(approval_id.as_bytes());
    a
}

/// An opaque message as stored by the relay.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct Sealed {
    pub nonce: String,
    pub ciphertext: String,
}

fn seal(key: &[u8; 32], aad: &[u8], plaintext: &[u8]) -> Sealed {
    let nonce: [u8; 24] = random();
    let ct = XChaCha20Poly1305::new(key.into())
        .encrypt(XNonce::from_slice(&nonce), Payload { msg: plaintext, aad })
        .expect("encryption of bounded plaintext cannot fail");
    Sealed { nonce: b64(&nonce), ciphertext: b64(&ct) }
}

fn open(key: &[u8; 32], aad: &[u8], sealed: &Sealed) -> Result<Zeroizing<Vec<u8>>> {
    let nonce: [u8; 24] = unb64(&sealed.nonce)?;
    let ct = B64.decode(sealed.ciphertext.as_bytes()).map_err(|_| anyhow!("invalid base64"))?;
    XChaCha20Poly1305::new(key.into())
        .decrypt(XNonce::from_slice(&nonce), Payload { msg: &ct, aad })
        .map(Zeroizing::new)
        .map_err(|_| anyhow!("message failed authentication"))
}

/// The send the agent wants approved. Every field is shown on the phone.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ApprovalRequest {
    pub approval_id: String,
    pub network: String,
    pub address: String,
    pub amount: u64,
    pub fee: u64,
    pub memo: Option<String>,
    pub context_id: Option<String>,
    pub tool: String,
    pub created_at: u64,
    pub expires_at: u64,
}

pub fn new_approval_id() -> String {
    hex_lower(&random::<16>())
}

fn hex_lower(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

impl ApprovalRequest {
    pub fn validate(&self) -> Result<()> {
        ensure!(
            self.approval_id.len() == 32 && self.approval_id.bytes().all(|b| b.is_ascii_hexdigit()),
            "invalid approval id"
        );
        ensure!(matches!(self.network.as_str(), "main" | "test"), "invalid network");
        ensure!(!self.address.is_empty() && self.address.len() <= MAX_ADDRESS_LEN, "invalid address");
        ensure!(self.address.bytes().all(|b| b.is_ascii_alphanumeric()), "invalid address");
        ensure!(self.amount > 0, "amount must be positive");
        ensure!(self.amount.checked_add(self.fee).is_some(), "amount overflow");
        if let Some(m) = &self.memo {
            ensure!(m.len() <= MAX_MEMO_BYTES, "memo too long");
        }
        if let Some(c) = &self.context_id {
            ensure!(c.len() <= MAX_CONTEXT_LEN && !c.chars().any(char::is_control), "invalid context id");
        }
        ensure!(
            !self.tool.is_empty() && self.tool.len() <= MAX_TOOL_LEN
                && self.tool.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_'),
            "invalid tool name"
        );
        ensure!(
            self.expires_at > self.created_at && self.expires_at - self.created_at <= MAX_REQUEST_TTL_SECS,
            "invalid expiry"
        );
        Ok(())
    }

    /// Hash both sides compute independently and the phone signs.
    pub fn proposal_hash(&self) -> [u8; 32] {
        fn put(st: &mut blake2b_simd::State, bytes: &[u8]) {
            st.update(&(bytes.len() as u32).to_le_bytes());
            st.update(bytes);
        }
        fn put_opt(st: &mut blake2b_simd::State, v: &Option<String>) {
            match v {
                None => {
                    st.update(&[0]);
                }
                Some(s) => {
                    st.update(&[1]);
                    put(st, s.as_bytes());
                }
            }
        }
        let mut st = blake2b_simd::Params::new()
            .hash_length(32)
            .personal(PROPOSAL_PERSONAL)
            .to_state();
        put(&mut st, self.approval_id.as_bytes());
        put(&mut st, self.network.as_bytes());
        put(&mut st, self.address.as_bytes());
        st.update(&self.amount.to_le_bytes());
        st.update(&self.fee.to_le_bytes());
        put_opt(&mut st, &self.memo);
        put_opt(&mut st, &self.context_id);
        put(&mut st, self.tool.as_bytes());
        st.update(&self.created_at.to_le_bytes());
        st.update(&self.expires_at.to_le_bytes());
        st.finalize().as_bytes().try_into().unwrap()
    }
}

/// Agent side: encrypt a request for the paired phone.
pub fn seal_request(
    agent: &AgentSecret,
    phone: &PhonePublic,
    channel_id: &ChannelId,
    req: &ApprovalRequest,
) -> Result<Sealed> {
    req.validate()?;
    let key = message_key(&agent.0, &phone.x25519, channel_id, Direction::AgentToPhone)?;
    let body = Zeroizing::new(serde_json::to_vec(req)?);
    Ok(seal(&key, &aad(Direction::AgentToPhone, channel_id, &req.approval_id), &body))
}

/// Phone side: decrypt and validate a request from the paired agent.
pub fn open_request(
    phone: &PhoneKeys,
    agent_public: &[u8; 32],
    channel_id: &ChannelId,
    approval_id: &str,
    sealed: &Sealed,
) -> Result<ApprovalRequest> {
    let key = message_key(&phone.x, agent_public, channel_id, Direction::AgentToPhone)?;
    let body = open(&key, &aad(Direction::AgentToPhone, channel_id, approval_id), sealed)?;
    let req: ApprovalRequest = serde_json::from_slice(&body)?;
    ensure!(req.approval_id == approval_id, "approval id mismatch");
    req.validate()?;
    Ok(req)
}

/// The phone's answer, signed over the proposal hash.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct Decision {
    pub approval_id: String,
    pub approved: bool,
    pub decided_at: u64,
    pub signature: String,
}

fn decision_message(proposal_hash: &[u8; 32], approved: bool, decided_at: u64) -> Vec<u8> {
    let mut m = Vec::with_capacity(DECISION_DOMAIN.len() + 41);
    m.extend_from_slice(DECISION_DOMAIN);
    m.extend_from_slice(proposal_hash);
    m.push(approved as u8);
    m.extend_from_slice(&decided_at.to_le_bytes());
    m
}

pub fn sign_decision(phone: &PhoneKeys, req: &ApprovalRequest, approved: bool, decided_at: u64) -> Decision {
    let sig = phone.sign.sign(&decision_message(&req.proposal_hash(), approved, decided_at));
    Decision {
        approval_id: req.approval_id.clone(),
        approved,
        decided_at,
        signature: b64(&sig.to_bytes()),
    }
}

pub fn seal_decision(
    phone: &PhoneKeys,
    agent_public: &[u8; 32],
    channel_id: &ChannelId,
    decision: &Decision,
) -> Result<Sealed> {
    let key = message_key(&phone.x, agent_public, channel_id, Direction::PhoneToAgent)?;
    let body = serde_json::to_vec(decision)?;
    Ok(seal(&key, &aad(Direction::PhoneToAgent, channel_id, &decision.approval_id), &body))
}

pub fn open_decision(
    agent: &AgentSecret,
    phone: &PhonePublic,
    channel_id: &ChannelId,
    approval_id: &str,
    sealed: &Sealed,
) -> Result<Decision> {
    let key = message_key(&agent.0, &phone.x25519, channel_id, Direction::PhoneToAgent)?;
    let body = open(&key, &aad(Direction::PhoneToAgent, channel_id, approval_id), sealed)?;
    let d: Decision = serde_json::from_slice(&body)?;
    ensure!(d.approval_id == approval_id, "approval id mismatch");
    Ok(d)
}

/// Agent side: accept a decision only if the pinned phone key signed the
/// agent's own request before it expired. Returns whether it was approved.
pub fn verify_decision(phone: &PhonePublic, own_request: &ApprovalRequest, d: &Decision, now: u64) -> Result<bool> {
    ensure!(d.approval_id == own_request.approval_id, "approval id mismatch");
    ensure!(now <= own_request.expires_at, "approval expired");
    ensure!(
        d.decided_at >= own_request.created_at && d.decided_at <= own_request.expires_at,
        "decision outside the request window"
    );
    let key = VerifyingKey::from_bytes(&phone.ed25519).map_err(|_| anyhow!("invalid pinned key"))?;
    let sig = Signature::from_bytes(&unb64::<64>(&d.signature)?);
    key.verify_strict(&decision_message(&own_request.proposal_hash(), d.approved, d.decided_at), &sig)
        .map_err(|_| anyhow!("decision signature is invalid"))?;
    Ok(d.approved)
}

// ---------------------------------------------------------------------------
// Relay wire types
// ---------------------------------------------------------------------------

pub mod wire {
    use serde::{Deserialize, Serialize};

    /// Largest opaque field the relay accepts, in base64 characters.
    pub const MAX_BLOB_CHARS: usize = 4096;

    #[derive(Debug, Clone, Serialize, Deserialize)]
    pub struct RegisterChannel {
        pub channel_id: String,
        pub agent_token_hash: String,
        pub phone_token_hash: String,
    }

    #[derive(Debug, Clone, Serialize, Deserialize)]
    pub struct PostRequest {
        pub approval_id: String,
        pub expires_at: u64,
        pub sealed: super::Sealed,
    }

    #[derive(Debug, Clone, Serialize, Deserialize)]
    pub struct PendingRequests {
        pub requests: Vec<PostRequest>,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn request(now: u64) -> ApprovalRequest {
        ApprovalRequest {
            approval_id: new_approval_id(),
            network: "main".into(),
            address: "u1testaddress".into(),
            amount: 150_000_000,
            fee: 10_000,
            memo: Some("Paiement facture n°42 — merci".into()),
            context_id: Some("ctx-7".into()),
            tool: "propose_send".into(),
            created_at: now,
            expires_at: now + 300,
        }
    }

    fn paired() -> (AgentSecret, PairingOffer, PhoneKeys, PhonePublic) {
        let agent = AgentSecret::generate();
        let offer = PairingOffer::new("https://relay.example", "laptop agent", &agent).unwrap();
        let phone = PhoneKeys::generate();
        let resp = make_pair_response(&PairingOffer::from_uri(&offer.to_uri()).unwrap(), &phone);
        let pinned = verify_pair_response(&offer, &resp).unwrap();
        (agent, offer, phone, pinned)
    }

    #[test]
    fn pairing_uri_round_trips_and_codes_match() {
        let agent = AgentSecret::generate();
        let offer = PairingOffer::new("https://relay.example/", "Mon agent ✓", &agent).unwrap();
        let parsed = PairingOffer::from_uri(&offer.to_uri()).unwrap();
        assert_eq!(parsed.relay_url, "https://relay.example");
        assert_eq!(parsed.agent_name, "Mon agent ✓");
        assert_eq!(parsed.channel_id, offer.channel_id);
        assert_eq!(parsed.check_code(), offer.check_code());
        assert_eq!(offer.check_code().len(), 6);
        assert_eq!(*parsed.tokens().agent, *offer.tokens().agent);
        assert_ne!(*offer.tokens().agent, *offer.tokens().phone);
    }

    #[test]
    fn pairing_rejects_bad_links_and_relays() {
        assert!(PairingOffer::from_uri("zipher://pair?v=2&r=x").is_err());
        assert!(validate_relay_url("http://relay.example").is_err());
        assert!(validate_relay_url("https://user@relay.example").is_err());
        assert!(validate_relay_url("http://127.0.0.1:8080").is_ok());
        let agent = AgentSecret::generate();
        let offer = PairingOffer::new("https://relay.example", "a", &agent).unwrap();
        let dup = format!("{}&c={}", offer.to_uri(), b64(&[0u8; 16]));
        assert!(PairingOffer::from_uri(&dup).is_err());
    }

    #[test]
    fn relay_cannot_substitute_phone_keys() {
        let agent = AgentSecret::generate();
        let offer = PairingOffer::new("https://relay.example", "a", &agent).unwrap();
        let mut resp = make_pair_response(&offer, &PhoneKeys::generate());
        resp.phone_x25519 = b64(&PhoneKeys::generate().public().x25519);
        assert!(verify_pair_response(&offer, &resp).is_err());
    }

    #[test]
    fn approval_round_trip_and_signature_binding() {
        let (agent, offer, phone, pinned) = paired();
        let now = 1_800_000_000;
        let req = request(now);
        let sealed = seal_request(&agent, &pinned, &offer.channel_id, &req).unwrap();
        let opened = open_request(&phone, &offer.agent_public, &offer.channel_id, &req.approval_id, &sealed).unwrap();
        assert_eq!(opened, req);

        let d = sign_decision(&phone, &opened, true, now + 20);
        let sealed_d = seal_decision(&phone, &offer.agent_public, &offer.channel_id, &d).unwrap();
        let got = open_decision(&agent, &pinned, &offer.channel_id, &req.approval_id, &sealed_d).unwrap();
        assert!(verify_decision(&pinned, &req, &got, now + 30).unwrap());

        // A signature is only valid for the exact proposal the agent holds.
        let mut other = req.clone();
        other.amount += 1;
        assert!(verify_decision(&pinned, &other, &got, now + 30).is_err());
        let mut other = req.clone();
        other.address = "u1attacker".into();
        assert!(verify_decision(&pinned, &other, &got, now + 30).is_err());

        // Flipping the approved flag breaks the signature.
        let mut flipped = got.clone();
        flipped.approved = !flipped.approved;
        assert!(verify_decision(&pinned, &req, &flipped, now + 30).is_err());

        // Too late, or signed by another phone.
        assert!(verify_decision(&pinned, &req, &got, now + 301).is_err());
        let stranger = sign_decision(&PhoneKeys::generate(), &req, true, now + 20);
        assert!(verify_decision(&pinned, &req, &stranger, now + 30).is_err());
    }

    #[test]
    fn ciphertexts_are_bound_to_direction_channel_and_id() {
        let (agent, offer, phone, pinned) = paired();
        let req = request(1_800_000_000);
        let sealed = seal_request(&agent, &pinned, &offer.channel_id, &req).unwrap();
        assert!(open_request(&phone, &offer.agent_public, &[9u8; 16], &req.approval_id, &sealed).is_err());
        assert!(open_request(&phone, &offer.agent_public, &offer.channel_id, &new_approval_id(), &sealed).is_err());
        // A request cannot be reflected back to the agent as a decision.
        assert!(open_decision(&agent, &pinned, &offer.channel_id, &req.approval_id, &sealed).is_err());
        let mut tampered = sealed.clone();
        let mut ct = B64.decode(tampered.ciphertext.as_bytes()).unwrap();
        ct[0] ^= 1;
        tampered.ciphertext = b64(&ct);
        assert!(open_request(&phone, &offer.agent_public, &offer.channel_id, &req.approval_id, &tampered).is_err());
        // The relay sees no plaintext fields.
        let wire = serde_json::to_string(&sealed).unwrap();
        assert!(!wire.contains("u1testaddress") && !wire.contains("150000000"));
    }

    #[test]
    fn requests_are_validated() {
        let now = 1_800_000_000;
        let mut r = request(now);
        r.expires_at = now + MAX_REQUEST_TTL_SECS + 1;
        assert!(r.validate().is_err());
        let mut r = request(now);
        r.memo = Some("x".repeat(MAX_MEMO_BYTES + 1));
        assert!(r.validate().is_err());
        let mut r = request(now);
        r.address = "u1 evil".into();
        assert!(r.validate().is_err());
        assert!(request(now).validate().is_ok());
    }

    #[test]
    fn keys_round_trip_and_low_order_points_are_rejected() {
        let phone = PhoneKeys::generate();
        let restored = PhoneKeys::from_bytes(phone.to_bytes().as_ref()).unwrap();
        assert_eq!(restored.public(), phone.public());
        let agent = AgentSecret::generate();
        assert_eq!(AgentSecret::from_bytes(*agent.to_bytes()).public(), agent.public());
        let zero = PhonePublic { x25519: [0u8; 32], ed25519: phone.public().ed25519 };
        assert!(seal_request(&agent, &zero, &[1u8; 16], &request(1_800_000_000)).is_err());
    }

    #[test]
    fn token_hash_comparison() {
        let t = [7u8; 32];
        let h = token_hash(&t);
        assert!(token_matches(&t, &h));
        assert!(!token_matches(&[8u8; 32], &h));
        assert!(!token_matches(b"short", &h));
    }
}
