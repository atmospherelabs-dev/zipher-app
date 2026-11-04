use std::io::{self, IsTerminal as _, Write as _};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use anyhow::Result;
use secrecy::{ExposeSecret, SecretString};
use serde::Serialize;
use zcash_protocol::consensus::Network;

use crate::helpers::*;
use crate::{ensure_data_dir, print_ok, Config};

pub async fn cmd_info(cfg: &Config) {
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
        network: if cfg.network == Network::TestNetwork {
            "testnet"
        } else {
            "mainnet"
        }
        .to_string(),
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

pub async fn cmd_wallet_init(cfg: &Config) -> Result<()> {
    let ows_passphrase = ows_passphrase()?;
    reject_legacy_seed(&cfg.data_dir)?;
    let db_path = std::path::PathBuf::from(&cfg.data_dir).join("zipher-data.sqlite");
    if db_path.try_exists()? {
        return Err(anyhow::anyhow!(
            "Wallet already exists in {}. Keep it intact and use a new --data-dir.",
            cfg.data_dir,
        ));
    }
    // Reject a corrupt operator policy before creating or opening a vault.
    checked_wallet_policy(&cfg.data_dir)?;

    let ows_wallet_name = std::env::var("OWS_WALLET").unwrap_or_else(|_| "default".to_string());

    // Check if OWS vault already has a wallet with this name
    let seed_phrase = if ows_lib::get_wallet(&ows_wallet_name, None).is_ok() {
        eprintln!(
            "OWS wallet '{}' already exists — reusing it.",
            ows_wallet_name
        );
        let exported = SecretString::new(ows_lib::export_wallet(&ows_wallet_name, Some(ows_passphrase.expose_secret()), None)
            .map_err(|_| anyhow::anyhow!("Cannot unlock the selected OWS wallet with OWS_PASSPHRASE. Existing vaults are unchanged; see docs/cli-wallet-security.md for migration."))?);
        if !exported.expose_secret().contains(' ') || exported.expose_secret().starts_with('{') {
            return Err(anyhow::anyhow!(
                "OWS wallet '{}' is a private-key wallet, not mnemonic. \
                 Zcash requires a mnemonic wallet for ZIP-32 key derivation.",
                ows_wallet_name,
            ));
        }
        exported
    } else {
        let wallet_info = ows_lib::create_wallet(
            &ows_wallet_name,
            Some(24),
            Some(ows_passphrase.expose_secret()),
            None,
        )
        .map_err(|e| anyhow::anyhow!("Failed to create OWS wallet: {}", e))?;
        eprintln!(
            "Created OWS vault wallet '{}' (id: {})",
            ows_wallet_name, wallet_info.id
        );

        SecretString::new(ows_lib::export_wallet(&ows_wallet_name, Some(ows_passphrase.expose_secret()), None)
            .map_err(|_| anyhow::anyhow!("Cannot unlock the newly encrypted OWS wallet. Its recovery material is retained."))?)
    };

    ensure_data_dir(&cfg.data_dir)?;
    let default_policy = ensure_wallet_policy(&cfg.data_dir)?;
    ensure_sapling_params(&cfg.data_dir).await?;
    let height = zipher_engine::wallet::fetch_latest_height(&cfg.server_url).await? as u32;

    zipher_engine::wallet::restore(
        &cfg.data_dir,
        &cfg.server_url,
        cfg.network,
        seed_phrase.expose_secret(),
        height,
        None,
        None, // no Zipher vault — seed lives in OWS vault
    )
    .await?;

    // Get the wallet address for the MCP config
    let addresses = zipher_engine::query::get_addresses()
        .await
        .unwrap_or_default();
    let address = addresses
        .first()
        .map(|a| a.address.clone())
        .unwrap_or_default();

    zipher_engine::wallet::close().await;

    let mcp_config = serde_json::json!({
        "mcpServers": {
            "zipher": {
                "command": "zipher-mcp-server",
            }
        }
    });

    #[derive(Serialize)]
    struct InitResult {
        birthday: u32,
        address: String,
        data_dir: String,
        ows_wallet: String,
        policy: zipher_engine::policy::SpendingPolicy,
        mcp_config: serde_json::Value,
        recovery_backup_command: &'static str,
    }

    let result = InitResult {
        birthday: height,
        address: address.clone(),
        data_dir: cfg.data_dir.clone(),
        ows_wallet: ows_wallet_name.clone(),
        policy: default_policy,
        mcp_config: mcp_config.clone(),
        recovery_backup_command: "zipher --human wallet backup --show-recovery",
    };

    print_ok(result, cfg.human, |r| {
        println!("Wallet initialized.");
        println!();
        println!("  Recovery phrase encrypted in OWS; not included in command output.");
        println!("  Private-terminal backup: {}", r.recovery_backup_command);
        println!();
        println!("  Address:    {}", r.address);
        println!("  Birthday:   {}", r.birthday);
        println!("  Data dir:   {}", r.data_dir);
        println!(
            "  OWS wallet: {} (encrypted at ~/.ows/wallets/)",
            r.ows_wallet
        );
        println!();
        println!("  Spending policy:");
        println!(
            "    max_per_tx:         {} ZAT ({:.4} ZEC)",
            r.policy.max_per_tx,
            r.policy.max_per_tx as f64 / 1e8
        );
        println!(
            "    daily_limit:        {} ZAT ({:.4} ZEC)",
            r.policy.daily_limit,
            r.policy.daily_limit as f64 / 1e8
        );
        println!(
            "    approval_threshold: {} ZAT ({:.4} ZEC)",
            r.policy.approval_threshold,
            r.policy.approval_threshold as f64 / 1e8
        );
        println!("    Edit: {}/policy.toml", r.data_dir);
        println!();
        println!("  MCP config (add to Claude/Cursor settings):");
        println!("  {}", serde_json::to_string_pretty(&r.mcp_config).unwrap());
        println!();
        println!("  Fund the wallet, then your AI agent can spend shielded ZEC.");
    });
    Ok(())
}

fn checked_wallet_policy(data_dir: &str) -> Result<zipher_engine::policy::SpendingPolicy> {
    let path = std::path::Path::new(data_dir).join("policy.toml");
    match std::fs::symlink_metadata(&path) {
        Ok(metadata) => {
            if !metadata.is_file() || metadata.file_type().is_symlink() {
                anyhow::bail!("policy.toml must be a regular file. Existing policy and recovery material are unchanged.");
            }
            zipher_engine::policy::load_policy_checked(data_dir)
                .map_err(|_| anyhow::anyhow!("Cannot read or parse policy.toml. Fix the existing policy before initializing or restoring; it was not overwritten."))
        }
        Err(error) if error.kind() == io::ErrorKind::NotFound => {
            Ok(zipher_engine::policy::SpendingPolicy {
                max_per_tx: 1_000_000,
                daily_limit: 10_000_000,
                approval_threshold: 5_000_000,
                require_context_id: false,
                min_spend_interval_ms: 0,
                allowlist: Vec::new(),
            })
        }
        Err(error) => Err(error.into()),
    }
}

fn ensure_wallet_policy(data_dir: &str) -> Result<zipher_engine::policy::SpendingPolicy> {
    let policy = checked_wallet_policy(data_dir)?;
    let path = std::path::Path::new(data_dir).join("policy.toml");
    // Never replace an operator's policy, including one created concurrently.
    match std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(path)
    {
        Ok(mut file) => file.write_all(toml::to_string_pretty(&policy)?.as_bytes())?,
        Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {
            return checked_wallet_policy(data_dir)
        }
        Err(error) => return Err(error.into()),
    }
    Ok(policy)
}

fn import_restored_seed(
    wallet_name: &str,
    seed: &SecretString,
    passphrase: &SecretString,
    vault_path: Option<&std::path::Path>,
) -> Result<()> {
    // Keep this check at the storage boundary too: callers and tests cannot
    // accidentally create an empty-credential vault through this entry point.
    if passphrase.expose_secret().trim().is_empty() {
        anyhow::bail!("A nonempty OWS_PASSPHRASE is required before importing recovery material.");
    }
    // OWS's vault lookup creates its directory. Validate through its pure
    // derivation API first so an invalid mnemonic cannot mutate storage.
    ows_lib::derive_address(seed.expose_secret(), "evm", Some(0)).map_err(|_| {
        anyhow::anyhow!("Invalid recovery mnemonic; no wallet or vault was created.")
    })?;
    ows_lib::import_wallet_mnemonic(
        wallet_name,
        seed.expose_secret(),
        Some(passphrase.expose_secret()),
        Some(0),
        vault_path,
    )
    .map_err(|_| {
        anyhow::anyhow!(
            "Encrypted OWS import failed. Use a valid mnemonic, an unused OWS_WALLET name \
         and a writable private vault directory. No existing recovery material was removed."
        )
    })?;
    Ok(())
}

pub async fn cmd_wallet_restore(cfg: &Config, seed_stdin: bool, birthday: u32) -> Result<()> {
    let passphrase = ows_passphrase()?;
    reject_legacy_seed(&cfg.data_dir)?;
    if !seed_stdin {
        anyhow::bail!("Restore requires --seed-stdin with redirected or piped recovery input. Do not put seed words in command arguments.");
    }
    let input = io::stdin();
    let seed = read_seed_input(input.lock(), input.is_terminal())?;

    let db_path = std::path::PathBuf::from(&cfg.data_dir).join("zipher-data.sqlite");
    if db_path.try_exists()? {
        anyhow::bail!("A wallet already exists in this data directory. Restore into a new --data-dir; keep the original wallet and recovery material.");
    }
    checked_wallet_policy(&cfg.data_dir)?;
    let wallet_name = std::env::var("OWS_WALLET").unwrap_or_else(|_| "default".to_string());
    import_restored_seed(&wallet_name, &seed, &passphrase, None)?;

    // Persist encrypted recovery material before any network-dependent wallet
    // initialization. If initialization fails, keep that vault for recovery.
    ensure_data_dir(&cfg.data_dir)?;
    ensure_wallet_policy(&cfg.data_dir)?;
    ensure_sapling_params(&cfg.data_dir).await?;

    eprintln!("Restoring wallet from seed (birthday={})...", birthday);

    zipher_engine::wallet::restore(
        &cfg.data_dir,
        &cfg.server_url,
        cfg.network,
        seed.expose_secret(),
        birthday,
        None,
        None,
    )
    .await?;

    let addresses = zipher_engine::query::get_addresses()
        .await
        .unwrap_or_default();
    let address = addresses
        .first()
        .map(|a| a.address.clone())
        .unwrap_or_default();

    zipher_engine::wallet::close().await;

    eprintln!("Wallet restored.");
    eprintln!("  Address:  {}", address);
    eprintln!("  Birthday: {}", birthday);
    eprintln!("  Data dir: {}", cfg.data_dir);
    eprintln!("  Recovery material: encrypted OWS wallet {wallet_name}");
    eprintln!("  Private-terminal backup: zipher --human wallet backup --show-recovery");

    Ok(())
}

pub fn cmd_wallet_backup(cfg: &Config, show_recovery: bool) -> Result<()> {
    validate_recovery_display(
        cfg.human,
        show_recovery,
        io::stdin().is_terminal(),
        io::stdout().is_terminal(),
    )?;
    let seed = read_seed(&cfg.data_dir)?;
    eprintln!("WARNING: This phrase controls all wallet funds. Use a private, unrecorded terminal; scrollback may retain it. Store a verified offline backup and never share it.");
    println!("{}", seed.expose_secret());
    Ok(())
}

pub async fn cmd_wallet_delete(cfg: &Config, confirm: bool) -> Result<()> {
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

pub async fn cmd_sync_start(cfg: &Config) -> Result<()> {
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
                eprint!(
                    "\r  {}/{} ({:.1}%)    ",
                    p.synced_height, p.latest_height, pct
                );
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

pub async fn cmd_sync_status(cfg: &Config) -> Result<()> {
    auto_open(cfg).await?;

    let synced = zipher_engine::query::get_synced_height().await?;
    let birthday = zipher_engine::query::get_birthday().await?;

    #[derive(Serialize)]
    struct SyncStatus {
        synced_height: u32,
        birthday: u32,
    }

    let status = SyncStatus {
        synced_height: synced,
        birthday,
    };

    print_ok(status, cfg.human, |s| {
        println!("Synced height: {}", s.synced_height);
        println!("Birthday:      {}", s.birthday);
    });

    zipher_engine::wallet::close().await;
    Ok(())
}

pub async fn cmd_balance(cfg: &Config) -> Result<()> {
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

pub async fn cmd_address(cfg: &Config) -> Result<()> {
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
                    if a.has_transparent {
                        Some("transparent")
                    } else {
                        None
                    },
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

pub async fn cmd_keys(cfg: &Config) -> Result<()> {
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

pub async fn cmd_transactions(cfg: &Config, limit: usize) -> Result<()> {
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

fn checked_send_policy(
    data_dir: &str,
    address: &str,
    amount: u64,
    fee: u64,
    context_id: &Option<String>,
) -> Result<zipher_engine::policy::SpendingPolicy> {
    let policy = checked_wallet_policy(data_dir)?;
    let total = amount
        .checked_add(fee)
        .ok_or_else(|| anyhow::anyhow!("Payment total overflow"))?;
    let spent = zipher_engine::audit::daily_spent(data_dir)?;
    zipher_engine::policy::check_proposal(&policy, address, total, context_id, spent)
        .map_err(|violation| anyhow::anyhow!("{violation}"))?;
    zipher_engine::policy::check_rate_limit(&policy)
        .map_err(|violation| anyhow::anyhow!("{violation}"))?;
    Ok(policy)
}

#[cfg(test)]
mod send_policy_review_tests {
    use super::*;

    struct Fixture(std::path::PathBuf);
    impl Fixture {
        fn new() -> Self {
            let path = std::env::temp_dir().join(format!(
                "zipher-cli-fee-policy-{}-{}",
                std::process::id(),
                std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .unwrap()
                    .as_nanos()
            ));
            std::fs::create_dir(&path).unwrap();
            Self(path)
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn policy_counts_fees_and_reservations_without_double_counting_settlement() {
        let fixture = Fixture::new();
        let directory = fixture.0.to_str().unwrap();
        std::fs::write(
            fixture.0.join("policy.toml"),
            "max_per_tx = 100\ndaily_limit = 100\n",
        )
        .unwrap();
        assert!(checked_send_policy(directory, "recipient", 90, 11, &None).is_err());
        let policy = checked_send_policy(directory, "recipient", 90, 10, &None).unwrap();
        let reservation =
            zipher_engine::audit::reserve_spend(directory, "recipient", 90, 10, &None, &policy)
                .unwrap();
        assert_eq!(
            zipher_engine::audit::daily_spent(directory).unwrap(),
            100,
            "uncertain submissions retain their budget"
        );
        assert!(checked_send_policy(directory, "recipient", 1, 1, &None).is_err());
        zipher_engine::audit::settle_spend(directory, reservation, "disposable-txid").unwrap();
        zipher_engine::audit::log_event(
            directory,
            "confirm_send",
            Some("recipient"),
            Some(90),
            Some(10),
            None,
            Some("disposable-txid"),
            None,
        )
        .unwrap();
        assert_eq!(zipher_engine::audit::daily_spent(directory).unwrap(), 100);
        std::fs::write(fixture.0.join("policy.toml"), "max_per_tx = [broken").unwrap();
        assert!(checked_send_policy(directory, "recipient", 1, 1, &None).is_err());
    }

    #[tokio::test]
    async fn confirm_rejects_an_old_unbound_record_before_network_or_credentials() {
        let fixture = Fixture::new();
        std::fs::write(fixture.0.join("pending_proposal.json"),r#"{"address":"recipient","amount":70000,"memo":null,"is_max":false,"context_id":null}"#).unwrap();
        let cfg = Config {
            data_dir: fixture.0.to_str().unwrap().into(),
            server_url: "https://no-network.invalid".into(),
            network: Network::MainNetwork,
            human: false,
        };
        let error = cmd_send_confirm(&cfg).await.unwrap_err().to_string();
        assert!(error.contains("Legacy or unbound"));
        assert_eq!(
            std::fs::read_dir(&fixture.0).unwrap().count(),
            1,
            "no parameter download, audit write or vault access"
        );
    }
}

pub async fn cmd_send_propose(
    cfg: &Config,
    to: String,
    amount: u64,
    is_max: bool,
    memo: Option<String>,
    context_id: Option<String>,
    priority: bool,
) -> Result<()> {
    checked_wallet_policy(&cfg.data_dir)?;
    invalidate_pending_review(&cfg.data_dir)?;
    sync_if_needed(cfg).await?;

    auto_open(cfg).await?;

    let (send_amount, fee, _) =
        zipher_engine::send::propose_send(&to, amount, memo.clone(), is_max, priority).await?;

    checked_send_policy(&cfg.data_dir, &to, send_amount, fee, &context_id)?;
    let mut pending = PendingProposal {
        address: to.clone(),
        amount: if is_max { send_amount } else { amount },
        memo: memo.clone(),
        is_max,
        context_id: context_id.clone(),
        review: None,
    };
    pending.bind_review(
        cfg,
        priority,
        send_amount,
        fee,
        zipher_engine::send::pending_review_branch()?,
        now_unix_secs()?,
    )?;
    save_pending(&cfg.data_dir, &pending)?;

    zipher_engine::audit::log_event(
        &cfg.data_dir,
        "propose_send",
        Some(&to),
        Some(send_amount),
        Some(fee),
        context_id.as_deref(),
        None,
        None,
    )
    .ok();

    #[derive(Serialize)]
    struct ProposalSummary {
        address: String,
        send_amount: u64,
        fee: u64,
        total: u64,
        send_amount_zec: f64,
        fee_zec: f64,
        priority: bool,
    }

    let summary = ProposalSummary {
        address: to.clone(),
        send_amount,
        fee,
        total: send_amount
            .checked_add(fee)
            .ok_or_else(|| anyhow::anyhow!("Payment total overflow"))?,
        send_amount_zec: send_amount as f64 / 1e8,
        fee_zec: fee as f64 / 1e8,
        priority,
    };

    print_ok(summary, cfg.human, |s| {
        println!("Proposal created:");
        println!("  To:     {}", s.address);
        println!(
            "  Amount: {:.8} ZEC ({} zat)",
            s.send_amount_zec, s.send_amount
        );
        println!("  Fee:    {:.8} ZEC ({} zat)", s.fee_zec, s.fee);
        println!("  Total:  {} zat", s.total);
        println!();
        println!("Run `zipher-cli send confirm` to sign and broadcast.");
    });

    zipher_engine::wallet::close().await;
    Ok(())
}

pub async fn cmd_send_confirm(cfg: &Config) -> Result<()> {
    let pending = load_pending(&cfg.data_dir)?;
    let priority = pending.validate_review(cfg, now_unix_secs()?)?.priority;
    checked_send_policy(
        &cfg.data_dir,
        &pending.address,
        pending.amount,
        pending
            .review
            .as_ref()
            .ok_or_else(|| anyhow::anyhow!("Review unavailable"))?
            .fee,
        &pending.context_id,
    )?;
    ensure_sapling_params(&cfg.data_dir).await?;
    sync_if_needed(cfg).await?;

    auto_open(cfg).await?;

    let (send_amount, fee, _) = zipher_engine::send::propose_send(
        &pending.address,
        pending.amount,
        pending.memo.clone(),
        pending.is_max,
        priority,
    )
    .await?;
    let fresh_branch = zipher_engine::send::pending_review_branch()?;
    pending.validate_fresh_totals(cfg, send_amount, fee, fresh_branch, now_unix_secs()?)?;
    zipher_engine::send::preflight_confirm_send().await?;
    checked_send_policy(
        &cfg.data_dir,
        &pending.address,
        send_amount,
        fee,
        &pending.context_id,
    )?;
    pending.validate_fresh_totals(cfg, send_amount, fee, fresh_branch, now_unix_secs()?)?;

    if cfg.human {
        let zec = send_amount as f64 / 1e8;
        let fee_zec = fee as f64 / 1e8;
        eprintln!(
            "Confirming: {:.8} ZEC + {:.8} fee to {}",
            zec, fee_zec, pending.address
        );
    }

    // Claim once before credentials/reservation: concurrent CLI confirmations
    // cannot both reserve or sign the same persisted review. A failed attempt
    // requires a fresh review, including after an ambiguous broadcast.
    consume_pending(&cfg.data_dir, &pending)?;
    let seed = read_seed(&cfg.data_dir)?;
    pending.validate_fresh_totals(cfg, send_amount, fee, fresh_branch, now_unix_secs()?)?;
    let policy = checked_send_policy(
        &cfg.data_dir,
        &pending.address,
        send_amount,
        fee,
        &pending.context_id,
    )?;
    let reservation = zipher_engine::audit::reserve_spend(
        &cfg.data_dir,
        &pending.address,
        send_amount,
        fee,
        &pending.context_id,
        &policy,
    )?;
    let txid = match zipher_engine::send::confirm_send(&seed).await {
        Ok(txid) => {
            zipher_engine::audit::settle_spend(&cfg.data_dir, reservation, &txid)
                .map_err(|error| anyhow::anyhow!("Transaction broadcast as {txid}, but its budget receipt needs reconciliation: {error}. Check its status before another payment."))?;
            zipher_engine::policy::record_confirm();
            zipher_engine::audit::log_event(
                &cfg.data_dir,
                "confirm_send",
                Some(&pending.address),
                Some(send_amount),
                Some(fee),
                pending.context_id.as_deref(),
                Some(&txid),
                None,
            )
            .ok();
            txid
        }
        Err(e) => {
            zipher_engine::audit::log_event(
                &cfg.data_dir,
                "confirm_send",
                Some(&pending.address),
                Some(send_amount),
                Some(fee),
                pending.context_id.as_deref(),
                None,
                Some(&format!("{:#}", e)),
            )
            .ok();
            return Err(e);
        }
    };

    #[derive(Serialize)]
    struct SendResult {
        txid: String,
        amount: u64,
        fee: u64,
        address: String,
    }

    print_ok(
        SendResult {
            txid: txid.clone(),
            amount: send_amount,
            fee,
            address: pending.address.clone(),
        },
        cfg.human,
        |r| {
            println!("Transaction broadcast.");
            println!("  txid: {}", r.txid);
        },
    );

    zipher_engine::wallet::close().await;
    Ok(())
}

pub async fn cmd_send_max(cfg: &Config, to: String) -> Result<()> {
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
            println!(
                "Max sendable to {}: {:.8} ZEC ({} zat)",
                m.address, m.max_amount_zec, m.max_amount
            );
        },
    );

    zipher_engine::wallet::close().await;
    Ok(())
}

pub async fn cmd_shield(cfg: &Config) -> Result<()> {
    ensure_sapling_params(&cfg.data_dir).await?;
    auto_open(cfg).await?;

    let seed = read_seed(&cfg.data_dir)?;
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

pub async fn cmd_consolidate(cfg: &Config) -> Result<()> {
    ensure_sapling_params(&cfg.data_dir).await?;
    force_sync(cfg).await?;
    auto_open(cfg).await?;

    let addresses = zipher_engine::query::get_addresses().await?;
    let own_addr = addresses
        .first()
        .map(|a| a.address.clone())
        .ok_or_else(|| anyhow::anyhow!("No address found — wallet may not be initialized"))?;

    if cfg.human {
        eprintln!("Consolidating shielded notes (send-to-self)...");
        eprintln!(
            "  Destination: {}...{}",
            &own_addr[..12],
            &own_addr[own_addr.len() - 8..]
        );
    }

    let (send_amount, fee, _) =
        zipher_engine::send::propose_send(&own_addr, 0, None, true, false).await?;

    if cfg.human {
        eprintln!(
            "  Amount: {:.8} ZEC (max minus fee)",
            send_amount as f64 / 1e8
        );
        eprintln!("  Fee:    {} zat", fee);
    }

    let seed = read_seed(&cfg.data_dir)?;
    let txid = zipher_engine::send::confirm_send(&seed).await?;

    #[derive(Serialize)]
    struct ConsolidateResult {
        txid: String,
        amount: u64,
        fee: u64,
    }

    print_ok(
        ConsolidateResult {
            txid: txid.clone(),
            amount: send_amount,
            fee,
        },
        cfg.human,
        |r| {
            println!("Notes consolidated successfully.");
            println!("  txid:   {}", r.txid);
            println!("  Amount: {:.8} ZEC", r.amount as f64 / 1e8);
            println!("  Fee:    {} zat", r.fee);
        },
    );

    zipher_engine::wallet::close().await;
    Ok(())
}

pub async fn cmd_store_signed_pczt(cfg: &Config, pczt_hex: String) -> Result<()> {
    let pczt_bytes = hex::decode(&pczt_hex).map_err(|e| anyhow::anyhow!("Invalid hex: {}", e))?;

    ensure_data_dir(&cfg.data_dir)?;
    auto_open(cfg).await?;

    if cfg.human {
        eprintln!(
            "Storing signed PCZT in wallet DB ({} bytes)...",
            pczt_bytes.len()
        );
    }

    let txid = zipher_engine::send::store_signed_pczt(&pczt_bytes).await?;

    #[derive(Serialize)]
    struct StorePcztResult {
        txid: String,
    }

    print_ok(StorePcztResult { txid: txid.clone() }, cfg.human, |r| {
        println!("Transaction stored: {}", r.txid);
        println!("Notes marked as spent — safe to create new PCZTs.");
    });

    zipher_engine::wallet::close().await;
    Ok(())
}

// ---------------------------------------------------------------------------
// Ironwood pool transfer (ZIP 318)
// ---------------------------------------------------------------------------

pub async fn cmd_ironwood_plan(cfg: &Config) -> Result<()> {
    sync_if_needed(cfg).await?;
    let result = async {
        let seed = read_seed(&cfg.data_dir)?;
        let plan = zipher_engine::ironwood_v2::plan(&seed).await?;
        print_ok(&plan, cfg.human, |p| {
            println!("Ironwood SDK transfer plan");
            println!("Amount: {} zat", p.total_migrating_zat);
            println!("Estimated fees: {} zat", p.estimated_total_fee_zat);
            println!(
                "Transactions: {} preparation + {} transfer",
                p.prep_tx_count, p.transfer_tx_count
            );
            println!("Use the wallet app to review and execute this transfer.");
        });
        Ok(())
    }
    .await;
    zipher_engine::wallet::close().await;
    result
}

pub async fn cmd_ironwood_status(cfg: &Config) -> Result<()> {
    auto_open(cfg).await?;
    let result = zipher_engine::ironwood_v2::status().await;
    zipher_engine::wallet::close().await;
    let report = result?;
    print_ok(&report, cfg.human, |r| {
        println!("Ironwood SDK transfer: {}", r.status);
        println!(
            "Confirmed: {}/{} transactions",
            r.confirmed_count, r.total_tx_count
        );
        println!("Confirmed amount: {} zat", r.total_confirmed_zat);
        println!("Next due height: {}", r.next_due_height);
    });
    Ok(())
}

// The removed scheduler only wrote a JSON file. It did not drive the current
// SDK's commit/prove/broadcast loop. Do not report a transfer as running or
// paused while the wallet's database-backed SDK runner is unaffected.
pub async fn cmd_ironwood_confirm(_cfg: &Config, _tor: bool) -> Result<()> {
    Err(anyhow::anyhow!("Headless Ironwood execution is not connected to the SDK runner. Use the wallet app to review and execute the transfer; no legacy JSON schedule was created."))
}

pub async fn cmd_ironwood_pause(_cfg: &Config) -> Result<()> {
    Err(anyhow::anyhow!("Headless pause cannot control the SDK migration runner. Use the wallet app managing this transfer. Nothing was paused."))
}

pub async fn cmd_ironwood_resume(_cfg: &Config) -> Result<()> {
    Err(anyhow::anyhow!("Headless resume is not connected to the SDK migration runner. Use the wallet app managing this transfer. Nothing was resumed."))
}

#[cfg(test)]
mod credential_storage_tests {
    use super::*;

    const TEST_SEED: &str = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";

    struct Fixture(std::path::PathBuf);
    impl Fixture {
        fn new() -> Self {
            Self(std::env::temp_dir().join(format!(
                    "zipher-restore-credential-test-{}-{}",
                    std::process::id(),
                    std::time::SystemTime::now()
                        .duration_since(std::time::UNIX_EPOCH)
                        .unwrap()
                        .as_nanos(),
                )))
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn restore_rejects_blank_credentials_and_invalid_mnemonic_without_storage_mutation() {
        let fixture = Fixture::new();
        let seed = SecretString::new(TEST_SEED.into());
        for passphrase in ["", " \t\n"] {
            assert!(import_restored_seed(
                "fixture",
                &seed,
                &SecretString::new(passphrase.into()),
                Some(&fixture.0)
            )
            .is_err());
            assert!(!fixture.0.exists());
        }
        assert!(import_restored_seed(
            "fixture",
            &SecretString::new("not a recovery mnemonic".into()),
            &SecretString::new("test-only credential".into()),
            Some(&fixture.0)
        )
        .is_err());
        assert!(!fixture.0.exists());
    }

    #[test]
    fn initialization_policy_is_conservative_and_preserves_existing_operator_policy() {
        let fixture = Fixture::new();
        let directory = fixture.0.to_str().unwrap();
        let defaults = checked_wallet_policy(directory).unwrap();
        assert_eq!(defaults.max_per_tx, 1_000_000);
        assert!(!fixture.0.exists());
        ensure_data_dir(directory).unwrap();
        ensure_wallet_policy(directory).unwrap();
        let path = fixture.0.join("policy.toml");
        let custom = "max_per_tx = 42\ndaily_limit = 84\n";
        std::fs::write(&path, custom).unwrap();
        assert_eq!(ensure_wallet_policy(directory).unwrap().max_per_tx, 42);
        assert_eq!(std::fs::read_to_string(&path).unwrap(), custom);
        std::fs::write(&path, "max_per_tx = [invalid").unwrap();
        assert!(checked_wallet_policy(directory).is_err());
        assert!(ensure_wallet_policy(directory).is_err());
        assert_eq!(
            std::fs::read_to_string(&path).unwrap(),
            "max_per_tx = [invalid"
        );
    }

    #[test]
    fn restored_seed_is_encrypted_in_ows_and_existing_vault_is_not_overwritten() {
        let fixture = Fixture::new();
        let seed = SecretString::new(TEST_SEED.into());
        let passphrase = SecretString::new("test-only nonempty credential".into());
        import_restored_seed("restored-fixture", &seed, &passphrase, Some(&fixture.0)).unwrap();
        assert!(!fixture.0.join(".seed").exists());
        let files: Vec<_> = std::fs::read_dir(fixture.0.join("wallets"))
            .unwrap()
            .map(|entry| entry.unwrap().path())
            .collect();
        assert_eq!(files.len(), 1);
        let encrypted = std::fs::read(&files[0]).unwrap();
        assert!(!encrypted
            .windows(TEST_SEED.len())
            .any(|bytes| bytes == TEST_SEED.as_bytes()));
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(
                std::fs::metadata(&files[0]).unwrap().permissions().mode() & 0o777,
                0o600
            );
        }
        assert!(ows_lib::export_wallet("restored-fixture", Some(""), Some(&fixture.0)).is_err());
        assert_eq!(
            ows_lib::export_wallet(
                "restored-fixture",
                Some(passphrase.expose_secret()),
                Some(&fixture.0)
            )
            .unwrap(),
            TEST_SEED
        );
        assert!(
            import_restored_seed("restored-fixture", &seed, &passphrase, Some(&fixture.0)).is_err()
        );
        assert_eq!(std::fs::read(&files[0]).unwrap(), encrypted);
        assert_eq!(
            std::fs::read_dir(fixture.0.join("wallets"))
                .unwrap()
                .count(),
            1
        );
    }
}
