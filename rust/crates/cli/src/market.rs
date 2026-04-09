use anyhow::Result;
use serde::Serialize;

use crate::helpers::*;
use crate::{print_ok, Config};

// ---------------------------------------------------------------------------
// OWS subprocess helper
// ---------------------------------------------------------------------------

pub async fn run_ows(args: &[&str]) -> Result<String> {
    let ows_bin = std::env::var("OWS_CLI").unwrap_or_else(|_| "ows".to_string());
    let output = tokio::process::Command::new(&ows_bin)
        .args(args)
        .output()
        .await
        .map_err(|e| anyhow::anyhow!("Failed to run ows CLI ({}): {}", ows_bin, e))?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(anyhow::anyhow!("ows {} failed: {}", args.join(" "), stderr));
    }

    Ok(String::from_utf8_lossy(&output.stdout).trim().to_string())
}

pub async fn get_ows_evm_address(wallet: &str) -> Result<String> {
    let output = run_ows(&["wallet", "list"]).await?;
    let mut in_wallet = false;
    for line in output.lines() {
        if line.starts_with("Name:") && line.contains(wallet) {
            in_wallet = true;
        }
        if in_wallet && line.contains("eip155:") && line.contains('→') {
            if let Some(addr) = line.split('→').nth(1) {
                return Ok(addr.trim().to_string());
            }
        }
        if in_wallet && line.is_empty() {
            break;
        }
    }
    Err(anyhow::anyhow!("EVM address not found for wallet '{}'", wallet))
}

// ---------------------------------------------------------------------------
// PCZT send command
// ---------------------------------------------------------------------------

pub async fn cmd_send_pczt(
    cfg: &Config,
    to: String,
    amount: u64,
    memo: Option<String>,
) -> Result<()> {
    ensure_sapling_params(&cfg.data_dir).await?;
    sync_if_needed(cfg).await?;

    auto_open(cfg).await?;

    let (_send_amount, fee, _) =
        zipher_engine::send::propose_send(&to, amount, memo, false).await?;

    if cfg.human {
        eprintln!("Creating unsigned Zcash transaction (PCZT)...");
        eprintln!("  Amount: {:.8} ZEC + {} zat fee", amount as f64 / 1e8, fee);
    }

    let pczt_bytes = zipher_engine::send::create_pczt().await?;
    let pczt_hex = hex::encode(&pczt_bytes);

    #[derive(Serialize)]
    struct PcztResult {
        pczt_hex: String,
        size_bytes: usize,
        address: String,
        amount: u64,
        fee: u64,
    }

    print_ok(
        PcztResult {
            pczt_hex: pczt_hex.clone(),
            size_bytes: pczt_bytes.len(),
            address: to.clone(),
            amount,
            fee,
        },
        cfg.human,
        |r| {
            println!("PCZT created ({} bytes).", r.size_bytes);
            println!("  To:     {}", r.address);
            println!("  Amount: {} zat", r.amount);
            println!("  Fee:    {} zat", r.fee);
            println!();
            println!("Sign and broadcast via OWS:");
            println!("  ows send-tx --chain zcash:mainnet --wallet <name> --tx {}", &r.pczt_hex[..64.min(r.pczt_hex.len())]);
        },
    );

    zipher_engine::wallet::close().await;
    Ok(())
}

// ---------------------------------------------------------------------------
// Market commands (Myriad prediction markets)
// ---------------------------------------------------------------------------

pub async fn cmd_market_list(cfg: &Config, keyword: Option<String>, limit: u32) -> Result<()> {
    let markets = zipher_engine::myriad::get_markets(keyword.as_deref(), limit).await?;

    print_ok(&markets, cfg.human, |markets| {
        if markets.is_empty() {
            println!("No markets found.");
        } else {
            for m in markets.iter() {
                let state = m.state.as_deref().unwrap_or("unknown");
                println!("  #{} [{}] {}", m.id, state, m.title);
                if !m.outcomes.is_empty() {
                    let outcomes: Vec<String> = m.outcomes.iter()
                        .map(|o| format!("{}: {:.1}%", o.title, o.price * 100.0))
                        .collect();
                    println!("      {}", outcomes.join(" | "));
                }
            }
        }
    });
    Ok(())
}

pub async fn cmd_market_show(cfg: &Config, id: u64) -> Result<()> {
    let market = zipher_engine::myriad::get_market(id).await?;

    print_ok(&market, cfg.human, |m| {
        println!("Market #{}: {}", m.id, m.title);
        if let Some(ref desc) = m.description {
            println!("  {}", desc);
        }
        println!("  State: {}", m.state.as_deref().unwrap_or("unknown"));
        println!("  Network: {}", m.network_id.unwrap_or(0));
        println!();
        for (i, o) in m.outcomes.iter().enumerate() {
            println!("  Outcome {}: {} — {:.1}% (${:.4})", i, o.title, o.price * 100.0, o.price);
        }
    });
    Ok(())
}

pub async fn cmd_market_bet(
    cfg: &Config,
    market_id: u64,
    outcome: u64,
    amount_usdt: f64,
    ows_wallet: String,
) -> Result<()> {
    ensure_sapling_params(&cfg.data_dir).await?;
    force_sync(cfg).await?;

    if cfg.human {
        eprintln!();
        eprintln!("=== Placing prediction market bet with ZEC ===");
        eprintln!("    Chains: Zcash → NEAR → BNB Chain (BSC)");
        eprintln!();
        eprintln!("[1/6] (BNB Chain) Resolving your BSC address via OWS...");
    }
    let bsc_address = get_ows_evm_address(&ows_wallet).await?;

    if cfg.human {
        eprintln!("       BSC address: {}", bsc_address);
    }

    let tokens = zipher_engine::swap::get_tokens().await?;
    let zec = zipher_engine::swap::find_zec_token(&tokens)
        .ok_or_else(|| anyhow::anyhow!("ZEC not found in NEAR Intents"))?;
    let zec_price = zec.price.unwrap_or(30.0);

    auto_open(cfg).await?;
    let addresses = zipher_engine::query::get_addresses().await?;
    let refund_addr = addresses.first()
        .map(|a| a.address.clone())
        .unwrap_or_default();

    if cfg.human {
        eprintln!();
        eprintln!("[2/6] (BNB Chain) Checking BNB gas balance...");
    }
    let bnb_balance = zipher_engine::myriad::get_bnb_balance(
        zipher_engine::myriad::BSC_RPC, &bsc_address,
    ).await?;

    let needs_gas = bnb_balance < zipher_engine::myriad::MIN_BNB_FOR_GAS;
    if needs_gas {
        if cfg.human {
            eprintln!("       BNB balance: {:.6} — not enough for gas, auto-funding...",
                bnb_balance as f64 / 1e18);
        }

        let bnb_token = tokens.iter()
            .find(|t| t.symbol.eq_ignore_ascii_case("BNB") && t.blockchain.eq_ignore_ascii_case("bsc"))
            .ok_or_else(|| anyhow::anyhow!("BNB on BSC not found in NEAR Intents"))?;

        let bnb_target = 0.005_f64;
        let bnb_usd_price = bnb_token.price.unwrap_or(600.0);
        let bnb_cost_usd = bnb_target * bnb_usd_price;
        let zec_for_bnb = (bnb_cost_usd / zec_price * 1e8) as u64;

        if cfg.human {
            eprintln!("       (Zcash → NEAR → BSC) Swapping {:.8} ZEC → {:.4} BNB for gas...",
                zec_for_bnb as f64 / 1e8, bnb_target);
        }

        let bnb_swap_quote = zipher_engine::swap::get_quote(
            &zec.asset_id, &bnb_token.asset_id,
            &zec_for_bnb.to_string(), &bsc_address, &refund_addr, 200,
        ).await?;

        let (_send_amount, _fee, _) = zipher_engine::send::propose_send(
            &bnb_swap_quote.deposit_address, zec_for_bnb, None, false,
        ).await?;
        let pczt_bytes = zipher_engine::send::create_pczt().await?;
        let pczt_hex = hex::encode(&pczt_bytes);

        let bnb_tx = run_ows(&[
            "sign", "send-tx", "--chain", "zcash:mainnet", "--wallet", &ows_wallet,
            "--rpc-url", &cfg.server_url, "--tx", &pczt_hex,
        ]).await?;

        if cfg.human {
            eprintln!("       (Zcash) Sent {:.8} ZEC for gas — tx: {}...",
                zec_for_bnb as f64 / 1e8, &bnb_tx[..16.min(bnb_tx.len())]);
        }

        zipher_engine::swap::submit_deposit(&bnb_tx, &bnb_swap_quote.deposit_address).await.ok();

        if cfg.human {
            eprintln!("       (NEAR)  Waiting for BNB gas swap to settle...");
        }
        for _ in 0..60 {
            tokio::time::sleep(std::time::Duration::from_secs(10)).await;
            let status = zipher_engine::swap::get_status(&bnb_swap_quote.deposit_address).await?;
            if status.status == "SUCCESS" || status.status == "COMPLETED" {
                if cfg.human {
                    eprintln!("       (BSC)   BNB gas received!");
                }
                break;
            }
            if status.status == "FAILED" {
                return Err(anyhow::anyhow!("BNB gas swap failed"));
            }
        }

        zipher_engine::wallet::close().await;
        force_sync(cfg).await?;
    } else {
        if cfg.human {
            eprintln!("       BNB balance: {:.6} — enough for gas", bnb_balance as f64 / 1e18);
        }
    }

    if cfg.human {
        eprintln!();
        eprintln!("[3/6] (Zcash → NEAR → BSC) Swapping ZEC → USDT via NEAR Intents...");
    }

    let usdt_matches: Vec<_> = tokens.iter()
        .filter(|t| t.symbol.eq_ignore_ascii_case("USDT") && t.blockchain.eq_ignore_ascii_case("bsc"))
        .collect();
    let usdt = usdt_matches.first()
        .ok_or_else(|| anyhow::anyhow!("USDT on BSC not found in NEAR Intents"))?;

    let usdt_needed = amount_usdt * 1.02;
    let zec_needed = (usdt_needed / zec_price * 1e8) as u64;

    let swap_quote = zipher_engine::swap::get_quote(
        &zec.asset_id, &usdt.asset_id,
        &zec_needed.to_string(), &bsc_address, &refund_addr, 100,
    ).await?;

    let (_send_amount, _fee, _) = zipher_engine::send::propose_send(
        &swap_quote.deposit_address, zec_needed, None, false,
    ).await?;

    let pczt_bytes = zipher_engine::send::create_pczt().await?;
    let pczt_hex = hex::encode(&pczt_bytes);

    if cfg.human {
        eprintln!("       (Zcash) Signing PCZT via OWS...");
    }
    let zcash_tx = run_ows(&[
        "sign", "send-tx", "--chain", "zcash:mainnet", "--wallet", &ows_wallet,
        "--rpc-url", &cfg.server_url, "--tx", &pczt_hex,
    ]).await?;

    if cfg.human {
        eprintln!("       (Zcash) Sent {:.8} ZEC — tx: {}...",
            zec_needed as f64 / 1e8, &zcash_tx[..16.min(zcash_tx.len())]);
    }

    zipher_engine::swap::submit_deposit(&zcash_tx, &swap_quote.deposit_address).await.ok();

    if cfg.human {
        eprintln!("       (NEAR)  Waiting for cross-chain swap to settle...");
    }
    for _ in 0..60 {
        tokio::time::sleep(std::time::Duration::from_secs(10)).await;
        let status = zipher_engine::swap::get_status(&swap_quote.deposit_address).await?;
        if status.status == "SUCCESS" || status.status == "COMPLETED" {
            if cfg.human {
                eprintln!("       (BSC)   Swap complete! USDT received on BNB Chain.");
            }
            break;
        }
        if status.status == "FAILED" {
            return Err(anyhow::anyhow!("Swap failed"));
        }
    }

    if cfg.human {
        eprintln!();
        eprintln!("[4/6] (BNB Chain) Refreshing prediction market quote...");
    }
    let quote = zipher_engine::myriad::get_quote(market_id, outcome, "buy", amount_usdt, 0.01).await?;

    if cfg.human {
        eprintln!("       You'll get {:.4} shares for ${:.2} USDT (fresh quote)", quote.shares, amount_usdt);
    }

    if cfg.human {
        eprintln!();
        eprintln!("[5/6] (BNB Chain) Approving USDT for Myriad contract...");
    }
    let approve_amount = ((amount_usdt * 1.05) * 1e6) as u128;
    let approve_data = zipher_engine::myriad::build_erc20_approve_calldata(
        zipher_engine::myriad::PM_CONTRACT,
        &format!("{:064x}", approve_amount),
    );
    let nonce = zipher_engine::myriad::get_nonce(
        zipher_engine::myriad::BSC_RPC, &bsc_address,
    ).await?;
    let approve_tx = zipher_engine::myriad::build_unsigned_eip1559_tx(
        56, nonce, 1_000_000_000, 5_000_000_000, 100_000,
        zipher_engine::myriad::USDT_BSC, 0, &approve_data,
    );
    let approve_hex = hex::encode(&approve_tx);
    run_ows(&[
        "sign", "send-tx", "--chain", "eip155:56", "--wallet", &ows_wallet, "--tx", &approve_hex,
    ]).await?;

    if cfg.human {
        eprintln!("       Approval signed via OWS and sent to BSC.");
    }

    if cfg.human {
        eprintln!();
        eprintln!("[6/6] (BNB Chain) Placing bet on Myriad prediction market...");
    }
    let bet_data = hex::decode(quote.calldata.trim_start_matches("0x"))
        .map_err(|e| anyhow::anyhow!("Invalid calldata: {}", e))?;
    let bet_nonce = nonce + 1;
    let bet_tx = zipher_engine::myriad::build_unsigned_eip1559_tx(
        56, bet_nonce, 1_000_000_000, 5_000_000_000, 300_000,
        zipher_engine::myriad::PM_CONTRACT, 0, &bet_data,
    );
    let bet_hex = hex::encode(&bet_tx);
    let bet_result = run_ows(&[
        "sign", "send-tx", "--chain", "eip155:56", "--wallet", &ows_wallet, "--tx", &bet_hex,
    ]).await?;

    #[derive(Serialize)]
    struct BetResult {
        market_id: u64,
        outcome: u64,
        amount_usdt: f64,
        shares: f64,
        zec_spent: u64,
        bsc_tx: String,
    }

    print_ok(
        BetResult {
            market_id,
            outcome,
            amount_usdt,
            shares: quote.shares,
            zec_spent: zec_needed,
            bsc_tx: bet_result.clone(),
        },
        cfg.human,
        |r| {
            println!();
            println!("=== Bet placed successfully! ===");
            println!();
            println!("  Market:     #{}", r.market_id);
            println!("  Outcome:    {}", r.outcome);
            println!("  Amount:     ${:.2} USDT", r.amount_usdt);
            println!("  Shares:     {:.4}", r.shares);
            println!("  ZEC spent:  {:.8} ZEC", r.zec_spent as f64 / 1e8);
            println!("  BSC tx:     {}", r.bsc_tx);
            println!();
            println!("  Flow: ZEC → NEAR Intents → USDT (BSC) → Myriad bet");
            println!("  All signing handled by Open Wallet Standard (OWS).");
        },
    );

    zipher_engine::wallet::close().await;
    Ok(())
}

pub async fn cmd_market_agent(
    cfg: &Config,
    max_bet: f64,
    min_edge_pct: f64,
    bankroll: f64,
    scan_limit: u32,
    ows_wallet: String,
    dry_run: bool,
) -> Result<()> {
    if cfg.human {
        eprintln!();
        eprintln!("=== Autonomous Market Agent ===");
        eprintln!("    Strategy: scan → research → Kelly-sized bet");
        eprintln!("    Bankroll: ${:.2}, max bet: ${:.2}, min edge: {:.1}%", bankroll, max_bet, min_edge_pct);
        if dry_run { eprintln!("    Mode: DRY RUN (no trades executed)"); }
        eprintln!();
    }

    if cfg.human { eprintln!("[1/4] Scanning prediction markets..."); }
    let markets = zipher_engine::myriad::get_markets(None, scan_limit).await?;
    let scanned = zipher_engine::myriad::rank_for_research(&markets);

    if cfg.human {
        eprintln!("      {} markets fetched, {} are contestable (uncertainty > 30%).",
            markets.len(), scanned.len());
    }

    if scanned.is_empty() {
        if cfg.human { eprintln!("      No contestable markets found. Agent standing by."); }
        #[derive(serde::Serialize)]
        struct AgentResult { action: String, markets_scanned: usize }
        print_ok(
            AgentResult { action: "no_trade".into(), markets_scanned: markets.len() },
            cfg.human, |_| {},
        );
        return Ok(());
    }

    if cfg.human {
        eprintln!();
        eprintln!("[2/4] Researching top {} markets...", scanned.len().min(5));
    }

    let top = scanned.iter().take(5).collect::<Vec<_>>();
    let mut research_results = Vec::new();

    for sm in &top {
        let queries = zipher_engine::research::research_queries_for_market(&sm.market.title);
        let query = queries.first().map(|s| s.as_str()).unwrap_or(&sm.market.title);

        if cfg.human {
            eprintln!("      Researching: \"{}\" (uncertainty {:.0}%)",
                sm.market.title, sm.uncertainty * 100.0);
        }

        let report = zipher_engine::research::search_news(query, 5).await
            .unwrap_or_else(|_| zipher_engine::research::ResearchReport {
                query: query.to_string(),
                items: vec![],
                summary: "Research unavailable.".to_string(),
                source: "error".to_string(),
            });

        research_results.push((sm, report));
    }

    // Without an LLM in the loop, the CLI agent uses a heuristic:
    // the MCP-based agent flow is better because the LLM reads
    // the research and forms its own probability estimate.
    if cfg.human {
        eprintln!();
        eprintln!("[3/4] Analyzing opportunities (Kelly Criterion)...");
    }

    let mut best_signal: Option<zipher_engine::myriad::TradeSignal> = None;

    for (sm, report) in &research_results {
        let has_research = !report.items.is_empty();
        let confidence = if has_research { 0.6 } else { 0.2 };

        for (idx, outcome) in sm.market.outcomes.iter().enumerate() {
            let market_prob = sm.implied_probs.get(idx).copied().unwrap_or(outcome.price);

            let edge_bump = if has_research { 0.08 } else { 0.03 };
            let estimated = (market_prob + edge_bump).min(0.95);

            if let Some(signal) = zipher_engine::myriad::analyze_opportunity(
                &sm.market, idx, estimated, confidence, bankroll, max_bet,
            ) {
                if signal.edge * 100.0 >= min_edge_pct {
                    if best_signal.as_ref().map_or(true, |best| signal.expected_value > best.expected_value) {
                        best_signal = Some(signal);
                    }
                }
            }
        }
    }

    let signal = match best_signal {
        Some(s) => s,
        None => {
            if cfg.human {
                eprintln!("      No opportunities meet the {:.1}% minimum edge. Agent standing by.", min_edge_pct);
            }
            #[derive(serde::Serialize)]
            struct AgentResult { action: String, markets_scanned: usize, researched: usize }
            print_ok(
                AgentResult {
                    action: "no_trade".into(),
                    markets_scanned: markets.len(),
                    researched: research_results.len(),
                },
                cfg.human, |_| {},
            );
            return Ok(());
        }
    };

    if cfg.human {
        eprintln!();
        eprintln!("  Best opportunity:");
        eprintln!("    Market:  #{} — {}", signal.market_id, signal.market_title);
        eprintln!("    Outcome: #{} — {}", signal.outcome_index, signal.outcome_title);
        eprintln!("    {}", signal.reason);
        eprintln!("    Bet:     ${:.2} USDT", signal.recommended_bet_usdt);
        eprintln!();
    }

    if dry_run {
        #[derive(serde::Serialize)]
        struct AgentResult {
            action: String,
            market_id: u64,
            market_title: String,
            outcome_index: usize,
            outcome_title: String,
            market_prob: f64,
            estimated_prob: f64,
            edge_pct: f64,
            kelly_fraction_pct: f64,
            expected_value: f64,
            recommended_bet_usdt: f64,
            confidence: f64,
        }
        print_ok(
            AgentResult {
                action: "recommend".into(),
                market_id: signal.market_id,
                market_title: signal.market_title,
                outcome_index: signal.outcome_index,
                outcome_title: signal.outcome_title,
                market_prob: signal.market_prob,
                estimated_prob: signal.estimated_prob,
                edge_pct: signal.edge * 100.0,
                kelly_fraction_pct: signal.kelly_fraction * 100.0,
                expected_value: signal.expected_value,
                recommended_bet_usdt: signal.recommended_bet_usdt,
                confidence: signal.confidence,
            },
            cfg.human,
            |r| {
                println!();
                println!("=== Agent Recommendation (dry run) ===");
                println!("  Market:     #{} — {}", r.market_id, r.market_title);
                println!("  Outcome:    #{} — {}", r.outcome_index, r.outcome_title);
                println!("  Market:     {:.1}%  →  Estimate: {:.1}%", r.market_prob * 100.0, r.estimated_prob * 100.0);
                println!("  Edge:       {:.1}%", r.edge_pct);
                println!("  EV:         ${:.3} per $1 risked", r.expected_value);
                println!("  Kelly:      {:.1}% of bankroll", r.kelly_fraction_pct);
                println!("  Bet:        ${:.2} USDT", r.recommended_bet_usdt);
                println!("  Confidence: {:.0}%", r.confidence * 100.0);
                println!();
                println!("  Run without --dry-run to execute.");
            },
        );
        return Ok(());
    }

    if cfg.human {
        eprintln!("[4/4] Executing bet via cross-chain pipeline...");
        eprintln!();
    }

    cmd_market_bet(
        cfg,
        signal.market_id,
        signal.outcome_index as u64,
        signal.recommended_bet_usdt,
        ows_wallet,
    ).await?;

    Ok(())
}

pub async fn cmd_market_positions(cfg: &Config, ows_wallet: String) -> Result<()> {
    let bsc_address = get_ows_evm_address(&ows_wallet).await?;

    let positions = zipher_engine::myriad::get_portfolio(&bsc_address).await?;

    print_ok(&positions, cfg.human, |positions| {
        if positions.is_empty() {
            println!("No open positions.");
        } else {
            for p in positions.iter() {
                println!("  Market #{} — Outcome {} — {:.4} shares", p.market_id, p.outcome_id, p.shares);
                if let Some(ref title) = p.market_title {
                    println!("    {}", title);
                }
            }
        }
    });
    Ok(())
}

/// Sell all open prediction market positions and sweep USDT back to ZEC.
pub async fn cmd_market_sweep(
    cfg: &Config,
    ows_wallet: String,
    sweep_to_zec: bool,
) -> Result<()> {
    ensure_sapling_params(&cfg.data_dir).await?;

    let bsc_address = get_ows_evm_address(&ows_wallet).await?;

    let positions = zipher_engine::myriad::get_portfolio(&bsc_address).await?;

    if positions.is_empty() {
        if cfg.human {
            println!("No open positions to sweep.");
        }
        return Ok(());
    }

    if cfg.human {
        println!("Found {} open positions. Selling all...", positions.len());
    }

    let mut total_usdt = 0.0f64;

    for pos in &positions {
        if pos.shares <= 0.0 {
            continue;
        }

        if cfg.human {
            eprintln!(
                "  Selling {:.4} shares of Market #{} Outcome #{}...",
                pos.shares, pos.market_id, pos.outcome_id
            );
        }

        let quote = match zipher_engine::myriad::get_quote(
            pos.market_id,
            pos.outcome_id,
            "sell",
            pos.shares,
            0.05,
        )
        .await
        {
            Ok(q) => q,
            Err(e) => {
                if cfg.human {
                    eprintln!("    Skipping: {}", e);
                }
                continue;
            }
        };

        if cfg.human {
            eprintln!("    Quote: {:.4} USDT", quote.value);
        }

        let calldata_bytes = hex::decode(quote.calldata.trim_start_matches("0x"))
            .map_err(|e| anyhow::anyhow!("Invalid calldata: {}", e))?;

        let nonce = zipher_engine::myriad::get_nonce(zipher_engine::myriad::BSC_RPC, &bsc_address).await?;
        let gas_limit = zipher_engine::myriad::estimate_gas(
            zipher_engine::myriad::BSC_RPC,
            &bsc_address,
            zipher_engine::myriad::PM_CONTRACT,
            &calldata_bytes,
        )
        .await
        .unwrap_or(300_000)
        .max(300_000);

        let tx_bytes = zipher_engine::myriad::build_unsigned_eip1559_tx(
            zipher_engine::myriad::BSC_NETWORK_ID,
            nonce,
            1_000_000_000,
            5_000_000_000,
            gas_limit,
            zipher_engine::myriad::PM_CONTRACT,
            0,
            &calldata_bytes,
        );

        let tx_hex = hex::encode(&tx_bytes);
        let signed = run_ows(&[
            "sign", "send-tx", "--chain", "eip155:56", "--tx", &tx_hex, "--wallet", &ows_wallet,
        ])
        .await?;

        if cfg.human {
            eprintln!("    Sold. TX: {}", &signed[..signed.len().min(20)]);
        }

        total_usdt += quote.value;
    }

    if cfg.human {
        println!("All positions sold. ~{:.2} USDT recovered on BSC.", total_usdt);
    }

    // Sweep USDT back to ZEC if requested
    if sweep_to_zec && total_usdt > 0.5 {
        if cfg.human {
            println!("Sweeping USDT on BSC → ZEC (shielded)...");
        }

        sync_if_needed(cfg).await?;
        auto_open(cfg).await?;

        let tokens = zipher_engine::swap::get_tokens().await?;
        let zec_token = zipher_engine::swap::find_zec_token(&tokens)
            .ok_or_else(|| anyhow::anyhow!("ZEC not found in swap tokens"))?;

        let usdt_token = tokens
            .iter()
            .find(|t| t.symbol.eq_ignore_ascii_case("USDT") && t.blockchain.eq_ignore_ascii_case("bsc"))
            .ok_or_else(|| anyhow::anyhow!("USDT on BSC not found in swap tokens"))?;

        let usdt_balance = zipher_engine::evm_pay::get_erc20_balance(
            zipher_engine::myriad::BSC_RPC,
            zipher_engine::myriad::USDT_BSC,
            &bsc_address,
        )
        .await
        .unwrap_or(0);

        if usdt_balance == 0 {
            if cfg.human {
                println!("No USDT balance to sweep. Shares may still be settling.");
            }
            zipher_engine::wallet::close().await;
            return Ok(());
        }

        let addresses = zipher_engine::query::get_addresses().await?;
        let zec_address = addresses
            .first()
            .map(|a| a.address.clone())
            .ok_or_else(|| anyhow::anyhow!("No ZEC address"))?;

        match zipher_engine::swap::get_quote(
            &usdt_token.asset_id,
            &zec_token.asset_id,
            &usdt_balance.to_string(),
            &zec_address,
            &bsc_address,
            100,
        )
        .await
        {
            Ok(quote) => {
                if cfg.human {
                    println!(
                        "  Sweep quote: {} USDT → ~{} ZEC",
                        usdt_balance, quote.amount_out
                    );
                    println!("  Deposit USDT to: {}", quote.deposit_address);
                    println!("  Use: zipher-cli swap execute --to ZEC --chain zcash ...");
                }
            }
            Err(e) => {
                if cfg.human {
                    eprintln!("  Could not get sweep quote: {}", e);
                }
            }
        }

        zipher_engine::wallet::close().await;
    }

    Ok(())
}
