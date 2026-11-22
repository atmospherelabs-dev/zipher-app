//! `zipher-relay [--listen ADDR] [--state FILE]`
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
    let mut args = std::env::args().skip(1);
    while let Some(a) = args.next() {
        match a.as_str() {
            "--listen" => listen = args.next().ok_or_else(|| anyhow::anyhow!("--listen needs a value"))?,
            "--state" => state = Some(PathBuf::from(args.next().ok_or_else(|| anyhow::anyhow!("--state needs a value"))?)),
            "-h" | "--help" => {
                println!("zipher-relay [--listen ADDR] [--state FILE]");
                return Ok(());
            }
            other => anyhow::bail!("unknown argument: {other}"),
        }
    }

    let relay = Relay::new(state);
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
    eprintln!("zipher-relay listening on {listen} ({restored} paired channels restored)");
    axum::serve(listener, relay.router())
        .with_graceful_shutdown(async {
            let _ = tokio::signal::ctrl_c().await;
        })
        .await?;
    Ok(())
}
