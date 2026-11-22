//! Mobile HITL (human-in-the-loop) approvals over the blind relay.
//!
//! Protocol v1, see `docs/hitl-relay-protocol.md`. The relay carries only
//! ciphertexts. An agent signs a send only after it has verified the paired
//! phone's Ed25519 signature over the proposal hash it computed itself.
//!
//! Agent state lives in `<data_dir>/hitl.json` with mode 0600. It holds the
//! agent's X25519 secret and relay token, which can read requests and post new
//! ones but cannot approve anything. Approval needs the phone's signing key,
//! which never leaves the phone.

use anyhow::{anyhow, bail, ensure, Context, Result};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use std::time::Duration;
use zeroize::Zeroizing;
use zipher_hitl_protocol::{self as proto, b64, unb64, wire};

pub use proto::ApprovalRequest;

pub const DEFAULT_RELAY_URL: &str = "https://relay.atmospherelabs.dev";
/// How long the phone has to approve a send.
pub const APPROVAL_TTL_SECS: u64 = 300;
/// How long a pairing code stays valid (the relay drops it after 10 minutes).
pub const PAIRING_TTL_SECS: u64 = 600;
const HTTP_TIMEOUT: Duration = Duration::from_secs(10);

fn now_unix() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

fn http() -> Result<reqwest::Client> {
    reqwest::Client::builder()
        .timeout(HTTP_TIMEOUT)
        .build()
        .context("HTTP client")
}

fn bearer(token: &[u8; 32]) -> String {
    format!("Bearer {}", b64(token))
}

// ---------------------------------------------------------------------------
// Agent state
// ---------------------------------------------------------------------------

#[derive(Clone, Serialize, Deserialize)]
struct Pairing {
    relay_url: String,
    channel_id: String,
    agent_secret: String,
    agent_token: String,
    phone_x25519: String,
    phone_ed25519: String,
    agent_name: String,
    paired_at: u64,
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
        // Files written by the old plaintext relay format have no v1 fields
        // and parse as "not paired", so users simply pair again.
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
    channel_id: proto::ChannelId,
    agent: proto::AgentSecret,
    agent_token: Zeroizing<[u8; 32]>,
    phone: proto::PhonePublic,
}

impl Pairing {
    fn open(&self) -> Result<Paired> {
        Ok(Paired {
            relay_url: self.relay_url.clone(),
            channel_id: unb64(&self.channel_id)?,
            agent: proto::AgentSecret::from_bytes(unb64(&self.agent_secret)?),
            agent_token: Zeroizing::new(unb64(&self.agent_token)?),
            phone: proto::PhonePublic {
                x25519: unb64(&self.phone_x25519)?,
                ed25519: unb64(&self.phone_ed25519)?,
            },
        })
    }
}

/// Public summary of the agent's pairing state. Contains no secrets.
#[derive(Debug, Clone, Serialize)]
pub struct HitlStatus {
    pub paired: bool,
    pub relay_url: Option<String>,
    pub agent_name: Option<String>,
    pub paired_at: Option<u64>,
}

pub fn status(data_dir: &str) -> Result<HitlStatus> {
    let s = load_state(data_dir)?;
    Ok(HitlStatus {
        paired: s.pairing.is_some(),
        relay_url: s.pairing.as_ref().map(|p| p.relay_url.clone()),
        agent_name: s.pairing.as_ref().map(|p| p.agent_name.clone()),
        paired_at: s.pairing.as_ref().map(|p| p.paired_at),
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
}

/// An unfinished pairing. It holds the pairing secret in memory only and is
/// meant for the operator's own terminal (`zipher pair`). Never expose it to
/// an agent: whoever holds the secret could pair a fake phone.
pub struct PairingSession {
    offer: proto::PairingOffer,
    agent: proto::AgentSecret,
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

/// Register a new channel with the relay and return the session to poll.
/// An existing pairing stays active until the new one completes.
pub async fn start_pairing(relay_url: Option<&str>, agent_name: &str) -> Result<PairingSession> {
    let relay_url = relay_url.unwrap_or(DEFAULT_RELAY_URL).trim_end_matches('/').to_string();
    let agent = proto::AgentSecret::generate();
    let offer = proto::PairingOffer::new(&relay_url, agent_name, &agent)?;
    let tokens = offer.tokens();

    let resp = http()?
        .post(format!("{relay_url}/v1/channels"))
        .json(&wire::RegisterChannel {
            channel_id: b64(&offer.channel_id),
            agent_token_hash: b64(&proto::token_hash(&tokens.agent)),
            phone_token_hash: b64(&proto::token_hash(&tokens.phone)),
        })
        .send()
        .await
        .map_err(|e| anyhow!("Could not reach the relay: {e}"))?;
    ensure!(resp.status().is_success(), "Relay refused the pairing ({})", resp.status());

    let start = PairingStart {
        uri: offer.to_uri(),
        check_code: offer.check_code(),
        relay_url,
        expires_in_secs: PAIRING_TTL_SECS,
    };
    Ok(PairingSession { offer, agent, started: std::time::Instant::now(), start })
}

impl PairingSession {
    /// Check whether the phone has answered; on success, save the pairing.
    pub async fn poll(&self, data_dir: &str) -> Result<PairingProgress> {
        if self.started.elapsed() >= Duration::from_secs(PAIRING_TTL_SECS) {
            return Ok(PairingProgress::Expired);
        }
        let tokens = self.offer.tokens();
        let channel = b64(&self.offer.channel_id);
        let resp = http()?
            .get(format!("{}/v1/channels/{}/pair", self.offer.relay_url, channel))
            .header("authorization", bearer(&tokens.agent))
            .send()
            .await
            .map_err(|e| anyhow!("Could not reach the relay: {e}"))?;
        match resp.status() {
            reqwest::StatusCode::NO_CONTENT => return Ok(PairingProgress::Waiting),
            reqwest::StatusCode::NOT_FOUND => return Ok(PairingProgress::Expired),
            s if !s.is_success() => bail!("Relay returned {s}"),
            _ => {}
        }
        let pair: proto::PairResponse = resp.json().await.context("pairing response")?;
        let phone = proto::verify_pair_response(&self.offer, &pair)?;

        let mut state = load_state(data_dir)?;
        // Retire the old channel, if any, now that the new one works.
        if let Some(old) = state.pairing.take() {
            if let Ok(p) = old.open() {
                let _ = delete_channel(&p).await;
            }
        }
        state.pairing = Some(Pairing {
            relay_url: self.offer.relay_url.clone(),
            channel_id: channel,
            agent_secret: b64(self.agent.to_bytes().as_ref()),
            agent_token: b64(tokens.agent.as_ref()),
            phone_x25519: b64(&phone.x25519),
            phone_ed25519: b64(&phone.ed25519),
            agent_name: self.offer.agent_name.clone(),
            paired_at: now_unix(),
        });
        save_state(data_dir, &state)?;
        tracing::info!("[HITL] Paired with phone");
        Ok(PairingProgress::Paired)
    }
}

async fn delete_channel(p: &Paired) -> Result<()> {
    http()?
        .delete(format!("{}/v1/channels/{}", p.relay_url, b64(&p.channel_id)))
        .header("authorization", bearer(&p.agent_token))
        .send()
        .await?;
    Ok(())
}

/// Forget the phone and close the relay channel.
pub async fn unpair(data_dir: &str) -> Result<()> {
    let mut state = load_state(data_dir)?;
    if let Some(p) = state.pairing.take() {
        if let Ok(p) = p.open() {
            let _ = delete_channel(&p).await;
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

/// Encrypt the send for the paired phone and post it. Keep the returned
/// request: the decision is only checked against this copy.
pub async fn request_approval(data_dir: &str, input: ApprovalInput<'_>) -> Result<ApprovalRequest> {
    let state = load_state(data_dir)?;
    let pairing = state
        .pairing
        .ok_or_else(|| anyhow!("No phone is paired. Run `zipher pair` first."))?;
    let p = pairing.open()?;
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
    let sealed = proto::seal_request(&p.agent, &p.phone, &p.channel_id, &req)?;
    let resp = http()?
        .post(format!("{}/v1/channels/{}/requests", p.relay_url, b64(&p.channel_id)))
        .header("authorization", bearer(&p.agent_token))
        .json(&wire::PostRequest { approval_id: req.approval_id.clone(), expires_at: req.expires_at, sealed })
        .send()
        .await
        .map_err(|e| anyhow!("Could not reach the relay: {e}"))?;
    ensure!(resp.status().is_success(), "Relay refused the approval request ({})", resp.status());
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
    let pairing = load_state(data_dir)?
        .pairing
        .ok_or_else(|| anyhow!("The phone was unpaired while approval was pending."))?;
    let p = pairing.open()?;
    let resp = http()?
        .get(format!(
            "{}/v1/channels/{}/decisions/{}",
            p.relay_url,
            b64(&p.channel_id),
            req.approval_id
        ))
        .header("authorization", bearer(&p.agent_token))
        .send()
        .await
        .map_err(|e| anyhow!("Could not reach the relay: {e}"))?;
    match resp.status() {
        reqwest::StatusCode::NO_CONTENT => return Ok(ApprovalOutcome::Pending),
        reqwest::StatusCode::NOT_FOUND => return Ok(ApprovalOutcome::Expired),
        s if !s.is_success() => bail!("Relay returned {s}"),
        _ => {}
    }
    let sealed: proto::Sealed = resp.json().await.context("decision")?;
    let outcome = proto::open_decision(&p.agent, &p.phone, &p.channel_id, &req.approval_id, &sealed)
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

/// The phone's record of a pairing. `phone_token` is a secret: store the
/// whole JSON in platform secure storage.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PhonePairing {
    pub relay_url: String,
    pub channel_id: String,
    pub agent_public: String,
    pub phone_token: String,
    pub agent_name: String,
}

fn phone_keys(keys_hex: &str) -> Result<proto::PhoneKeys> {
    let bytes = Zeroizing::new(hex::decode(keys_hex).map_err(|_| anyhow!("invalid phone key"))?);
    proto::PhoneKeys::from_bytes(&bytes)
}

/// Answer a pairing offer the user has confirmed.
pub async fn phone_complete_pairing(uri: &str, keys_hex: &str) -> Result<PhonePairing> {
    let offer = proto::PairingOffer::from_uri(uri)?;
    let keys = phone_keys(keys_hex)?;
    let tokens = offer.tokens();
    let resp = http()?
        .post(format!("{}/v1/channels/{}/pair", offer.relay_url, b64(&offer.channel_id)))
        .header("authorization", bearer(&tokens.phone))
        .json(&proto::make_pair_response(&offer, &keys))
        .send()
        .await
        .map_err(|e| anyhow!("Could not reach the relay: {e}"))?;
    match resp.status() {
        s if s.is_success() => {}
        reqwest::StatusCode::NOT_FOUND => bail!("This pairing code has expired. Start pairing again on the agent."),
        reqwest::StatusCode::CONFLICT => bail!("This pairing code was already used."),
        s => bail!("Relay returned {s}"),
    }
    Ok(PhonePairing {
        relay_url: offer.relay_url.clone(),
        channel_id: b64(&offer.channel_id),
        agent_public: b64(&offer.agent_public),
        phone_token: b64(tokens.phone.as_ref()),
        agent_name: offer.agent_name.clone(),
    })
}

/// Decrypt the agent's open requests. Requests that fail to decrypt or
/// validate are skipped.
pub async fn phone_fetch_requests(pairing: &PhonePairing, keys_hex: &str) -> Result<Vec<ApprovalRequest>> {
    let keys = phone_keys(keys_hex)?;
    let channel_id: proto::ChannelId = unb64(&pairing.channel_id)?;
    let agent_public: [u8; 32] = unb64(&pairing.agent_public)?;
    let token: Zeroizing<[u8; 32]> = Zeroizing::new(unb64(&pairing.phone_token)?);
    let resp = http()?
        .get(format!("{}/v1/channels/{}/requests", pairing.relay_url, pairing.channel_id))
        .header("authorization", bearer(&token))
        .send()
        .await
        .map_err(|e| anyhow!("Could not reach the relay: {e}"))?;
    ensure!(resp.status() != reqwest::StatusCode::NOT_FOUND, "This agent was unpaired.");
    ensure!(resp.status().is_success(), "Relay returned {}", resp.status());
    let list: wire::PendingRequests = resp.json().await.context("pending requests")?;
    let now = now_unix();
    Ok(list
        .requests
        .iter()
        .filter_map(|r| proto::open_request(&keys, &agent_public, &channel_id, &r.approval_id, &r.sealed).ok())
        .filter(|r| r.expires_at >= now)
        .collect())
}

/// Sign and send the user's decision on a request returned by
/// [`phone_fetch_requests`].
pub async fn phone_submit_decision(
    pairing: &PhonePairing,
    keys_hex: &str,
    request: &ApprovalRequest,
    approved: bool,
) -> Result<()> {
    request.validate()?;
    let now = now_unix();
    ensure!(now <= request.expires_at, "This request has expired.");
    let keys = phone_keys(keys_hex)?;
    let channel_id: proto::ChannelId = unb64(&pairing.channel_id)?;
    let agent_public: [u8; 32] = unb64(&pairing.agent_public)?;
    let token: Zeroizing<[u8; 32]> = Zeroizing::new(unb64(&pairing.phone_token)?);
    let decision = proto::sign_decision(&keys, request, approved, now);
    let sealed = proto::seal_decision(&keys, &agent_public, &channel_id, &decision)?;
    let resp = http()?
        .post(format!(
            "{}/v1/channels/{}/decisions/{}",
            pairing.relay_url, pairing.channel_id, request.approval_id
        ))
        .header("authorization", bearer(&token))
        .json(&sealed)
        .send()
        .await
        .map_err(|e| anyhow!("Could not reach the relay: {e}"))?;
    ensure!(
        resp.status() != reqwest::StatusCode::NOT_FOUND,
        "This request is no longer open; it may have expired or been answered."
    );
    ensure!(resp.status().is_success(), "Relay returned {}", resp.status());
    Ok(())
}

/// Close the channel from the phone.
pub async fn phone_unpair(pairing: &PhonePairing) -> Result<()> {
    let token: Zeroizing<[u8; 32]> = Zeroizing::new(unb64(&pairing.phone_token)?);
    http()?
        .delete(format!("{}/v1/channels/{}", pairing.relay_url, pairing.channel_id))
        .header("authorization", bearer(&token))
        .send()
        .await?;
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

    #[tokio::test]
    async fn agent_and_phone_complete_an_approval_over_a_real_relay() {
        let relay = spawn_relay().await;
        let dir = temp_dir();

        let session = start_pairing(Some(&relay), "test agent").await.unwrap();
        let start = session.start.clone();
        assert_eq!(session.poll(&dir).await.unwrap(), PairingProgress::Waiting);
        assert!(!status(&dir).unwrap().paired);
        // Nothing secret is written before the phone answers.
        assert!(!state_path(&dir).exists());

        let preview = phone_preview_pairing(&start.uri).unwrap();
        assert_eq!(preview.check_code, start.check_code);
        let keys = phone_generate_keys();
        let phone = phone_complete_pairing(&start.uri, &keys).await.unwrap();
        assert!(phone_complete_pairing(&start.uri, &keys).await.is_err(), "pairing code is single use");
        assert_eq!(session.poll(&dir).await.unwrap(), PairingProgress::Paired);
        let saved = std::fs::read_to_string(state_path(&dir)).unwrap();
        let secret = start.uri.split("&s=").nth(1).unwrap().split('&').next().unwrap();
        assert!(!saved.contains(secret), "pairing secret must not be stored");
        assert!(status(&dir).unwrap().paired);

        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = std::fs::metadata(state_path(&dir)).unwrap().permissions().mode();
            assert_eq!(mode & 0o777, 0o600);
        }

        let req = request_approval(&dir, ApprovalInput {
            network: "main",
            address: "u1merchant",
            amount: 200_000_000,
            fee: 10_000,
            memo: Some("invoice 42"),
            context_id: Some("ctx"),
            tool: "propose_send",
        })
        .await
        .unwrap();
        assert_eq!(check_approval(&dir, &req).await.unwrap(), ApprovalOutcome::Pending);

        let open = phone_fetch_requests(&phone, &keys).await.unwrap();
        assert_eq!(open, vec![req.clone()]);
        phone_submit_decision(&phone, &keys, &open[0], true).await.unwrap();
        assert_eq!(check_approval(&dir, &req).await.unwrap(), ApprovalOutcome::Approved);
        // Read once; afterwards the relay no longer has it.
        assert_eq!(check_approval(&dir, &req).await.unwrap(), ApprovalOutcome::Expired);

        // A decision the phone signed for a different amount is refused.
        let req2 = request_approval(&dir, ApprovalInput {
            network: "main", address: "u1merchant", amount: 300_000_000, fee: 10_000,
            memo: None, context_id: None, tool: "propose_send",
        })
        .await
        .unwrap();
        let mut altered = phone_fetch_requests(&phone, &keys).await.unwrap().remove(0);
        altered.amount = 1;
        phone_submit_decision(&phone, &keys, &altered, true).await.unwrap();
        assert_eq!(check_approval(&dir, &req2).await.unwrap(), ApprovalOutcome::Rejected);

        // Rejections come through as rejections.
        let req3 = request_approval(&dir, ApprovalInput {
            network: "main", address: "u1merchant", amount: 300_000_000, fee: 10_000,
            memo: None, context_id: None, tool: "propose_send",
        })
        .await
        .unwrap();
        let r3 = phone_fetch_requests(&phone, &keys).await.unwrap().remove(0);
        phone_submit_decision(&phone, &keys, &r3, false).await.unwrap();
        assert_eq!(check_approval(&dir, &req3).await.unwrap(), ApprovalOutcome::Rejected);

        unpair(&dir).await.unwrap();
        assert!(!status(&dir).unwrap().paired);
        assert!(phone_fetch_requests(&phone, &keys).await.is_err());
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn old_plaintext_state_reads_as_unpaired() {
        let dir = temp_dir();
        std::fs::write(
            state_path(&dir),
            r#"{"enabled":true,"relay_url":"https://relay.atmospherelabs.dev","pairing":{"channel_id":"ch_1","device_name":"mobile","paired_at_unix":1,"relay_url":"x"}}"#,
        )
        .unwrap();
        assert!(!status(&dir).unwrap().paired);
        std::fs::remove_dir_all(dir).unwrap();
    }
}
