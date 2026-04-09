use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use anyhow::Result;
use serde::Serialize;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixListener;
use zeroize::Zeroize;

use crate::helpers::*;
use crate::{print_ok, Config, ensure_data_dir};

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
            unsafe {
                return libc_kill(pid) == 0;
            }
        }
    }
    false
}

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

    let seed_str = read_seed(&cfg.data_dir)?;
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

    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&sock, std::fs::Permissions::from_mode(0o600))?;
    }

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
            let shutdown_ref = shutdown.clone();

            tokio::spawn(async move {
                let (reader, mut writer) = stream.into_split();
                let mut lines = BufReader::new(reader).lines();

                while let Ok(Some(line)) = lines.next_line().await {
                    let resp = handle_ipc_command(
                        &line, &state, &data_dir, &shutdown_ref,
                    ).await;
                    let _ = writer.write_all(resp.as_bytes()).await;
                    let _ = writer.write_all(b"\n").await;
                }
            });
        }
    }

    zipher_engine::sync::stop().await;
    zipher_engine::wallet::close().await;

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
