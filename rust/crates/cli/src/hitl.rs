//! `zipher pair` / `zipher unpair`: link this agent to a Zipher phone for
//! approvals. Pairing is operator-only: the link contains a one-time secret,
//! so it is shown only in an interactive terminal and never written to disk.

use std::io::{self, IsTerminal as _};
use std::time::Duration;

use anyhow::{bail, Result};
use zipher_engine::hitl::{self, PairingProgress};

use crate::Config;

pub async fn cmd_pair(cfg: &Config, agent_name: &str, relay_url: Option<&str>) -> Result<()> {
    if !io::stdin().is_terminal() || !io::stdout().is_terminal() {
        bail!("`zipher pair` must run in an interactive terminal: the pairing link contains a one-time secret that agents must not see.");
    }
    let session = hitl::start_pairing(relay_url, agent_name).await?;
    let start = &session.start;

    println!();
    println!("  Scan this with Zipher on your phone (Settings > Agent approvals):");
    println!();
    match qrcode::QrCode::new(start.uri.as_bytes()) {
        Ok(code) => {
            let art = code
                .render::<qrcode::render::unicode::Dense1x2>()
                .dark_color(qrcode::render::unicode::Dense1x2::Light)
                .light_color(qrcode::render::unicode::Dense1x2::Dark)
                .quiet_zone(true)
                .build();
            for line in art.lines() {
                println!("  {line}");
            }
        }
        Err(_) => println!("  {}", start.uri),
    }
    println!();
    println!("  Check code: {}   (the phone must show the same code)", start.check_code);
    println!("  Relay:      {}", start.relay_url);
    println!("  Waiting up to {} minutes…", start.expires_in_secs / 60);

    loop {
        match session.poll(&cfg.data_dir).await? {
            PairingProgress::Waiting => tokio::time::sleep(Duration::from_secs(2)).await,
            PairingProgress::Paired => {
                println!();
                println!("  Paired. Sends above your approval threshold now ask your phone first.");
                println!("  Set the threshold with: zipher policy set approval_threshold <zatoshis>");
                return Ok(());
            }
            PairingProgress::Expired => bail!("The pairing code expired. Run `zipher pair` again."),
        }
    }
}

pub async fn cmd_unpair(cfg: &Config) -> Result<()> {
    hitl::unpair(&cfg.data_dir).await?;
    println!("Unpaired. Sends above the approval threshold are refused until you pair again.");
    Ok(())
}
