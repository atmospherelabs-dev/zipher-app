//! ZEC gift links ("liberated payments", ZIP 324).
//!
//! A gift is a tiny, single-purpose wallet whose secret travels in a link:
//! the sender funds the wallet's Orchard-only default address and shares the
//! link; whoever holds the link sweeps the funds into a wallet of their own.
//!
//! Interoperable with the link formats Zodl and Vizor wallets read and write
//! (implemented here from their published format description):
//!
//! ```text
//! https://<any host>[/path]#v=1&key=<bech32m entropy>&height=<birthday>[&amount=<ZEC>][&desc=<text>]
//! https://<any host>/payment-links/open#v1=|v2=|v3=<base64url JSON>      (legacy, read only)
//! ```
//!
//! * The secret is BIP 39 entropy (empty passphrase); the gift wallet is ZIP 32
//!   account 0 of that seed. `key` uses HRP `zgift` (mainnet) / `zgifttest`.
//! * The link fragment never reaches a web server. The host is not part of the
//!   gift.
//! * `v`, `key` and `height` are strict; `amount` and `desc` are informational
//!   (the chain is authoritative) and a malformed one is read as absent.
//! * A gift is funded with [`CLAIM_FEE_RESERVE`] on top of its face value so
//!   claiming it does not eat into the amount.
//!
//! Nothing in this module logs or formats the secret; `Debug` is redacted.

use std::collections::HashMap;
use std::fmt;
use std::num::NonZeroU32;
use std::path::{Path, PathBuf};

use anyhow::{anyhow, bail, Context, Result};
use base64::engine::general_purpose::{URL_SAFE, URL_SAFE_NO_PAD};
use base64::Engine as _;
use bech32::primitives::decode::CheckedHrpstring;
use bech32::{Bech32m, Hrp};
use secrecy::SecretVec;
use zcash_client_backend::data_api::chain::{
    error::Error as ChainError, scan_cached_blocks, ChainState,
};
use zcash_client_backend::data_api::scanning::ScanPriority;
use zcash_client_backend::data_api::wallet::input_selection::LockedInputPolicy;
use zcash_client_backend::data_api::wallet::{
    create_proposed_transactions, propose_send_max_transfer, ConfirmationsPolicy, SpendingKeys,
};
use zcash_client_backend::data_api::{
    AccountBirthday, MaxSpendMode, WalletRead, WalletWrite,
};
use zcash_client_backend::proto::compact_formats::CompactBlock;
use zcash_client_backend::proto::service::{
    compact_tx_streamer_client::CompactTxStreamerClient, BlockId, BlockRange, ChainSpec,
};
use zcash_client_backend::wallet::OvkPolicy;
use zcash_client_sqlite::wallet::init::init_wallet_db;
use zcash_keys::address::Address;
use zcash_keys::keys::{UnifiedAddressRequest, UnifiedSpendingKey};
use zcash_protocol::consensus::{BlockHeight, Network, NetworkType, NetworkUpgrade, Parameters};
use zcash_protocol::value::Zatoshis;
use zcash_protocol::ShieldedPool;
use zeroize::{Zeroize, Zeroizing};

use crate::send::DbType;
use crate::wallet::{connect_lwd, connect_lwd_tor};
use crate::{open_wallet_db, ENGINE, WALLET_TRANSPORT};

/// ZIP 317 minimum fee: what a one-input, one-output Orchard claim costs.
pub const CLAIM_FEE_RESERVE: u64 = 10_000;
pub const MAX_LINK_LENGTH: usize = 16 * 1024;
pub const MAX_MESSAGE_BYTES: usize = 512;
/// Where Zipher's links point. The page only explains how to claim; the
/// gift itself is in the fragment, which browsers never send.
pub const DEFAULT_HOST: &str = "https://zipher.to/gift";

const HRP_MAIN: &str = "zgift";
const HRP_TEST: &str = "zgifttest";
const MAX_SUPPLY_ZAT: u64 = 21_000_000 * 100_000_000;
const SCAN_BATCH: u32 = 1_000;

// ---------------------------------------------------------------------------
// Link codec (pure; no network, no disk)
// ---------------------------------------------------------------------------

/// Which encoding a link was read from.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LinkFormat {
    V1,
    LegacyV1,
    LegacyV2,
    LegacyV3,
}

enum Secret {
    /// 16–32 bytes of BIP 39 entropy.
    Entropy(Zeroizing<Vec<u8>>),
    /// Older Vizor links carry the phrase itself.
    Phrase(Zeroizing<String>),
}

/// A parsed or freshly minted gift. Holds a spending secret.
pub struct GiftLink {
    pub format: LinkFormat,
    pub network: NetworkType,
    secret: Secret,
    pub birthday: u32,
    pub amount: Option<u64>,
    pub message: Option<String>,
}

impl fmt::Debug for GiftLink {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("GiftLink")
            .field("format", &self.format)
            .field("network", &self.network)
            .field("secret", &"<redacted>")
            .field("birthday", &self.birthday)
            .field("amount", &self.amount)
            .finish()
    }
}

/// Errors that never contain any part of the link.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LinkError {
    NotAGift,
    UnsupportedVersion,
    UnsupportedNetwork,
    Invalid(&'static str),
    TooLong,
}

impl fmt::Display for LinkError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            LinkError::NotAGift => write!(f, "This is not a gift link."),
            LinkError::UnsupportedVersion => {
                write!(f, "This gift link is from a newer app. Update Zipher to open it.")
            }
            LinkError::UnsupportedNetwork => write!(f, "This gift is for a network Zipher does not support."),
            LinkError::Invalid(field) => write!(f, "This gift link is damaged ({field})."),
            LinkError::TooLong => write!(f, "This gift link is too long."),
        }
    }
}

impl std::error::Error for LinkError {}

fn network_params(network: NetworkType) -> Result<Network, LinkError> {
    match network {
        NetworkType::Main => Ok(Network::MainNetwork),
        NetworkType::Test => Ok(Network::TestNetwork),
        NetworkType::Regtest => Err(LinkError::UnsupportedNetwork),
    }
}

/// Gift wallets hold Orchard funds only, which cannot predate NU5.
pub fn min_birthday(network: NetworkType) -> u32 {
    network_params(network)
        .ok()
        .and_then(|p| p.activation_height(NetworkUpgrade::Nu5))
        .map(u32::from)
        .unwrap_or(1)
}

fn check_birthday(network: NetworkType, height: u32) -> Result<u32, LinkError> {
    if height < min_birthday(network) {
        return Err(LinkError::Invalid("height"));
    }
    Ok(height)
}

/// Strips what could hide or reorder text; line breaks become spaces.
/// ZWJ/ZWNJ and variation selectors stay (emoji need them).
pub fn sanitize_message(text: &str) -> Option<String> {
    let cleaned: String = text
        .chars()
        .filter_map(|c| match c {
            '\t' | '\n' | '\u{0B}' | '\u{0C}' | '\r' | '\u{85}' | '\u{2028}' | '\u{2029}' => Some(' '),
            '\u{061C}' | '\u{200B}' | '\u{200E}' | '\u{200F}' | '\u{FEFF}' => None,
            '\u{202A}'..='\u{202E}' | '\u{2060}'..='\u{2064}' | '\u{2066}'..='\u{206F}' => None,
            '\u{FFF9}'..='\u{FFFB}' => None,
            c if c.is_control() => None,
            c => Some(c),
        })
        .collect();
    let trimmed = cleaned.trim();
    if trimmed.is_empty() {
        None
    } else {
        Some(trimmed.to_string())
    }
}

/// Canonical decimal ZEC (≤ 8 fraction digits, no sign/exponent), non-zero.
fn parse_zec(text: &str) -> Option<u64> {
    let (whole, frac) = match text.split_once('.') {
        Some((w, f)) if !f.is_empty() => (w, f),
        Some(_) => return None,
        None => (text, ""),
    };
    let digits = |s: &str| !s.is_empty() && s.bytes().all(|b| b.is_ascii_digit());
    if !digits(whole) || (!frac.is_empty() && !digits(frac)) || frac.len() > 8 {
        return None;
    }
    let whole: u64 = whole.parse().ok()?;
    let frac: u64 = format!("{frac:0<8}").parse().ok()?;
    let zat = whole.checked_mul(100_000_000)?.checked_add(frac)?;
    (zat > 0 && zat <= MAX_SUPPLY_ZAT).then_some(zat)
}

fn format_zec(zat: u64) -> String {
    let frac = format!("{:08}", zat % 100_000_000);
    let frac = frac.trim_end_matches('0');
    if frac.is_empty() {
        (zat / 100_000_000).to_string()
    } else {
        format!("{}.{}", zat / 100_000_000, frac)
    }
}

/// RFC 3986 unreserved characters stay literal; everything else is %XX (UTF-8).
fn percent_encode(text: &str) -> String {
    let mut out = String::with_capacity(text.len() * 3);
    for b in text.bytes() {
        if b.is_ascii_alphanumeric() || matches!(b, b'-' | b'.' | b'_' | b'~') {
            out.push(b as char);
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}

/// Form decoding (`+` is a space). Malformed escapes or non-UTF-8 → None.
fn percent_decode(text: &str) -> Option<String> {
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        match bytes[i] {
            b'%' => {
                let hex = bytes.get(i + 1..i + 3)?;
                let s = std::str::from_utf8(hex).ok()?;
                out.push(u8::from_str_radix(s, 16).ok()?);
                i += 3;
            }
            b'+' => {
                out.push(b' ');
                i += 1;
            }
            b => {
                out.push(b);
                i += 1;
            }
        }
    }
    String::from_utf8(out).ok()
}

fn hrp(network: NetworkType) -> Result<Hrp, LinkError> {
    Hrp::parse(match network {
        NetworkType::Main => HRP_MAIN,
        NetworkType::Test => HRP_TEST,
        NetworkType::Regtest => return Err(LinkError::UnsupportedNetwork),
    })
    .map_err(|_| LinkError::Invalid("key"))
}

fn decode_key(key: &str) -> Result<(NetworkType, Zeroizing<Vec<u8>>), LinkError> {
    // Bech32m only; mixed case is rejected by the checked parser.
    let parsed = CheckedHrpstring::new::<Bech32m>(key).map_err(|_| LinkError::Invalid("key"))?;
    let network = match parsed.hrp().to_lowercase().as_str() {
        HRP_MAIN => NetworkType::Main,
        HRP_TEST => NetworkType::Test,
        _ => return Err(LinkError::UnsupportedNetwork),
    };
    // Non-zero padding would be a second spelling of the same secret.
    parsed
        .validate_segwit_padding()
        .map_err(|_| LinkError::Invalid("key"))?;
    let bytes: Zeroizing<Vec<u8>> = Zeroizing::new(parsed.byte_iter().collect());
    if bytes.len() != 32 {
        return Err(LinkError::Invalid("key"));
    }
    Ok((network, bytes))
}

fn split_https(link: &str) -> Result<(&str, &str), LinkError> {
    let (base, fragment) = link.split_once('#').ok_or(LinkError::NotAGift)?;
    let scheme_ok = base
        .get(..8)
        .is_some_and(|s| s.eq_ignore_ascii_case("https://"));
    let rest = base.get(8..).unwrap_or("");
    if !scheme_ok || rest.is_empty() || rest.starts_with('/') || base.chars().any(char::is_whitespace) {
        return Err(LinkError::NotAGift);
    }
    Ok((base, fragment))
}

/// Cheap prefix test for routing pasted/scanned text; [`GiftLink::parse`]
/// is what validates.
pub fn looks_like_gift(text: &str) -> bool {
    let t = text.trim();
    let Some((_, fragment)) = t.split_once('#') else {
        return false;
    };
    t.get(..8).is_some_and(|s| s.eq_ignore_ascii_case("https://"))
        && (fragment.starts_with("v=1&") && fragment.contains("key=zgift")
            || ["v1=", "v2=", "v3="].iter().any(|p| fragment.starts_with(p))
                && t.contains("/payment-links/"))
}

impl GiftLink {
    /// A new gift with fresh random 32-byte entropy.
    pub fn mint(
        network: NetworkType,
        birthday: u32,
        amount: u64,
        message: Option<String>,
    ) -> Result<Self, LinkError> {
        let birthday = check_birthday(network, birthday)?;
        network_params(network)?;
        if amount == 0 || amount > MAX_SUPPLY_ZAT {
            return Err(LinkError::Invalid("amount"));
        }
        let message = match message {
            None => None,
            Some(m) => {
                let clean = sanitize_message(&m);
                if clean.as_ref().is_some_and(|c| c.len() > MAX_MESSAGE_BYTES) {
                    return Err(LinkError::Invalid("desc"));
                }
                clean
            }
        };
        let mut entropy = Zeroizing::new(vec![0u8; 32]);
        use rand::RngCore;
        rand::rngs::OsRng.fill_bytes(&mut entropy);
        Ok(Self {
            format: LinkFormat::V1,
            network,
            secret: Secret::Entropy(entropy),
            birthday,
            amount: Some(amount),
            message,
        })
    }

    #[cfg(test)]
    fn from_entropy(network: NetworkType, entropy: &[u8], birthday: u32, amount: Option<u64>, message: Option<&str>) -> Self {
        Self {
            format: LinkFormat::V1,
            network,
            secret: Secret::Entropy(Zeroizing::new(entropy.to_vec())),
            birthday,
            amount,
            message: message.map(str::to_string),
        }
    }

    pub fn parse(link: &str) -> Result<Self, LinkError> {
        let link = link.trim();
        if link.len() > MAX_LINK_LENGTH {
            return Err(LinkError::TooLong);
        }
        let (_, fragment) = split_https(link)?;
        for (prefix, format) in [
            ("v3=", LinkFormat::LegacyV3),
            ("v2=", LinkFormat::LegacyV2),
            ("v1=", LinkFormat::LegacyV1),
        ] {
            if let Some(payload) = fragment.strip_prefix(prefix) {
                return parse_legacy(format, payload);
            }
        }
        parse_v1(fragment)
    }

    /// Writes the `v=1` form. Only 32-byte-entropy gifts can be written.
    pub fn to_link(&self, host: &str) -> Result<Zeroizing<String>, LinkError> {
        let host = host.trim();
        split_https(&format!("{host}#")).map_err(|_| LinkError::Invalid("host"))?;
        let Secret::Entropy(entropy) = &self.secret else {
            return Err(LinkError::UnsupportedVersion);
        };
        if entropy.len() != 32 {
            return Err(LinkError::UnsupportedVersion);
        }
        let key = Zeroizing::new(
            bech32::encode::<Bech32m>(hrp(self.network)?, entropy).map_err(|_| LinkError::Invalid("key"))?,
        );
        // Browsers normalise `https://host#…` to `https://host/#…`.
        let slash = if host[8..].contains('/') { "" } else { "/" };
        let mut out = Zeroizing::new(String::with_capacity(host.len() + key.len() + 64));
        out.push_str(host);
        out.push_str(slash);
        out.push_str("#v=1&key=");
        out.push_str(&key);
        out.push_str("&height=");
        out.push_str(&self.birthday.to_string());
        if let Some(a) = self.amount {
            out.push_str("&amount=");
            out.push_str(&format_zec(a));
        }
        if let Some(m) = &self.message {
            out.push_str("&desc=");
            out.push_str(&percent_encode(m));
        }
        Ok(out)
    }

    fn seed(&self) -> Result<Zeroizing<[u8; 64]>> {
        let mnemonic = match &self.secret {
            Secret::Entropy(e) => bip0039::Mnemonic::<bip0039::English>::from_entropy(e.to_vec()),
            Secret::Phrase(p) => {
                let normalized = Zeroizing::new(p.split_whitespace().collect::<Vec<_>>().join(" "));
                bip0039::Mnemonic::<bip0039::English>::from_phrase(normalized.as_str())
            }
        }
        .map_err(|_| anyhow!("This gift link's key is damaged."))?;
        Ok(Zeroizing::new(mnemonic.to_seed("")))
    }

    pub fn params(&self) -> Result<Network> {
        Ok(network_params(self.network)?)
    }

    pub fn spending_key(&self) -> Result<UnifiedSpendingKey> {
        let seed = self.seed()?;
        UnifiedSpendingKey::from_seed(&self.params()?, seed.as_slice(), zip32::AccountId::ZERO)
            .map_err(|e| anyhow!("Gift key derivation failed: {e:?}"))
    }

    /// The Orchard-only address the gift is funded at.
    pub fn funding_address(&self) -> Result<String> {
        let ufvk = self.spending_key()?.to_unified_full_viewing_key();
        let (ua, _) = ufvk
            .default_address(UnifiedAddressRequest::ORCHARD)
            .map_err(|e| anyhow!("Gift address derivation failed: {e:?}"))?;
        Ok(ua.encode(&self.params()?))
    }
}

fn parse_v1(fragment: &str) -> Result<GiftLink, LinkError> {
    let (mut v, mut key, mut height) = (None, None, None);
    // Informational fields: a repeat makes them ambiguous, so drop both.
    let (mut amount, mut desc): (Option<Option<&str>>, Option<Option<&str>>) = (None, None);
    for pair in fragment.split('&').filter(|p| !p.is_empty()) {
        let (name, value) = pair.split_once('=').unwrap_or((pair, ""));
        let strict = match name {
            "v" => &mut v,
            "key" => &mut key,
            "height" => &mut height,
            "amount" => {
                amount = Some(if amount.is_some() { None } else { Some(value) });
                continue;
            }
            "desc" => {
                desc = Some(if desc.is_some() { None } else { Some(value) });
                continue;
            }
            _ => continue, // later versions may add optional fields
        };
        if strict.replace(value).is_some() {
            return Err(LinkError::Invalid("duplicate field"));
        }
    }
    match v {
        None if key.is_none() => return Err(LinkError::NotAGift),
        None => return Err(LinkError::Invalid("v")),
        Some("1") => {}
        Some(_) => return Err(LinkError::UnsupportedVersion),
    }
    let (network, entropy) = decode_key(key.ok_or(LinkError::Invalid("key"))?)?;
    let height = height.ok_or(LinkError::Invalid("height"))?;
    if height.is_empty() || height.starts_with('0') || !height.bytes().all(|b| b.is_ascii_digit()) {
        return Err(LinkError::Invalid("height"));
    }
    let birthday = check_birthday(network, height.parse().map_err(|_| LinkError::Invalid("height"))?)?;
    Ok(GiftLink {
        format: LinkFormat::V1,
        network,
        secret: Secret::Entropy(entropy),
        birthday,
        amount: amount.flatten().and_then(parse_zec),
        message: desc
            .flatten()
            .and_then(percent_decode)
            .filter(|t| t.len() <= MAX_MESSAGE_BYTES)
            .and_then(|t| sanitize_message(&t)),
    })
}

fn b64url(text: &str) -> Option<Zeroizing<Vec<u8>>> {
    let engine = if text.ends_with('=') { &URL_SAFE } else { &URL_SAFE_NO_PAD };
    engine.decode(text).ok().map(Zeroizing::new)
}

fn json_u64(v: Option<&serde_json::Value>) -> Option<u64> {
    match v? {
        serde_json::Value::Number(n) => n.as_u64(),
        serde_json::Value::String(s) => {
            let s = s.trim();
            (!s.is_empty() && s.bytes().all(|b| b.is_ascii_digit()))
                .then(|| s.parse().ok())
                .flatten()
        }
        _ => None,
    }
}

fn json_text(v: Option<&serde_json::Value>) -> Option<String> {
    v.and_then(|v| v.as_str())
        .filter(|s| s.len() <= MAX_MESSAGE_BYTES)
        .and_then(sanitize_message)
}

fn take_string(v: Option<&mut serde_json::Value>) -> Option<Zeroizing<String>> {
    match v.map(std::mem::take) {
        Some(serde_json::Value::String(s)) => Some(Zeroizing::new(s)),
        _ => None,
    }
}

fn parse_legacy(format: LinkFormat, payload: &str) -> Result<GiftLink, LinkError> {
    if payload.is_empty() || payload.contains('&') {
        return Err(LinkError::Invalid("payload"));
    }
    let bytes = b64url(payload).ok_or(LinkError::Invalid("payload"))?;
    let mut json: serde_json::Value =
        serde_json::from_slice(&bytes).map_err(|_| LinkError::Invalid("payload"))?;
    drop(bytes);
    let network_of = |v: Option<&serde_json::Value>| match v.and_then(|v| v.as_str()).map(str::trim) {
        Some("main") => Ok(NetworkType::Main),
        Some(_) => Err(LinkError::UnsupportedNetwork),
        None => Err(LinkError::Invalid("network")),
    };
    let amount_of = |v: Option<&serde_json::Value>| {
        json_u64(v)
            .filter(|z| *z > 0 && *z <= MAX_SUPPLY_ZAT)
            .ok_or(LinkError::Invalid("amount"))
    };
    let height_of = |network, v: Option<&serde_json::Value>| {
        let h = json_u64(v)
            .and_then(|h| u32::try_from(h).ok())
            .ok_or(LinkError::Invalid("height"))?;
        check_birthday(network, h)
    };
    let gift = if format == LinkFormat::LegacyV3 {
        let items = json
            .as_array_mut()
            .filter(|a| (4..=8).contains(&a.len()))
            .ok_or(LinkError::Invalid("payload"))?;
        let encoded = take_string(items.get_mut(1)).ok_or(LinkError::Invalid("key"))?;
        let entropy = b64url(&encoded).ok_or(LinkError::Invalid("key"))?;
        drop(encoded);
        if !matches!(entropy.len(), 16 | 20 | 24 | 28 | 32) {
            return Err(LinkError::Invalid("key"));
        }
        let network = network_of(items.first())?;
        if !items.get(3).is_some_and(|v| v.is_string()) {
            return Err(LinkError::Invalid("amount"));
        }
        GiftLink {
            format,
            network,
            birthday: height_of(network, items.get(2))?,
            amount: Some(amount_of(items.get(3))?),
            message: json_text(items.get(6)),
            secret: Secret::Entropy(entropy),
        }
    } else {
        let obj = json.as_object_mut().ok_or(LinkError::Invalid("payload"))?;
        let phrase = take_string(obj.get_mut("mnemonic")).ok_or(LinkError::Invalid("mnemonic"))?;
        let expected = if format == LinkFormat::LegacyV1 { 1 } else { 2 };
        if obj.get("v").and_then(|v| v.as_u64()) != Some(expected) {
            return Err(LinkError::UnsupportedVersion);
        }
        let network = network_of(obj.get("network"))?;
        GiftLink {
            format,
            network,
            birthday: height_of(network, obj.get("birthdayHeight"))?,
            amount: Some(amount_of(obj.get("amountZatoshi"))?),
            message: json_text(obj.get("presentation").and_then(|p| p.get("message"))),
            secret: Secret::Phrase(phrase),
        }
    };
    gift.seed().map_err(|_| LinkError::Invalid("key"))?;
    Ok(gift)
}

// ---------------------------------------------------------------------------
// Card wallets: temporary, isolated wallets used to check and sweep a gift
// ---------------------------------------------------------------------------

struct CardSession {
    link: GiftLink,
    dir: PathBuf,
    db_path: PathBuf,
    cipher_key: Option<String>,
    params: Network,
    server_url: String,
    /// Raw bytes of a created sweep, kept so a lost broadcast can be resent
    /// unchanged (never re-created: its inputs are already spent locally).
    sweep: Option<(String, Vec<u8>)>,
}

impl Drop for CardSession {
    fn drop(&mut self) {
        if let Some(k) = self.cipher_key.as_mut() {
            k.zeroize();
        }
    }
}

lazy_static::lazy_static! {
    static ref SESSIONS: tokio::sync::Mutex<HashMap<String, CardSession>> =
        tokio::sync::Mutex::new(HashMap::new());
}

/// Root for card wallets: next to the wallets, excluded from nothing else.
async fn cards_root() -> Result<(PathBuf, Network, String)> {
    let guard = ENGINE.lock().await;
    let engine = guard.as_ref().ok_or_else(|| anyhow!("Open a wallet first."))?;
    let wallet_dir = engine
        .db_data_path
        .parent()
        .ok_or_else(|| anyhow!("Cannot locate wallet directory"))?;
    let root = wallet_dir.parent().unwrap_or(wallet_dir).join("gift-cards");
    Ok((root, engine.params, engine.server_url.clone()))
}

async fn lwd(server_url: &str) -> Result<CompactTxStreamerClient<tonic::transport::Channel>> {
    // The main wallet's privacy setting; a required Tor route never falls back.
    let tor = WALLET_TRANSPORT.lock().await.route()?;
    match tor {
        Some(client) => connect_lwd_tor(&client, server_url).await,
        None => connect_lwd(server_url).await,
    }
}

async fn chain_tip(client: &mut CompactTxStreamerClient<tonic::transport::Channel>) -> Result<u32> {
    let tip = client
        .get_latest_block(ChainSpec {})
        .await
        .map_err(|e| anyhow!("Could not reach the Zcash server: {}", e.code()))?
        .into_inner()
        .height;
    u32::try_from(tip).context("Server returned an invalid height")
}

async fn chain_state_before(
    client: &mut CompactTxStreamerClient<tonic::transport::Channel>,
    height: u32,
) -> Result<ChainState> {
    let prior = height.checked_sub(1).context("height before genesis")?;
    client
        .get_tree_state(BlockId { height: u64::from(prior), hash: vec![] })
        .await
        .map_err(|e| anyhow!("get_tree_state: {}", e.code()))?
        .into_inner()
        .to_chain_state()
        .map_err(|e| anyhow!("tree state: {e:?}"))
}

async fn blocks(
    client: &mut CompactTxStreamerClient<tonic::transport::Channel>,
    start: u32,
    end: u32,
) -> Result<Vec<CompactBlock>> {
    let mut stream = client
        .get_block_range(BlockRange {
            start: Some(BlockId { height: u64::from(start), hash: vec![] }),
            end: Some(BlockId { height: u64::from(end - 1), hash: vec![] }),
            pool_types: vec![],
        })
        .await
        .map_err(|e| anyhow!("get_block_range: {}", e.code()))?
        .into_inner();
    let mut out = Vec::with_capacity((end - start) as usize);
    let mut expected = u64::from(start);
    loop {
        let next = tokio::time::timeout(std::time::Duration::from_secs(30), stream.message())
            .await
            .map_err(|_| anyhow!("The Zcash server stopped responding"))?
            .map_err(|e| anyhow!("get_block_range: {}", e.code()))?;
        let Some(block) = next else { break };
        if block.height != expected || block.height >= u64::from(end) {
            bail!("Server returned blocks out of order");
        }
        expected += 1;
        out.push(block);
    }
    if expected != u64::from(end) {
        bail!("Server returned an incomplete block range");
    }
    Ok(out)
}

/// One downloaded batch, read twice by the scanner.
struct Blocks(Vec<CompactBlock>);

impl zcash_client_backend::data_api::chain::BlockSource for Blocks {
    type Error = std::convert::Infallible;

    fn with_blocks<F, WalletErrT>(
        &self,
        from_height: Option<BlockHeight>,
        limit: Option<usize>,
        mut with_block: F,
    ) -> Result<(), ChainError<WalletErrT, Self::Error>>
    where
        F: FnMut(CompactBlock) -> Result<(), ChainError<WalletErrT, Self::Error>>,
    {
        let from = from_height.map(u64::from).unwrap_or(0);
        for block in self.0.iter().skip_while(|b| b.height < from).take(limit.unwrap_or(usize::MAX)) {
            with_block(block.clone())?;
        }
        Ok(())
    }
}

/// What [`mint`] returns. `link` is a bearer secret.
pub struct MintedGift {
    pub link: Zeroizing<String>,
    pub funding_address: String,
    pub birthday: u32,
    /// Face value plus [`CLAIM_FEE_RESERVE`]: the amount to send.
    pub funding_amount: u64,
}

/// Creates a gift for the open wallet's network, birthday at the current tip.
/// Nothing is sent; the caller funds `funding_address` through the normal
/// reviewed and authenticated send path.
pub async fn mint(amount: u64, message: Option<String>, host: Option<String>) -> Result<MintedGift> {
    let (_, params, server_url) = cards_root().await?;
    let mut client = lwd(&server_url).await?;
    let tip = chain_tip(&mut client).await?;
    let link = GiftLink::mint(params.network_type(), tip, amount, message)?;
    let funding_amount = amount
        .checked_add(CLAIM_FEE_RESERVE)
        .filter(|a| *a <= MAX_SUPPLY_ZAT)
        .context("Amount too large")?;
    Ok(MintedGift {
        link: link.to_link(host.as_deref().unwrap_or(DEFAULT_HOST))?,
        funding_address: link.funding_address()?,
        birthday: tip,
        funding_amount,
    })
}

/// A link's public facts, without opening anything.
pub struct GiftSummary {
    pub network_matches: bool,
    pub testnet: bool,
    pub birthday: u32,
    pub stated_amount: Option<u64>,
    pub message: Option<String>,
    pub funding_address: String,
    pub format: LinkFormat,
}

pub async fn summarize(link: &str) -> Result<GiftSummary> {
    let gift = GiftLink::parse(link)?;
    let ours = ENGINE.lock().await.as_ref().map(|e| e.params.network_type());
    Ok(GiftSummary {
        network_matches: ours == Some(gift.network),
        testnet: gift.network == NetworkType::Test,
        birthday: gift.birthday,
        stated_amount: gift.amount,
        funding_address: gift.funding_address()?,
        message: gift.message.clone(),
        format: gift.format,
    })
}

fn dir_name(funding_address: &str) -> String {
    use sha2::Digest;
    let digest = sha2::Sha256::digest(funding_address.as_bytes());
    hex::encode(&digest[..12])
}

/// Opens (creates) the gift's temporary wallet and returns a handle.
pub async fn open(link: &str) -> Result<String> {
    let gift = GiftLink::parse(link)?;
    let (root, params, server_url) = cards_root().await?;
    if params.network_type() != gift.network {
        bail!(if gift.network == NetworkType::Test {
            "This is a testnet gift. Switch to a testnet wallet to claim it."
        } else {
            "This gift is for mainnet. Switch to a mainnet wallet to claim it."
        });
    }
    let funding = gift.funding_address()?;
    let mut sessions = SESSIONS.lock().await;
    if let Some((id, _)) = sessions.iter().find(|(_, s)| s.link.funding_address().ok().as_ref() == Some(&funding)) {
        return Ok(id.clone());
    }
    let dir = root.join(dir_name(&funding));
    // A leftover from a killed run: its key is random, so it cannot be reused.
    if dir.exists() {
        let _ = std::fs::remove_dir_all(&dir);
    }
    std::fs::create_dir_all(&dir)?;
    let db_path = dir.join("card.sqlite");
    let mut key_bytes = Zeroizing::new([0u8; 32]);
    {
        use rand::RngCore;
        rand::rngs::OsRng.fill_bytes(key_bytes.as_mut());
    }
    let cipher_key = Some(format!("x'{}'", hex::encode(key_bytes.as_ref())));

    let result = async {
        let mut client = lwd(&server_url).await?;
        let birthday_state = chain_state_before(&mut client, gift.birthday).await?;
        let birthday = AccountBirthday::from_parts(birthday_state, None);
        let seed = gift.seed()?;
        let mut db = open_wallet_db(&db_path, params, &cipher_key)?;
        init_wallet_db(&mut db, None).map_err(|e| anyhow!("init card wallet: {e:?}"))?;
        db.import_account_hd(
            "Gift",
            &SecretVec::new(seed.to_vec()),
            zip32::AccountId::ZERO,
            &birthday,
            None,
        )
        .map_err(|e| anyhow!("import gift account: {e:?}"))?;
        Ok::<(), anyhow::Error>(())
    }
    .await;
    if let Err(e) = result {
        let _ = std::fs::remove_dir_all(&dir);
        return Err(e);
    }
    let id = uuid::Uuid::new_v4().to_string();
    sessions.insert(
        id.clone(),
        CardSession { link: gift, dir, db_path, cipher_key, params, server_url, sweep: None },
    );
    Ok(id)
}

/// What a synced gift holds. All values are zatoshis.
#[derive(Debug, Clone, Default)]
pub struct GiftStatus {
    /// Spendable now.
    pub spendable: u64,
    /// Received but waiting for confirmations (up to 10 for funds from
    /// another wallet).
    pub pending: u64,
    /// Exact fee and amount of a full sweep to `destination`, when spendable.
    pub fee: u64,
    pub redeemable: u64,
    pub scanned_height: u32,
    pub tip_height: u32,
    /// The gift wallet has seen at least one transaction (its funding). With
    /// nothing left, that means someone claimed it.
    pub seen_funding: bool,
}

fn card_db(s: &CardSession) -> Result<DbType> {
    open_wallet_db(&s.db_path, s.params, &s.cipher_key)
}

/// Funds from another wallet need 10 confirmations before they can be
/// spent (ZIP 315): the issuer still knows the key.
fn card_policy() -> ConfirmationsPolicy {
    ConfirmationsPolicy::new(
        NonZeroU32::new(3).unwrap(),
        NonZeroU32::new(10).unwrap(),
        true,
    )
    .unwrap_or_default()
}

async fn sync_card(s: &CardSession) -> Result<(u32, u32)> {
    let mut client = lwd(&s.server_url).await?;
    let tip = chain_tip(&mut client).await?;
    let mut db = card_db(s)?;
    db.update_chain_tip(BlockHeight::from_u32(tip))
        .map_err(|e| anyhow!("update tip: {e:?}"))?;
    let mut rewinds = 0;
    'outer: loop {
        let mut ranges: Vec<_> = db
            .suggest_scan_ranges()
            .map_err(|e| anyhow!("scan ranges: {e:?}"))?
            .into_iter()
            .filter(|r| r.priority() > ScanPriority::Scanned && !r.is_empty())
            .collect();
        if ranges.is_empty() {
            break;
        }
        // Linear from the birthday: witnesses build in order and no subtree
        // roots are needed for a range this small.
        ranges.sort_by_key(|r| r.block_range().start);
        for range in ranges {
            let (start, end) = (u32::from(range.block_range().start), u32::from(range.block_range().end));
            let mut from = start;
            while from < end {
                let to = end.min(from + SCAN_BATCH);
                let state = chain_state_before(&mut client, from).await?;
                let source = Blocks(blocks(&mut client, from, to).await?);
                match scan_cached_blocks(&s.params, &source, &mut db, BlockHeight::from_u32(from), &state, (to - from) as usize) {
                    Ok(_) => {}
                    Err(ChainError::Scan(e)) if e.is_continuity_error() && rewinds < 3 => {
                        rewinds += 1;
                        let back = e.at_height().saturating_sub(10);
                        db.truncate_to_height(back).map_err(|e| anyhow!("rewind: {e:?}"))?;
                        continue 'outer;
                    }
                    Err(e) => bail!("Scanning the gift failed: {e:?}"),
                }
                from = to;
            }
        }
    }
    let scanned = db
        .block_fully_scanned()
        .map_err(|e| anyhow!("{e:?}"))?
        .map(|m| u32::from(m.block_height()))
        .unwrap_or(0);
    Ok((scanned, tip))
}

fn sweep_target(params: &Network, destination: &str) -> Result<zcash_address::ZcashAddress> {
    let addr = Address::decode(params, destination)
        .ok_or_else(|| anyhow!("That address is not valid for this network."))?;
    match &addr {
        Address::Unified(ua) if ua.has_orchard() => {}
        _ => bail!("Gifts are claimed to a shielded unified address of this wallet."),
    }
    Ok(addr.to_zcash_address(params))
}

const POOLS: [ShieldedPool; 3] = [ShieldedPool::Orchard, ShieldedPool::Ironwood, ShieldedPool::Sapling];

/// Syncs the gift wallet and reports what it holds. With `destination`, also
/// prices an exact full sweep to it.
pub async fn check(handle: &str, destination: Option<&str>) -> Result<GiftStatus> {
    let sessions = SESSIONS.lock().await;
    let s = sessions.get(handle).ok_or_else(|| anyhow!("This gift was closed. Open it again."))?;
    let (scanned_height, tip_height) = sync_card(s).await?;
    let db = card_db(s)?;
    let account = db
        .get_account_ids()
        .map_err(|e| anyhow!("{e:?}"))?
        .into_iter()
        .next()
        .ok_or_else(|| anyhow!("Gift wallet has no account"))?;
    let summary = db
        .get_wallet_summary(card_policy())
        .map_err(|e| anyhow!("{e:?}"))?;
    let (spendable, pending) = summary
        .as_ref()
        .and_then(|s| s.account_balances().get(&account))
        .map(|b| {
            let shielded = [b.sapling_balance(), b.orchard_balance(), b.ironwood_balance()];
            (
                shielded.iter().map(|x| x.spendable_value().into_u64()).sum::<u64>(),
                shielded
                    .iter()
                    .map(|x| x.value_pending_spendability().into_u64() + x.change_pending_confirmation().into_u64())
                    .sum::<u64>(),
            )
        })
        .unwrap_or((0, 0));
    drop(db);
    let seen_funding = crate::open_cipher_conn(&s.db_path, &s.cipher_key)?
        .query_row("SELECT COUNT(*) FROM v_transactions", [], |r| r.get::<_, i64>(0))
        .map(|n| n > 0)
        .unwrap_or(false);
    let mut status = GiftStatus { spendable, pending, scanned_height, tip_height, seen_funding, ..Default::default() };
    if let (Some(dest), true) = (destination, spendable > 0) {
        let to = sweep_target(&s.params, dest)?;
        let snapshot = crate::fees::snapshot(false).await?;
        let mut db = card_db(s)?;
        match propose_send_max_transfer::<_, _, _, std::convert::Infallible>(
            &mut db,
            &s.params,
            account,
            &POOLS,
            &snapshot.fee_rule()?,
            to,
            None,
            MaxSpendMode::MaxSpendable,
            card_policy(),
            &LockedInputPolicy::default(),
            None,
        ) {
            Ok(p) => {
                let step = p.steps().first();
                let fee = step.balance().fee_required().into_u64();
                status.fee = fee;
                status.redeemable = spendable.saturating_sub(fee);
            }
            // Everything would go to the fee: dust.
            Err(e) if format!("{e:?}").contains("InsufficientFunds") => {}
            Err(e) => bail!("Could not price the claim: {e:?}"),
        }
    }
    Ok(status)
}

pub struct SweepOutcome {
    pub txid: String,
    pub amount: u64,
    pub fee: u64,
    pub accepted: bool,
    pub detail: Option<String>,
}

/// Sends everything the gift holds to `destination` (an address of the open
/// wallet). Call only after the user confirmed and passed device
/// authentication. The outgoing viewing key is discarded so the gift's key
/// cannot reveal where it went.
pub async fn sweep(handle: &str, destination: &str) -> Result<SweepOutcome> {
    let mut sessions = SESSIONS.lock().await;
    let s = sessions.get_mut(handle).ok_or_else(|| anyhow!("This gift was closed. Open it again."))?;
    if s.sweep.is_some() {
        bail!("This gift's claim was already created. Use resend instead.");
    }
    let to = sweep_target(&s.params, destination)?;
    let snapshot = crate::fees::snapshot(false).await?;
    let mut db = card_db(s)?;
    let account = db
        .get_account_ids()
        .map_err(|e| anyhow!("{e:?}"))?
        .into_iter()
        .next()
        .ok_or_else(|| anyhow!("Gift wallet has no account"))?;
    let proposal = propose_send_max_transfer::<_, _, _, std::convert::Infallible>(
        &mut db,
        &s.params,
        account,
        &POOLS,
        &snapshot.fee_rule()?,
        to,
        None,
        MaxSpendMode::MaxSpendable,
        card_policy(),
        &LockedInputPolicy::default(),
        None,
    )
    .map_err(|e| {
        if format!("{e:?}").contains("InsufficientFunds") {
            anyhow!("There is nothing to claim: the gift is empty, still confirming, or smaller than the fee.")
        } else {
            anyhow!("Could not prepare the claim: {e:?}")
        }
    })?;
    if proposal.steps().len() != 1 {
        bail!("Unexpected multi-step claim");
    }
    let step = proposal.steps().first();
    let fee = step.balance().fee_required().into_u64();
    let amount: u64 = step
        .transaction_request()
        .payments()
        .values()
        .filter_map(|p| p.amount())
        .map(Zatoshis::into_u64)
        .sum();
    let expiry = snapshot.expiry_at_review(u32::from(proposal.min_target_height()))?;
    let prover = load_prover(&s.dir)?;
    let usk = s.link.spending_key()?;
    let txids = create_proposed_transactions::<_, _, std::convert::Infallible, _, std::convert::Infallible, _>(
        &mut db,
        &s.params,
        &prover,
        &prover,
        &SpendingKeys::from_unified_spending_key(usk),
        OvkPolicy::Discard,
        &proposal,
        Some(expiry),
    )
    .map_err(|e| anyhow!("Could not create the claim: {e:?}"))?;
    let txid = *txids.first();
    let tx = db
        .get_transaction(txid)
        .map_err(|e| anyhow!("{e:?}"))?
        .ok_or_else(|| anyhow!("Claim not found after creation"))?;
    let mut raw = Vec::new();
    tx.write(&mut raw)?;
    drop(db);
    // From here a transaction exists. Never error: report the outcome.
    s.sweep = Some((txid.to_string(), raw.clone()));
    let (server, params) = (s.server_url.clone(), s.params);
    drop(sessions);
    let result = async {
        let tor = snapshot.broadcast_transport().await?;
        crate::send::broadcast_for_generation(&server, &params, raw, tor, snapshot.generation()).await
    }
    .await;
    Ok(SweepOutcome {
        txid: txid.to_string(),
        amount,
        fee,
        accepted: result.is_ok(),
        detail: result.err().map(|e| format!("{e:#}")),
    })
}

/// Resends an already created claim, byte for byte.
pub async fn resend(handle: &str) -> Result<SweepOutcome> {
    let (server, params, txid, raw) = {
        let sessions = SESSIONS.lock().await;
        let s = sessions.get(handle).ok_or_else(|| anyhow!("This gift was closed."))?;
        let (txid, raw) = s.sweep.clone().ok_or_else(|| anyhow!("No claim to resend"))?;
        (s.server_url.clone(), s.params, txid, raw)
    };
    let snapshot = crate::fees::snapshot(false).await?;
    let tor = snapshot.broadcast_transport().await?;
    let result = crate::send::broadcast_for_generation(&server, &params, raw, tor, snapshot.generation()).await;
    Ok(SweepOutcome { txid, amount: 0, fee: 0, accepted: result.is_ok(), detail: result.err().map(|e| format!("{e:#}")) })
}

/// Stops using a gift wallet and deletes its files. The key is in the link,
/// so nothing is lost.
pub async fn close(handle: &str) {
    if let Some(s) = SESSIONS.lock().await.remove(handle) {
        let _ = std::fs::remove_dir_all(&s.dir);
    }
}

/// Deletes card wallets a killed run left behind. Skips open ones.
pub async fn remove_leftovers() -> Result<u32> {
    let (root, _, _) = cards_root().await?;
    let open: Vec<PathBuf> = SESSIONS.lock().await.values().map(|s| s.dir.clone()).collect();
    let mut removed = 0;
    if let Ok(entries) = std::fs::read_dir(&root) {
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_dir() && !open.contains(&path) && std::fs::remove_dir_all(&path).is_ok() {
                removed += 1;
            }
        }
    }
    Ok(removed)
}

/// The Sapling parameters live next to the wallets. A gift claim spends
/// Orchard notes, but the builder still wants a prover instance.
fn load_prover(card_dir: &Path) -> Result<zcash_proofs::prover::LocalTxProver> {
    let mut dir = card_dir.to_path_buf();
    for _ in 0..4 {
        let (spend, output) = (dir.join("sapling-spend.params"), dir.join("sapling-output.params"));
        if spend.exists() && output.exists() {
            return Ok(zcash_proofs::prover::LocalTxProver::new(&spend, &output));
        }
        if !dir.pop() {
            break;
        }
    }
    // Wallet directories sit one level deeper than the parameters.
    if let Ok(entries) = std::fs::read_dir(&dir) {
        for e in entries.flatten() {
            let d = e.path();
            let (spend, output) = (d.join("sapling-spend.params"), d.join("sapling-output.params"));
            if spend.exists() && output.exists() {
                return Ok(zcash_proofs::prover::LocalTxProver::new(&spend, &output));
            }
        }
    }
    bail!("Sapling parameters not found")
}

#[cfg(test)]
mod tests {
    use super::*;

    const HOST: &str = "https://example.com/";

    #[test]
    fn v1_round_trip_and_reference_key_encoding() {
        // Interop vector from the published format description.
        let gift = GiftLink::from_entropy(NetworkType::Main, &[0xA5; 32], 3_500_000, Some(150_000_000), Some("Hi from Zcash! \u{1F6E1}\u{FE0F} 100% ~_.-+/"));
        let link = gift.to_link("https://example.com").unwrap();
        assert_eq!(
            link.as_str(),
            "https://example.com/#v=1&key=zgift15kj6tfd95kj6tfd95kj6tfd95kj6tfd95kj6tfd95kj6tfd95kjsuax7hg&height=3500000&amount=1.5&desc=Hi%20from%20Zcash%21%20%F0%9F%9B%A1%EF%B8%8F%20100%25%20~_.-%2B%2F"
        );
        let back = GiftLink::parse(&link).unwrap();
        assert_eq!(back.format, LinkFormat::V1);
        assert_eq!(back.birthday, 3_500_000);
        assert_eq!(back.amount, Some(150_000_000));
        assert_eq!(back.message.as_deref(), Some("Hi from Zcash! \u{1F6E1}\u{FE0F} 100% ~_.-+/"));
        assert_eq!(back.funding_address().unwrap(), gift.funding_address().unwrap());
        // A path host keeps its path; the host is not part of the gift.
        let path = gift.to_link("https://zipher.to/gift").unwrap();
        assert!(path.starts_with("https://zipher.to/gift#v=1&key=zgift1"));
        let moved = path.replacen("https://zipher.to/gift", "HTTPS://other.example/x", 1);
        assert_eq!(GiftLink::parse(&moved).unwrap().funding_address().unwrap(), gift.funding_address().unwrap());
    }

    #[test]
    fn reference_testnet_key_derives_the_published_funding_address() {
        let link = "https://example.com/#v=1&key=zgifttest1xzr6q9crzm5zzl6ge2m5ym4wc74ajl96hc6qqy0sh9xhwgvxjfrqlnz3au&height=4000000&amount=0.1234&desc=Hi%20from%20Zcash%21";
        let gift = GiftLink::parse(link).unwrap();
        assert_eq!(gift.network, NetworkType::Test);
        assert_eq!(gift.amount, Some(12_340_000));
        assert_eq!(gift.message.as_deref(), Some("Hi from Zcash!"));
        assert_eq!(
            gift.funding_address().unwrap(),
            "utest1t2mdpt5zzhunczjk2cggyz8wt7hh09h9a3rmfmatcgntfmg5kyknca2k3d28val00rs93larmf6yp5ycxwqnrvl5h973efddjs88hggf"
        );
        assert_eq!(gift.to_link(HOST).unwrap().as_str(), link);
    }

    #[test]
    fn reads_the_published_legacy_v3_vector() {
        // 16 zero bytes of entropy: never fund this.
        let link = "https://link.vizor.cash/payment-links/open#v3=WyJtYWluIiwiQUFBQUFBQUFBQUFBQUFBQUFBQUFBQSIsMzQ4MzE0MSwiMTAwMDAwMCIsImtuaWdodE1hZ2ljIiwxMS4xNywiSXQncyBhIGdyZWF0IGRheSB0byBzaGllbGQgeW91ciBaRUMg8J-boe-4jyJd";
        assert!(looks_like_gift(link));
        let gift = GiftLink::parse(link).unwrap();
        assert_eq!(gift.format, LinkFormat::LegacyV3);
        assert_eq!(gift.network, NetworkType::Main);
        assert_eq!(gift.birthday, 3_483_141);
        assert_eq!(gift.amount, Some(1_000_000));
        assert_eq!(gift.message.as_deref(), Some("It's a great day to shield your ZEC \u{1F6E1}\u{FE0F}"));
        assert!(gift.funding_address().unwrap().starts_with("u1"));
        // Legacy links are read, not written.
        assert!(gift.to_link(HOST).is_err());
    }

    #[test]
    fn reads_legacy_v2_with_odd_whitespace() {
        let json = serde_json::json!({
            "v": 2, "network": "main", "amountZatoshi": "2500000",
            "mnemonic": format!("{}  art", ["abandon"; 23].join(" ")),
            "birthdayHeight": 3_000_000, "presentation": {"message": "hi\nthere"},
        });
        let link = format!("https://x.example/payment-links/open#v2={}", URL_SAFE_NO_PAD.encode(json.to_string()));
        let gift = GiftLink::parse(&link).unwrap();
        assert_eq!(gift.format, LinkFormat::LegacyV2);
        assert_eq!(gift.amount, Some(2_500_000));
        assert_eq!(gift.message.as_deref(), Some("hi there"));
        gift.spending_key().unwrap();
    }

    #[test]
    fn strict_fields_reject_and_informational_fields_degrade() {
        let ok = GiftLink::from_entropy(NetworkType::Main, &[1; 32], 3_500_000, None, None)
            .to_link(HOST)
            .unwrap();
        let key = ok.split('&').nth(1).unwrap().to_string();
        let base = "https://example.com/";
        let nu5 = min_birthday(NetworkType::Main);
        for (link, err) in [
            (format!("{base}#v=2&{key}&height=3500000"), LinkError::UnsupportedVersion),
            (format!("{base}#v=1&height=3500000"), LinkError::Invalid("key")),
            (format!("{base}#v=1&{key}"), LinkError::Invalid("height")),
            (format!("{base}#v=1&{key}&height=03500000"), LinkError::Invalid("height")),
            (format!("{base}#v=1&{key}&height={}", nu5 - 1), LinkError::Invalid("height")),
            (format!("{base}#v=1&{key}&{key}&height=3500000"), LinkError::Invalid("duplicate field")),
            (format!("http://example.com/#v=1&{key}&height=3500000"), LinkError::NotAGift),
            (format!("{base}v=1&{key}&height=3500000"), LinkError::NotAGift),
            ("https://example.com/#foo=bar".to_string(), LinkError::NotAGift),
        ] {
            assert_eq!(GiftLink::parse(&link).unwrap_err(), err, "{link}");
        }
        // Flip one checksum character.
        let mut bad = ok.to_string();
        let i = bad.find("&height").unwrap() - 1;
        bad.replace_range(i..i + 1, if &bad[i..i + 1] == "q" { "p" } else { "q" });
        assert_eq!(GiftLink::parse(&bad).unwrap_err(), LinkError::Invalid("key"));
        // Upper-case keys (QR alphanumeric form) are fine; mixed case is not.
        let upper = format!("{base}#v=1&key={}&height=3500000", key.trim_start_matches("key=").to_uppercase());
        assert!(GiftLink::parse(&upper).is_ok());
        // Bad informational values are dropped, not fatal; unknown fields ignored.
        let soft = format!("{}&amount=1e8&desc=%ZZ&future=1&amount=2", ok.as_str());
        let gift = GiftLink::parse(&soft).unwrap();
        assert_eq!(gift.amount, None);
        assert_eq!(gift.message, None);
        assert_eq!(GiftLink::parse(&"x".repeat(MAX_LINK_LENGTH + 1)).unwrap_err(), LinkError::TooLong);
    }

    #[test]
    fn messages_are_sanitized() {
        assert_eq!(sanitize_message("a\u{202E}b\u{200B}c\r\nd").as_deref(), Some("abc  d"));
        assert_eq!(sanitize_message(" \u{200B}\n "), None);
        // Emoji sequences keep their joiners.
        assert_eq!(sanitize_message("👩‍💻").as_deref(), Some("👩‍💻"));
    }

    #[test]
    fn mint_is_random_and_round_trips() {
        let a = GiftLink::mint(NetworkType::Main, 3_500_000, 25_000_000, Some("Welcome!".into())).unwrap();
        let b = GiftLink::mint(NetworkType::Main, 3_500_000, 25_000_000, None).unwrap();
        assert_ne!(a.funding_address().unwrap(), b.funding_address().unwrap());
        let link = a.to_link(DEFAULT_HOST).unwrap();
        assert!(looks_like_gift(&link));
        let back = GiftLink::parse(&link).unwrap();
        assert_eq!(back.funding_address().unwrap(), a.funding_address().unwrap());
        assert_eq!(back.amount, Some(25_000_000));
        assert!(format!("{back:?}").contains("<redacted>"));
        assert!(!format!("{back:?}").contains("zgift"));
        assert!(GiftLink::mint(NetworkType::Main, 1, 1, None).is_err());
        assert!(GiftLink::mint(NetworkType::Main, 3_500_000, 0, None).is_err());
    }

    #[test]
    fn zec_amounts() {
        assert_eq!(parse_zec("1.5"), Some(150_000_000));
        assert_eq!(parse_zec("0.00000001"), Some(1));
        for bad in ["0", "1.", ".5", "1.123456789", "-1", "1e8", "21000001"] {
            assert_eq!(parse_zec(bad), None, "{bad}");
        }
        assert_eq!(format_zec(150_000_000), "1.5");
        assert_eq!(format_zec(100_000_000), "1");
        assert_eq!(format_zec(12_340_000), "0.1234");
    }
}
