//! HTTP for the approval relay, over Tor by default.
//!
//! With Tor the relay never learns the agent's or the phone's IP address, so
//! the daily mailboxes cannot be linked by network address. A route that asks
//! for Tor never falls back to a direct connection. Loopback relays (local
//! development and tests) are always reached directly.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::time::Duration;

use anyhow::{anyhow, Context, Result};
use bytes::Bytes;
use http_body_util::{BodyExt, Full};
use zcash_client_backend::tor;

static TOR_CLIENTS: tokio::sync::Mutex<Option<HashMap<PathBuf, tor::Client>>> = tokio::sync::Mutex::const_new(None);

const TOR_BOOTSTRAP: Duration = Duration::from_secs(120);
const DIRECT_TIMEOUT: Duration = Duration::from_secs(10);
/// Relay replies are small; refuse anything larger.
const MAX_REPLY: usize = 256 * 1024;

async fn read_limited(mut resp: reqwest::Response) -> Result<Vec<u8>> {
    let mut body = Vec::new();
    while let Some(chunk) = resp.chunk().await.map_err(|e| anyhow!("Could not read the relay's reply: {e}"))? {
        if body.len() + chunk.len() > MAX_REPLY {
            return Err(anyhow!("The relay's reply is too large"));
        }
        body.extend_from_slice(&chunk);
    }
    Ok(body)
}

pub struct Reply {
    pub status: u16,
    pub body: Vec<u8>,
}

impl Reply {
    pub fn json<T: serde::de::DeserializeOwned>(&self) -> Result<T> {
        serde_json::from_slice(&self.body).context("unexpected relay response")
    }
}

#[derive(Clone)]
pub enum Net {
    Direct(reqwest::Client),
    Tor(tor::Client),
}

fn is_loopback(url: &str) -> bool {
    let rest = url.split("://").nth(1).unwrap_or("");
    let host = rest.split(['/', ':']).next().unwrap_or("");
    matches!(host, "localhost" | "127.0.0.1" | "[::1]")
}

/// Tor state lives in `<state_dir>/tor-hitl`, separate from the wallet's own
/// Tor circuits. Bootstrapped once per process.
async fn tor_client(state_dir: &Path) -> Result<tor::Client> {
    let dir = state_dir.join("tor-hitl");
    let mut guard = TOR_CLIENTS.lock().await;
    let map = guard.get_or_insert_with(HashMap::new);
    if let Some(c) = map.get(&dir) {
        return Ok(c.clone());
    }
    tokio::fs::create_dir_all(&dir).await?;
    let client = tokio::time::timeout(
        TOR_BOOTSTRAP,
        tor::Client::create(&dir, |perms| {
            perms.ignore_prefix(&dir);
        }),
    )
    .await
    .map_err(|_| anyhow!("Connecting to Tor timed out"))?
    .map_err(|e| anyhow!("Could not connect to Tor: {e}"))?;
    map.insert(dir, client.clone());
    Ok(client)
}

impl Net {
    /// Pick the route for `relay_url`.
    pub async fn for_relay(relay_url: &str, use_tor: bool, state_dir: &Path) -> Result<Self> {
        if use_tor && !is_loopback(relay_url) {
            return Ok(Net::Tor(tor_client(state_dir).await?));
        }
        Ok(Net::Direct(
            reqwest::Client::builder().timeout(DIRECT_TIMEOUT).build().context("HTTP client")?,
        ))
    }

    /// The same route on a fresh Tor circuit, so requests for different
    /// mailboxes cannot be tied together by the circuit they share.
    pub fn isolated(&self) -> Self {
        match self {
            Net::Direct(c) => Net::Direct(c.clone()),
            Net::Tor(c) => Net::Tor(c.isolated_client()),
        }
    }

    pub fn is_tor(&self) -> bool {
        matches!(self, Net::Tor(_))
    }

    pub async fn get(&self, url: &str, bearer: Option<&[u8; 32]>) -> Result<Reply> {
        let auth = bearer.map(|t| format!("Bearer {}", zipher_hitl_protocol::b64(t)));
        match self {
            Net::Direct(http) => {
                let mut req = http.get(url);
                if let Some(a) = &auth {
                    req = req.header("authorization", a);
                }
                let resp = req.send().await.map_err(|e| anyhow!("Could not reach the relay: {e}"))?;
                let status = resp.status().as_u16();
                Ok(Reply { status, body: read_limited(resp).await? })
            }
            Net::Tor(client) => {
                let uri: hyper::Uri = url.parse().context("relay URL")?;
                let resp = client
                    .http_get(
                        uri,
                        |b| match &auth {
                            Some(a) => b.header("authorization", a.as_str()),
                            None => b,
                        },
                        |body| async {
                            Ok(body.collect().await.map_err(tor::http::HttpError::from)?.to_bytes().to_vec())
                        },
                        1,
                        |r| r.is_err().then_some(tor::http::Retry::Isolated),
                    )
                    .await
                    .map_err(|e| anyhow!("Could not reach the relay over Tor: {e}"))?;
                let status = resp.status().as_u16();
                let body = resp.into_body();
                if body.len() > MAX_REPLY {
                    return Err(anyhow!("The relay's reply is too large"));
                }
                Ok(Reply { status, body })
            }
        }
    }

    pub async fn post(&self, url: &str, bearer: Option<&[u8; 32]>, json: Option<Vec<u8>>) -> Result<Reply> {
        let auth = bearer.map(|t| format!("Bearer {}", zipher_hitl_protocol::b64(t)));
        match self {
            Net::Direct(http) => {
                let mut req = http.post(url);
                if let Some(a) = &auth {
                    req = req.header("authorization", a);
                }
                if let Some(body) = json {
                    req = req.header("content-type", "application/json").body(body);
                }
                let resp = req.send().await.map_err(|e| anyhow!("Could not reach the relay: {e}"))?;
                let status = resp.status().as_u16();
                Ok(Reply { status, body: read_limited(resp).await? })
            }
            Net::Tor(client) => {
                let uri: hyper::Uri = url.parse().context("relay URL")?;
                let has_body = json.is_some();
                let body = Full::new(Bytes::from(json.unwrap_or_default()));
                let resp = client
                    .http_post(
                        uri,
                        |b| {
                            let b = match &auth {
                                Some(a) => b.header("authorization", a.as_str()),
                                None => b,
                            };
                            if has_body { b.header("content-type", "application/json") } else { b }
                        },
                        body,
                        |body| async {
                            Ok(body.collect().await.map_err(tor::http::HttpError::from)?.to_bytes().to_vec())
                        },
                        0,
                        |_| None,
                    )
                    .await
                    .map_err(|e| anyhow!("Could not reach the relay over Tor: {e}"))?;
                let status = resp.status().as_u16();
                let body = resp.into_body();
                if body.len() > MAX_REPLY {
                    return Err(anyhow!("The relay's reply is too large"));
                }
                Ok(Reply { status, body })
            }
        }
    }
}
