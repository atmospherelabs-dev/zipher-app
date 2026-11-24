//! `zipher-relay [--listen ADDR] [--state FILE]
//!               [--apns-key AuthKey.p8 --apns-key-id ID --apns-team-id ID [--apns-topic BUNDLE]]`
//!
//! Without the APNs flags the relay works but phones only see requests while
//! Zipher is open.
//!
//! Defaults to 127.0.0.1:8787 behind a TLS-terminating proxy. Configure the
//! proxy not to write access logs for this host: the relay itself logs no
//! client addresses or request contents.

use std::path::PathBuf;
use std::time::Duration;

use zipher_relay::Relay;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let mut listen = "127.0.0.1:8787".to_string();
    let mut state = None;
    let (mut apns_key, mut apns_key_id, mut apns_team_id) = (None, None, None);
    let mut apns_topic = "dev.atmospherelabs.zipher".to_string();
    let mut args = std::env::args().skip(1);
    while let Some(a) = args.next() {
        match a.as_str() {
            "--listen" => listen = args.next().ok_or_else(|| anyhow::anyhow!("--listen needs a value"))?,
            "--state" => state = Some(PathBuf::from(args.next().ok_or_else(|| anyhow::anyhow!("--state needs a value"))?)),
            "--apns-key" => apns_key = Some(args.next().ok_or_else(|| anyhow::anyhow!("--apns-key needs a file"))?),
            "--apns-key-id" => apns_key_id = Some(args.next().ok_or_else(|| anyhow::anyhow!("--apns-key-id needs a value"))?),
            "--apns-team-id" => apns_team_id = Some(args.next().ok_or_else(|| anyhow::anyhow!("--apns-team-id needs a value"))?),
            "--apns-topic" => apns_topic = args.next().ok_or_else(|| anyhow::anyhow!("--apns-topic needs a value"))?,
            "-h" | "--help" => {
                println!("zipher-relay [--listen ADDR] [--state FILE]");
                return Ok(());
            }
            other => anyhow::bail!("unknown argument: {other}"),
        }
    }

    let mut relay = Relay::new(state);
    let push = match (apns_key, apns_key_id, apns_team_id) {
        (Some(file), Some(key_id), Some(team_id)) => {
            let pem = std::fs::read_to_string(&file)?;
            relay = relay.with_apns(zipher_relay::push::Apns::new(&pem, &key_id, &team_id, &apns_topic, None)?);
            "on"
        }
        (None, None, None) => "off",
        _ => anyhow::bail!("--apns-key, --apns-key-id and --apns-team-id go together"),
    };
    let restored = relay.load().await?;
    let sweeper = relay.clone();
    tokio::spawn(async move {
        let mut tick = tokio::time::interval(Duration::from_secs(30));
        loop {
            tick.tick().await;
            sweeper.sweep().await;
        }
    });

    let listener = tokio::net::TcpListener::bind(&listen).await?;
    eprintln!("zipher-relay listening on {listen} ({restored} paired channels restored, push {push})");
    axum::serve(listener, relay.router())
        .with_graceful_shutdown(async {
            let _ = tokio::signal::ctrl_c().await;
        })
        .await?;
    Ok(())
}
