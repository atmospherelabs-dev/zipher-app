//! Mobile HITL (human-in-the-loop) approvals over the blind relay.
//!
//! Protocol v1, see `docs/hitl-relay-protocol.md`.
//! - The relay carries only fixed-size ciphertexts.
//! - After pairing, both sides use a new mailbox (channel and tokens) every
//!   UTC day, derived from a root only they know, and reach the relay over Tor
//!   by default, so the relay cannot link days or learn network addresses.
//! - An agent signs a send only after it has verified the paired phone's
//!   Ed25519 signature over the proposal hash it computed itself.
//!
//! Agent state lives in `<data_dir>/hitl.json` with mode 0600. It holds the
//! agent's X25519 secret and the rotation root, which can read and post
//! requests but cannot approve anything: that needs the phone's signing key.

use anyhow::{anyhow, bail, Context, Result};
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use std::time::Duration;
use zeroize::Zeroizing;
use zipher_hitl_protocol::{self as proto, b64, epoch_of, unb64, wire};

use crate::hitl_net::{Net, Reply};

pub use proto::ApprovalRequest;

pub const DEFAULT_RELAY_URL: &str = "https://relay.atmospherelabs.dev";
/// How long the phone has to approve a send.
pub const APPROVAL_TTL_SECS: u64 = 300;
/// How long a pairing code stays valid (the relay drops it after 10 minutes).
pub const PAIRING_TTL_SECS: u64 = 600;
/// Unpairing revokes, and push covers, this many upcoming daily mailboxes.
const DAYS_AHEAD: u64 = 7;

fn now_unix() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

fn channel_url(relay: &str, day: &proto::EpochChannel, rest: &str) -> String {
    format!("{relay}/v1/channels/{}{rest}", b64(&day.channel_id))
}

/// Make sure a day's mailbox exists. Either side may create it; whoever
/// comes second gets 409, which is fine.
async fn ensure_day(net: &Net, relay: &str, day: &proto::EpochChannel) -> Result<()> {
    let body = serde_json::to_vec(&wire::RegisterChannel {
        channel_id: b64(&day.channel_id),
        agent_token_hash: b64(&proto::token_hash(&day.agent_token)),
        phone_token_hash: b64(&proto::token_hash(&day.phone_token)),
        rotated: true,
    })?;
    let r = net.post(&format!("{relay}/v1/channels"), None, Some(body)).await?;
    match r.status {
        201 | 409 => Ok(()),
        s => bail!("Relay refused the mailbox ({s})"),
    }
}

// ---------------------------------------------------------------------------
// Agent state
// ---------------------------------------------------------------------------

#[derive(Clone, Serialize, Deserialize)]
struct Pairing {
    relay_url: String,
    root: String,
    agent_secret: String,
    phone_x25519: String,
    phone_ed25519: String,
    agent_name: String,
    paired_at: u64,
    #[serde(default = "default_true")]
    tor: bool,
}

fn default_true() -> bool {
    true
}

#[derive(Clone, Default, Serialize, Deserialize)]
struct AgentState {
    #[serde(default)]
    pairing: Option<Pairing>,
}

fn state_path(data_dir: &str) -> PathBuf {
    PathBuf::from(data_dir).join("hitl.json")
}

fn load_state(data_dir: &str) -> Result<AgentState> {
    match std::fs::read(state_path(data_dir)) {
        // Older formats have no rotation root and parse as "not paired", so
        // users simply pair again.
        Ok(bytes) => Ok(serde_json::from_slice(&bytes).unwrap_or_default()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(AgentState::default()),
        Err(e) => Err(e).context("read hitl.json"),
    }
}

fn save_state(data_dir: &str, state: &AgentState) -> Result<()> {
    let path = state_path(data_dir);
    let tmp = path.with_extension("json.tmp");
    let json = Zeroizing::new(serde_json::to_vec_pretty(state)?);
    {
        use std::io::Write;
        let mut opts = std::fs::OpenOptions::new();
        opts.write(true).create(true).truncate(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            opts.mode(0o600);
        }
        let mut f = opts.open(&tmp).context("write hitl.json")?;
        f.write_all(&json)?;
        f.sync_all()?;
    }
    std::fs::rename(&tmp, &path).context("replace hitl.json")?;
    Ok(())
}

struct Paired {
    relay_url: String,
    root: Zeroizing<[u8; 32]>,
    agent: proto::AgentSecret,
    phone: proto::PhonePublic,
    tor: bool,
}

impl Pairing {
    fn open(&self) -> Result<Paired> {
        Ok(Paired {
            relay_url: self.relay_url.clone(),
            root: Zeroizing::new(unb64(&self.root)?),
            agent: proto::AgentSecret::from_bytes(unb64(&self.agent_secret)?),
            phone: proto::PhonePublic {
                x25519: unb64(&self.phone_x25519)?,
                ed25519: unb64(&self.phone_ed25519)?,
            },
            tor: self.tor,
        })
    }
}

impl Paired {
    async fn net(&self, data_dir: &str) -> Result<Net> {
        Net::for_relay(&self.relay_url, self.tor, Path::new(data_dir)).await
    }
}

/// Public summary of the agent's pairing state. Contains no secrets.
#[derive(Debug, Clone, Serialize)]
pub struct HitlStatus {
    pub paired: bool,
    pub relay_url: Option<String>,
    pub agent_name: Option<String>,
    pub paired_at: Option<u64>,
    pub tor: Option<bool>,
}

pub fn status(data_dir: &str) -> Result<HitlStatus> {
    let s = load_state(data_dir)?;
    Ok(HitlStatus {
        paired: s.pairing.is_some(),
        relay_url: s.pairing.as_ref().map(|p| p.relay_url.clone()),
        agent_name: s.pairing.as_ref().map(|p| p.agent_name.clone()),
        paired_at: s.pairing.as_ref().map(|p| p.paired_at),
        tor: s.pairing.as_ref().map(|p| p.tor),
    })
}

pub fn is_paired(data_dir: &str) -> bool {
    load_state(data_dir).map(|s| s.pairing.is_some()).unwrap_or(false)
}

// ---------------------------------------------------------------------------
// Agent: pairing
// ---------------------------------------------------------------------------

/// What the operator shows to the phone. `uri` contains the pairing secret:
/// display it locally as a QR code, never send it anywhere else.
#[derive(Debug, Clone, Serialize)]
pub struct PairingStart {
    pub uri: String,
    pub check_code: String,
    pub relay_url: String,
    pub expires_in_secs: u64,
    pub tor: bool,
}

/// An unfinished pairing. It holds the pairing secret in memory only and is
/// meant for the operator's own terminal (`zipher pair`). Never expose it to
/// an agent: whoever holds the secret could pair a fake phone.
pub struct PairingSession {
    offer: proto::PairingOffer,
    agent: proto::AgentSecret,
    net: Net,
    tor: bool,
    started: std::time::Instant,
    pub start: PairingStart,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum PairingProgress {
    /// Waiting for the phone to scan and confirm.
    Waiting,
    /// The phone confirmed; approvals now go to it.
    Paired,
    /// The pairing code expired; start again.
    Expired,
}

/// Register a pairing channel with the relay and return the session to poll.
/// An existing pairing stays active until the new one completes.
pub async fn start_pairing(
    data_dir: &str,
    relay_url: Option<&str>,
    agent_name: &str,
    tor: bool,
) -> Result<PairingSession> {
    let relay_url = relay_url.unwrap_or(DEFAULT_RELAY_URL).trim_end_matches('/').to_string();
    let agent = proto::AgentSecret::generate();
    let offer = proto::PairingOffer::new(&relay_url, agent_name, &agent)?;
    let tokens = offer.tokens();
    let net = Net::for_relay(&relay_url, tor, Path::new(data_dir)).await?;

    let body = serde_json::to_vec(&wire::RegisterChannel {
        channel_id: b64(&offer.channel_id),
        agent_token_hash: b64(&proto::token_hash(&tokens.agent)),
        phone_token_hash: b64(&proto::token_hash(&tokens.phone)),
        rotated: false,
    })?;
    let r = net.post(&format!("{relay_url}/v1/channels"), None, Some(body)).await?;
    if r.status != 201 {
        bail!("Relay refused the pairing ({})", r.status);
    }

    let start = PairingStart {
        uri: offer.to_uri(),
        check_code: offer.check_code(),
        relay_url,
        expires_in_secs: PAIRING_TTL_SECS,
        tor: net.is_tor(),
    };
    Ok(PairingSession { offer, agent, net, tor, started: std::time::Instant::now(), start })
}

impl PairingSession {
    /// Check whether the phone has answered; on success, save the pairing.
    pub async fn poll(&self, data_dir: &str) -> Result<PairingProgress> {
        if self.started.elapsed() >= Duration::from_secs(PAIRING_TTL_SECS) {
            return Ok(PairingProgress::Expired);
        }
        let tokens = self.offer.tokens();
        let r = self
            .net
            .get(
                &format!("{}/v1/channels/{}/pair", self.offer.relay_url, b64(&self.offer.channel_id)),
                Some(&tokens.agent),
            )
            .await?;
        match r.status {
            204 => return Ok(PairingProgress::Waiting),
            404 => return Ok(PairingProgress::Expired),
            200 => {}
            s => bail!("Relay returned {s}"),
        }
        let pair: proto::PairResponse = r.json()?;
        let phone = proto::verify_pair_response(&self.offer, &pair)?;

        let mut state = load_state(data_dir)?;
        if let Some(old) = state.pairing.take() {
            if let Ok(p) = old.open() {
                let _ = revoke_days(&p, data_dir).await;
            }
        }
        state.pairing = Some(Pairing {
            relay_url: self.offer.relay_url.clone(),
            root: b64(self.offer.rotation_root().as_ref()),
            agent_secret: b64(self.agent.to_bytes().as_ref()),
            phone_x25519: b64(&phone.x25519),
            phone_ed25519: b64(&phone.ed25519),
            agent_name: self.offer.agent_name.clone(),
            paired_at: now_unix(),
            tor: self.tor,
        });
        save_state(data_dir, &state)?;
        tracing::info!("[HITL] Paired with phone");
        Ok(PairingProgress::Paired)
    }
}

/// Revoke today's and the coming week's mailboxes so the phone learns it was
/// unpaired whenever it next checks.
async fn revoke_days(p: &Paired, data_dir: &str) -> Result<()> {
    let net = p.net(data_dir).await?;
    let today = epoch_of(now_unix());
    for e in today..=today + DAYS_AHEAD {
        let day = proto::epoch_channel(&p.root, e);
        ensure_day(&net, &p.relay_url, &day).await?;
        net.post(&channel_url(&p.relay_url, &day, "/revoke"), Some(&day.agent_token), None).await?;
    }
    Ok(())
}

/// Forget the phone and revoke the mailboxes.
pub async fn unpair(data_dir: &str) -> Result<()> {
    let mut state = load_state(data_dir)?;
    if let Some(p) = state.pairing.take() {
        if let Ok(p) = p.open() {
            let _ = revoke_days(&p, data_dir).await;
        }
    }
    save_state(data_dir, &state)
}

// ---------------------------------------------------------------------------
// Agent: approvals
// ---------------------------------------------------------------------------

/// Everything the phone is asked to approve.
pub struct ApprovalInput<'a> {
    pub network: &'a str,
    pub address: &'a str,
    pub amount: u64,
    pub fee: u64,
    pub memo: Option<&'a str>,
    pub context_id: Option<&'a str>,
    pub tool: &'a str,
}

fn paired(data_dir: &str) -> Result<Paired> {
    load_state(data_dir)?
        .pairing
        .ok_or_else(|| anyhow!("No phone is paired. Run `zipher pair` first."))?
        .open()
}

/// Encrypt the send for the paired phone and post it to today's mailbox.
/// Keep the returned request: the decision is only checked against this copy.
pub async fn request_approval(data_dir: &str, input: ApprovalInput<'_>) -> Result<ApprovalRequest> {
    let p = paired(data_dir)?;
    let now = now_unix();
    let req = ApprovalRequest {
        approval_id: proto::new_approval_id(),
        network: input.network.to_string(),
        address: input.address.to_string(),
        amount: input.amount,
        fee: input.fee,
        memo: input.memo.map(str::to_string),
        context_id: input.context_id.map(str::to_string),
        tool: input.tool.to_string(),
        created_at: now,
        expires_at: now + APPROVAL_TTL_SECS,
    };
    let day = proto::epoch_channel(&p.root, epoch_of(req.created_at));
    let sealed = proto::seal_request(&p.agent, &p.phone, &day.channel_id, &req)?;
    let net = p.net(data_dir).await?;
    ensure_day(&net, &p.relay_url, &day).await?;
    let body = serde_json::to_vec(&wire::PostRequest {
        approval_id: req.approval_id.clone(),
        expires_at: req.expires_at,
        sealed,
    })?;
    let r = net.post(&channel_url(&p.relay_url, &day, "/requests"), Some(&day.agent_token), Some(body)).await?;
    match r.status {
        201 => {}
        410 => bail!("The phone unpaired this agent. Run `zipher pair` again."),
        s => bail!("Relay refused the approval request ({s})"),
    }
    tracing::info!("[HITL] Approval request sent to paired phone");
    Ok(req)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ApprovalOutcome {
    Pending,
    Approved,
    Rejected,
    Expired,
}

/// Fetch and verify the phone's decision for a request this agent sent.
/// Anything that fails verification is treated as a rejection.
pub async fn check_approval(data_dir: &str, req: &ApprovalRequest) -> Result<ApprovalOutcome> {
    let now = now_unix();
    if now > req.expires_at {
        return Ok(ApprovalOutcome::Expired);
    }
    let p = paired(data_dir).map_err(|_| anyhow!("The phone was unpaired while approval was pending."))?;
    let day = proto::epoch_channel(&p.root, epoch_of(req.created_at));
    let net = p.net(data_dir).await?;
    let r = net
        .get(&channel_url(&p.relay_url, &day, &format!("/decisions/{}", req.approval_id)), Some(&day.agent_token))
        .await?;
    match r.status {
        204 => return Ok(ApprovalOutcome::Pending),
        404 | 410 => return Ok(ApprovalOutcome::Expired),
        200 => {}
        s => bail!("Relay returned {s}"),
    }
    let sealed: proto::Sealed = r.json()?;
    let outcome = proto::open_decision(&p.agent, &p.phone, &day.channel_id, &req.approval_id, &sealed)
        .and_then(|d| proto::verify_decision(&p.phone, req, &d, now));
    Ok(match outcome {
        Ok(true) => ApprovalOutcome::Approved,
        Ok(false) => ApprovalOutcome::Rejected,
        Err(e) => {
            tracing::warn!("[HITL] Discarded an invalid decision: {e}");
            ApprovalOutcome::Rejected
        }
    })
}

// ---------------------------------------------------------------------------
// Phone side (called from the app through flutter_rust_bridge)
// ---------------------------------------------------------------------------

/// What the phone shows before the user confirms pairing.
#[derive(Debug, Clone, Serialize)]
pub struct PairingPreview {
    pub relay_url: String,
    pub agent_name: String,
    pub check_code: String,
}

pub fn phone_preview_pairing(uri: &str) -> Result<PairingPreview> {
    let offer = proto::PairingOffer::from_uri(uri)?;
    Ok(PairingPreview {
        relay_url: offer.relay_url.clone(),
        agent_name: offer.agent_name.clone(),
        check_code: offer.check_code(),
    })
}

/// Fresh phone keys, hex encoded, for platform secure storage.
pub fn phone_generate_keys() -> String {
    hex::encode(proto::PhoneKeys::generate().to_bytes().as_ref())
}

/// The phone's record of a pairing. `root` is a secret: store the whole JSON
/// in platform secure storage.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PhonePairing {
    pub relay_url: String,
    pub agent_public: String,
    pub root: String,
    pub agent_name: String,
}

impl PhonePairing {
    fn root(&self) -> Result<Zeroizing<[u8; 32]>> {
        Ok(Zeroizing::new(unb64(&self.root)?))
    }
}

/// How the phone reaches the relay.
pub struct PhoneRoute<'a> {
    /// App documents directory; Tor keeps its state under it.
    pub state_dir: &'a str,
    pub use_tor: bool,
}

impl PhoneRoute<'_> {
    async fn net(&self, relay_url: &str) -> Result<Net> {
        Net::for_relay(relay_url, self.use_tor, Path::new(self.state_dir)).await
    }
}

fn phone_keys(keys_hex: &str) -> Result<proto::PhoneKeys> {
    let bytes = Zeroizing::new(hex::decode(keys_hex).map_err(|_| anyhow!("invalid phone key"))?);
    proto::PhoneKeys::from_bytes(&bytes)
}

/// Answer a pairing offer the user has confirmed.
pub async fn phone_complete_pairing(uri: &str, keys_hex: &str, route: &PhoneRoute<'_>) -> Result<PhonePairing> {
    let offer = proto::PairingOffer::from_uri(uri)?;
    let keys = phone_keys(keys_hex)?;
    let tokens = offer.tokens();
    let net = route.net(&offer.relay_url).await?;
    let body = serde_json::to_vec(&proto::make_pair_response(&offer, &keys))?;
    let r = net
        .post(
            &format!("{}/v1/channels/{}/pair", offer.relay_url, b64(&offer.channel_id)),
            Some(&tokens.phone),
            Some(body),
        )
        .await?;
    match r.status {
        201 => {}
        404 => bail!("This pairing code has expired. Start pairing again on the agent."),
        409 => bail!("This pairing code was already used."),
        s => bail!("Relay returned {s}"),
    }
    Ok(PhonePairing {
        relay_url: offer.relay_url.clone(),
        agent_public: b64(&offer.agent_public),
        root: b64(offer.rotation_root().as_ref()),
        agent_name: offer.agent_name.clone(),
    })
}

fn unpaired() -> anyhow::Error {
    anyhow!("This agent was unpaired.")
}

/// Decrypt the agent's open requests from today's and yesterday's mailboxes.
/// Requests that fail to decrypt or validate are skipped.
pub async fn phone_fetch_requests(
    pairing: &PhonePairing,
    keys_hex: &str,
    route: &PhoneRoute<'_>,
) -> Result<Vec<ApprovalRequest>> {
    let keys = phone_keys(keys_hex)?;
    let root = pairing.root()?;
    let agent_public: [u8; 32] = unb64(&pairing.agent_public)?;
    let net = route.net(&pairing.relay_url).await?;
    let now = now_unix();
    let today = epoch_of(now);
    let mut out = Vec::new();
    // Yesterday covers requests sent just before midnight UTC.
    for e in [today, today.saturating_sub(1)] {
        let day = proto::epoch_channel(&root, e);
        let r: Reply = net.get(&channel_url(&pairing.relay_url, &day, "/requests"), Some(&day.phone_token)).await?;
        match r.status {
            200 => {}
            404 => {
                if e == today {
                    // The agent has not used today's mailbox yet.
                    ensure_day(&net, &pairing.relay_url, &day).await?;
                }
                continue;
            }
            410 => return Err(unpaired()),
            s => bail!("Relay returned {s}"),
        }
        let list: wire::PendingRequests = r.json()?;
        out.extend(
            list.requests
                .iter()
                .filter_map(|r| proto::open_request(&keys, &agent_public, &day.channel_id, &r.approval_id, &r.sealed).ok())
                .filter(|r| r.expires_at >= now && epoch_of(r.created_at) == e),
        );
    }
    Ok(out)
}

/// Sign and send the user's decision on a request returned by
/// [`phone_fetch_requests`].
pub async fn phone_submit_decision(
    pairing: &PhonePairing,
    keys_hex: &str,
    request: &ApprovalRequest,
    approved: bool,
    route: &PhoneRoute<'_>,
) -> Result<()> {
    request.validate()?;
    let now = now_unix();
    if now > request.expires_at {
        bail!("This request has expired.");
    }
    let keys = phone_keys(keys_hex)?;
    let root = pairing.root()?;
    let agent_public: [u8; 32] = unb64(&pairing.agent_public)?;
    let day = proto::epoch_channel(&root, epoch_of(request.created_at));
    let decision = proto::sign_decision(&keys, request, approved, now);
    let sealed = proto::seal_decision(&keys, &agent_public, &day.channel_id, &decision)?;
    let net = route.net(&pairing.relay_url).await?;
    let r = net
        .post(
            &channel_url(&pairing.relay_url, &day, &format!("/decisions/{}", request.approval_id)),
            Some(&day.phone_token),
            Some(serde_json::to_vec(&sealed)?),
        )
        .await?;
    match r.status {
        201 => Ok(()),
        404 => bail!("This request is no longer open; it may have expired or been answered."),
        410 => Err(unpaired()),
        s => bail!("Relay returned {s}"),
    }
}

/// Ask for content-free wake-ups on today's and the coming week's mailboxes.
/// Re-run whenever the app opens so the window keeps moving forward.
/// `token` is the APNs device token (hex); `sandbox` for development builds.
pub async fn phone_set_push(
    pairing: &PhonePairing,
    route: &PhoneRoute<'_>,
    token: Option<(&str, bool)>,
) -> Result<()> {
    let root = pairing.root()?;
    let net = route.net(&pairing.relay_url).await?;
    let today = epoch_of(now_unix());
    for e in today..=today + DAYS_AHEAD {
        let day = proto::epoch_channel(&root, e);
        ensure_day(&net, &pairing.relay_url, &day).await?;
        let r = match token {
            Some((token, sandbox)) => {
                let body = serde_json::to_vec(&serde_json::json!({"platform": "apns", "token": token, "sandbox": sandbox}))?;
                net.post(&channel_url(&pairing.relay_url, &day, "/push"), Some(&day.phone_token), Some(body)).await?
            }
            None => net.post(&channel_url(&pairing.relay_url, &day, "/push/clear"), Some(&day.phone_token), None).await?,
        };
        match r.status {
            204 => {}
            410 => return Err(unpaired()),
            s => bail!("Relay refused the push setting ({s})"),
        }
    }
    Ok(())
}

/// Unpair from the phone: revoke today's and the coming week's mailboxes.
pub async fn phone_unpair(pairing: &PhonePairing, route: &PhoneRoute<'_>) -> Result<()> {
    let root = pairing.root()?;
    let net = route.net(&pairing.relay_url).await?;
    let today = epoch_of(now_unix());
    for e in today..=today + DAYS_AHEAD {
        let day = proto::epoch_channel(&root, e);
        ensure_day(&net, &pairing.relay_url, &day).await?;
        net.post(&channel_url(&pairing.relay_url, &day, "/revoke"), Some(&day.phone_token), None).await?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    async fn spawn_relay() -> String {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move {
            axum::serve(listener, zipher_relay::Relay::new(None).router()).await.unwrap();
        });
        format!("http://{addr}")
    }

    fn temp_dir() -> String {
        let d = std::env::temp_dir().join(format!("zipher-hitl-{}", proto::new_approval_id()));
        std::fs::create_dir_all(&d).unwrap();
        d.to_string_lossy().into_owned()
    }

    fn input(amount: u64) -> ApprovalInput<'static> {
        ApprovalInput {
            network: "main",
            address: "u1merchant",
            amount,
            fee: 10_000,
            memo: Some("invoice 42"),
            context_id: Some("ctx"),
            tool: "propose_send",
        }
    }

    #[tokio::test]
    async fn agent_and_phone_complete_an_approval_over_a_real_relay() {
        // ZIPHER_TEST_RELAY=<url> runs the same flow against a deployed relay
        // (over Tor unless ZIPHER_TEST_NO_TOR is set).
        let (relay, tor) = match std::env::var("ZIPHER_TEST_RELAY") {
            Ok(url) => (url, std::env::var("ZIPHER_TEST_NO_TOR").is_err()),
            Err(_) => (spawn_relay().await, false),
        };
        let dir = temp_dir();
        let phone_dir = temp_dir();
        let route = PhoneRoute { state_dir: &phone_dir, use_tor: tor };

        let session = start_pairing(&dir, Some(&relay), "test agent", tor).await.unwrap();
        let start = session.start.clone();
        assert_eq!(start.tor, tor);
        assert_eq!(session.poll(&dir).await.unwrap(), PairingProgress::Waiting);
        assert!(!status(&dir).unwrap().paired);
        assert!(!state_path(&dir).exists(), "nothing secret is written before the phone answers");

        let preview = phone_preview_pairing(&start.uri).unwrap();
        assert_eq!(preview.check_code, start.check_code);
        let keys = phone_generate_keys();
        let phone = phone_complete_pairing(&start.uri, &keys, &route).await.unwrap();
        assert!(phone_complete_pairing(&start.uri, &keys, &route).await.is_err(), "pairing code is single use");
        assert_eq!(session.poll(&dir).await.unwrap(), PairingProgress::Paired);
        let saved = std::fs::read_to_string(state_path(&dir)).unwrap();
        let secret = start.uri.split("&s=").nth(1).unwrap().split('&').next().unwrap();
        assert!(!saved.contains(secret), "pairing secret must not be stored");
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = std::fs::metadata(state_path(&dir)).unwrap().permissions().mode();
            assert_eq!(mode & 0o777, 0o600);
        }

        // Phone checks before the agent ever wrote today: no error, nothing pending.
        assert!(phone_fetch_requests(&phone, &keys, &route).await.unwrap().is_empty());

        let req = request_approval(&dir, input(200_000_000)).await.unwrap();
        assert_eq!(check_approval(&dir, &req).await.unwrap(), ApprovalOutcome::Pending);
        let open = phone_fetch_requests(&phone, &keys, &route).await.unwrap();
        assert_eq!(open, vec![req.clone()]);
        phone_submit_decision(&phone, &keys, &open[0], true, &route).await.unwrap();
        assert_eq!(check_approval(&dir, &req).await.unwrap(), ApprovalOutcome::Approved);
        assert_eq!(check_approval(&dir, &req).await.unwrap(), ApprovalOutcome::Expired, "read once");

        // A decision the phone signed for a different amount is refused.
        let req2 = request_approval(&dir, input(300_000_000)).await.unwrap();
        let mut altered = phone_fetch_requests(&phone, &keys, &route).await.unwrap().remove(0);
        altered.amount = 1;
        phone_submit_decision(&phone, &keys, &altered, true, &route).await.unwrap();
        assert_eq!(check_approval(&dir, &req2).await.unwrap(), ApprovalOutcome::Rejected);

        let req3 = request_approval(&dir, input(300_000_000)).await.unwrap();
        let r3 = phone_fetch_requests(&phone, &keys, &route).await.unwrap().remove(0);
        phone_submit_decision(&phone, &keys, &r3, false, &route).await.unwrap();
        assert_eq!(check_approval(&dir, &req3).await.unwrap(), ApprovalOutcome::Rejected);

        // Unpairing on the agent is visible to the phone.
        unpair(&dir).await.unwrap();
        assert!(!status(&dir).unwrap().paired);
        let err = phone_fetch_requests(&phone, &keys, &route).await.unwrap_err();
        assert!(err.to_string().contains("unpaired"));
        let _ = std::fs::remove_dir_all(dir);
        let _ = std::fs::remove_dir_all(phone_dir);
    }

    #[tokio::test]
    async fn phone_unpair_stops_the_agent() {
        let relay = spawn_relay().await;
        let dir = temp_dir();
        let route = PhoneRoute { state_dir: &dir, use_tor: false };
        let session = start_pairing(&dir, Some(&relay), "agent", false).await.unwrap();
        let keys = phone_generate_keys();
        let phone = phone_complete_pairing(&session.start.uri, &keys, &route).await.unwrap();
        session.poll(&dir).await.unwrap();
        phone_set_push(&phone, &route, Some((&"ab".repeat(32), true))).await.unwrap();
        phone_set_push(&phone, &route, None).await.unwrap();
        phone_unpair(&phone, &route).await.unwrap();
        let err = request_approval(&dir, input(1)).await.unwrap_err();
        assert!(err.to_string().contains("unpaired"));
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn older_state_reads_as_unpaired() {
        let dir = temp_dir();
        std::fs::write(
            state_path(&dir),
            r#"{"pairing":{"relay_url":"x","channel_id":"a","agent_secret":"b","agent_token":"c","phone_x25519":"d","phone_ed25519":"e","agent_name":"f","paired_at":1}}"#,
        )
        .unwrap();
        assert!(!status(&dir).unwrap().paired);
        let _ = std::fs::remove_dir_all(dir);
    }

    /// Manual device check: `ZIPHER_TEST_RELAY=<url> ZIPHER_PAIR_URI_FILE=<path>
    /// cargo test -p zipher-engine --lib hitl::tests::manual_phone_flow -- --ignored --nocapture`
    /// Pairs with a real phone, sends one request and reports the verified outcome.
    #[tokio::test]
    #[ignore]
    async fn manual_phone_flow() {
        let relay = std::env::var("ZIPHER_TEST_RELAY").expect("ZIPHER_TEST_RELAY");
        let uri_file = std::env::var("ZIPHER_PAIR_URI_FILE").expect("ZIPHER_PAIR_URI_FILE");
        let tor = std::env::var("ZIPHER_TEST_NO_TOR").is_err();
        let dir = temp_dir();
        let session = start_pairing(&dir, Some(&relay), "Claude on MacBook Pro", tor).await.unwrap();
        std::fs::write(&uri_file, &session.start.uri).unwrap();
        println!("check code: {} (tor: {})", session.start.check_code, session.start.tor);
        loop {
            match session.poll(&dir).await.unwrap() {
                PairingProgress::Paired => break,
                PairingProgress::Expired => panic!("pairing expired"),
                PairingProgress::Waiting => tokio::time::sleep(Duration::from_secs(2)).await,
            }
        }
        let _ = std::fs::remove_file(&uri_file);
        println!("paired");
        let req = request_approval(&dir, ApprovalInput {
            network: "main",
            address: "u1qx7k3m9wz2vpr5hd8lyn4ecaf6tjgs0ux3wq8m2n7vldk9pz4h6rc5ty8gj2fe3sa0kw7xnl",
            amount: 150_000_000,
            fee: 10_000,
            memo: Some("Invoice #1042 — hosting for December"),
            context_id: Some("order-1042"),
            tool: "propose_send",
        })
        .await
        .unwrap();
        println!("request sent");
        loop {
            match check_approval(&dir, &req).await.unwrap() {
                ApprovalOutcome::Pending => tokio::time::sleep(Duration::from_secs(2)).await,
                other => {
                    println!("outcome: {other:?}");
                    break;
                }
            }
        }
        unpair(&dir).await.unwrap();
    }
}
