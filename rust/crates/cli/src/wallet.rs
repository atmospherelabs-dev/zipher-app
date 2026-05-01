use std::io::{self, Write as _};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use anyhow::Result;
use serde::Serialize;
use zcash_protocol::consensus::Network;

use crate::helpers::*;
use crate::{print_ok, Config, ensure_data_dir};

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

pub async fn cmd_wallet_init(cfg: &Config) -> Result<()> {
    ensure_data_dir(&cfg.data_dir)?;
    ensure_sapling_params(&cfg.data_dir).await?;

    let db_path = std::path::PathBuf::from(&cfg.data_dir).join("zipher-data.sqlite");
    if db_path.exists() {
        return Err(anyhow::anyhow!(
            "Wallet already exists in {}. Use `wallet delete --confirm` first.",
            cfg.data_dir,
        ));
    }

    let ows_wallet_name = std::env::var("OWS_WALLET").unwrap_or_else(|_| "default".to_string());
    let ows_passphrase = std::env::var("OWS_PASSPHRASE").unwrap_or_default();

    // Check if OWS vault already has a wallet with this name
    let seed_phrase = if ows_lib::get_wallet(&ows_wallet_name, None).is_ok() {
        eprintln!("OWS wallet '{}' already exists — reusing it.", ows_wallet_name);
        let exported = ows_lib::export_wallet(&ows_wallet_name, Some(&ows_passphrase), None)
            .map_err(|e| anyhow::anyhow!("Failed to export OWS wallet: {}", e))?;
        if !exported.contains(' ') || exported.starts_with('{') {
            return Err(anyhow::anyhow!(
                "OWS wallet '{}' is a private-key wallet, not mnemonic. \
                 Zcash requires a mnemonic wallet for ZIP-32 key derivation.",
                ows_wallet_name,
            ));
        }
        exported
    } else {
        let wallet_info = ows_lib::create_wallet(&ows_wallet_name, Some(24), Some(&ows_passphrase), None)
            .map_err(|e| anyhow::anyhow!("Failed to create OWS wallet: {}", e))?;
        eprintln!("Created OWS vault wallet '{}' (id: {})", ows_wallet_name, wallet_info.id);

        ows_lib::export_wallet(&ows_wallet_name, Some(&ows_passphrase), None)
            .map_err(|e| anyhow::anyhow!("Failed to export seed from new wallet: {}", e))?
    };

    let height = zipher_engine::wallet::fetch_latest_height(&cfg.server_url).await? as u32;

    zipher_engine::wallet::restore(
        &cfg.data_dir,
        &cfg.server_url,
        cfg.network,
        &seed_phrase,
        height,
        None,
        None, // no Zipher vault — seed lives in OWS vault
    ).await?;

    // Create default spending policy
    let default_policy = zipher_engine::policy::SpendingPolicy {
        max_per_tx: 1_000_000,        // 0.01 ZEC
        daily_limit: 10_000_000,      // 0.1 ZEC
        approval_threshold: 5_000_000, // 0.05 ZEC
        require_context_id: false,
        min_spend_interval_ms: 0,
        allowlist: Vec::new(),
    };
    zipher_engine::policy::save_policy(&cfg.data_dir, &default_policy)?;

    // Get the wallet address for the MCP config
    let addresses = zipher_engine::query::get_addresses().await.unwrap_or_default();
    let address = addresses.first().map(|a| a.address.clone()).unwrap_or_default();

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
        seed_phrase: String,
        birthday: u32,
        address: String,
        data_dir: String,
        ows_wallet: String,
        policy: zipher_engine::policy::SpendingPolicy,
        mcp_config: serde_json::Value,
    }

    let result = InitResult {
        seed_phrase: seed_phrase.clone(),
        birthday: height,
        address: address.clone(),
        data_dir: cfg.data_dir.clone(),
        ows_wallet: ows_wallet_name.clone(),
        policy: default_policy,
        mcp_config: mcp_config.clone(),
    };

    print_ok(result, cfg.human, |r| {
        println!("Wallet initialized.");
        println!();
        println!("  SEED PHRASE (back this up — shown only once):");
        println!("  {}", r.seed_phrase);
        println!();
        println!("  Address:    {}", r.address);
        println!("  Birthday:   {}", r.birthday);
        println!("  Data dir:   {}", r.data_dir);
        println!("  OWS wallet: {} (encrypted at ~/.ows/wallets/)", r.ows_wallet);
        println!();
        println!("  Default policy:");
        println!("    max_per_tx:         {} ZAT ({:.4} ZEC)", r.policy.max_per_tx, r.policy.max_per_tx as f64 / 1e8);
        println!("    daily_limit:        {} ZAT ({:.4} ZEC)", r.policy.daily_limit, r.policy.daily_limit as f64 / 1e8);
        println!("    approval_threshold: {} ZAT ({:.4} ZEC)", r.policy.approval_threshold, r.policy.approval_threshold as f64 / 1e8);
        println!("    Edit: {}/policy.toml", r.data_dir);
        println!();
        println!("  MCP config (add to Claude/Cursor settings):");
        println!("  {}", serde_json::to_string_pretty(&r.mcp_config).unwrap());
        println!();
        println!("  Fund the wallet, then your AI agent can spend shielded ZEC.");
    });
    Ok(())
}

pub async fn cmd_wallet_create(cfg: &Config) -> Result<()> {
    ensure_data_dir(&cfg.data_dir)?;
    ensure_sapling_params(&cfg.data_dir).await?;

    let passphrase = vault_passphrase();
    let height = zipher_engine::wallet::fetch_latest_height(&cfg.server_url).await? as u32;
    let seed_phrase = zipher_engine::wallet::create(
        &cfg.data_dir,
        &cfg.server_url,
        cfg.network,
        height,
        None,
        Some(&passphrase),
    )
    .await?;

    #[derive(Serialize)]
    struct CreateResult {
        seed_phrase: String,
        birthday: u32,
        data_dir: String,
        vault: bool,
    }

    let result = CreateResult {
        seed_phrase: seed_phrase.clone(),
        birthday: height,
        data_dir: cfg.data_dir.clone(),
        vault: true,
    };

    print_ok(result, cfg.human, |r| {
        println!("Wallet created (seed stored in encrypted vault).");
        println!();
        println!("  SEED PHRASE (write this down as backup):");
        println!("  {}", r.seed_phrase);
        println!();
        println!("  Birthday: {}", r.birthday);
        println!("  Data dir: {}", r.data_dir);
        println!();
        println!("  The seed is encrypted in the vault. Set ZIPHER_VAULT_PASS to");
        println!("  protect it with a passphrase, or leave empty for agent mode.");
    });
    Ok(())
}

pub async fn cmd_wallet_restore(cfg: &Config, birthday: u32) -> Result<()> {
    ensure_data_dir(&cfg.data_dir)?;
    ensure_sapling_params(&cfg.data_dir).await?;

    let seed = read_seed(&cfg.data_dir)?;
    let passphrase = vault_passphrase();

    use secrecy::ExposeSecret;
    zipher_engine::wallet::restore(
        &cfg.data_dir,
        &cfg.server_url,
        cfg.network,
        seed.expose_secret(),
        birthday,
        None,
        Some(&passphrase),
    )
    .await?;

    #[derive(Serialize)]
    struct RestoreResult {
        birthday: u32,
        data_dir: String,
        vault: bool,
    }

    print_ok(
        RestoreResult { birthday, data_dir: cfg.data_dir.clone(), vault: true },
        cfg.human,
        |r| {
            println!("Wallet restored (seed stored in encrypted vault).");
            println!("  Birthday: {}", r.birthday);
            println!("  Data dir: {}", r.data_dir);
            println!("  Run `zipher-cli sync start` to scan the blockchain.");
        },
    );
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

pub async fn cmd_sync_status(cfg: &Config) -> Result<()> {
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

pub async fn cmd_send_propose(
    cfg: &Config,
    to: String,
    amount: u64,
    is_max: bool,
    memo: Option<String>,
    context_id: Option<String>,
) -> Result<()> {
    sync_if_needed(cfg).await?;
    let policy = zipher_engine::policy::load_policy(&cfg.data_dir);

    // For max sends, we don't know the amount until the engine produces the proposal,
    // so we skip the policy daily-limit check here. (The rate-limit check still runs
    // in cmd_send_confirm.)
    if !is_max {
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
    }

    auto_open(cfg).await?;

    let (send_amount, fee, _) =
        zipher_engine::send::propose_send(&to, amount, memo.clone(), is_max).await?;

    let pending = PendingProposal {
        address: to.clone(),
        amount: if is_max { send_amount } else { amount },
        memo: memo.clone(),
        is_max,
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

pub async fn cmd_send_confirm(cfg: &Config) -> Result<()> {
    ensure_sapling_params(&cfg.data_dir).await?;
    sync_if_needed(cfg).await?;
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

    let seed = read_seed(&cfg.data_dir)?;
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
            println!("Max sendable to {}: {:.8} ZEC ({} zat)", m.address, m.max_amount_zec, m.max_amount);
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
        eprintln!("  Destination: {}...{}", &own_addr[..12], &own_addr[own_addr.len()-8..]);
    }

    let (send_amount, fee, _) =
        zipher_engine::send::propose_send(&own_addr, 0, None, true).await?;

    if cfg.human {
        eprintln!("  Amount: {:.8} ZEC (max minus fee)", send_amount as f64 / 1e8);
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
        ConsolidateResult { txid: txid.clone(), amount: send_amount, fee },
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
    let pczt_bytes = hex::decode(&pczt_hex)
        .map_err(|e| anyhow::anyhow!("Invalid hex: {}", e))?;

    ensure_data_dir(&cfg.data_dir)?;
    auto_open(cfg).await?;

    if cfg.human {
        eprintln!("Storing signed PCZT in wallet DB ({} bytes)...", pczt_bytes.len());
    }

    let txid = zipher_engine::send::store_signed_pczt(&pczt_bytes).await?;

    #[derive(Serialize)]
    struct StorePcztResult {
        txid: String,
    }

    print_ok(
        StorePcztResult { txid: txid.clone() },
        cfg.human,
        |r| {
            println!("Transaction stored: {}", r.txid);
            println!("Notes marked as spent — safe to create new PCZTs.");
        },
    );

    zipher_engine::wallet::close().await;
    Ok(())
}
