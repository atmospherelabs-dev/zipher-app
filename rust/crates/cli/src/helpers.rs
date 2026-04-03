use std::io::{self, BufRead, Write as _};
use std::path::PathBuf;

use anyhow::Result;
use secrecy::SecretString;
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
// Seed reading: Zipher vault -> OWS vault -> ZIPHER_SEED env -> stdin
// ---------------------------------------------------------------------------

pub fn vault_passphrase() -> String {
    std::env::var("ZIPHER_VAULT_PASS").unwrap_or_default()
}

pub fn read_seed_from_vault(data_dir: &str) -> Option<SecretString> {
    if !zipher_engine::vault::Vault::exists(data_dir) {
        return None;
    }
    let passphrase = vault_passphrase();
    match zipher_engine::wallet::decrypt_vault(data_dir, &passphrase) {
        Ok(seed) => Some(seed),
        Err(e) => {
            eprintln!("Vault exists but decryption failed: {}", e);
            None
        }
    }
}

/// Read the seed directly from OWS's vault (`~/.ows/wallets/`).
/// Calls `ows_lib::export_wallet` — no subprocess, no pipe, pure Rust.
fn read_seed_from_ows() -> Option<SecretString> {
    let ows_wallet = std::env::var("OWS_WALLET").unwrap_or_else(|_| "default".to_string());
    let passphrase = std::env::var("OWS_PASSPHRASE").unwrap_or_default();

    let exported = ows_lib::export_wallet(&ows_wallet, Some(&passphrase), None).ok()?;

    // export_wallet returns either a mnemonic (space-separated words) or a JSON key pair.
    // We only want mnemonics — key pairs can't derive Zcash keys via ZIP-32.
    if exported.contains(' ') && !exported.starts_with('{') {
        Some(SecretString::new(exported))
    } else {
        None
    }
}

pub fn read_seed(data_dir: &str) -> Result<SecretString> {
    // 1. Zipher's own vault
    if let Some(seed) = read_seed_from_vault(data_dir) {
        return Ok(seed);
    }

    // 2. OWS vault (same mnemonic, shared wallet)
    if let Some(seed) = read_seed_from_ows() {
        return Ok(seed);
    }

    // 3. Explicit env var
    if let Ok(seed) = std::env::var("ZIPHER_SEED") {
        if !seed.is_empty() {
            return Ok(SecretString::new(seed));
        }
    }

    // 4. Interactive prompt
    eprint!("Enter seed phrase: ");
    io::stderr().flush()?;
    let mut line = String::new();
    io::stdin().lock().read_line(&mut line)?;
    let trimmed = line.trim().to_string();
    if trimmed.is_empty() {
        return Err(anyhow::anyhow!(
            "No seed available. Create a wallet with `ows wallet create`, set ZIPHER_SEED, or pipe via stdin."
        ));
    }
    Ok(SecretString::new(trimmed))
}

// ---------------------------------------------------------------------------
// Pending proposal persistence
// ---------------------------------------------------------------------------

#[derive(Serialize, serde::Deserialize)]
pub struct PendingProposal {
    pub address: String,
    pub amount: u64,
    pub memo: Option<String>,
    pub is_max: bool,
    pub context_id: Option<String>,
}

fn pending_path(data_dir: &str) -> PathBuf {
    PathBuf::from(data_dir).join("pending_proposal.json")
}

pub fn save_pending(data_dir: &str, proposal: &PendingProposal) -> Result<()> {
    let path = pending_path(data_dir);
    let json = serde_json::to_string_pretty(proposal)?;
    std::fs::write(&path, json)?;
    Ok(())
}

pub fn load_pending(data_dir: &str) -> Result<PendingProposal> {
    let path = pending_path(data_dir);
    if !path.exists() {
        return Err(anyhow::anyhow!(
            "No pending proposal. Run `zipher-cli send propose` first."
        ));
    }
    let json = std::fs::read_to_string(&path)?;
    let proposal: PendingProposal = serde_json::from_str(&json)?;
    Ok(proposal)
}

pub fn delete_pending(data_dir: &str) {
    let path = pending_path(data_dir);
    std::fs::remove_file(path).ok();
}

// ---------------------------------------------------------------------------
// Auto-open: detect wallet in data dir and open it
// ---------------------------------------------------------------------------

pub async fn auto_open(cfg: &Config) -> Result<()> {
    let db_path = PathBuf::from(&cfg.data_dir).join("zipher-data.sqlite");
    if !db_path.exists() {
        return Err(anyhow::anyhow!(
            "No wallet found in {}. Run `zipher-cli wallet create` or `wallet restore` first.",
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

    let needs_sync = blocks_behind > STALE_BLOCK_THRESHOLD || (blocks_behind > 0 && has_unconfirmed);

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
