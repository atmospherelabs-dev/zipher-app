use std::io::Read as _;
use std::path::PathBuf;

use anyhow::Result;
use secrecy::{ExposeSecret, SecretString};
use serde::Serialize;

use crate::Config;

// ---------------------------------------------------------------------------
// Sapling parameter auto-download
// ---------------------------------------------------------------------------

const SAPLING_SPEND_URL: &str = "https://download.z.cash/downloads/sapling-spend.params";
const SAPLING_OUTPUT_URL: &str = "https://download.z.cash/downloads/sapling-output.params";
const SAPLING_SPEND_SHA256: &str =
    "8e48ffd23abb3a5fd9c5589204f32d9c31285a04b78096ba40a79b75677efc13";
const SAPLING_OUTPUT_SHA256: &str =
    "2f0ebbcbb9bb0bcffe95a397e7eba89c29eb4dde6191c339db88570e3f3fb0e4";

pub async fn ensure_sapling_params(data_dir: &str) -> Result<()> {
    let parent = std::path::Path::new(data_dir)
        .parent()
        .unwrap_or(std::path::Path::new(data_dir));
    let spend_path = parent.join("sapling-spend.params");
    let output_path = parent.join("sapling-output.params");

    if spend_path.exists() && output_path.exists() {
        return Ok(());
    }

    std::fs::create_dir_all(parent)?;

    if !spend_path.exists() {
        download_and_verify(
            SAPLING_SPEND_URL,
            &spend_path,
            SAPLING_SPEND_SHA256,
            "sapling-spend.params (~47 MB)",
        )
        .await?;
    }

    if !output_path.exists() {
        download_and_verify(
            SAPLING_OUTPUT_URL,
            &output_path,
            SAPLING_OUTPUT_SHA256,
            "sapling-output.params (~3.5 MB)",
        )
        .await?;
    }

    Ok(())
}

async fn download_and_verify(
    url: &str,
    dest: &std::path::Path,
    expected_sha256: &str,
    label: &str,
) -> Result<()> {
    eprintln!("Downloading {}...", label);

    let response = reqwest::get(url)
        .await
        .map_err(|e| anyhow::anyhow!("Failed to download {}: {}", label, e))?;

    if !response.status().is_success() {
        return Err(anyhow::anyhow!(
            "Download failed for {}: HTTP {}",
            label,
            response.status()
        ));
    }

    let bytes = response
        .bytes()
        .await
        .map_err(|e| anyhow::anyhow!("Failed to read {}: {}", label, e))?;

    use sha2::Digest;
    let hash = sha2::Sha256::digest(&bytes);
    let hex_hash = hex::encode(hash);
    if hex_hash != expected_sha256 {
        return Err(anyhow::anyhow!(
            "Checksum mismatch for {}. Expected {}, got {}",
            label,
            expected_sha256,
            hex_hash
        ));
    }

    std::fs::write(dest, &bytes)?;
    eprintln!("  Verified and saved to {}", dest.display());
    Ok(())
}

// ---------------------------------------------------------------------------
// Seed reading: OWS vault only
// ---------------------------------------------------------------------------

pub fn validate_ows_passphrase(value: Option<String>) -> Result<SecretString> {
    match value {
        Some(value) if !value.trim().is_empty() => Ok(SecretString::new(value)),
        _ => anyhow::bail!(
            "Set OWS_PASSPHRASE to a nonempty secret before creating, restoring or unlocking \
             a wallet. Empty-passphrase vaults are not unlocked by Zipher. Existing recovery \
             material is unchanged; see docs/cli-wallet-security.md for explicit migration."
        ),
    }
}

pub fn ows_passphrase() -> Result<SecretString> {
    validate_ows_passphrase(std::env::var("OWS_PASSPHRASE").ok())
}

pub fn reject_legacy_seed(data_dir: &str) -> Result<()> {
    if std::path::Path::new(data_dir).join(".seed").try_exists()? {
        anyhow::bail!(
            "Legacy plaintext .seed recovery material exists in this data directory. \
             Zipher will not read, delete or migrate it automatically. Keep your backup; \
             restore through --seed-stdin into a NEW --data-dir and an unused OWS_WALLET \
             name with a nonempty OWS_PASSPHRASE. Verify recovery before manually removing \
             any original material. See docs/cli-wallet-security.md."
        );
    }
    Ok(())
}

/// Reject argv seeds before clap can include their value in a parsing error.
pub fn unsafe_seed_argument(argument: &std::ffi::OsStr) -> bool {
    let bytes = argument.as_encoded_bytes();
    bytes == b"--seed" || bytes.starts_with(b"--seed=")
}

/// Recovery input must be redirected/piped; an interactive terminal would echo it.
pub fn read_seed_input<R: std::io::Read>(reader: R, is_terminal: bool) -> Result<SecretString> {
    if is_terminal {
        anyhow::bail!(
            "--seed-stdin requires redirected or piped input, not an echoing terminal. \
             Read from a protected recovery file or a trusted secret manager; never put \
             the mnemonic in command arguments or shell command text."
        );
    }
    const MAX_SEED_BYTES: u64 = 1024;
    let mut bytes = zeroize::Zeroizing::new(Vec::new());
    reader.take(MAX_SEED_BYTES + 1).read_to_end(&mut bytes)?;
    if bytes.len() as u64 > MAX_SEED_BYTES {
        anyhow::bail!("Recovery input is too large; expected one BIP-39 mnemonic.");
    }
    let text = std::str::from_utf8(&bytes)
        .map_err(|_| anyhow::anyhow!("Recovery input must be UTF-8 mnemonic words."))?;
    let words: Vec<_> = text.split_whitespace().collect();
    if !matches!(words.len(), 12 | 15 | 18 | 21 | 24)
        || words
            .iter()
            .any(|word| !word.bytes().all(|b| b.is_ascii_lowercase()))
    {
        anyhow::bail!("Recovery input must contain one valid English BIP-39 mnemonic.");
    }
    Ok(SecretString::new(words.join(" ")))
}

pub fn validate_recovery_display(
    human: bool,
    requested: bool,
    input_terminal: bool,
    output_terminal: bool,
) -> Result<()> {
    if !human || !requested || !input_terminal || !output_terminal {
        anyhow::bail!(
            "Recovery display requires `zipher --human wallet backup --show-recovery` \
             in a trusted private terminal, with neither stdin nor stdout redirected. \
             Do not use a recorded/shared terminal; its scrollback may retain the phrase."
        );
    }
    Ok(())
}

fn read_seed_with<F>(data_dir: &str, credential: Option<String>, export: F) -> Result<SecretString>
where
    F: FnOnce(&str) -> Result<String>,
{
    reject_legacy_seed(data_dir)?;
    let passphrase = validate_ows_passphrase(credential)?;
    let exported = SecretString::new(export(passphrase.expose_secret())?);
    if exported.expose_secret().contains(' ') && !exported.expose_secret().starts_with('{') {
        Ok(exported)
    } else {
        anyhow::bail!("The selected OWS wallet is not a mnemonic wallet.")
    }
}

pub fn read_seed(data_dir: &str) -> Result<SecretString> {
    let wallet = std::env::var("OWS_WALLET").unwrap_or_else(|_| "default".to_string());
    read_seed_with(
        data_dir,
        std::env::var("OWS_PASSPHRASE").ok(),
        |passphrase| {
            ows_lib::export_wallet(&wallet, Some(passphrase), None).map_err(|_| {
                anyhow::anyhow!(
                    "Cannot unlock the selected OWS mnemonic wallet. Check OWS_WALLET and \
             OWS_PASSPHRASE in the trusted operator terminal. No plaintext fallback is used."
                )
            })
        },
    )
}

// ---------------------------------------------------------------------------
// Pending proposal persistence
// ---------------------------------------------------------------------------

pub const SEND_REVIEW_TTL_SECS: u64 = 120;

#[derive(Clone, Serialize, serde::Deserialize)]
pub struct PendingProposal {
    pub address: String,
    pub amount: u64,
    pub memo: Option<String>,
    pub is_max: bool,
    pub context_id: Option<String>,
    #[serde(default)]
    pub review: Option<PendingReview>,
}

#[derive(Clone, Debug, Serialize, serde::Deserialize)]
pub struct PendingReview {
    pub priority: bool,
    pub amount: u64,
    pub fee: u64,
    pub branch: u32,
    pub network: String,
    pub endpoint: String,
    pub created_at: u64,
    pub digest: String,
}

pub fn now_unix_secs() -> Result<u64> {
    Ok(std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_err(|_| anyhow::anyhow!("System clock is invalid; review the payment again"))?
        .as_secs())
}

fn network_name(network: zcash_protocol::consensus::Network) -> &'static str {
    match network {
        zcash_protocol::consensus::Network::MainNetwork => "mainnet",
        zcash_protocol::consensus::Network::TestNetwork => "testnet",
    }
}

impl PendingProposal {
    pub fn bind_review(
        &mut self,
        cfg: &Config,
        priority: bool,
        amount: u64,
        fee: u64,
        branch: u32,
        created_at: u64,
    ) -> Result<()> {
        amount
            .checked_add(fee)
            .ok_or_else(|| anyhow::anyhow!("Payment total overflow"))?;
        anyhow::ensure!(
            amount == self.amount && amount > 0 && fee > 0,
            "Invalid reviewed payment totals"
        );
        self.review = Some(PendingReview {
            priority,
            amount,
            fee,
            branch,
            network: network_name(cfg.network).into(),
            endpoint: cfg.server_url.clone(),
            created_at,
            digest: String::new(),
        });
        let digest = self.review_digest()?;
        self.review
            .as_mut()
            .ok_or_else(|| anyhow::anyhow!("Review unavailable"))?
            .digest = digest;
        Ok(())
    }

    fn review_digest(&self) -> Result<String> {
        use sha2::Digest;
        let review = self.review.as_ref().ok_or_else(|| {
            anyhow::anyhow!(
                "Legacy or unbound proposal; run `zipher-cli send propose` and review again"
            )
        })?;
        // An integrity binding for the persisted review, not a substitute for
        // the operator's ownership of this local file and signing credential.
        let encoded = serde_json::to_vec(&(
            "zipher-cli-send-review-v1",
            &self.address,
            self.amount,
            &self.memo,
            self.is_max,
            &self.context_id,
            review.priority,
            review.amount,
            review.fee,
            review.branch,
            &review.network,
            &review.endpoint,
            review.created_at,
        ))?;
        Ok(hex::encode(sha2::Sha256::digest(encoded)))
    }

    pub fn validate_review(&self, cfg: &Config, now: u64) -> Result<&PendingReview> {
        let review = self.review.as_ref().ok_or_else(|| {
            anyhow::anyhow!(
                "Legacy or unbound proposal; run `zipher-cli send propose` and review again"
            )
        })?;
        zcash_protocol::consensus::BranchId::try_from(review.branch)
            .map_err(|_| anyhow::anyhow!("Unknown reviewed consensus branch; review again"))?;
        anyhow::ensure!(
            review.network == network_name(cfg.network) && review.endpoint == cfg.server_url,
            "Payment network or server changed; run `zipher-cli send propose` and review again"
        );
        anyhow::ensure!(
            now >= review.created_at && now - review.created_at <= SEND_REVIEW_TTL_SECS,
            "Payment review expired; run `zipher-cli send propose` and review again"
        );
        anyhow::ensure!(
            review.amount == self.amount && review.amount > 0 && review.fee > 0,
            "Reviewed payment totals changed; review again"
        );
        review
            .amount
            .checked_add(review.fee)
            .ok_or_else(|| anyhow::anyhow!("Payment total overflow"))?;
        anyhow::ensure!(
            review.digest == self.review_digest()?,
            "Persisted payment review changed; review again"
        );
        Ok(review)
    }

    pub fn validate_fresh_totals(
        &self,
        cfg: &Config,
        amount: u64,
        fee: u64,
        branch: u32,
        now: u64,
    ) -> Result<()> {
        let reviewed = self.validate_review(cfg, now)?;
        anyhow::ensure!(reviewed.amount == amount && reviewed.fee == fee && reviewed.branch == branch,
            "Payment amount, fee or network upgrade changed since review; run `zipher-cli send propose` and approve the new totals");
        Ok(())
    }
}

fn pending_path(data_dir: &str) -> PathBuf {
    PathBuf::from(data_dir).join("pending_proposal.json")
}

pub fn save_pending(data_dir: &str, proposal: &PendingProposal) -> Result<()> {
    let path = pending_path(data_dir);
    let temporary = unique_pending_path(data_dir, "writing")?;
    let mut options = std::fs::OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let result = (|| -> Result<()> {
        use std::io::Write as _;
        let mut file = options.open(&temporary)?;
        file.write_all(&serde_json::to_vec_pretty(proposal)?)?;
        file.sync_all()?;
        std::fs::rename(&temporary, &path)?;
        Ok(())
    })();
    if result.is_err() {
        let _ = std::fs::remove_file(&temporary);
    }
    result?;
    Ok(())
}

fn unique_pending_path(data_dir: &str, purpose: &str) -> Result<PathBuf> {
    let nonce = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_err(|_| anyhow::anyhow!("System clock is invalid"))?
        .as_nanos();
    Ok(PathBuf::from(data_dir).join(format!(
        "pending_proposal.{purpose}.{}.{nonce}.json",
        std::process::id()
    )))
}

fn read_pending_path(path: &std::path::Path) -> Result<PendingProposal> {
    let mut bytes = Vec::new();
    std::fs::File::open(path)?
        .take(65_537)
        .read_to_end(&mut bytes)?;
    anyhow::ensure!(
        bytes.len() <= 65_536,
        "Pending proposal is too large; review again"
    );
    Ok(serde_json::from_slice(&bytes)?)
}

pub fn load_pending(data_dir: &str) -> Result<PendingProposal> {
    let path = pending_path(data_dir);
    if !path.exists() {
        return Err(anyhow::anyhow!(
            "No pending proposal. Run `zipher-cli send propose` first."
        ));
    }
    read_pending_path(&path)
}

/// Atomically claim this exact review once before budget reservation/signing.
/// A failed or uncertain submission can never be retried with the old review.
pub fn consume_pending(data_dir: &str, expected: &PendingProposal) -> Result<()> {
    let expected_digest = expected
        .review
        .as_ref()
        .ok_or_else(|| anyhow::anyhow!("Payment review is unbound"))?
        .digest
        .clone();
    let claimed = unique_pending_path(data_dir, "consumed")?;
    std::fs::rename(pending_path(data_dir), &claimed).map_err(|_| {
        anyhow::anyhow!("Payment review was already used or replaced; review again")
    })?;
    let result = (|| -> Result<()> {
        let actual = read_pending_path(&claimed)?;
        anyhow::ensure!(
            actual.review_digest()? == expected_digest
                && actual
                    .review
                    .as_ref()
                    .is_some_and(|r| r.digest == expected_digest),
            "Payment review was replaced; review again"
        );
        Ok(())
    })();
    let cleanup = std::fs::remove_file(&claimed);
    result?;
    cleanup?;
    Ok(())
}

pub fn delete_pending(data_dir: &str) {
    let path = pending_path(data_dir);
    std::fs::remove_file(path).ok();
    zipher_engine::send::clear_pczt_lock(data_dir);
}

pub fn invalidate_pending_review(data_dir: &str) -> Result<()> {
    match std::fs::remove_file(pending_path(data_dir)) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error.into()),
    }
}

#[cfg(test)]
mod send_review_tests {
    use super::*;
    use zcash_protocol::consensus::Network;

    struct Fixture(PathBuf);
    impl Fixture {
        fn new() -> Self {
            static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
            let path = std::env::temp_dir().join(format!(
                "zipher-cli-review-test-{}-{}-{}",
                std::process::id(),
                now_unix_secs().unwrap(),
                NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
            ));
            std::fs::create_dir(&path).unwrap();
            Self(path)
        }
        fn config(&self) -> Config {
            Config {
                data_dir: self.0.to_str().unwrap().into(),
                server_url: "https://review.example:443".into(),
                network: Network::MainNetwork,
                human: false,
            }
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    fn reviewed(cfg: &Config) -> PendingProposal {
        let mut pending = PendingProposal {
            address: "disposable-recipient".into(),
            amount: 70_000,
            memo: Some("reviewed memo".into()),
            is_max: false,
            context_id: Some("review-context".into()),
            review: None,
        };
        pending
            .bind_review(
                cfg,
                true,
                70_000,
                100_000,
                u32::from(zcash_protocol::consensus::BranchId::Nu6_3),
                1_000,
            )
            .unwrap();
        pending
    }

    #[test]
    fn persisted_priority_and_exact_totals_survive_roundtrip_and_are_used_once() {
        let fixture = Fixture::new();
        let cfg = fixture.config();
        let pending = reviewed(&cfg);
        save_pending(&cfg.data_dir, &pending).unwrap();
        let loaded = load_pending(&cfg.data_dir).unwrap();
        assert!(loaded.validate_review(&cfg, 1_001).unwrap().priority);
        assert!(loaded
            .validate_fresh_totals(
                &cfg,
                70_000,
                100_000,
                u32::from(zcash_protocol::consensus::BranchId::Nu6_3),
                1_001
            )
            .is_ok());
        assert!(
            loaded
                .validate_fresh_totals(
                    &cfg,
                    70_000,
                    10_000,
                    u32::from(zcash_protocol::consensus::BranchId::Nu6_3),
                    1_001
                )
                .is_err(),
            "priority cannot silently become standard"
        );
        assert!(
            loaded
                .validate_fresh_totals(
                    &cfg,
                    71_000,
                    100_000,
                    u32::from(zcash_protocol::consensus::BranchId::Nu6_3),
                    1_001
                )
                .is_err(),
            "send-max changes require a new review"
        );
        assert!(
            loaded
                .validate_fresh_totals(
                    &cfg,
                    70_000,
                    100_000,
                    u32::from(zcash_protocol::consensus::BranchId::Nu7),
                    1_001
                )
                .is_err(),
            "an activation change requires review even when amount and fee match"
        );
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(
                std::fs::metadata(pending_path(&cfg.data_dir))
                    .unwrap()
                    .permissions()
                    .mode()
                    & 0o777,
                0o600
            );
        }
        consume_pending(&cfg.data_dir, &loaded).unwrap();
        assert!(consume_pending(&cfg.data_dir, &loaded).is_err());
        assert_eq!(std::fs::read_dir(&fixture.0).unwrap().count(), 0);
    }

    #[test]
    fn legacy_unbound_expired_future_and_changed_network_reviews_fail_closed() {
        let fixture = Fixture::new();
        let mut cfg = fixture.config();
        let legacy:PendingProposal=serde_json::from_str(r#"{"address":"recipient","amount":70000,"memo":null,"is_max":false,"context_id":null}"#).unwrap();
        assert!(legacy.validate_review(&cfg, 1_001).is_err());
        let pending = reviewed(&cfg);
        assert!(pending.validate_review(&cfg, 1_120).is_ok());
        assert!(pending.validate_review(&cfg, 1_121).is_err());
        assert!(pending.validate_review(&cfg, 999).is_err());
        cfg.network = Network::TestNetwork;
        assert!(pending.validate_review(&cfg, 1_001).is_err());
        cfg.network = Network::MainNetwork;
        cfg.server_url = "https://other.example:443".into();
        assert!(pending.validate_review(&cfg, 1_001).is_err());
    }

    #[test]
    fn edits_to_priority_recipient_or_memo_invalidate_the_saved_review() {
        let fixture = Fixture::new();
        let cfg = fixture.config();
        let pending = reviewed(&cfg);
        let mut changed = pending.clone();
        changed.review.as_mut().unwrap().priority = false;
        assert!(changed.validate_review(&cfg, 1_001).is_err());
        changed = pending.clone();
        changed.address = "replacement-recipient".into();
        assert!(changed.validate_review(&cfg, 1_001).is_err());
        changed = pending.clone();
        changed.memo = Some("replacement memo".into());
        assert!(changed.validate_review(&cfg, 1_001).is_err());
        changed = pending.clone();
        changed.review = None;
        assert!(changed.validate_review(&cfg, 1_001).is_err());
    }
}

// ---------------------------------------------------------------------------
// Auto-open: detect wallet in data dir and open it
// ---------------------------------------------------------------------------

pub async fn auto_open(cfg: &Config) -> Result<()> {
    let db_path = PathBuf::from(&cfg.data_dir).join("zipher-data.sqlite");
    if !db_path.exists() {
        return Err(anyhow::anyhow!(
            "No wallet found in {}. Run `zipher-cli wallet init` first.",
            cfg.data_dir
        ));
    }
    zipher_engine::wallet::open(&cfg.data_dir, &cfg.server_url, cfg.network, None).await
}

// ---------------------------------------------------------------------------
// Sync helpers
// ---------------------------------------------------------------------------

pub async fn force_sync(cfg: &Config) -> Result<()> {
    auto_open(cfg).await?;

    let synced = zipher_engine::query::get_synced_height().await.unwrap_or(0);
    let latest = zipher_engine::wallet::fetch_latest_height(&cfg.server_url)
        .await
        .unwrap_or(synced as u64) as u32;

    let blocks_behind = if latest > synced { latest - synced } else { 0 };

    if blocks_behind == 0 {
        return Ok(());
    }

    eprintln!("Syncing wallet ({} blocks behind)...", blocks_behind);
    zipher_engine::sync::start().await?;

    loop {
        tokio::time::sleep(std::time::Duration::from_secs(2)).await;
        let p = zipher_engine::sync::get_progress().await;

        if p.synced_height > 0 && p.synced_height >= p.latest_height {
            eprintln!("Synced to {}.", p.synced_height);
            break;
        }
        if !p.is_syncing && !zipher_engine::sync::is_running() {
            eprintln!("Sync finished at {}.", p.synced_height);
            break;
        }
    }

    zipher_engine::sync::stop().await;
    zipher_engine::wallet::close().await;
    auto_open(cfg).await?;
    Ok(())
}

const STALE_BLOCK_THRESHOLD: u32 = 10;

pub async fn sync_if_needed(cfg: &Config) -> Result<()> {
    auto_open(cfg).await?;

    let synced = zipher_engine::query::get_synced_height().await.unwrap_or(0);
    let latest = zipher_engine::wallet::fetch_latest_height(&cfg.server_url)
        .await
        .unwrap_or(synced as u64) as u32;

    let blocks_behind = if latest > synced { latest - synced } else { 0 };

    let has_unconfirmed = if blocks_behind <= STALE_BLOCK_THRESHOLD {
        let bal = zipher_engine::query::get_wallet_balance().await.ok();
        bal.map(|b| {
            b.unconfirmed_sapling > 0
                || b.unconfirmed_orchard > 0
                || b.unconfirmed_transparent > 0
                || (b.total_orchard > b.orchard)
                || (b.total_sapling > b.sapling)
                || (b.total_transparent > b.transparent)
        })
        .unwrap_or(false)
    } else {
        false
    };

    let needs_sync =
        blocks_behind > STALE_BLOCK_THRESHOLD || (blocks_behind > 0 && has_unconfirmed);

    if !needs_sync {
        // Wallet DB is already at (or near) the chain tip, but the in-memory
        // `SYNC_PROGRESS` hasn't been populated this process. Seed it so that
        // `ensure_synced` (used by spend paths) doesn't fail with "synced: 0".
        zipher_engine::sync::set_progress(synced, latest).await;
    }

    if needs_sync {
        if has_unconfirmed {
            eprintln!("Unconfirmed outputs detected. Syncing to pick up confirmations...");
        } else {
            eprintln!(
                "Wallet is {} blocks behind (at {}, tip {}). Syncing...",
                blocks_behind, synced, latest
            );
        }

        zipher_engine::sync::start().await?;

        loop {
            tokio::time::sleep(std::time::Duration::from_secs(2)).await;
            let p = zipher_engine::sync::get_progress().await;

            if p.synced_height > 0 && p.synced_height >= p.latest_height {
                eprintln!("Synced to {}.", p.synced_height);
                break;
            }
            if !p.is_syncing && !zipher_engine::sync::is_running() {
                eprintln!("Sync finished at {}.", p.synced_height);
                break;
            }
        }

        zipher_engine::sync::stop().await;
        zipher_engine::wallet::close().await;
        auto_open(cfg).await?;
    }

    Ok(())
}

#[cfg(test)]
mod credential_security_tests {
    use super::*;
    use std::sync::atomic::{AtomicU64, Ordering};

    const TEST_SEED: &str = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
    static NEXT_FIXTURE: AtomicU64 = AtomicU64::new(0);

    fn unused_dir() -> std::path::PathBuf {
        std::env::temp_dir().join(format!(
            "zipher-cli-credential-test-{}-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos(),
            NEXT_FIXTURE.fetch_add(1, Ordering::Relaxed),
        ))
    }

    #[test]
    fn missing_and_blank_credentials_do_not_touch_storage_or_export() {
        let dir = unused_dir();
        for value in [None, Some(String::new()), Some(" \t\n".into())] {
            let result = read_seed_with(dir.to_str().unwrap(), value, |_| {
                panic!("must not inspect a vault without a usable credential")
            });
            assert!(result.is_err());
            assert!(!dir.exists());
        }
    }

    #[test]
    fn nonempty_credential_is_not_trimmed_or_changed() {
        let dir = unused_dir();
        let seed = read_seed_with(
            dir.to_str().unwrap(),
            Some(" test-only credential ".into()),
            |pass| {
                assert_eq!(pass, " test-only credential ");
                Ok(TEST_SEED.into())
            },
        )
        .unwrap();
        assert_eq!(seed.expose_secret(), TEST_SEED);
        assert!(!dir.exists());
    }

    #[test]
    fn legacy_seed_is_retained_without_reading_or_exporting() {
        let dir = unused_dir();
        std::fs::create_dir(&dir).unwrap();
        let file = dir.join(".seed");
        std::fs::write(&file, TEST_SEED).unwrap();
        let result = read_seed_with(
            dir.to_str().unwrap(),
            Some("test-only credential".into()),
            |_| panic!("legacy plaintext must never fall back to or unlock another seed"),
        );
        assert!(result
            .unwrap_err()
            .to_string()
            .contains("will not read, delete or migrate"));
        assert_eq!(std::fs::read_to_string(file).unwrap(), TEST_SEED);
        assert_eq!(std::fs::read_dir(&dir).unwrap().count(), 1);
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn restore_seed_input_is_bounded_private_and_not_in_argv() {
        assert!(read_seed_input(TEST_SEED.as_bytes(), true).is_err());
        assert!(read_seed_input(&b""[..], false).is_err());
        assert!(read_seed_input(&[0xff, 0xfe][..], false).is_err());
        assert!(read_seed_input(&vec![b'a'; 1025][..], false).is_err());
        let wrapped = TEST_SEED.replace(' ', "\n");
        assert_eq!(
            read_seed_input(wrapped.as_bytes(), false)
                .unwrap()
                .expose_secret(),
            TEST_SEED
        );
        assert!(unsafe_seed_argument(std::ffi::OsStr::new("--seed")));
        assert!(unsafe_seed_argument(std::ffi::OsStr::new(
            "--seed=test-only-value"
        )));
        assert!(!unsafe_seed_argument(std::ffi::OsStr::new("--seed-stdin")));
    }

    #[test]
    fn backup_requires_explicit_human_terminal_opt_in() {
        for options in [
            (false, true, true, true),
            (true, false, true, true),
            (true, true, false, true),
            (true, true, true, false),
        ] {
            assert!(validate_recovery_display(options.0, options.1, options.2, options.3).is_err());
        }
        assert!(validate_recovery_display(true, true, true, true).is_ok());
    }
}
