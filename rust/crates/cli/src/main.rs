use anyhow::Result;
use clap::{Parser, Subcommand};
use serde::Serialize;
use zcash_protocol::consensus::Network;

mod daemon;
mod helpers;
mod market;
mod payment;
mod policy;
mod serve;
mod session;
mod swap;
mod wallet;

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

    /// Prediction market operations via Myriad (ZEC → USDT → bet)
    #[command(subcommand)]
    Market(MarketCmd),

    /// Start a paid HTTP API server (x402 pay-per-call)
    Serve {
        /// Port to listen on
        #[arg(long, default_value = "8402")]
        port: u16,

        /// Price per API call in zatoshis (default: 10000 = 0.0001 ZEC)
        #[arg(long)]
        price: Option<u64>,
    },

    /// Sweep remaining funds from an EVM chain back to shielded ZEC
    Sweep {
        /// Token symbol to sweep (e.g., USDC, USDT)
        #[arg(long)]
        token: String,

        /// Chain to sweep from (e.g., base, bsc)
        #[arg(long)]
        chain: String,

        /// OWS wallet name for EVM signing
        #[arg(long, default_value = "default")]
        ows_wallet: String,
    },
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

    /// Create a PCZT (unsigned transaction) for external signing via OWS
    Pczt {
        /// Destination address
        #[arg(long)]
        to: String,

        /// Amount in zatoshis
        #[arg(long)]
        amount: u64,

        /// Optional memo (shielded only)
        #[arg(long)]
        memo: Option<String>,
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
enum MarketCmd {
    /// Search prediction markets on Myriad
    List {
        /// Search keyword
        #[arg(long)]
        keyword: Option<String>,

        /// Max results
        #[arg(long, default_value = "20")]
        limit: u32,
    },

    /// Show market details with outcome prices
    Show {
        /// Market ID
        id: u64,
    },

    /// Place a bet: ZEC → USDT → approve → buy shares
    Bet {
        /// Market ID
        #[arg(long)]
        id: u64,

        /// Outcome index (0, 1, ...)
        #[arg(long)]
        outcome: u64,

        /// Amount in USDT
        #[arg(long)]
        amount: f64,

        /// OWS wallet name for signing
        #[arg(long, env = "OWS_WALLET")]
        ows_wallet: String,
    },

    /// Show open positions
    Positions {
        /// OWS wallet name
        #[arg(long, env = "OWS_WALLET")]
        ows_wallet: String,
    },

    /// Sell all positions and sweep funds back to ZEC
    Sweep {
        /// OWS wallet name
        #[arg(long, env = "OWS_WALLET")]
        ows_wallet: String,

        /// After selling, swap USDT back to shielded ZEC
        #[arg(long, default_value = "true")]
        to_zec: bool,
    },

    /// Autonomous agent: scan → research → analyze → bet (Kelly-sized)
    Agent {
        /// Maximum bet amount in USDT (hard risk cap)
        #[arg(long, default_value = "5.0")]
        max_bet: f64,

        /// Minimum edge (%) to trigger a bet. e.g. 5 = need 5% edge over market
        #[arg(long, default_value = "5.0")]
        min_edge_pct: f64,

        /// Available bankroll in USDT (for Kelly position sizing)
        #[arg(long, default_value = "50.0")]
        bankroll: f64,

        /// Number of markets to scan
        #[arg(long, default_value = "50")]
        scan_limit: u32,

        /// OWS wallet name for signing
        #[arg(long, env = "OWS_WALLET")]
        ows_wallet: String,

        /// Dry run: scan, research, analyze but don't execute
        #[arg(long)]
        dry_run: bool,
    },
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

pub struct Config {
    pub data_dir: String,
    pub server_url: String,
    pub network: Network,
    pub human: bool,
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

pub fn ensure_data_dir(data_dir: &str) -> Result<()> {
    std::fs::create_dir_all(data_dir)?;
    Ok(())
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

#[tokio::main]
async fn main() {
    let cli = Cli::parse();
    let cfg = resolve_config(&cli);

    let log_level = if cli.human {
        tracing::Level::INFO
    } else {
        std::env::var("ZIPHER_LOG")
            .ok()
            .and_then(|v| v.parse().ok())
            .unwrap_or(tracing::Level::WARN)
    };
    tracing_subscriber::fmt()
        .with_max_level(log_level)
        .with_target(false)
        .init();

    let result: Result<()> = match cli.command {
        Commands::Info => {
            wallet::cmd_info(&cfg).await;
            Ok(())
        }
        Commands::Wallet(sub) => match sub {
            WalletCmd::Create => wallet::cmd_wallet_create(&cfg).await,
            WalletCmd::Restore { birthday } => wallet::cmd_wallet_restore(&cfg, birthday).await,
            WalletCmd::Delete { confirm } => wallet::cmd_wallet_delete(&cfg, confirm).await,
        },
        Commands::Sync(sub) => match sub {
            SyncCmd::Start => wallet::cmd_sync_start(&cfg).await,
            SyncCmd::Status => wallet::cmd_sync_status(&cfg).await,
        },
        Commands::Balance => wallet::cmd_balance(&cfg).await,
        Commands::Address => wallet::cmd_address(&cfg).await,
        Commands::Keys => wallet::cmd_keys(&cfg).await,
        Commands::Transactions { limit } => wallet::cmd_transactions(&cfg, limit).await,
        Commands::Send(sub) => match sub {
            SendCmd::Propose { to, amount, memo, context_id } => {
                wallet::cmd_send_propose(&cfg, to, amount, memo, context_id).await
            }
            SendCmd::Confirm => wallet::cmd_send_confirm(&cfg).await,
            SendCmd::Max { to } => wallet::cmd_send_max(&cfg, to).await,
            SendCmd::Pczt { to, amount, memo } => {
                market::cmd_send_pczt(&cfg, to, amount, memo).await
            }
        },
        Commands::Shield => wallet::cmd_shield(&cfg).await,
        Commands::Policy(sub) => match sub {
            PolicyCmd::Show => policy::cmd_policy_show(&cfg).await,
            PolicyCmd::Set { field, value } => policy::cmd_policy_set(&cfg, field, value).await,
            PolicyCmd::AddAllowlist { address } => policy::cmd_policy_add_allowlist(&cfg, address).await,
            PolicyCmd::RemoveAllowlist { address } => policy::cmd_policy_remove_allowlist(&cfg, address).await,
        },
        Commands::Audit { limit, since } => policy::cmd_audit(&cfg, limit, since).await,
        Commands::Daemon(sub) => match sub {
            DaemonCmd::Start => daemon::cmd_start(&cfg).await,
            DaemonCmd::Status => daemon::cmd_status(&cfg).await,
            DaemonCmd::Stop => daemon::cmd_stop(&cfg).await,
            DaemonCmd::Lock => daemon::cmd_lock(&cfg).await,
            DaemonCmd::Unlock => daemon::cmd_unlock(&cfg).await,
        },
        Commands::X402(sub) => match sub {
            X402Cmd::Propose { body, context_id } => {
                payment::cmd_x402_propose(&cfg, body, context_id).await
            }
            X402Cmd::Pay { body, context_id } => {
                payment::cmd_x402_pay(&cfg, body, context_id).await
            }
        },
        Commands::Pay { url, context_id, method } => {
            payment::cmd_pay(&cfg, url, context_id, method).await
        }
        Commands::Swap(sub) => match sub {
            SwapCmd::Tokens => swap::cmd_swap_tokens(&cfg).await,
            SwapCmd::Quote { to, chain, amount, recipient, slippage } => {
                swap::cmd_swap_quote(&cfg, to, chain, amount, recipient, slippage).await
            }
            SwapCmd::Execute { to, chain, amount, recipient, slippage, context_id } => {
                swap::cmd_swap_execute(&cfg, to, chain, amount, recipient, slippage, context_id).await
            }
            SwapCmd::Status { deposit_address } => {
                swap::cmd_swap_status(&cfg, deposit_address).await
            }
        },
        Commands::Session(sub) => match sub {
            SessionCmd::Open { server_url, deposit, merchant_id, pay_to, context_id } => {
                session::cmd_session_open(&cfg, server_url, deposit, merchant_id, pay_to, context_id).await
            }
            SessionCmd::Request { url, method } => {
                session::cmd_session_request(&cfg, url, method).await
            }
            SessionCmd::List => session::cmd_session_list(&cfg).await,
            SessionCmd::Close { session_id } => session::cmd_session_close(&cfg, session_id).await,
        },
        Commands::Market(sub) => match sub {
            MarketCmd::List { keyword, limit } => market::cmd_market_list(&cfg, keyword, limit).await,
            MarketCmd::Show { id } => market::cmd_market_show(&cfg, id).await,
            MarketCmd::Bet { id, outcome, amount, ows_wallet } => {
                market::cmd_market_bet(&cfg, id, outcome, amount, ows_wallet).await
            }
            MarketCmd::Positions { ows_wallet } => market::cmd_market_positions(&cfg, ows_wallet).await,
            MarketCmd::Sweep { ows_wallet, to_zec } => market::cmd_market_sweep(&cfg, ows_wallet, to_zec).await,
            MarketCmd::Agent { max_bet, min_edge_pct, bankroll, scan_limit, ows_wallet, dry_run } => {
                market::cmd_market_agent(&cfg, max_bet, min_edge_pct, bankroll, scan_limit, ows_wallet, dry_run).await
            }
        },
        Commands::Serve { port, price } => {
            serve::cmd_serve(&cfg, port, price).await;
            Ok(())
        },
        Commands::Sweep { token, chain, ows_wallet } => {
            payment::cmd_sweep(&cfg, token, chain, ows_wallet).await
        },
    };

    if let Err(e) = result {
        print_err(&e, cfg.human);
        std::process::exit(1);
    }
}
