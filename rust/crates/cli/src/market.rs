use anyhow::Result;
use serde::Serialize;

use crate::helpers::*;
use crate::{print_ok, Config};
use secrecy::ExposeSecret;

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
    slippage: f64,
    max_price_move: f64,
) -> Result<()> {
    ensure_sapling_params(&cfg.data_dir).await?;
    force_sync(cfg).await?;

    if cfg.human {
        eprintln!();
        eprintln!("=== Placing prediction market bet with ZEC ===");
        eprintln!("    Chains: Zcash → NEAR → BNB Chain (BSC)");
        eprintln!("    Slippage: {:.1}%, Max price move: {:.1}%", slippage * 100.0, max_price_move);
        eprintln!();
        eprintln!("[1/7] (BNB Chain) Resolving your BSC address via OWS...");
    }
    let bsc_address = get_ows_evm_address(&ows_wallet).await?;

    if cfg.human {
        eprintln!("       BSC address: {}", bsc_address);
    }

    let tokens = zipher_engine::swap::get_tokens().await?;
    let zec = zipher_engine::swap::find_zec_token(&tokens)
        .ok_or_else(|| anyhow::anyhow!("ZEC not found in NEAR Intents"))?;
    let zec_price = zec.price
        .ok_or_else(|| anyhow::anyhow!("ZEC price unavailable from NEAR Intents — cannot size swap safely"))?;

    if cfg.human {
        eprintln!("       Live ZEC price: ${:.2} (from NEAR Intents)", zec_price);
    }

    let pre_quote = zipher_engine::myriad::get_quote(market_id, outcome, "buy", amount_usdt, slippage).await?;
    let initial_price = pre_quote.price;
    if cfg.human {
        eprintln!("       Pre-swap quote: {:.4} shares @ {:.4} price", pre_quote.shares, initial_price);
    }

    auto_open(cfg).await?;
    let addresses = zipher_engine::query::get_addresses().await?;
    let refund_addr = addresses.first()
        .map(|a| a.address.clone())
        .unwrap_or_default();

    if cfg.human {
        eprintln!();
        eprintln!("[2/7] (BNB Chain) Checking BNB gas balance...");
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
        zipher_engine::send::clear_pczt_lock(&cfg.data_dir);

        if cfg.human {
            eprintln!("       (Zcash) Sent {:.8} ZEC for gas — tx: {}...",
                zec_for_bnb as f64 / 1e8, &bnb_tx[..16.min(bnb_tx.len())]);
        }

        zipher_engine::swap::submit_deposit(&bnb_tx, &bnb_swap_quote.deposit_address).await.ok();

        if cfg.human {
            eprintln!("       (NEAR)  Waiting for BNB gas swap to settle...");
        }
        let mut gas_settled = false;
        for _ in 0..60 {
            tokio::time::sleep(std::time::Duration::from_secs(10)).await;
            let status = zipher_engine::swap::get_status(&bnb_swap_quote.deposit_address).await?;
            if status.status == "SUCCESS" || status.status == "COMPLETED" {
                if cfg.human {
                    eprintln!("       (BSC)   BNB gas received!");
                }
                gas_settled = true;
                break;
            }
            if status.status == "FAILED" {
                return Err(anyhow::anyhow!("BNB gas swap failed"));
            }
        }
        if !gas_settled {
            return Err(anyhow::anyhow!("BNB gas swap timed out after 10 minutes"));
        }

        zipher_engine::wallet::close().await;
        force_sync(cfg).await?;
    } else if cfg.human {
        eprintln!("       BNB balance: {:.6} — enough for gas", bnb_balance as f64 / 1e18);
    }

    if cfg.human {
        eprintln!();
        eprintln!("[3/7] (Zcash → NEAR → BSC) Swapping ZEC → USDT via NEAR Intents...");
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
    zipher_engine::send::clear_pczt_lock(&cfg.data_dir);

    if cfg.human {
        eprintln!("       (Zcash) Sent {:.8} ZEC — tx: {}...",
            zec_needed as f64 / 1e8, &zcash_tx[..16.min(zcash_tx.len())]);
    }

    zipher_engine::swap::submit_deposit(&zcash_tx, &swap_quote.deposit_address).await.ok();

    if cfg.human {
        eprintln!("       (NEAR)  Waiting for cross-chain swap to settle...");
    }
    let mut swap_settled = false;
    for _ in 0..60 {
        tokio::time::sleep(std::time::Duration::from_secs(10)).await;
        let status = zipher_engine::swap::get_status(&swap_quote.deposit_address).await?;
        if status.status == "SUCCESS" || status.status == "COMPLETED" {
            if cfg.human {
                eprintln!("       (BSC)   Swap complete! USDT received on BNB Chain.");
            }
            swap_settled = true;
            break;
        }
        if status.status == "FAILED" {
            return Err(anyhow::anyhow!("Swap failed"));
        }
    }
    if !swap_settled {
        return Err(anyhow::anyhow!("ZEC → USDT swap timed out after 10 minutes"));
    }

    if cfg.human {
        eprintln!();
        eprintln!("[4/7] (BNB Chain) Verifying USDT balance on BSC...");
    }
    let usdt_balance = zipher_engine::evm_pay::get_erc20_balance(
        zipher_engine::myriad::BSC_RPC,
        zipher_engine::myriad::USDT_BSC,
        &bsc_address,
    ).await.unwrap_or(0);

    let usdt_balance_f = usdt_balance as f64 / 1e18; // BSC USDT = 18 decimals
    if cfg.human {
        eprintln!("       USDT balance: ${:.2}", usdt_balance_f);
    }
    if usdt_balance_f < 0.50 {
        return Err(anyhow::anyhow!(
            "Swap failed: only ${:.2} USDT arrived. Swap may have failed or is still settling.",
            usdt_balance_f
        ));
    }

    // Adjust bet to actual balance (swap fees/slippage eat 1-5%)
    let actual_bet = if usdt_balance_f < amount_usdt { usdt_balance_f } else { amount_usdt };
    let adjusted = actual_bet < amount_usdt;
    if adjusted && cfg.human {
        eprintln!("       Adjusting bet: ${:.2} → ${:.2} (swap fees)", amount_usdt, actual_bet);
    }

    if cfg.human {
        eprintln!();
        eprintln!("[5/7] (BNB Chain) Refreshing prediction market quote + price check...");
    }
    let quote = zipher_engine::myriad::get_quote(market_id, outcome, "buy", actual_bet, slippage).await?;

    let current_price = quote.price;
    if initial_price > 0.0 && current_price > 0.0 {
        let price_move_pct = ((current_price - initial_price) / initial_price * 100.0).abs();
        if cfg.human {
            eprintln!("       Price: {:.4} → {:.4} ({:+.1}% change)", initial_price, current_price, price_move_pct);
        }
        if price_move_pct > max_price_move {
            return Err(anyhow::anyhow!(
                "Price moved {:.1}% (limit: {:.1}%). Pre-swap: {:.4}, now: {:.4}. Aborting to protect against adverse movement.",
                price_move_pct, max_price_move, initial_price, current_price
            ));
        }
    }

    if cfg.human {
        eprintln!("       You'll get {:.4} shares for ${:.2} USDT (fresh quote)", quote.shares, actual_bet);
    }

    if cfg.human {
        eprintln!();
        eprintln!("[6/7] (BNB Chain) Approving USDT for Myriad contract...");
    }
    let approve_amount = ((actual_bet * 1.05) * 1e18) as u128; // BSC USDT = 18 decimals
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
        eprintln!("[7/7] (BNB Chain) Placing bet on Myriad prediction market...");
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
        initial_price: f64,
        final_price: f64,
    }

    print_ok(
        BetResult {
            market_id,
            outcome,
            amount_usdt: actual_bet,
            shares: quote.shares,
            zec_spent: zec_needed,
            bsc_tx: bet_result.clone(),
            initial_price,
            final_price: current_price,
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
            println!("  Price:      {:.4} → {:.4}", r.initial_price, r.final_price);
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
    slippage: f64,
    max_price_move: f64,
) -> Result<()> {
    if cfg.human {
        eprintln!();
        eprintln!("=== Autonomous Market Agent ===");
        eprintln!("    Strategy: scan → research → Kelly-sized bet");
        eprintln!("    Bankroll: ${:.2}, max bet: ${:.2}, min edge: {:.1}%", bankroll, max_bet, min_edge_pct);
        eprintln!("    Slippage: {:.1}%, Max price move: {:.1}%", slippage * 100.0, max_price_move);
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
        slippage,
        max_price_move,
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

// ---------------------------------------------------------------------------
// Polymarket (Gamma API — discovery & inspection, no wallet)
// ---------------------------------------------------------------------------

fn fmt_usd(n: f64) -> String {
    if n >= 1_000_000.0 {
        format!("${:.1}M", n / 1_000_000.0)
    } else if n >= 1_000.0 {
        format!("${:.1}k", n / 1_000.0)
    } else {
        format!("${:.0}", n)
    }
}

#[derive(Serialize)]
struct PolymarketShowOutput {
    question: String,
    condition_id: String,
    outcomes: Vec<PolymarketOutcomeLine>,
    best_bid: Option<f64>,
    best_ask: Option<f64>,
    spread: Option<f64>,
    volume_24hr: f64,
    liquidity: f64,
    neg_risk: bool,
    accepting_orders: bool,
    clob_token_ids: Vec<String>,
}

#[derive(Serialize)]
struct PolymarketOutcomeLine {
    label: String,
    price: f64,
    price_pct: String,
}

pub async fn cmd_polymarket_list(
    cfg: &Config,
    keyword: Option<String>,
    limit: u32,
    show_all: bool,
) -> Result<()> {
    let summary =
        zipher_engine::polymarket::polymarket_discover(keyword.as_deref(), limit, show_all).await?;

    print_ok(&summary, cfg.human, |s| {
        println!();
        println!("=== Polymarket — Top events (Gamma) ===");
        if show_all {
            println!("(Quality filters disabled: --all)");
        }
        println!();

        for row in &s.rows {
            let tag = if row.kind == "grouped" {
                if row.neg_risk {
                    "[MULTI]"
                } else {
                    "[GROUP]"
                }
            } else {
                "[BINARY]"
            };

            println!("  {} {}", tag, row.title);
            println!(
                "      {} sub-markets · {} vol/24h (event)",
                row.market_count,
                fmt_usd(row.volume_24hr)
            );

            if row.top_runners.is_empty() {
                println!("      (no sub-markets passed quality filters — try --all)");
            } else {
                let parts: Vec<String> = row
                    .top_runners
                    .iter()
                    .map(|r| format!("{}: {:.1}%", r.label, r.price * 100.0))
                    .collect();
                println!("      {}", parts.join("  |  "));
            }
            println!();
        }

        println!(
            "  {} events → {} sub-markets total, {} after quality filter, {} display rows",
            s.events_fetched,
            s.total_submarkets,
            s.submarkets_after_filter,
            s.rows.len()
        );
        println!();
    });

    Ok(())
}

pub async fn cmd_polymarket_show(cfg: &Config, condition_id: String) -> Result<()> {
    let m = zipher_engine::polymarket::polymarket_gamma_get_market_by_condition(&condition_id).await?;

    let labels = m.outcome_labels();
    let prices = m.outcome_prices_vec();
    let mut outcomes = Vec::new();
    for (i, lab) in labels.iter().enumerate() {
        let price = prices.get(i).copied().unwrap_or(0.0);
        outcomes.push(PolymarketOutcomeLine {
            label: lab.clone(),
            price,
            price_pct: format!("{:.2}%", price * 100.0),
        });
    }

    let out = PolymarketShowOutput {
        question: m.display_title(),
        condition_id: m.condition_id_str(),
        outcomes,
        best_bid: m.best_bid_f(),
        best_ask: m.best_ask_f(),
        spread: m.spread_f(),
        volume_24hr: m.volume_24hr(),
        liquidity: m.liquidity_num_f(),
        neg_risk: m.neg_risk_effective(),
        accepting_orders: m.accepting_orders_effective(),
        clob_token_ids: m.clob_token_ids_vec(),
    };

    print_ok(&out, cfg.human, |o| {
        println!();
        println!("{}", o.question);
        println!("  condition_id: {}", o.condition_id);
        println!();
        print!("  Outcomes: ");
        let parts: Vec<String> = o
            .outcomes
            .iter()
            .map(|x| format!("{} ({})", x.label, x.price_pct))
            .collect();
        println!("{}", parts.join("  |  "));
        println!();
        println!(
            "  Bid: {}  Ask: {}  Spread: {}",
            o.best_bid.map(|x| format!("{:.4}", x)).unwrap_or_else(|| "—".into()),
            o.best_ask.map(|x| format!("{:.4}", x)).unwrap_or_else(|| "—".into()),
            o.spread
                .map(|x| format!("{:.2}%", x * 100.0))
                .unwrap_or_else(|| "—".into())
        );
        println!(
            "  Volume 24h: {}  Liquidity: {}",
            fmt_usd(o.volume_24hr),
            fmt_usd(o.liquidity)
        );
        println!(
            "  negRisk: {}  Accepting orders: {}",
            o.neg_risk, o.accepting_orders
        );
        println!();
        println!("  CLOB token IDs:");
        for tid in &o.clob_token_ids {
            let short = if tid.len() > 24 {
                format!("{}…{}", &tid[..12], &tid[tid.len() - 8..])
            } else {
                tid.clone()
            };
            println!("    {}", short);
        }
        println!();
    });

    Ok(())
}

/// Open positions for a Polygon wallet (Polymarket Data API — read-only).
pub async fn cmd_polymarket_positions(cfg: &Config, user: String) -> Result<()> {
    let positions = zipher_engine::polymarket::polymarket_get_positions(&user).await?;
    print_ok(positions, cfg.human, |rows| {
        println!();
        println!("=== Polymarket — Open positions (Data API) ===");
        println!("  user: {}", user);
        println!();
        if rows.is_empty() {
            println!("  (no open positions)\n");
            return;
        }
        for p in rows {
            let title = p.title.as_deref().unwrap_or("(no title)");
            let out = p.outcome.as_deref().unwrap_or("?");
            println!("  {} — {}", title, out);
            println!(
                "    size: {:.4}  avg {:.2}%  cur {:.2}%  value {}  PnL {} ({:+.1}%)",
                p.size,
                p.avg_price * 100.0,
                p.cur_price * 100.0,
                fmt_usd(p.current_value),
                fmt_usd(p.cash_pnl),
                p.percent_pnl
            );
            println!("    condition_id: {}", p.condition_id);
            println!("    asset (token): {}", p.asset);
            println!();
        }
    });
    Ok(())
}

// ---------------------------------------------------------------------------
// Polymarket CLOB V2 — test order (full auth + sign + POST)
// ---------------------------------------------------------------------------

pub async fn cmd_polymarket_test_order(
    cfg: &Config,
    token_id: String,
    amount: f64,
    price: f64,
    side: String,
    neg_risk: bool,
) -> Result<()> {
    let seed_secret = read_seed(&cfg.data_dir)?;
    let seed = seed_secret.expose_secret();

    eprintln!("=== Polymarket CLOB V2 Test Order ===");
    eprintln!();

    // 1. Derive Polygon address
    let address = zipher_engine::polymarket::derive_address(seed)?;
    eprintln!("[1] Address: {}", address);

    // 2. L1 auth — derive CLOB API credentials
    eprintln!("[2] L1 auth — deriving CLOB API key...");
    let ts = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)?.as_secs();
    let (auth_addr, auth_sig) = zipher_engine::polymarket::sign_clob_auth(seed, ts, 0)?;
    let ts_str = ts.to_string();

    let l1_headers = [
        ("POLY_ADDRESS", auth_addr.as_str()),
        ("POLY_SIGNATURE", auth_sig.as_str()),
        ("POLY_TIMESTAMP", ts_str.as_str()),
        ("POLY_NONCE", "0"),
    ];

    let client = reqwest::Client::new();

    // Try derive existing key, fall back to create
    let mut resp = client
        .get("https://clob.polymarket.com/auth/derive-api-key")
        .headers(build_header_map(&l1_headers))
        .send().await?;

    if !resp.status().is_success() {
        eprintln!("   derive-api-key returned {}, trying create...", resp.status());
        resp = client
            .post("https://clob.polymarket.com/auth/api-key")
            .headers(build_header_map(&l1_headers))
            .send().await?;
    }

    let auth_body: serde_json::Value = resp.json().await?;
    eprintln!("   Auth response: {}", serde_json::to_string_pretty(&auth_body)?);

    let api_key = auth_body["apiKey"].as_str()
        .or_else(|| auth_body["key"].as_str())
        .ok_or_else(|| anyhow::anyhow!("No API key in auth response"))?;
    let api_secret = auth_body["secret"].as_str().unwrap_or("");
    let passphrase = auth_body["passphrase"].as_str().unwrap_or("");

    eprintln!("   API key: {}...", &api_key[..api_key.len().min(16)]);
    eprintln!();

    // 3. Build & sign V2 order
    eprintln!("[3] Building V2 order...");
    let side_int: u8 = if side.eq_ignore_ascii_case("BUY") { 0 } else { 1 };

    // Fetch tick size for precision rounding
    let tick_size: f64 = {
        let url = format!("https://clob.polymarket.com/tick-size?token_id={}", token_id);
        match client.get(&url).send().await {
            Ok(r) if r.status().is_success() => {
                let txt = r.text().await.unwrap_or_default();
                txt.trim().trim_matches('"').parse().unwrap_or(0.01)
            }
            _ => 0.01,
        }
    };
    let tick_decimals = {
        let s = format!("{}", tick_size);
        s.find('.').map(|d| s.len() - d - 1).unwrap_or(0)
    };
    eprintln!("   Tick size: {} ({} decimals)", tick_size, tick_decimals);

    // Express price as integer ratio for exact tick alignment
    let price_denom = 10u64.pow(tick_decimals as u32);
    let price_num = (price / tick_size).round() as u64;
    eprintln!("    Price as ratio: {}/{} = {:.6}", price_num, price_denom, price_num as f64 / price_denom as f64);

    let desired_taker = (amount / (price_num as f64 * tick_size) * 1e6).round() as u64;
    let shares_amount_raw = (desired_taker / price_denom) * price_denom;
    let maker_amount_raw = shares_amount_raw * price_num / price_denom;

    let (m_raw, t_raw) = if side_int == 0 {
        (maker_amount_raw.to_string(), shares_amount_raw.to_string())
    } else {
        (shares_amount_raw.to_string(), maker_amount_raw.to_string())
    };

    let salt = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)?.as_millis().to_string();
    let timestamp = (std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)?.as_secs()).to_string();
    let zero_bytes32 = "0x0000000000000000000000000000000000000000000000000000000000000000";

    let order = zipher_engine::polymarket::PolymarketOrder {
        salt: salt.clone(),
        maker: address.clone(),
        signer: address.clone(),
        token_id: token_id.clone(),
        maker_amount: m_raw.clone(),
        taker_amount: t_raw.clone(),
        side: side_int,
        signature_type: 0,
        timestamp: timestamp.clone(),
        metadata: zero_bytes32.to_string(),
        builder: zero_bytes32.to_string(),
    };

    eprintln!("   Order: {:?}", order);

    let signature = zipher_engine::polymarket::sign_order(seed, &order, neg_risk)?;
    eprintln!("   Signature: {}...", &signature[..signature.len().min(20)]);
    eprintln!();

    // 4. Build JSON body (raw integer amounts, same as EIP-712)
    let order_body = serde_json::json!({
        "order": {
            "salt": salt.parse::<i64>().unwrap_or(0),
            "maker": address,
            "signer": address,
            "tokenId": token_id,
            "makerAmount": m_raw,
            "takerAmount": t_raw,
            "side": side.to_uppercase(),
            "signatureType": 0,
            "timestamp": timestamp,
            "metadata": zero_bytes32,
            "builder": zero_bytes32,
            "signature": signature,
        },
        "owner": api_key,
        "orderType": "GTC",
    });

    eprintln!("[4] Posting order to CLOB...");
    eprintln!("   Body: {}", serde_json::to_string_pretty(&order_body)?);

    // 5. Build L2 HMAC headers
    let body_str = serde_json::to_string(&order_body)?;
    let hmac_ts = (std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)?.as_secs()).to_string();
    let hmac_message = format!("{}POST/order{}", hmac_ts, body_str);
    eprintln!("   HMAC message: {}...{}", &hmac_message[..60.min(hmac_message.len())], &hmac_message[hmac_message.len().saturating_sub(30)..]);

    use hmac::{Hmac, Mac};
    use sha2::Sha256;
    type HmacSha256 = Hmac<Sha256>;

    let secret_bytes = base64::Engine::decode(
        &base64::engine::general_purpose::STANDARD, api_secret
    ).unwrap_or_default();
    let mut mac = HmacSha256::new_from_slice(&secret_bytes)
        .map_err(|e| anyhow::anyhow!("HMAC init failed: {}", e))?;
    mac.update(hmac_message.as_bytes());
    let hmac_sig = base64::Engine::encode(
        &base64::engine::general_purpose::URL_SAFE,
        mac.finalize().into_bytes()
    );

    eprintln!("   HMAC sig: {}...", &hmac_sig[..20.min(hmac_sig.len())]);
    eprintln!("   L2 headers: POLY_ADDRESS={}, POLY_API_KEY={}, POLY_TIMESTAMP={}", &address, api_key, &hmac_ts);

    let l2_headers = [
        ("Content-Type", "application/json"),
        ("POLY_ADDRESS", &address),
        ("POLY_API_KEY", api_key),
        ("POLY_SIGNATURE", &hmac_sig),
        ("POLY_TIMESTAMP", &hmac_ts),
        ("POLY_PASSPHRASE", passphrase),
    ];

    let resp = client
        .post("https://clob.polymarket.com/order")
        .headers(build_header_map(&l2_headers))
        .body(body_str)
        .send().await?;

    let status = resp.status();
    let resp_body: serde_json::Value = resp.json().await
        .unwrap_or_else(|_| serde_json::json!({"error": "non-JSON response"}));

    eprintln!();
    eprintln!("[5] Response (HTTP {}):", status);
    eprintln!("{}", serde_json::to_string_pretty(&resp_body)?);

    if status.is_success() {
        println!("Order posted successfully!");
    } else {
        eprintln!("Order failed.");
    }

    Ok(())
}

fn build_header_map(pairs: &[(&str, &str)]) -> reqwest::header::HeaderMap {
    let mut map = reqwest::header::HeaderMap::new();
    for (k, v) in pairs {
        if let (Ok(name), Ok(val)) = (
            reqwest::header::HeaderName::from_bytes(k.as_bytes()),
            reqwest::header::HeaderValue::from_str(v),
        ) {
            map.insert(name, val);
        }
    }
    map
}

// ---------------------------------------------------------------------------
// polymarket full-bet — on-chain flow: approve → wrap → approve → sign → post
// ---------------------------------------------------------------------------

pub async fn cmd_polymarket_full_bet(
    cfg: &crate::Config,
    token_id: String,
    amount: f64,
    price: f64,
    side: String,
    neg_risk: bool,
) -> anyhow::Result<()> {
    use secrecy::ExposeSecret;

    const POLYGON_RPC: &str = "https://polygon-bor-rpc.publicnode.com";
    const USDCE: &str = "0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174";
    const PUSD: &str = "0xC011a7E12a19f7B1f670d46F03B03f3342E82DFB";
    const ONRAMP: &str = "0x93070a847efEf7F70739046A929D47a521F5B8ee";

    let seed_secret = read_seed(&cfg.data_dir)?;
    let seed = seed_secret.expose_secret().clone();
    let address = zipher_engine::ows::derive_evm_address(&seed)?;
    let exchange = if neg_risk {
        zipher_engine::polymarket::NEG_RISK_CTF_EXCHANGE
    } else {
        zipher_engine::polymarket::CTF_EXCHANGE
    };

    eprintln!("=== Polymarket Full Bet (on-chain) ===\n");
    eprintln!("[1] Address: {}", address);

    // -- Check balances --
    let usdce_bal = zipher_engine::evm::get_erc20_balance(POLYGON_RPC, USDCE, &address).await?;
    let pusd_bal = zipher_engine::evm::get_erc20_balance(POLYGON_RPC, PUSD, &address).await?;
    let pol_bal = zipher_engine::evm::get_native_balance(POLYGON_RPC, &address).await?;
    eprintln!("[2] Balances:");
    eprintln!("    USDC.e:  {:.6}", usdce_bal as f64 / 1e6);
    eprintln!("    pUSD:    {:.6}", pusd_bal as f64 / 1e6);
    eprintln!("    POL:     {:.4}", pol_bal as f64 / 1e18);

    let amount_micro = (amount * 1e6) as u128;
    if usdce_bal < amount_micro && pusd_bal < amount_micro {
        eprintln!("\n  Not enough USDC.e or pUSD. Need {} but have USDC.e={}, pUSD={}",
            amount_micro, usdce_bal, pusd_bal);
        return Err(anyhow::anyhow!("Insufficient balance"));
    }

    // -- Only wrap if we don't already have enough pUSD --
    if pusd_bal < amount_micro {
        eprintln!("\n[3] Approving USDC.e → CollateralOnramp...");
        let fees = zipher_engine::evm::suggest_eip1559_fees(POLYGON_RPC, 137).await?;
        let approve_hash = zipher_engine::evm::approve_erc20(
            POLYGON_RPC, &seed, &address, USDCE, ONRAMP, amount_micro, 137, &fees,
        ).await?;
        let r = zipher_engine::evm::wait_for_receipt(POLYGON_RPC, &approve_hash, 60).await?;
        eprintln!("    tx: {} (status: {}, gas: {})", approve_hash, if r.status { "OK" } else { "REVERTED" }, r.gas_used);
        if !r.status { return Err(anyhow::anyhow!("Approve USDC.e reverted")); }

        eprintln!("[4] Wrapping USDC.e → pUSD via CollateralOnramp.wrap(asset,to,amount)...");
        // Build calldata: wrap(address _asset, address _to, uint256 _amount) = 0x62355638
        let asset_clean = USDCE.trim_start_matches("0x");
        let to_clean = address.trim_start_matches("0x");
        let mut calldata = Vec::with_capacity(100);
        calldata.extend_from_slice(&hex::decode("62355638").unwrap());
        // _asset
        calldata.extend_from_slice(&[0u8; 12]);
        calldata.extend_from_slice(&hex::decode(asset_clean.to_lowercase()).unwrap());
        // _to
        calldata.extend_from_slice(&[0u8; 12]);
        calldata.extend_from_slice(&hex::decode(to_clean.to_lowercase()).unwrap());
        // _amount
        let amount_bytes = amount_micro.to_be_bytes(); // u128 = 16 bytes
        calldata.extend_from_slice(&[0u8; 16]); // pad to 32
        calldata.extend_from_slice(&amount_bytes);

        let nonce = zipher_engine::evm::get_nonce(POLYGON_RPC, &address).await?;
        let fees = zipher_engine::evm::suggest_eip1559_fees(POLYGON_RPC, 137).await?;
        let unsigned = zipher_engine::evm::build_unsigned_eip1559_tx(
            137, nonce, fees.max_priority_fee_per_gas, fees.max_fee_per_gas,
            200_000, ONRAMP, &[0], &calldata,
        );
        let wrap_hash = zipher_engine::evm::sign_and_broadcast(&seed, &unsigned, POLYGON_RPC).await?;
        eprintln!("    tx: {}", wrap_hash);
        let r = zipher_engine::evm::wait_for_receipt(POLYGON_RPC, &wrap_hash, 60).await?;
        eprintln!("    status: {}, gas: {}", if r.status { "OK" } else { "REVERTED" }, r.gas_used);
        if !r.status { return Err(anyhow::anyhow!("Wrap USDC.e → pUSD reverted")); }

        // Verify pUSD balance
        let new_pusd = zipher_engine::evm::get_erc20_balance(POLYGON_RPC, PUSD, &address).await?;
        eprintln!("    pUSD balance after wrap: {:.6}", new_pusd as f64 / 1e6);
    } else {
        eprintln!("\n[3-4] Already have enough pUSD, skipping wrap.");
    }

    // -- Approve pUSD to exchange with fee buffer --
    let approve_micro = (amount * 1.05 * 1e6) as u128; // 5% buffer for CLOB fees
    eprintln!("[5] Approving {} pUSD → exchange {}...", approve_micro as f64 / 1e6, &exchange[..10]);
    let fees2 = zipher_engine::evm::suggest_eip1559_fees(POLYGON_RPC, 137).await?;
    let approve_hash = zipher_engine::evm::approve_erc20(
        POLYGON_RPC, &seed, &address, PUSD, exchange, approve_micro, 137, &fees2,
    ).await?;
    let r = zipher_engine::evm::wait_for_receipt(POLYGON_RPC, &approve_hash, 60).await?;
    eprintln!("    tx: {} (status: {}, gas: {})", approve_hash, if r.status { "OK" } else { "REVERTED" }, r.gas_used);
    if !r.status { return Err(anyhow::anyhow!("Approve pUSD reverted")); }

    // -- L1 auth --
    eprintln!("[6] L1 auth...");
    let client = reqwest::Client::new();
    let ts = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH)?.as_secs();
    let (auth_addr, auth_sig) = zipher_engine::polymarket::sign_clob_auth(&seed, ts, 0)?;
    let ts_str = ts.to_string();
    let l1_headers = [
        ("POLY_ADDRESS", auth_addr.as_str()),
        ("POLY_SIGNATURE", auth_sig.as_str()),
        ("POLY_TIMESTAMP", ts_str.as_str()),
        ("POLY_NONCE", "0"),
    ];
    let mut resp = client
        .get("https://clob.polymarket.com/auth/derive-api-key")
        .headers(build_header_map(&l1_headers))
        .send().await?;
    if !resp.status().is_success() {
        let st = resp.status();
        let body = resp.text().await.unwrap_or_default();
        eprintln!("    derive-api-key: {} — {}", st, body);
        resp = client.post("https://clob.polymarket.com/auth/api-key")
            .headers(build_header_map(&l1_headers))
            .send().await?;
    }
    let auth_status = resp.status();
    let auth_body = resp.text().await?;
    if !auth_status.is_success() {
        return Err(anyhow::anyhow!("L1 auth failed ({}): {}", auth_status, auth_body));
    }
    let creds: serde_json::Value = serde_json::from_str(&auth_body)
        .map_err(|e| anyhow::anyhow!("Failed to parse auth response: {} — body: {}", e, auth_body))?;
    let api_key = creds["apiKey"].as_str().or(creds["key"].as_str())
        .ok_or_else(|| anyhow::anyhow!("No apiKey"))?;
    let api_secret = creds["secret"].as_str().unwrap_or("");
    let passphrase = creds["passphrase"].as_str().unwrap_or("");
    eprintln!("    API key: {}...", &api_key[..16.min(api_key.len())]);

    // -- Fetch tick size & build order --
    eprintln!("[7] Building order...");
    let tick_size: f64 = {
        let url = format!("https://clob.polymarket.com/tick-size?token_id={}", token_id);
        match client.get(&url).send().await {
            Ok(r) if r.status().is_success() => {
                let txt = r.text().await.unwrap_or_default();
                txt.trim().trim_matches('"').parse().unwrap_or(0.01)
            }
            _ => 0.01,
        }
    };
    let tick_decimals = {
        let s = format!("{}", tick_size);
        s.find('.').map(|d| s.len() - d - 1).unwrap_or(0)
    };
    eprintln!("    Tick size: {} ({} decimals)", tick_size, tick_decimals);

    let side_int: u8 = if side.eq_ignore_ascii_case("BUY") { 0 } else { 1 };

    // Express price as integer ratio for exact tick alignment
    let price_denom = 10u64.pow(tick_decimals as u32);
    let price_num = (price / tick_size).round() as u64;
    eprintln!("    Price as ratio: {}/{} = {:.6}", price_num, price_denom, price_num as f64 / price_denom as f64);

    let desired_taker = (amount / (price_num as f64 * tick_size) * 1e6).round() as u64;
    let shares_amount_raw = (desired_taker / price_denom) * price_denom;
    let maker_amount_raw = shares_amount_raw * price_num / price_denom;

    let (m_raw, t_raw) = if side_int == 0 {
        (maker_amount_raw.to_string(), shares_amount_raw.to_string())
    } else {
        (shares_amount_raw.to_string(), maker_amount_raw.to_string())
    };
    eprintln!("    makerAmount: {}, takerAmount: {}", m_raw, t_raw);

    let salt = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH)?
        .as_millis().to_string();
    let timestamp = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH)?
        .as_secs().to_string();
    let zero_bytes32 = "0x0000000000000000000000000000000000000000000000000000000000000000";

    let order = zipher_engine::polymarket::PolymarketOrder {
        salt: salt.clone(), maker: address.clone(), signer: address.clone(),
        token_id: token_id.clone(),
        maker_amount: m_raw.clone(), taker_amount: t_raw.clone(),
        side: side_int, signature_type: 0,
        timestamp: timestamp.clone(),
        metadata: zero_bytes32.to_string(), builder: zero_bytes32.to_string(),
    };
    let signature = zipher_engine::polymarket::sign_order(&seed, &order, neg_risk)?;

    // -- Post order --
    eprintln!("[8] Posting order...");
    let order_body = serde_json::json!({
        "order": {
            "salt": salt.parse::<i64>().unwrap_or(0),
            "maker": address, "signer": address, "tokenId": token_id,
            "makerAmount": m_raw, "takerAmount": t_raw,
            "side": side.to_uppercase(), "signatureType": 0,
            "timestamp": timestamp, "metadata": zero_bytes32, "builder": zero_bytes32,
            "signature": signature,
        },
        "owner": api_key, "orderType": "GTC",
    });

    let body_str = serde_json::to_string(&order_body)?;
    let hmac_ts = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)?.as_secs().to_string();
    let hmac_message = format!("{}POST/order{}", hmac_ts, body_str);

    use hmac::{Hmac, Mac};
    use sha2::Sha256;
    type HmacSha256 = Hmac<Sha256>;

    let secret_bytes = base64::Engine::decode(
        &base64::engine::general_purpose::STANDARD, api_secret
    ).unwrap_or_default();
    let mut mac = HmacSha256::new_from_slice(&secret_bytes)
        .map_err(|e| anyhow::anyhow!("HMAC init failed: {}", e))?;
    mac.update(hmac_message.as_bytes());
    let hmac_sig = base64::Engine::encode(
        &base64::engine::general_purpose::URL_SAFE,
        mac.finalize().into_bytes()
    );

    let l2_headers = [
        ("Content-Type", "application/json"),
        ("POLY_ADDRESS", &address),
        ("POLY_API_KEY", api_key),
        ("POLY_SIGNATURE", &hmac_sig),
        ("POLY_TIMESTAMP", &hmac_ts),
        ("POLY_PASSPHRASE", passphrase),
    ];

    let resp = client
        .post("https://clob.polymarket.com/order")
        .headers(build_header_map(&l2_headers))
        .body(body_str)
        .send().await?;

    let status = resp.status();
    let body = resp.text().await?;
    eprintln!("\n[9] Response (HTTP {}):", status);
    if let Ok(parsed) = serde_json::from_str::<serde_json::Value>(&body) {
        eprintln!("{}", serde_json::to_string_pretty(&parsed)?);
    } else {
        eprintln!("{}", body);
    }

    if status.is_success() {
        eprintln!("\nOrder placed successfully!");
    } else {
        eprintln!("\nOrder failed.");
    }

    Ok(())
}
