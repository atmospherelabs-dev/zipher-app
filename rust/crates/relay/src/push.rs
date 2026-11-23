//! Content-free Apple push for approval requests.
//!
//! The relay cannot read requests, and the push it sends says only that an
//! agent is waiting. Tapping it opens Zipher, which fetches and decrypts the
//! request itself. Device tokens are never logged.

use std::sync::Mutex;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use anyhow::{anyhow, bail, Context, Result};
use base64::engine::general_purpose::{STANDARD, URL_SAFE_NO_PAD};
use base64::Engine as _;
use ring::rand::SystemRandom;
use ring::signature::{EcdsaKeyPair, ECDSA_P256_SHA256_FIXED_SIGNING};
use serde::{Deserialize, Serialize};

const PRODUCTION: &str = "https://api.push.apple.com";
const SANDBOX: &str = "https://api.sandbox.push.apple.com";
/// Apple accepts provider tokens for an hour; refresh well before that.
const JWT_LIFETIME: Duration = Duration::from_secs(50 * 60);

/// Where a phone wants its wake-up pushes sent.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct PushTarget {
    pub platform: String,
    pub token: String,
    #[serde(default)]
    pub sandbox: bool,
}

impl PushTarget {
    pub fn validate(&self) -> Result<()> {
        if self.platform != "apns" {
            bail!("unsupported push platform");
        }
        if !(32..=200).contains(&self.token.len()) || !self.token.bytes().all(|b| b.is_ascii_hexdigit()) {
            bail!("invalid device token");
        }
        Ok(())
    }
}

#[derive(Debug, PartialEq, Eq)]
pub enum PushOutcome {
    Sent,
    /// Apple says the token is dead; forget it.
    TokenGone,
    Failed,
}

pub struct Apns {
    key: EcdsaKeyPair,
    key_id: String,
    team_id: String,
    topic: String,
    /// Tests point both environments at a local mock.
    base_override: Option<String>,
    http: reqwest::Client,
    jwt: Mutex<Option<(String, Instant)>>,
}

fn pem_to_der(pem: &str) -> Result<Vec<u8>> {
    let body: String = pem
        .lines()
        .filter(|l| !l.starts_with("-----"))
        .collect::<Vec<_>>()
        .join("");
    STANDARD.decode(body.trim()).context("APNs key is not valid PEM")
}

impl Apns {
    /// `key_pem` is the contents of the AuthKey_XXXX.p8 file from Apple.
    pub fn new(key_pem: &str, key_id: &str, team_id: &str, topic: &str, base_override: Option<String>) -> Result<Self> {
        let der = pem_to_der(key_pem)?;
        let key = EcdsaKeyPair::from_pkcs8(&ECDSA_P256_SHA256_FIXED_SIGNING, &der, &SystemRandom::new())
            .map_err(|_| anyhow!("APNs key is not a P-256 PKCS#8 key"))?;
        Ok(Self {
            key,
            key_id: key_id.to_string(),
            team_id: team_id.to_string(),
            topic: topic.to_string(),
            base_override,
            http: reqwest::Client::builder()
                .timeout(Duration::from_secs(10))
                .build()
                .context("HTTP client")?,
            jwt: Mutex::new(None),
        })
    }

    fn provider_token(&self) -> Result<String> {
        let mut cached = self.jwt.lock().expect("jwt cache");
        if let Some((jwt, at)) = cached.as_ref() {
            if at.elapsed() < JWT_LIFETIME {
                return Ok(jwt.clone());
            }
        }
        let iat = SystemTime::now().duration_since(UNIX_EPOCH)?.as_secs();
        let header = URL_SAFE_NO_PAD.encode(format!(r#"{{"alg":"ES256","kid":"{}"}}"#, self.key_id));
        let claims = URL_SAFE_NO_PAD.encode(format!(r#"{{"iss":"{}","iat":{}}}"#, self.team_id, iat));
        let signing_input = format!("{header}.{claims}");
        let sig = self
            .key
            .sign(&SystemRandom::new(), signing_input.as_bytes())
            .map_err(|_| anyhow!("could not sign APNs token"))?;
        let jwt = format!("{signing_input}.{}", URL_SAFE_NO_PAD.encode(sig.as_ref()));
        *cached = Some((jwt.clone(), Instant::now()));
        Ok(jwt)
    }

    /// Wake the phone. The payload is the same for every request.
    pub async fn wake(&self, target: &PushTarget, expires_at: u64) -> PushOutcome {
        match self.try_wake(target, expires_at).await {
            Ok(o) => o,
            Err(_) => PushOutcome::Failed,
        }
    }

    async fn try_wake(&self, target: &PushTarget, expires_at: u64) -> Result<PushOutcome> {
        let base = self
            .base_override
            .as_deref()
            .unwrap_or(if target.sandbox { SANDBOX } else { PRODUCTION });
        let body = serde_json::json!({
            "aps": {
                "alert": {
                    "title": "Approval needed",
                    "body": "Your agent is asking you to approve a payment."
                },
                "sound": "default"
            }
        });
        let resp = self
            .http
            .post(format!("{base}/3/device/{}", target.token))
            .header("authorization", format!("bearer {}", self.provider_token()?))
            .header("apns-topic", &self.topic)
            .header("apns-push-type", "alert")
            .header("apns-priority", "10")
            .header("apns-expiration", expires_at.to_string())
            .json(&body)
            .send()
            .await?;
        Ok(match resp.status().as_u16() {
            200 => PushOutcome::Sent,
            410 => PushOutcome::TokenGone,
            400 => {
                let reason = resp.text().await.unwrap_or_default();
                if reason.contains("BadDeviceToken") || reason.contains("DeviceTokenNotForTopic") {
                    PushOutcome::TokenGone
                } else {
                    PushOutcome::Failed
                }
            }
            _ => PushOutcome::Failed,
        })
    }
}
