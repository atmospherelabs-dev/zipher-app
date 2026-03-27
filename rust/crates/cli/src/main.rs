use std::io::{self, BufRead, Read as _, Write as _};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use anyhow::Result;
use clap::{Parser, Subcommand};
use secrecy::SecretString;
use serde::Serialize;
use zcash_protocol::consensus::Network;

// ---------------------------------------------------------------------------
// CLI definition
// ---------------------------------------------------------------------------

#[derive(Parser)]
#[command(
    name = "zipher-cli",
    about = "Headless Zcash light wallet for AI agents",
    version
)]
struct Cli {
    /// Wallet data directory
    #[arg(long, global = true)]
    data_dir: Option<String>,

    /// Use Zcash testnet
    #[arg(long, global = true)]
    testnet: bool,

    /// Override lightwalletd server URL
    #[arg(long, global = true)]
    server: Option<String>,

    /// Human-readable output instead of JSON
    #[arg(long, global = true)]
    human: bool,

    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    /// Print version and build info
    Info,

    /// Wallet lifecycle
    #[command(subcommand)]
    Wallet(WalletCmd),

    /// Sync with the Zcash network
    #[command(subcommand)]
    Sync(SyncCmd),

    /// Show wallet balance
    Balance,

    /// Show wallet addresses
    Address,

    /// Export viewing keys (UFVK, UIVK)
    Keys,

    /// Show transaction history
    Transactions {
        /// Maximum number of transactions to show
        #[arg(long, default_value = "20")]
        limit: usize,
    },

    /// Send ZEC (two-step: propose then confirm)
    #[command(subcommand)]
    Send(SendCmd),

    /// Shield transparent funds into the shielded pool
    Shield,

    /// Spending policy management
    #[command(subcommand)]
    Policy(PolicyCmd),

    /// View the audit log
    Audit {
        /// Maximum number of entries
        #[arg(long, default_value = "50")]
        limit: usize,

        /// Only show entries since this ISO 8601 timestamp
        #[arg(long)]
        since: Option<String>,
    },

    /// Daemon mode (long-running background process)
    #[command(subcommand)]
    Daemon(DaemonCmd),

    /// Pay an HTTP 402 paywall (x402 protocol)
    #[command(subcommand)]
    X402(X402Cmd),

    /// Pay any 402 paywall by URL (auto-detects x402 or MPP protocol)
    Pay {
        /// The URL to pay for
        url: String,

        /// Context identifier for audit trail
        #[arg(long)]
        context_id: Option<String>,

        /// HTTP method to use (default: GET)
        #[arg(long, default_value = "GET")]
        method: String,
    },

    /// Cross-chain swaps via Near Intents
    #[command(subcommand)]
    Swap(SwapCmd),

    /// Session-based payments (prepaid credit via CipherPay)
    #[command(subcommand)]
    Session(SessionCmd),
}

#[derive(Subcommand)]
enum SwapCmd {
    /// List available swap tokens
    Tokens,

    /// Get a swap quote (ZEC to another asset)
    Quote {
        /// Destination asset symbol (e.g., USDC, ETH, BTC)
        #[arg(long)]
        to: String,

        /// Destination blockchain (e.g., eth, sol, arb). Auto-detected if unambiguous.
        #[arg(long)]
        chain: Option<String>,

        /// Amount in zatoshis to swap
        #[arg(long)]
        amount: u64,

        /// Recipient address on the destination chain
        #[arg(long)]
        recipient: String,

        /// Slippage tolerance in basis points (default: 100 = 1%)
        #[arg(long, default_value = "100")]
        slippage: u32,
    },

    /// Execute a swap (get quote + send ZEC to deposit address)
    Execute {
        /// Destination asset symbol (e.g., USDC, ETH, BTC)
        #[arg(long)]
        to: String,

        /// Destination blockchain (e.g., eth, sol, arb)
        #[arg(long)]
        chain: Option<String>,

        /// Amount in zatoshis to swap
        #[arg(long)]
        amount: u64,

        /// Recipient address on the destination chain
        #[arg(long)]
        recipient: String,

        /// Slippage tolerance in basis points (default: 100 = 1%)
        #[arg(long, default_value = "100")]
        slippage: u32,

        /// Context identifier for audit trail
        #[arg(long)]
        context_id: Option<String>,
    },

    /// Check swap status by deposit address
    Status {
        /// The deposit address from the swap quote
        #[arg(long)]
        deposit_address: String,
    },
}

#[derive(Subcommand)]
enum SessionCmd {
    /// Open a new session (pay once, get bearer token for many requests)
    Open {
        /// Server URL to create a session for
        #[arg(long)]
        server_url: String,

        /// Amount in zatoshis to deposit as credit
        #[arg(long)]
        deposit: u64,

        /// Merchant ID on CipherPay
        #[arg(long)]
        merchant_id: String,

        /// Merchant's Zcash payment address
        #[arg(long)]
        pay_to: String,

        /// Context identifier for audit trail
        #[arg(long)]
        context_id: Option<String>,
    },

    /// Make a request using an active session
    Request {
        /// URL to request
        url: String,

        /// HTTP method (default: GET)
        #[arg(long, default_value = "GET")]
        method: String,
    },

    /// List active sessions
    List,

    /// Close a session
    Close {
        /// Session ID to close
        #[arg(long)]
        session_id: String,
    },
}

#[derive(Subcommand)]
enum WalletCmd {
    /// Create a new wallet
    Create,

    /// Restore wallet from seed phrase (read from stdin or ZIPHER_SEED)
    Restore {
        /// Birthday height for faster sync
        #[arg(long)]
        birthday: u32,
    },

    /// Delete wallet data from disk
    Delete {
        /// Required flag to confirm deletion
        #[arg(long)]
        confirm: bool,
    },
}

#[derive(Subcommand)]
enum SyncCmd {
    /// Start syncing (blocks until fully synced, Ctrl+C to stop)
    Start,

    /// Show current sync progress
    Status,
}

#[derive(Subcommand)]
enum SendCmd {
    /// Create a send proposal (no seed required)
    Propose {
        /// Destination address
        #[arg(long)]
        to: String,

        /// Amount in zatoshis
        #[arg(long)]
        amount: u64,

        /// Optional memo (shielded only)
        #[arg(long)]
        memo: Option<String>,

        /// Context identifier for audit trail
        #[arg(long)]
        context_id: Option<String>,
    },

    /// Sign and broadcast a pending proposal (requires seed)
    Confirm,

    /// Show maximum sendable amount to an address
    Max {
        /// Destination address
        #[arg(long)]
        to: String,
    },
}

#[derive(Subcommand)]
enum PolicyCmd {
    /// Display the current spending policy
    Show,

    /// Set a policy field (e.g., max_per_tx, daily_limit, min_spend_interval_ms, approval_threshold, require_context_id)
    Set {
        /// Field name
        #[arg(long)]
        field: String,

        /// Field value
        #[arg(long)]
        value: String,
    },

    /// Add an address to the allowlist
    AddAllowlist {
        /// Address to allow
        #[arg(long)]
        address: String,
    },

    /// Remove an address from the allowlist
    RemoveAllowlist {
        /// Address to remove
        #[arg(long)]
        address: String,
    },
}

#[derive(Subcommand)]
enum DaemonCmd {
    /// Start the daemon (foreground process with sync loop + IPC socket)
    Start,

    /// Check if the daemon is running
    Status,

    /// Ask the daemon to stop
    Stop,

    /// Zeroize seed material in memory (wallet becomes read-only, sync continues)
    Lock,

    /// Unlock spending (daemon reads ZIPHER_SEED from its own environment)
    Unlock,
}

#[derive(Subcommand)]
enum X402Cmd {
    /// Parse a 402 response and create a send proposal (no seed required)
    Propose {
        /// The HTTP 402 response body JSON (reads from stdin if omitted)
        #[arg(long)]
        body: Option<String>,

        /// Context identifier for audit trail
        #[arg(long)]
        context_id: Option<String>,
    },

    /// Parse a 402 response, pay, and return the PAYMENT-SIGNATURE header (requires seed)
    Pay {
        /// The HTTP 402 response body JSON (reads from stdin if omitted)
        #[arg(long)]
        body: Option<String>,

        /// Context identifier for audit trail
        #[arg(long)]
        context_id: Option<String>,
    },
}

// ---------------------------------------------------------------------------
// JSON output helpers
// ---------------------------------------------------------------------------

#[derive(Serialize)]
struct CliOutput<T: Serialize> {
    ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    data: Option<T>,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<String>,
}

fn print_ok<T: Serialize>(data: T, human: bool, human_fmt: impl FnOnce(&T)) {
    if human {
        human_fmt(&data);
    } else {
        let output = CliOutput { ok: true, data: Some(data), error: None };
        println!("{}", serde_json::to_string_pretty(&output).unwrap());
    }
}

fn print_err(e: &anyhow::Error, human: bool) {
    if human {
        eprintln!("Error: {:#}", e);
    } else {
        let output: CliOutput<()> = CliOutput {
            ok: false,
            data: None,
            error: Some(format!("{:#}", e)),
        };
        println!("{}", serde_json::to_string_pretty(&output).unwrap());
    }
}

// ---------------------------------------------------------------------------
// Config resolution
// ---------------------------------------------------------------------------

const DEFAULT_MAINNET_SERVER: &str = "https://lightwalletd.mainnet.cipherscan.app:443";
const DEFAULT_TESTNET_SERVER: &str = "https://lightwalletd.testnet.cipherscan.app:443";

struct Config {
    data_dir: String,
    server_url: String,
    network: Network,
    human: bool,
}

fn resolve_config(cli: &Cli) -> Config {
    let network = if cli.testnet { Network::TestNetwork } else { Network::MainNetwork };

    let default_server = if cli.testnet { DEFAULT_TESTNET_SERVER } else { DEFAULT_MAINNET_SERVER };
    let server_url = cli.server.clone().unwrap_or_else(|| default_server.to_string());

    let net_suffix = if cli.testnet { "testnet" } else { "mainnet" };
    let data_dir = cli.data_dir.clone().unwrap_or_else(|| {
        let home = dirs::home_dir().expect("Cannot determine home directory");
        home.join(".zipher").join(net_suffix).to_string_lossy().to_string()
    });

    Config { data_dir, server_url, network, human: cli.human }
}

fn ensure_data_dir(data_dir: &str) -> Result<()> {
    std::fs::create_dir_all(data_dir)?;
    Ok(())
}

// ---------------------------------------------------------------------------
// Sapling parameter auto-download
// ---------------------------------------------------------------------------

const SAPLING_SPEND_URL: &str = "https://download.z.cash/downloads/sapling-spend.params";
const SAPLING_OUTPUT_URL: &str = "https://download.z.cash/downloads/sapling-output.params";
const SAPLING_SPEND_SHA256: &str =
    "8e48ffd23abb3a5fd9c5589204f32d9c31285a04b78096ba40a79b75677efc13";
const SAPLING_OUTPUT_SHA256: &str =
    "2f0ebbcbb9bb0bcffe95a397e7eba89c29eb4dde6191c339db88570e3f3fb0e4";

async fn ensure_sapling_params(data_dir: &str) -> Result<()> {
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
// Seed reading (env var first, then stdin)
// ---------------------------------------------------------------------------

fn read_seed() -> Result<SecretString> {
    if let Ok(seed) = std::env::var("ZIPHER_SEED") {
        if !seed.is_empty() {
            return Ok(SecretString::new(seed));
        }
    }

    eprint!("Enter seed phrase: ");
    io::stderr().flush()?;
    let mut line = String::new();
    io::stdin().lock().read_line(&mut line)?;
    let trimmed = line.trim().to_string();
    if trimmed.is_empty() {
        return Err(anyhow::anyhow!("No seed phrase provided. Set ZIPHER_SEED or pipe via stdin."));
    }
    Ok(SecretString::new(trimmed))
}

// ---------------------------------------------------------------------------
// Pending proposal persistence
// ---------------------------------------------------------------------------

#[derive(Serialize, serde::Deserialize)]
struct PendingProposal {
    address: String,
    amount: u64,
    memo: Option<String>,
    is_max: bool,
    context_id: Option<String>,
}

fn pending_path(data_dir: &str) -> PathBuf {
    PathBuf::from(data_dir).join("pending_proposal.json")
}

fn save_pending(data_dir: &str, proposal: &PendingProposal) -> Result<()> {
    let path = pending_path(data_dir);
    let json = serde_json::to_string_pretty(proposal)?;
    std::fs::write(&path, json)?;
    Ok(())
}

fn load_pending(data_dir: &str) -> Result<PendingProposal> {
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

fn delete_pending(data_dir: &str) {
    let path = pending_path(data_dir);
    std::fs::remove_file(path).ok();
}

// ---------------------------------------------------------------------------
// Auto-open: detect wallet in data dir and open it
// ---------------------------------------------------------------------------

async fn auto_open(cfg: &Config) -> Result<()> {
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
// Auto-sync if wallet is stale
// ---------------------------------------------------------------------------

const STALE_BLOCK_THRESHOLD: u32 = 10;

async fn sync_if_needed(cfg: &Config) -> Result<()> {
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

// ---------------------------------------------------------------------------
// Command handlers
// ---------------------------------------------------------------------------

async fn cmd_info(cfg: &Config) {
    #[derive(Serialize)]
    struct InfoData {
        version: String,
        engine: String,
        network: String,
        data_dir: String,
        server: String,
    }

    let data = InfoData {
        version: env!("CARGO_PKG_VERSION").to_string(),
        engine: "zipher-engine".to_string(),
        network: if cfg.network == Network::TestNetwork { "testnet" } else { "mainnet" }.to_string(),
        data_dir: cfg.data_dir.clone(),
        server: cfg.server_url.clone(),
    };

    print_ok(data, cfg.human, |d| {
        println!("zipher-cli {}", d.version);
        println!("engine:  {}", d.engine);
        println!("network: {}", d.network);
        println!("data:    {}", d.data_dir);
        println!("server:  {}", d.server);
    });
}

async fn cmd_wallet_create(cfg: &Config) -> Result<()> {
    ensure_data_dir(&cfg.data_dir)?;
    ensure_sapling_params(&cfg.data_dir).await?;

    let height = zipher_engine::wallet::fetch_latest_height(&cfg.server_url).await? as u32;
    let seed_phrase = zipher_engine::wallet::create(
        &cfg.data_dir,
        &cfg.server_url,
        cfg.network,
        height,
        None,
    )
    .await?;

    #[derive(Serialize)]
    struct CreateResult {
        seed_phrase: String,
        birthday: u32,
        data_dir: String,
    }

    let result = CreateResult {
        seed_phrase: seed_phrase.clone(),
        birthday: height,
        data_dir: cfg.data_dir.clone(),
    };

    print_ok(result, cfg.human, |r| {
        println!("Wallet created.");
        println!();
        println!("  SEED PHRASE (write this down, store it safely):");
        println!("  {}", r.seed_phrase);
        println!();
        println!("  Birthday: {}", r.birthday);
        println!("  Data dir: {}", r.data_dir);
        println!();
        println!("  WARNING: This seed phrase is the ONLY way to recover your wallet.");
        println!("  It will NOT be shown again.");
    });
    Ok(())
}

async fn cmd_wallet_restore(cfg: &Config, birthday: u32) -> Result<()> {
    ensure_data_dir(&cfg.data_dir)?;
    ensure_sapling_params(&cfg.data_dir).await?;

    let seed = read_seed()?;
    use secrecy::ExposeSecret;
    zipher_engine::wallet::restore(
        &cfg.data_dir,
        &cfg.server_url,
        cfg.network,
        seed.expose_secret(),
        birthday,
        None,
    )
    .await?;

    #[derive(Serialize)]
    struct RestoreResult {
        birthday: u32,
        data_dir: String,
    }

    print_ok(
        RestoreResult { birthday, data_dir: cfg.data_dir.clone() },
        cfg.human,
        |r| {
            println!("Wallet restored.");
            println!("  Birthday: {}", r.birthday);
            println!("  Data dir: {}", r.data_dir);
            println!("  Run `zipher-cli sync start` to scan the blockchain.");
        },
    );
    Ok(())
}

async fn cmd_wallet_delete(cfg: &Config, confirm: bool) -> Result<()> {
    if !confirm {
        return Err(anyhow::anyhow!(
            "Pass --confirm to delete wallet data. This action is irreversible."
        ));
    }

    zipher_engine::wallet::delete(&cfg.data_dir)?;

    print_ok("deleted", cfg.human, |_| {
        println!("Wallet data deleted from {}", cfg.data_dir);
    });
    Ok(())
}

async fn cmd_sync_start(cfg: &Config) -> Result<()> {
    auto_open(cfg).await?;
    zipher_engine::sync::start().await?;

    let cancel = Arc::new(AtomicBool::new(false));
    let cancel_clone = cancel.clone();
    ctrlc::set_handler(move || {
        cancel_clone.store(true, Ordering::SeqCst);
    })
    .ok();

    if cfg.human {
        eprintln!("Syncing... (Ctrl+C to stop)");
    }

    loop {
        tokio::time::sleep(std::time::Duration::from_secs(2)).await;

        let p = zipher_engine::sync::get_progress().await;

        if cfg.human {
            if let Some(ref err) = p.connection_error {
                eprintln!("  Connection error: {} (retrying...)", err);
            } else if p.latest_height > 0 {
                let pct = if p.latest_height > 0 {
                    (p.synced_height as f64 / p.latest_height as f64 * 100.0).min(100.0)
                } else {
                    0.0
                };
                eprint!("\r  {}/{} ({:.1}%)    ", p.synced_height, p.latest_height, pct);
                io::stderr().flush().ok();
            }
        }

        if cancel.load(Ordering::SeqCst) {
            zipher_engine::sync::stop().await;
            if cfg.human {
                eprintln!("\nSync stopped by user.");
            }
            break;
        }

        if !p.is_syncing && p.synced_height > 0 && p.synced_height >= p.latest_height {
            if cfg.human {
                eprintln!("\nFully synced at height {}.", p.synced_height);
            }
            break;
        }

        if !p.is_syncing && !zipher_engine::sync::is_running() {
            if cfg.human {
                eprintln!("\nSync finished.");
            }
            break;
        }
    }

    let final_progress = zipher_engine::sync::get_progress().await;
    if !cfg.human {
        print_ok(final_progress, false, |_| {});
    }

    zipher_engine::wallet::close().await;
    Ok(())
}

async fn cmd_sync_status(cfg: &Config) -> Result<()> {
    auto_open(cfg).await?;

    let synced = zipher_engine::query::get_synced_height().await?;
    let birthday = zipher_engine::query::get_birthday().await?;

    #[derive(Serialize)]
    struct SyncStatus {
        synced_height: u32,
        birthday: u32,
    }

    let status = SyncStatus { synced_height: synced, birthday };

    print_ok(status, cfg.human, |s| {
        println!("Synced height: {}", s.synced_height);
        println!("Birthday:      {}", s.birthday);
    });

    zipher_engine::wallet::close().await;
    Ok(())
}

async fn cmd_balance(cfg: &Config) -> Result<()> {
    sync_if_needed(cfg).await?;
    let balance = zipher_engine::query::get_wallet_balance().await?;

    print_ok(&balance, cfg.human, |b| {
        let total = b.sapling + b.orchard + b.transparent;
        let total_zec = total as f64 / 1e8;
        println!("Balance: {:.8} ZEC ({} zat)", total_zec, total);
        println!();
        println!("  Shielded (Orchard):  {} zat", b.orchard);
        println!("  Shielded (Sapling):  {} zat", b.sapling);
        println!("  Transparent:         {} zat", b.transparent);
        let pending = b.unconfirmed_sapling + b.unconfirmed_orchard + b.unconfirmed_transparent;
        if pending > 0 {
            println!();
            println!("  Pending:             {} zat", pending);
        }
    });

    zipher_engine::wallet::close().await;
    Ok(())
}

async fn cmd_address(cfg: &Config) -> Result<()> {
    sync_if_needed(cfg).await?;
    let addresses = zipher_engine::query::get_addresses().await?;

    print_ok(&addresses, cfg.human, |addrs| {
        if addrs.is_empty() {
            println!("No addresses found.");
        } else {
            for a in addrs.iter() {
                println!("{}", a.address);
                let pools: Vec<&str> = [
                    if a.has_orchard { Some("orchard") } else { None },
                    if a.has_sapling { Some("sapling") } else { None },
                    if a.has_transparent { Some("transparent") } else { None },
                ]
                .iter()
                .filter_map(|p| *p)
                .collect();
                println!("  pools: {}", pools.join(", "));
            }
        }
    });

    zipher_engine::wallet::close().await;
    Ok(())
}

async fn cmd_keys(cfg: &Config) -> Result<()> {
    auto_open(cfg).await?;

    let ufvk = zipher_engine::query::export_ufvk().await?;
    let uivk = zipher_engine::query::export_uivk().await?;

    #[derive(Serialize)]
    struct KeysData {
        ufvk: Option<String>,
        uivk: Option<String>,
    }

    let data = KeysData {
        ufvk: ufvk.clone(),
        uivk: uivk.clone(),
    };

    print_ok(data, cfg.human, |d| {
        if let Some(ref k) = d.ufvk {
            println!("UFVK (Unified Full Viewing Key):");
            println!("  {}", k);
            println!();
        }
        if let Some(ref k) = d.uivk {
            println!("UIVK (Unified Incoming Viewing Key):");
            println!("  {}", k);
            println!();
            println!("Use the UIVK to register with CipherPay for payment detection.");
        }
        if d.ufvk.is_none() && d.uivk.is_none() {
            println!("No viewing keys found. Create a wallet first.");
        }
    });

    zipher_engine::wallet::close().await;
    Ok(())
}

async fn cmd_transactions(cfg: &Config, limit: usize) -> Result<()> {
    auto_open(cfg).await?;
    let mut txs = zipher_engine::query::get_transactions().await?;
    txs.truncate(limit);

    print_ok(&txs, cfg.human, |txs| {
        if txs.is_empty() {
            println!("No transactions.");
        } else {
            for tx in txs.iter() {
                let zec = tx.value as f64 / 1e8;
                let sign = if tx.value >= 0 { "+" } else { "" };
                println!(
                    "  {} {}{:.8} ZEC  h={}  {}",
                    &tx.txid[..12],
                    sign,
                    zec,
                    tx.height,
                    tx.kind,
                );
                if let Some(ref memo) = tx.memo {
                    println!("    memo: {}", memo);
                }
            }
        }
    });

    zipher_engine::wallet::close().await;
    Ok(())
}

async fn cmd_send_propose(
    cfg: &Config,
    to: String,
    amount: u64,
    memo: Option<String>,
    context_id: Option<String>,
) -> Result<()> {
    sync_if_needed(cfg).await?;
    let policy = zipher_engine::policy::load_policy(&cfg.data_dir);

    let daily_spent = zipher_engine::audit::daily_spent(&cfg.data_dir).unwrap_or(0);
    if let Err(violation) = zipher_engine::policy::check_proposal(
        &policy, &to, amount, &context_id, daily_spent,
    ) {
        zipher_engine::audit::log_event(
            &cfg.data_dir, "propose_send", Some(&to),
            Some(amount), None, context_id.as_deref(),
            None, Some(&violation.to_string()),
        ).ok();
        return Err(anyhow::anyhow!("{}", violation));
    }

    auto_open(cfg).await?;

    let (send_amount, fee, _) = zipher_engine::send::propose_send(&to, amount, memo.clone(), false).await?;

    let pending = PendingProposal {
        address: to.clone(),
        amount,
        memo: memo.clone(),
        is_max: false,
        context_id: context_id.clone(),
    };
    save_pending(&cfg.data_dir, &pending)?;

    zipher_engine::audit::log_event(
        &cfg.data_dir, "propose_send", Some(&to),
        Some(send_amount), Some(fee), context_id.as_deref(),
        None, None,
    ).ok();

    #[derive(Serialize)]
    struct ProposalSummary {
        address: String,
        send_amount: u64,
        fee: u64,
        total: u64,
        send_amount_zec: f64,
        fee_zec: f64,
    }

    let summary = ProposalSummary {
        address: to.clone(),
        send_amount,
        fee,
        total: send_amount + fee,
        send_amount_zec: send_amount as f64 / 1e8,
        fee_zec: fee as f64 / 1e8,
    };

    print_ok(summary, cfg.human, |s| {
        println!("Proposal created:");
        println!("  To:     {}", s.address);
        println!("  Amount: {:.8} ZEC ({} zat)", s.send_amount_zec, s.send_amount);
        println!("  Fee:    {:.8} ZEC ({} zat)", s.fee_zec, s.fee);
        println!("  Total:  {} zat", s.total);
        println!();
        println!("Run `zipher-cli send confirm` to sign and broadcast.");
    });

    zipher_engine::wallet::close().await;
    Ok(())
}

async fn cmd_send_confirm(cfg: &Config) -> Result<()> {
    ensure_sapling_params(&cfg.data_dir).await?;
    let pending = load_pending(&cfg.data_dir)?;

    let policy = zipher_engine::policy::load_policy(&cfg.data_dir);
    if let Err(violation) = zipher_engine::policy::check_rate_limit(&policy) {
        zipher_engine::audit::log_event(
            &cfg.data_dir, "confirm_send", Some(&pending.address),
            Some(pending.amount), None, pending.context_id.as_deref(),
            None, Some(&violation.to_string()),
        ).ok();
        return Err(anyhow::anyhow!("{}", violation));
    }

    auto_open(cfg).await?;

    let (send_amount, fee, _) = zipher_engine::send::propose_send(
        &pending.address,
        pending.amount,
        pending.memo.clone(),
        pending.is_max,
    )
    .await?;

    if cfg.human {
        let zec = send_amount as f64 / 1e8;
        let fee_zec = fee as f64 / 1e8;
        eprintln!("Confirming: {:.8} ZEC + {:.8} fee to {}", zec, fee_zec, pending.address);
    }

    let seed = read_seed()?;
    let txid = match zipher_engine::send::confirm_send(&seed).await {
        Ok(txid) => {
            zipher_engine::policy::record_confirm();
            zipher_engine::audit::log_event(
                &cfg.data_dir, "confirm_send", Some(&pending.address),
                Some(send_amount), Some(fee), pending.context_id.as_deref(),
                Some(&txid), None,
            ).ok();
            txid
        }
        Err(e) => {
            zipher_engine::audit::log_event(
                &cfg.data_dir, "confirm_send", Some(&pending.address),
                Some(send_amount), Some(fee), pending.context_id.as_deref(),
                None, Some(&format!("{:#}", e)),
            ).ok();
            return Err(e);
        }
    };

    delete_pending(&cfg.data_dir);

    #[derive(Serialize)]
    struct SendResult {
        txid: String,
        amount: u64,
        fee: u64,
        address: String,
    }

    print_ok(
        SendResult { txid: txid.clone(), amount: send_amount, fee, address: pending.address.clone() },
        cfg.human,
        |r| {
            println!("Transaction broadcast.");
            println!("  txid: {}", r.txid);
        },
    );

    zipher_engine::wallet::close().await;
    Ok(())
}

async fn cmd_send_max(cfg: &Config, to: String) -> Result<()> {
    auto_open(cfg).await?;
    let max = zipher_engine::send::get_max_sendable(&to).await?;

    #[derive(Serialize)]
    struct MaxSendable {
        max_amount: u64,
        max_amount_zec: f64,
        address: String,
    }

    print_ok(
        MaxSendable {
            max_amount: max,
            max_amount_zec: max as f64 / 1e8,
            address: to.clone(),
        },
        cfg.human,
        |m| {
            println!("Max sendable to {}: {:.8} ZEC ({} zat)", m.address, m.max_amount_zec, m.max_amount);
        },
    );

    zipher_engine::wallet::close().await;
    Ok(())
}

async fn cmd_shield(cfg: &Config) -> Result<()> {
    ensure_sapling_params(&cfg.data_dir).await?;
    auto_open(cfg).await?;

    let seed = read_seed()?;
    let txid = zipher_engine::send::shield_funds(&seed).await?;

    #[derive(Serialize)]
    struct ShieldResult {
        txid: String,
    }

    print_ok(ShieldResult { txid: txid.clone() }, cfg.human, |r| {
        println!("Shielding transaction broadcast.");
        println!("  txid: {}", r.txid);
    });

    zipher_engine::wallet::close().await;
    Ok(())
}

// ---------------------------------------------------------------------------
// x402 commands
// ---------------------------------------------------------------------------

fn read_402_body(body: &Option<String>) -> Result<String> {
    if let Some(b) = body {
        return Ok(b.clone());
    }
    let mut buf = String::new();
    io::stdin().lock().read_to_string(&mut buf)?;
    let trimmed = buf.trim().to_string();
    if trimmed.is_empty() {
        return Err(anyhow::anyhow!(
            "No 402 body provided. Pass --body '<JSON>' or pipe via stdin."
        ));
    }
    Ok(trimmed)
}

fn expected_network(cfg: &Config) -> &'static str {
    if cfg.network == Network::TestNetwork {
        "zcash:testnet"
    } else {
        "zcash:mainnet"
    }
}

async fn cmd_x402_propose(
    cfg: &Config,
    body: Option<String>,
    context_id: Option<String>,
) -> Result<()> {
    let raw = read_402_body(&body)?;
    let req = zipher_engine::x402::parse_402_response(&raw, expected_network(cfg))?;
    let amount = zipher_engine::x402::amount_zatoshis(&req)?;

    cmd_send_propose(cfg, req.pay_to, amount, None, context_id).await
}

async fn cmd_x402_pay(
    cfg: &Config,
    body: Option<String>,
    context_id: Option<String>,
) -> Result<()> {
    ensure_sapling_params(&cfg.data_dir).await?;
    sync_if_needed(cfg).await?;
    let raw = read_402_body(&body)?;
    let req = zipher_engine::x402::parse_402_response(&raw, expected_network(cfg))?;
    let amount = zipher_engine::x402::amount_zatoshis(&req)?;
    let address = req.pay_to.clone();

    let policy = zipher_engine::policy::load_policy(&cfg.data_dir);

    let daily_spent = zipher_engine::audit::daily_spent(&cfg.data_dir).unwrap_or(0);
    if let Err(violation) = zipher_engine::policy::check_proposal(
        &policy, &address, amount, &context_id, daily_spent,
    ) {
        zipher_engine::audit::log_event(
            &cfg.data_dir, "x402_pay", Some(&address),
            Some(amount), None, context_id.as_deref(),
            None, Some(&violation.to_string()),
        ).ok();
        return Err(anyhow::anyhow!("{}", violation));
    }

    if let Err(violation) = zipher_engine::policy::check_rate_limit(&policy) {
        zipher_engine::audit::log_event(
            &cfg.data_dir, "x402_pay", Some(&address),
            Some(amount), None, context_id.as_deref(),
            None, Some(&violation.to_string()),
        ).ok();
        return Err(anyhow::anyhow!("{}", violation));
    }

    auto_open(cfg).await?;

    let (send_amount, fee, _) =
        zipher_engine::send::propose_send(&address, amount, None, false).await?;

    if cfg.human {
        let zec = send_amount as f64 / 1e8;
        let fee_zec = fee as f64 / 1e8;
        eprintln!(
            "x402 payment: {:.8} ZEC + {:.8} fee to {}",
            zec, fee_zec, address
        );
    }

    let seed = read_seed()?;
    let txid = match zipher_engine::send::confirm_send(&seed).await {
        Ok(txid) => {
            zipher_engine::policy::record_confirm();
            zipher_engine::audit::log_event(
                &cfg.data_dir, "x402_pay", Some(&address),
                Some(send_amount), Some(fee), context_id.as_deref(),
                Some(&txid), None,
            ).ok();
            txid
        }
        Err(e) => {
            zipher_engine::audit::log_event(
                &cfg.data_dir, "x402_pay", Some(&address),
                Some(send_amount), Some(fee), context_id.as_deref(),
                None, Some(&format!("{:#}", e)),
            ).ok();
            return Err(e);
        }
    };

    delete_pending(&cfg.data_dir);

    let payment_signature = zipher_engine::x402::build_payment_signature(&txid, &req);

    #[derive(Serialize)]
    struct X402PayResult {
        txid: String,
        payment_signature: String,
        amount: u64,
        fee: u64,
        address: String,
    }

    print_ok(
        X402PayResult {
            txid: txid.clone(),
            payment_signature: payment_signature.clone(),
            amount: send_amount,
            fee,
            address: address.clone(),
        },
        cfg.human,
        |r| {
            println!("x402 payment broadcast.");
            println!("  txid: {}", r.txid);
            println!("  amount: {:.8} ZEC ({} zat)", r.amount as f64 / 1e8, r.amount);
            println!("  fee:    {:.8} ZEC ({} zat)", r.fee as f64 / 1e8, r.fee);
            println!();
            println!("PAYMENT-SIGNATURE header:");
            println!("  {}", r.payment_signature);
        },
    );

    zipher_engine::wallet::close().await;
    Ok(())
}

// ---------------------------------------------------------------------------
// Universal pay command (auto-detects x402 or MPP)
// ---------------------------------------------------------------------------

async fn cmd_pay(
    cfg: &Config,
    url: String,
    context_id: Option<String>,
    http_method: String,
) -> Result<()> {
    ensure_sapling_params(&cfg.data_dir).await?;
    sync_if_needed(cfg).await?;

    let client = reqwest::Client::new();
    let initial_resp = match http_method.to_uppercase().as_str() {
        "POST" => client.post(&url).send().await,
        "PUT" => client.put(&url).send().await,
        _ => client.get(&url).send().await,
    }
    .map_err(|e| anyhow::anyhow!("HTTP request failed: {}", e))?;

    if initial_resp.status() != reqwest::StatusCode::PAYMENT_REQUIRED {
        let status = initial_resp.status();
        let body = initial_resp.text().await.unwrap_or_default();
        if status.is_success() {
            println!("{}", body);
            return Ok(());
        }
        return Err(anyhow::anyhow!("Expected HTTP 402, got {}: {}", status, body));
    }

    let mut headers = std::collections::HashMap::new();
    for (k, v) in initial_resp.headers() {
        if let Ok(val) = v.to_str() {
            headers.insert(k.as_str().to_lowercase(), val.to_string());
        }
    }
    let body = initial_resp.text().await.unwrap_or_default();

    let network = expected_network(cfg);
    let protocol = zipher_engine::payment::detect_protocol(&headers, &body, network)?;
    let info = protocol.info()?;

    if cfg.human {
        eprintln!(
            "402 detected ({} protocol). {} zat to {}",
            info.protocol, info.amount, info.address
        );
    }

    let address = protocol.address()?;
    let amount = protocol.amount_zatoshis()?;

    let policy = zipher_engine::policy::load_policy(&cfg.data_dir);
    let daily_spent = zipher_engine::audit::daily_spent(&cfg.data_dir).unwrap_or(0);
    if let Err(violation) = zipher_engine::policy::check_proposal(
        &policy, &address, amount, &context_id, daily_spent,
    ) {
        zipher_engine::audit::log_event(
            &cfg.data_dir, "pay", Some(&address),
            Some(amount), None, context_id.as_deref(),
            None, Some(&violation.to_string()),
        ).ok();
        return Err(anyhow::anyhow!("{}", violation));
    }
    if let Err(violation) = zipher_engine::policy::check_rate_limit(&policy) {
        return Err(anyhow::anyhow!("{}", violation));
    }

    auto_open(cfg).await?;

    let (send_amount, fee, _) =
        zipher_engine::send::propose_send(&address, amount, None, false).await?;

    let seed = read_seed()?;
    let txid = match zipher_engine::send::confirm_send(&seed).await {
        Ok(txid) => {
            zipher_engine::policy::record_confirm();
            zipher_engine::audit::log_event(
                &cfg.data_dir, "pay", Some(&address),
                Some(send_amount), Some(fee), context_id.as_deref(),
                Some(&txid), None,
            ).ok();
            txid
        }
        Err(e) => {
            zipher_engine::audit::log_event(
                &cfg.data_dir, "pay", Some(&address),
                Some(send_amount), Some(fee), context_id.as_deref(),
                None, Some(&format!("{:#}", e)),
            ).ok();
            return Err(e);
        }
    };

    delete_pending(&cfg.data_dir);

    let (cred_header, cred_value) = protocol.build_credential(&txid);

    let retry_resp = match http_method.to_uppercase().as_str() {
        "POST" => client.post(&url).header(&cred_header, &cred_value).send().await,
        "PUT" => client.put(&url).header(&cred_header, &cred_value).send().await,
        _ => client.get(&url).header(&cred_header, &cred_value).send().await,
    }
    .map_err(|e| anyhow::anyhow!("Retry request failed: {}", e))?;

    let retry_status = retry_resp.status();
    let receipt = retry_resp
        .headers()
        .get("payment-receipt")
        .and_then(|v| v.to_str().ok())
        .map(|s| s.to_string());
    let response_body = retry_resp.text().await.unwrap_or_default();

    #[derive(Serialize)]
    struct PayResult {
        txid: String,
        protocol: String,
        credential_header: String,
        credential_value: String,
        amount: u64,
        fee: u64,
        address: String,
        retry_status: u16,
        receipt: Option<String>,
        response: String,
    }

    print_ok(
        PayResult {
            txid: txid.clone(),
            protocol: info.protocol.clone(),
            credential_header: cred_header.clone(),
            credential_value: cred_value.clone(),
            amount: send_amount,
            fee,
            address: address.clone(),
            retry_status: retry_status.as_u16(),
            receipt,
            response: response_body.clone(),
        },
        cfg.human,
        |r| {
            println!("Payment complete ({} protocol).", r.protocol);
            println!("  txid:   {}", r.txid);
            println!("  amount: {:.8} ZEC ({} zat)", r.amount as f64 / 1e8, r.amount);
            println!("  fee:    {:.8} ZEC ({} zat)", r.fee as f64 / 1e8, r.fee);
            println!("  retry:  HTTP {}", r.retry_status);
            println!();
            if r.response.len() < 2000 {
                println!("Response:");
                println!("{}", r.response);
            } else {
                println!("Response: ({} bytes)", r.response.len());
            }
        },
    );

    zipher_engine::wallet::close().await;
    Ok(())
}

// ---------------------------------------------------------------------------
// Swap commands (Near Intents)
// ---------------------------------------------------------------------------

async fn cmd_swap_tokens(cfg: &Config) -> Result<()> {
    let tokens = zipher_engine::swap::get_tokens().await?;

    #[derive(Serialize)]
    struct TokenInfo {
        asset_id: String,
        symbol: String,
        blockchain: String,
        decimals: u32,
        price: Option<f64>,
    }

    let list: Vec<TokenInfo> = zipher_engine::swap::swappable_tokens(&tokens)
        .into_iter()
        .map(|t| TokenInfo {
            asset_id: t.asset_id.clone(),
            symbol: t.symbol.clone(),
            blockchain: t.blockchain.clone(),
            decimals: t.decimals,
            price: t.price,
        })
        .collect();

    let zec = zipher_engine::swap::find_zec_token(&tokens);

    #[derive(Serialize)]
    struct TokensResult {
        zec_asset_id: Option<String>,
        available_tokens: Vec<TokenInfo>,
        total: usize,
    }

    let total = list.len();
    print_ok(
        TokensResult {
            zec_asset_id: zec.map(|t| t.asset_id.clone()),
            available_tokens: list,
            total,
        },
        cfg.human,
        |r| {
            if let Some(ref zec_id) = r.zec_asset_id {
                println!("ZEC asset ID: {}", zec_id);
            }
            println!("{} swappable tokens available.", r.total);
            for t in &r.available_tokens {
                let price = t.price.map_or("n/a".into(), |p| format!("${:.2}", p));
                println!("  {} ({}) — {} — {}", t.symbol, t.blockchain, t.asset_id, price);
            }
        },
    );
    Ok(())
}

async fn cmd_swap_quote(
    cfg: &Config,
    to_symbol: String,
    chain: Option<String>,
    amount: u64,
    recipient: String,
    slippage: u32,
) -> Result<()> {
    let tokens = zipher_engine::swap::get_tokens().await?;

    let zec = zipher_engine::swap::find_zec_token(&tokens)
        .ok_or_else(|| anyhow::anyhow!("ZEC not found in Near Intents token list"))?;

    let dest = find_destination_token(&tokens, &to_symbol, chain.as_deref())?;

    auto_open(cfg).await?;
    let addresses = zipher_engine::query::get_addresses().await?;
    let refund_addr = addresses
        .first()
        .map(|a| a.address.clone())
        .unwrap_or_default();

    let quote = zipher_engine::swap::get_quote(
        &zec.asset_id,
        &dest.asset_id,
        &amount.to_string(),
        &recipient,
        &refund_addr,
        slippage,
    )
    .await?;

    print_ok(&quote, cfg.human, |q| {
        println!("Swap quote received:");
        println!("  Send:    {} zat ZEC", q.amount_in);
        println!("  Receive: {} {} ({})", q.amount_out, to_symbol, dest.blockchain);
        if let Some(ref min) = q.min_amount_out {
            println!("  Min out: {}", min);
        }
        println!("  Deposit: {}", q.deposit_address);
        println!("  Deadline: {}", q.deadline);
        println!();
        println!("To execute: zipher-cli swap execute --to {} --amount {} --recipient {}", to_symbol, amount, recipient);
    });

    zipher_engine::wallet::close().await;
    Ok(())
}

async fn cmd_swap_execute(
    cfg: &Config,
    to_symbol: String,
    chain: Option<String>,
    amount: u64,
    recipient: String,
    slippage: u32,
    context_id: Option<String>,
) -> Result<()> {
    ensure_sapling_params(&cfg.data_dir).await?;
    sync_if_needed(cfg).await?;

    let tokens = zipher_engine::swap::get_tokens().await?;
    let zec = zipher_engine::swap::find_zec_token(&tokens)
        .ok_or_else(|| anyhow::anyhow!("ZEC not found in Near Intents token list"))?;
    let dest = find_destination_token(&tokens, &to_symbol, chain.as_deref())?;

    auto_open(cfg).await?;
    let addresses = zipher_engine::query::get_addresses().await?;
    let refund_addr = addresses
        .first()
        .map(|a| a.address.clone())
        .unwrap_or_default();

    let quote = zipher_engine::swap::get_quote(
        &zec.asset_id,
        &dest.asset_id,
        &amount.to_string(),
        &recipient,
        &refund_addr,
        slippage,
    )
    .await?;

    if quote.deposit_address.is_empty() {
        return Err(anyhow::anyhow!("No deposit address in quote"));
    }

    if cfg.human {
        eprintln!(
            "Sending {} zat to deposit address {} (swap to {} {})",
            amount, quote.deposit_address, to_symbol, dest.blockchain
        );
    }

    let (send_amount, fee, _) =
        zipher_engine::send::propose_send(&quote.deposit_address, amount, None, false).await?;

    let seed = read_seed()?;
    let txid = match zipher_engine::send::confirm_send(&seed).await {
        Ok(txid) => {
            zipher_engine::policy::record_confirm();
            zipher_engine::audit::log_event(
                &cfg.data_dir, "swap_execute", Some(&quote.deposit_address),
                Some(send_amount), Some(fee), context_id.as_deref(),
                Some(&txid), None,
            ).ok();
            txid
        }
        Err(e) => {
            zipher_engine::audit::log_event(
                &cfg.data_dir, "swap_execute", Some(&quote.deposit_address),
                Some(send_amount), Some(fee), context_id.as_deref(),
                None, Some(&format!("{:#}", e)),
            ).ok();
            return Err(e);
        }
    };

    delete_pending(&cfg.data_dir);

    if let Err(e) = zipher_engine::swap::submit_deposit(&txid, &quote.deposit_address).await {
        if cfg.human {
            eprintln!("Warning: deposit submit notification failed: {}. Swap may still proceed.", e);
        }
    }

    #[derive(Serialize)]
    struct SwapResult {
        txid: String,
        deposit_address: String,
        amount_in: String,
        amount_out: String,
        destination_symbol: String,
        destination_chain: String,
        recipient: String,
        fee: u64,
    }

    print_ok(
        SwapResult {
            txid: txid.clone(),
            deposit_address: quote.deposit_address.clone(),
            amount_in: quote.amount_in.clone(),
            amount_out: quote.amount_out.clone(),
            destination_symbol: to_symbol.clone(),
            destination_chain: dest.blockchain.clone(),
            recipient: recipient.clone(),
            fee,
        },
        cfg.human,
        |r| {
            println!("Swap initiated.");
            println!("  ZEC txid:     {}", r.txid);
            println!("  Deposit addr: {}", r.deposit_address);
            println!("  Amount in:    {} zat", r.amount_in);
            println!("  Amount out:   {} {} ({})", r.amount_out, r.destination_symbol, r.destination_chain);
            println!("  Recipient:    {}", r.recipient);
            println!("  Fee:          {} zat", r.fee);
            println!();
            println!("Check status: zipher-cli swap status --deposit-address {}", r.deposit_address);
        },
    );

    zipher_engine::wallet::close().await;
    Ok(())
}

async fn cmd_swap_status(cfg: &Config, deposit_address: String) -> Result<()> {
    let status = zipher_engine::swap::get_status(&deposit_address).await?;

    print_ok(&status, cfg.human, |s| {
        println!("Swap status: {}", s.status);
        if let Some(ref h) = s.tx_hash_in {
            println!("  TX in:  {}", h);
        }
        if let Some(ref h) = s.tx_hash_out {
            println!("  TX out: {}", h);
        }
    });
    Ok(())
}

fn find_destination_token<'a>(
    tokens: &'a [zipher_engine::swap::SwapToken],
    symbol: &str,
    chain: Option<&str>,
) -> Result<&'a zipher_engine::swap::SwapToken> {
    let matches: Vec<&zipher_engine::swap::SwapToken> = tokens
        .iter()
        .filter(|t| t.symbol.eq_ignore_ascii_case(symbol))
        .filter(|t| {
            chain.map_or(true, |c| t.blockchain.eq_ignore_ascii_case(c))
        })
        .collect();

    match matches.len() {
        0 => Err(anyhow::anyhow!(
            "Token '{}' not found{}",
            symbol,
            chain.map_or(String::new(), |c| format!(" on chain '{}'", c))
        )),
        1 => Ok(matches[0]),
        _ => {
            let chains: Vec<String> = matches.iter().map(|t| t.blockchain.clone()).collect();
            Err(anyhow::anyhow!(
                "'{}' exists on multiple chains: {}. Use --chain to specify.",
                symbol,
                chains.join(", ")
            ))
        }
    }
}

// ---------------------------------------------------------------------------
// Session commands
// ---------------------------------------------------------------------------

async fn cmd_session_open(
    cfg: &Config,
    server_url: String,
    deposit: u64,
    merchant_id: String,
    pay_to: String,
    context_id: Option<String>,
) -> Result<()> {
    ensure_sapling_params(&cfg.data_dir).await?;
    sync_if_needed(cfg).await?;

    let memo = format!("zipher:session:{}", merchant_id);

    auto_open(cfg).await?;
    let (send_amount, fee, _) =
        zipher_engine::send::propose_send(&pay_to, deposit, Some(memo), false).await?;

    let seed = read_seed()?;
    let txid = match zipher_engine::send::confirm_send(&seed).await {
        Ok(txid) => {
            zipher_engine::policy::record_confirm();
            zipher_engine::audit::log_event(
                &cfg.data_dir, "session_open", Some(&pay_to),
                Some(send_amount), Some(fee), context_id.as_deref(),
                Some(&txid), None,
            ).ok();
            txid
        }
        Err(e) => {
            zipher_engine::audit::log_event(
                &cfg.data_dir, "session_open", Some(&pay_to),
                Some(send_amount), Some(fee), context_id.as_deref(),
                None, Some(&format!("{:#}", e)),
            ).ok();
            return Err(e);
        }
    };

    delete_pending(&cfg.data_dir);

    let session = zipher_engine::session::open_session(
        None,
        &txid,
        &merchant_id,
        &server_url,
        &cfg.data_dir,
    )
    .await?;

    print_ok(&session, cfg.human, |s| {
        println!("Session opened.");
        println!("  ID:       {}", s.session_id);
        println!("  Balance:  {} zat", s.balance_remaining);
        println!("  Expires:  {}", s.expires_at);
        println!("  Cost/req: {} zat", s.cost_per_request);
        println!("  Deposit:  {}", s.deposit_txid);
    });

    zipher_engine::wallet::close().await;
    Ok(())
}

async fn cmd_session_request(
    cfg: &Config,
    url: String,
    method: String,
) -> Result<()> {
    let host = url
        .split("//")
        .nth(1)
        .and_then(|s| s.split('/').next())
        .unwrap_or(&url);
    let server_url = format!(
        "{}//{}",
        url.split("//").next().unwrap_or("https:"),
        host
    );

    let session = zipher_engine::session::find_session(&cfg.data_dir, &server_url)
        .ok_or_else(|| anyhow::anyhow!(
            "No active session for {}. Use `session open` first.", server_url
        ))?;

    let (status, body, remaining) =
        zipher_engine::session::session_request(&session, &url, &method).await?;

    if let Some(rem) = remaining {
        let mut store = zipher_engine::session::load_sessions(&cfg.data_dir);
        if let Some(s) = store.sessions.iter_mut().find(|s| s.session_id == session.session_id) {
            s.balance_remaining = rem;
        }
        zipher_engine::session::save_sessions(&cfg.data_dir, &store).ok();
    }

    #[derive(Serialize)]
    struct SessionRequestResult {
        status: u16,
        session_id: String,
        balance_remaining: Option<u64>,
        response: String,
    }

    print_ok(
        SessionRequestResult {
            status,
            session_id: session.session_id.clone(),
            balance_remaining: remaining,
            response: body.clone(),
        },
        cfg.human,
        |r| {
            println!("HTTP {} (session {})", r.status, r.session_id);
            if let Some(bal) = r.balance_remaining {
                println!("  Balance remaining: {} zat", bal);
            }
            println!();
            if r.response.len() < 2000 {
                println!("{}", r.response);
            } else {
                println!("({} bytes)", r.response.len());
            }
        },
    );
    Ok(())
}

async fn cmd_session_list(cfg: &Config) -> Result<()> {
    let sessions = zipher_engine::session::list_sessions(&cfg.data_dir);

    #[derive(Serialize)]
    struct ListResult {
        total: usize,
        sessions: Vec<zipher_engine::session::Session>,
    }

    print_ok(
        ListResult {
            total: sessions.len(),
            sessions: sessions.clone(),
        },
        cfg.human,
        |r| {
            if r.sessions.is_empty() {
                println!("No active sessions.");
            } else {
                for s in &r.sessions {
                    println!(
                        "  {} — {} — {} zat remaining (expires {})",
                        s.session_id, s.server_url, s.balance_remaining, s.expires_at
                    );
                }
            }
        },
    );
    Ok(())
}

async fn cmd_session_close(cfg: &Config, session_id: String) -> Result<()> {
    let summary = zipher_engine::session::close_session(None, &session_id, &cfg.data_dir).await?;

    print_ok(&summary, cfg.human, |s| {
        println!("Session closed.");
        println!("  ID:             {}", s.session_id);
        println!("  Status:         {}", s.status);
        println!("  Requests made:  {}", s.requests_made);
        println!("  Balance used:   {} zat", s.balance_used);
        println!("  Balance left:   {} zat", s.balance_remaining);
    });
    Ok(())
}

// ---------------------------------------------------------------------------
// Policy commands
// ---------------------------------------------------------------------------

async fn cmd_policy_show(cfg: &Config) -> Result<()> {
    let policy = zipher_engine::policy::load_policy(&cfg.data_dir);

    print_ok(&policy, cfg.human, |p| {
        println!("Spending Policy:");
        println!("  max_per_tx:            {} zat", p.max_per_tx);
        println!("  daily_limit:           {} zat", p.daily_limit);
        println!("  min_spend_interval_ms: {} ms", p.min_spend_interval_ms);
        println!("  require_context_id:    {}", p.require_context_id);
        println!("  approval_threshold:    {} zat", p.approval_threshold);
        if p.allowlist.is_empty() {
            println!("  allowlist:             (any address)");
        } else {
            println!("  allowlist:");
            for addr in &p.allowlist {
                println!("    - {}", addr);
            }
        }
    });
    Ok(())
}

async fn cmd_policy_set(cfg: &Config, field: String, value: String) -> Result<()> {
    ensure_data_dir(&cfg.data_dir)?;
    let mut policy = zipher_engine::policy::load_policy(&cfg.data_dir);

    match field.as_str() {
        "max_per_tx" => policy.max_per_tx = value.parse()?,
        "daily_limit" => policy.daily_limit = value.parse()?,
        "min_spend_interval_ms" => policy.min_spend_interval_ms = value.parse()?,
        "approval_threshold" => policy.approval_threshold = value.parse()?,
        "require_context_id" => policy.require_context_id = value.parse()?,
        _ => return Err(anyhow::anyhow!("Unknown policy field: {}. Valid fields: max_per_tx, daily_limit, min_spend_interval_ms, approval_threshold, require_context_id", field)),
    }

    zipher_engine::policy::save_policy(&cfg.data_dir, &policy)?;

    print_ok("updated", cfg.human, |_| {
        println!("Policy updated: {} = {}", field, value);
    });
    Ok(())
}

async fn cmd_policy_add_allowlist(cfg: &Config, address: String) -> Result<()> {
    ensure_data_dir(&cfg.data_dir)?;
    let mut policy = zipher_engine::policy::load_policy(&cfg.data_dir);

    if !policy.allowlist.contains(&address) {
        policy.allowlist.push(address.clone());
        zipher_engine::policy::save_policy(&cfg.data_dir, &policy)?;
    }

    print_ok("added", cfg.human, |_| {
        println!("Address added to allowlist: {}", address);
    });
    Ok(())
}

async fn cmd_policy_remove_allowlist(cfg: &Config, address: String) -> Result<()> {
    ensure_data_dir(&cfg.data_dir)?;
    let mut policy = zipher_engine::policy::load_policy(&cfg.data_dir);

    policy.allowlist.retain(|a| a != &address);
    zipher_engine::policy::save_policy(&cfg.data_dir, &policy)?;

    print_ok("removed", cfg.human, |_| {
        println!("Address removed from allowlist: {}", address);
    });
    Ok(())
}

// ---------------------------------------------------------------------------
// Audit command
// ---------------------------------------------------------------------------

async fn cmd_audit(cfg: &Config, limit: usize, since: Option<String>) -> Result<()> {
    let entries = zipher_engine::audit::query_log(
        &cfg.data_dir,
        limit,
        since.as_deref(),
    )?;

    print_ok(&entries, cfg.human, |entries| {
        if entries.is_empty() {
            println!("No audit log entries.");
        } else {
            for e in entries.iter() {
                let amt = e.amount.map(|a| format!("{} zat", a)).unwrap_or_default();
                let err_tag = if e.error.is_some() { " [ERR]" } else { "" };
                println!(
                    "  #{} {} {}{} {}",
                    e.id, e.timestamp, e.action, err_tag, amt,
                );
                if let Some(ref addr) = e.address {
                    println!("       to: {}", addr);
                }
                if let Some(ref txid) = e.txid {
                    println!("       txid: {}", txid);
                }
                if let Some(ref ctx) = e.context_id {
                    println!("       context: {}", ctx);
                }
                if let Some(ref err) = e.error {
                    println!("       error: {}", err);
                }
            }
        }
    });
    Ok(())
}

// ---------------------------------------------------------------------------
// Daemon mode
// ---------------------------------------------------------------------------

mod daemon {
    use super::*;
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::Arc;
    use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
    use tokio::net::UnixListener;
    use zeroize::Zeroize;

    fn sock_path(data_dir: &str) -> PathBuf {
        PathBuf::from(data_dir).join("daemon.sock")
    }

    fn pid_path(data_dir: &str) -> PathBuf {
        PathBuf::from(data_dir).join("daemon.pid")
    }

    pub fn is_running(data_dir: &str) -> bool {
        let pidfile = pid_path(data_dir);
        if !pidfile.exists() {
            return false;
        }
        if let Ok(contents) = std::fs::read_to_string(&pidfile) {
            if let Ok(pid) = contents.trim().parse::<u32>() {
                // check if process is alive
                unsafe {
                    return libc_kill(pid) == 0;
                }
            }
        }
        false
    }

    /// Portable "is PID alive" check (signal 0)
    #[cfg(unix)]
    unsafe fn libc_kill(pid: u32) -> i32 {
        extern "C" { fn kill(pid: i32, sig: i32) -> i32; }
        unsafe { kill(pid as i32, 0) }
    }

    #[cfg(not(unix))]
    unsafe fn libc_kill(_pid: u32) -> i32 { -1 }

    fn write_pid(data_dir: &str) {
        let _ = std::fs::write(
            pid_path(data_dir),
            format!("{}", std::process::id()),
        );
    }

    fn remove_pid(data_dir: &str) {
        let _ = std::fs::remove_file(pid_path(data_dir));
    }

    struct DaemonState {
        seed: tokio::sync::RwLock<Option<String>>,
        locked: AtomicBool,
    }

    pub async fn cmd_start(cfg: &Config) -> Result<()> {
        if is_running(&cfg.data_dir) {
            return Err(anyhow::anyhow!("Daemon is already running."));
        }

        ensure_data_dir(&cfg.data_dir)?;
        write_pid(&cfg.data_dir);

        let seed_str = read_seed()?;
        use secrecy::ExposeSecret;
        let seed_value = seed_str.expose_secret().to_string();

        let state = Arc::new(DaemonState {
            seed: tokio::sync::RwLock::new(Some(seed_value)),
            locked: AtomicBool::new(false),
        });

        auto_open(cfg).await?;
        zipher_engine::sync::start().await?;

        if cfg.human {
            eprintln!("Daemon started (pid {}). Sync running.", std::process::id());
            eprintln!("Socket: {}", sock_path(&cfg.data_dir).display());
        }

        let sock = sock_path(&cfg.data_dir);
        if sock.exists() {
            std::fs::remove_file(&sock)?;
        }
        let listener = UnixListener::bind(&sock)?;

        let shutdown = Arc::new(AtomicBool::new(false));
        let shutdown_clone = shutdown.clone();
        ctrlc::set_handler(move || {
            shutdown_clone.store(true, Ordering::SeqCst);
        }).ok();

        loop {
            if shutdown.load(Ordering::SeqCst) {
                break;
            }

            let accept = tokio::select! {
                result = listener.accept() => Some(result),
                _ = tokio::time::sleep(std::time::Duration::from_secs(1)) => None,
            };

            if let Some(Ok((stream, _))) = accept {
                let state = state.clone();
                let data_dir = cfg.data_dir.clone();
                let server_url = cfg.server_url.clone();
                let network = cfg.network;
                let shutdown_ref = shutdown.clone();

                tokio::spawn(async move {
                    let (reader, mut writer) = stream.into_split();
                    let mut lines = BufReader::new(reader).lines();

                    while let Ok(Some(line)) = lines.next_line().await {
                        let resp = handle_ipc_command(
                            &line, &state, &data_dir, &server_url, network, &shutdown_ref,
                        ).await;
                        let _ = writer.write_all(resp.as_bytes()).await;
                        let _ = writer.write_all(b"\n").await;
                    }
                });
            }
        }

        // Cleanup
        zipher_engine::sync::stop().await;
        zipher_engine::wallet::close().await;

        // Zeroize seed on shutdown
        if let Some(ref mut s) = *state.seed.write().await {
            s.zeroize();
        }

        std::fs::remove_file(&sock).ok();
        remove_pid(&cfg.data_dir);

        if cfg.human {
            eprintln!("Daemon stopped.");
        }

        Ok(())
    }

    async fn handle_ipc_command(
        cmd: &str,
        state: &Arc<DaemonState>,
        data_dir: &str,
        _server_url: &str,
        _network: Network,
        shutdown: &Arc<AtomicBool>,
    ) -> String {
        let parts: Vec<&str> = cmd.trim().splitn(2, ' ').collect();
        let command = parts.first().copied().unwrap_or("");
        let _args = parts.get(1).copied().unwrap_or("");

        match command {
            "ping" => r#"{"ok":true,"data":"pong"}"#.to_string(),

            "status" => {
                let progress = zipher_engine::sync::get_progress().await;
                let locked = state.locked.load(Ordering::SeqCst);
                serde_json::to_string(&serde_json::json!({
                    "ok": true,
                    "data": {
                        "locked": locked,
                        "synced_height": progress.synced_height,
                        "latest_height": progress.latest_height,
                        "is_syncing": progress.is_syncing,
                    }
                })).unwrap_or_else(|_| r#"{"ok":false,"error":"serialize"}"#.into())
            }

            "lock" => {
                let mut seed_guard = state.seed.write().await;
                if let Some(ref mut s) = *seed_guard {
                    s.zeroize();
                }
                *seed_guard = None;
                state.locked.store(true, Ordering::SeqCst);

                zipher_engine::audit::log_event(
                    data_dir, "daemon_lock", None, None, None, None, None, None,
                ).ok();

                r#"{"ok":true,"data":"locked"}"#.to_string()
            }

            "unlock" => {
                let seed_value = std::env::var("ZIPHER_SEED").unwrap_or_default();
                if seed_value.is_empty() {
                    return r#"{"ok":false,"error":"SEED_REQUIRED: set ZIPHER_SEED env var on the daemon process before unlocking"}"#.to_string();
                }
                let mut seed_guard = state.seed.write().await;
                *seed_guard = Some(seed_value);
                state.locked.store(false, Ordering::SeqCst);

                zipher_engine::audit::log_event(
                    data_dir, "daemon_unlock", None, None, None, None, None, None,
                ).ok();

                r#"{"ok":true,"data":"unlocked"}"#.to_string()
            }

            "stop" => {
                shutdown.store(true, Ordering::SeqCst);
                r#"{"ok":true,"data":"stopping"}"#.to_string()
            }

            _ => {
                format!(r#"{{"ok":false,"error":"UNKNOWN_COMMAND: {}"}}"#, command)
            }
        }
    }

    pub async fn cmd_status(cfg: &Config) -> Result<()> {
        let running = is_running(&cfg.data_dir);
        let sock = sock_path(&cfg.data_dir);

        #[derive(Serialize)]
        struct DaemonStatus {
            running: bool,
            socket: String,
            pid_file: String,
        }

        let status = DaemonStatus {
            running,
            socket: sock.display().to_string(),
            pid_file: pid_path(&cfg.data_dir).display().to_string(),
        };

        if running && sock.exists() {
            if let Ok(stream) = tokio::net::UnixStream::connect(&sock).await {
                let (reader, mut writer) = stream.into_split();
                use tokio::io::{AsyncBufReadExt, AsyncWriteExt};
                let _ = writer.write_all(b"status\n").await;
                let mut lines = BufReader::new(reader).lines();
                if let Ok(Some(line)) = lines.next_line().await {
                    if cfg.human {
                        println!("Daemon running (pid file: {})", status.pid_file);
                        println!("Response: {}", line);
                    } else {
                        println!("{}", line);
                    }
                    return Ok(());
                }
            }
        }

        print_ok(status, cfg.human, |s| {
            if s.running {
                println!("Daemon is running.");
            } else {
                println!("Daemon is not running.");
            }
            println!("  Socket: {}", s.socket);
        });
        Ok(())
    }

    async fn send_daemon_command(data_dir: &str, cmd: &str) -> Result<String> {
        let sock = sock_path(data_dir);
        if !sock.exists() {
            return Err(anyhow::anyhow!("Daemon is not running (no socket found)."));
        }

        let stream = tokio::net::UnixStream::connect(&sock).await
            .map_err(|e| anyhow::anyhow!("Cannot connect to daemon: {}", e))?;

        let (reader, mut writer) = stream.into_split();
        use tokio::io::{AsyncBufReadExt, AsyncWriteExt};
        writer.write_all(cmd.as_bytes()).await?;
        writer.write_all(b"\n").await?;

        let mut lines = BufReader::new(reader).lines();
        let response = lines.next_line().await?
            .unwrap_or_else(|| r#"{"ok":false,"error":"no response"}"#.to_string());
        Ok(response)
    }

    pub async fn cmd_stop(cfg: &Config) -> Result<()> {
        let resp = send_daemon_command(&cfg.data_dir, "stop").await?;
        if cfg.human {
            println!("Daemon: {}", resp);
        } else {
            println!("{}", resp);
        }
        Ok(())
    }

    pub async fn cmd_lock(cfg: &Config) -> Result<()> {
        let resp = send_daemon_command(&cfg.data_dir, "lock").await?;
        if cfg.human {
            println!("Daemon: {}", resp);
            println!("Seed material zeroized. Spending disabled until `daemon unlock`.");
        } else {
            println!("{}", resp);
        }
        Ok(())
    }

    pub async fn cmd_unlock(cfg: &Config) -> Result<()> {
        let resp = send_daemon_command(&cfg.data_dir, "unlock").await?;
        if cfg.human {
            println!("Daemon: {}", resp);
            println!("Seed read from ZIPHER_SEED env var on the daemon process.");
        } else {
            println!("{}", resp);
        }
        Ok(())
    }
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

#[tokio::main]
async fn main() {
    let cli = Cli::parse();
    let cfg = resolve_config(&cli);

    tracing_subscriber::fmt()
        .with_max_level(tracing::Level::WARN)
        .with_target(false)
        .init();

    let result: Result<()> = match cli.command {
        Commands::Info => {
            cmd_info(&cfg).await;
            Ok(())
        }
        Commands::Wallet(sub) => match sub {
            WalletCmd::Create => cmd_wallet_create(&cfg).await,
            WalletCmd::Restore { birthday } => cmd_wallet_restore(&cfg, birthday).await,
            WalletCmd::Delete { confirm } => cmd_wallet_delete(&cfg, confirm).await,
        },
        Commands::Sync(sub) => match sub {
            SyncCmd::Start => cmd_sync_start(&cfg).await,
            SyncCmd::Status => cmd_sync_status(&cfg).await,
        },
        Commands::Balance => cmd_balance(&cfg).await,
        Commands::Address => cmd_address(&cfg).await,
        Commands::Keys => cmd_keys(&cfg).await,
        Commands::Transactions { limit } => cmd_transactions(&cfg, limit).await,
        Commands::Send(sub) => match sub {
            SendCmd::Propose { to, amount, memo, context_id } => {
                cmd_send_propose(&cfg, to, amount, memo, context_id).await
            }
            SendCmd::Confirm => cmd_send_confirm(&cfg).await,
            SendCmd::Max { to } => cmd_send_max(&cfg, to).await,
        },
        Commands::Shield => cmd_shield(&cfg).await,
        Commands::Policy(sub) => match sub {
            PolicyCmd::Show => cmd_policy_show(&cfg).await,
            PolicyCmd::Set { field, value } => cmd_policy_set(&cfg, field, value).await,
            PolicyCmd::AddAllowlist { address } => cmd_policy_add_allowlist(&cfg, address).await,
            PolicyCmd::RemoveAllowlist { address } => cmd_policy_remove_allowlist(&cfg, address).await,
        },
        Commands::Audit { limit, since } => cmd_audit(&cfg, limit, since).await,
        Commands::Daemon(sub) => match sub {
            DaemonCmd::Start => daemon::cmd_start(&cfg).await,
            DaemonCmd::Status => daemon::cmd_status(&cfg).await,
            DaemonCmd::Stop => daemon::cmd_stop(&cfg).await,
            DaemonCmd::Lock => daemon::cmd_lock(&cfg).await,
            DaemonCmd::Unlock => daemon::cmd_unlock(&cfg).await,
        },
        Commands::X402(sub) => match sub {
            X402Cmd::Propose { body, context_id } => {
                cmd_x402_propose(&cfg, body, context_id).await
            }
            X402Cmd::Pay { body, context_id } => {
                cmd_x402_pay(&cfg, body, context_id).await
            }
        },
        Commands::Pay { url, context_id, method } => {
            cmd_pay(&cfg, url, context_id, method).await
        }
        Commands::Swap(sub) => match sub {
            SwapCmd::Tokens => cmd_swap_tokens(&cfg).await,
            SwapCmd::Quote { to, chain, amount, recipient, slippage } => {
                cmd_swap_quote(&cfg, to, chain, amount, recipient, slippage).await
            }
            SwapCmd::Execute { to, chain, amount, recipient, slippage, context_id } => {
                cmd_swap_execute(&cfg, to, chain, amount, recipient, slippage, context_id).await
            }
            SwapCmd::Status { deposit_address } => {
                cmd_swap_status(&cfg, deposit_address).await
            }
        },
        Commands::Session(sub) => match sub {
            SessionCmd::Open { server_url, deposit, merchant_id, pay_to, context_id } => {
                cmd_session_open(&cfg, server_url, deposit, merchant_id, pay_to, context_id).await
            }
            SessionCmd::Request { url, method } => {
                cmd_session_request(&cfg, url, method).await
            }
            SessionCmd::List => cmd_session_list(&cfg).await,
            SessionCmd::Close { session_id } => cmd_session_close(&cfg, session_id).await,
        },
    };

    if let Err(e) = result {
        print_err(&e, cfg.human);
        std::process::exit(1);
    }
}
