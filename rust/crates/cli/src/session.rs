use anyhow::Result;
use serde::Serialize;

use crate::helpers::*;
use crate::{print_ok, Config};

pub async fn cmd_session_open(
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
    let policy = zipher_engine::policy::load_policy(&cfg.data_dir);
    let daily_spent = zipher_engine::audit::daily_spent(&cfg.data_dir).unwrap_or(0);
    if let Err(violation) = zipher_engine::policy::check_proposal(
        &policy, &pay_to, deposit, &context_id, daily_spent,
    ) {
        zipher_engine::audit::log_event(
            &cfg.data_dir, "session_open", Some(&pay_to),
            Some(deposit), None, context_id.as_deref(),
            None, Some(&violation.to_string()),
        ).ok();
        return Err(anyhow::anyhow!("{}", violation));
    }
    if let Err(violation) = zipher_engine::policy::check_rate_limit(&policy) {
        zipher_engine::audit::log_event(
            &cfg.data_dir, "session_open", Some(&pay_to),
            Some(deposit), None, context_id.as_deref(),
            None, Some(&violation.to_string()),
        ).ok();
        return Err(anyhow::anyhow!("{}", violation));
    }

    let (send_amount, fee, _) =
        zipher_engine::send::propose_send(&pay_to, deposit, Some(memo), false).await?;

    let seed = read_seed(&cfg.data_dir)?;
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

pub async fn cmd_session_request(
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

pub async fn cmd_session_list(cfg: &Config) -> Result<()> {
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

pub async fn cmd_session_close(cfg: &Config, session_id: String) -> Result<()> {
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
