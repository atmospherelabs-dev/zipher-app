use anyhow::Result;

use crate::{print_ok, Config, ensure_data_dir};

pub async fn cmd_policy_show(cfg: &Config) -> Result<()> {
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

pub async fn cmd_policy_set(cfg: &Config, field: String, value: String) -> Result<()> {
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

pub async fn cmd_policy_add_allowlist(cfg: &Config, address: String) -> Result<()> {
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

pub async fn cmd_policy_remove_allowlist(cfg: &Config, address: String) -> Result<()> {
    ensure_data_dir(&cfg.data_dir)?;
    let mut policy = zipher_engine::policy::load_policy(&cfg.data_dir);

    policy.allowlist.retain(|a| a != &address);
    zipher_engine::policy::save_policy(&cfg.data_dir, &policy)?;

    print_ok("removed", cfg.human, |_| {
        println!("Address removed from allowlist: {}", address);
    });
    Ok(())
}

pub async fn cmd_audit(cfg: &Config, limit: usize, since: Option<String>) -> Result<()> {
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
