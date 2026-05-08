use std::time::{Duration, Instant};

use anyhow::Result;
use serde::Serialize;

use crate::helpers::auto_open;
use crate::{print_ok, Config};

#[derive(Debug, Serialize)]
struct SyncBenchmarkResult {
    started_synced_height: u32,
    started_latest_height: u32,
    final_synced_height: u32,
    final_latest_height: u32,
    elapsed_ms: u128,
    blocks_scanned: u32,
    blocks_per_second: f64,
    progress_samples: usize,
    phase_samples: Vec<PhaseSample>,
    timed_out: bool,
    caught_up: bool,
    final_phase: String,
    maintenance_queue_len: u32,
    connection_error: Option<String>,
    maintenance_error: Option<String>,
}

#[derive(Debug, Serialize)]
struct PhaseSample {
    phase: String,
    samples: usize,
}

pub async fn cmd_sync_benchmark(cfg: &Config, max_seconds: u64, poll_ms: u64) -> Result<()> {
    auto_open(cfg).await?;

    let started_synced_height = zipher_engine::query::get_synced_height().await.unwrap_or(0);
    let started_latest_height = zipher_engine::wallet::fetch_latest_height(&cfg.server_url)
        .await
        .unwrap_or(started_synced_height as u64) as u32;

    let poll_interval = Duration::from_millis(poll_ms.max(100));
    let max_duration = if max_seconds == 0 {
        None
    } else {
        Some(Duration::from_secs(max_seconds))
    };

    if cfg.human {
        eprintln!(
            "Benchmarking sync from {} toward tip {}...",
            started_synced_height, started_latest_height
        );
    }

    let started = Instant::now();
    let mut phase_counts: Vec<(String, usize)> = Vec::new();
    let mut samples = 0usize;
    let mut timed_out = false;

    zipher_engine::sync::start().await?;

    loop {
        tokio::time::sleep(poll_interval).await;
        let progress = zipher_engine::sync::get_progress().await;
        samples += 1;
        record_phase(&mut phase_counts, &progress.phase);

        if cfg.human {
            let latest = progress.latest_height.max(started_latest_height);
            let pct = if latest > 0 {
                (progress.synced_height as f64 / latest as f64 * 100.0).min(100.0)
            } else {
                0.0
            };
            eprintln!(
                "  phase={} synced={}/{} ({:.2}%) queue={}",
                progress.phase, progress.synced_height, latest, pct, progress.maintenance_queue_len
            );
        }

        let caught_up =
            progress.latest_height > 0 && progress.synced_height >= progress.latest_height;
        if caught_up {
            break;
        }

        if let Some(max_duration) = max_duration {
            if started.elapsed() >= max_duration {
                timed_out = true;
                break;
            }
        }

        if !progress.is_syncing && !zipher_engine::sync::is_running() {
            break;
        }
    }

    let final_progress = zipher_engine::sync::get_progress().await;
    zipher_engine::sync::stop().await;
    zipher_engine::wallet::close().await;

    let elapsed = started.elapsed();
    let blocks_scanned = final_progress
        .synced_height
        .saturating_sub(started_synced_height);
    let blocks_per_second = if elapsed.as_secs_f64() > 0.0 {
        blocks_scanned as f64 / elapsed.as_secs_f64()
    } else {
        0.0
    };
    let caught_up = final_progress.latest_height > 0
        && final_progress.synced_height >= final_progress.latest_height;

    let result = SyncBenchmarkResult {
        started_synced_height,
        started_latest_height,
        final_synced_height: final_progress.synced_height,
        final_latest_height: final_progress.latest_height,
        elapsed_ms: elapsed.as_millis(),
        blocks_scanned,
        blocks_per_second,
        progress_samples: samples,
        phase_samples: phase_counts
            .into_iter()
            .map(|(phase, samples)| PhaseSample { phase, samples })
            .collect(),
        timed_out,
        caught_up,
        final_phase: final_progress.phase,
        maintenance_queue_len: final_progress.maintenance_queue_len,
        connection_error: final_progress.connection_error,
        maintenance_error: final_progress.maintenance_error,
    };

    print_ok(result, cfg.human, |r| {
        println!("Sync benchmark complete.");
        println!(
            "  started:       {}/{}",
            r.started_synced_height, r.started_latest_height
        );
        println!(
            "  final:         {}/{}",
            r.final_synced_height, r.final_latest_height
        );
        println!("  elapsed:       {} ms", r.elapsed_ms);
        println!("  blocks:        {}", r.blocks_scanned);
        println!("  throughput:    {:.2} blocks/s", r.blocks_per_second);
        println!("  caught up:     {}", r.caught_up);
        println!("  timed out:     {}", r.timed_out);
        println!("  final phase:   {}", r.final_phase);
        println!("  enhance queue: {}", r.maintenance_queue_len);
        if let Some(err) = &r.connection_error {
            println!("  connection:    {}", err);
        }
        if let Some(err) = &r.maintenance_error {
            println!("  maintenance:   {}", err);
        }
    });

    Ok(())
}

fn record_phase(counts: &mut Vec<(String, usize)>, phase: &str) {
    if let Some((_, count)) = counts.iter_mut().find(|(p, _)| p == phase) {
        *count += 1;
    } else {
        counts.push((phase.to_string(), 1));
    }
}
