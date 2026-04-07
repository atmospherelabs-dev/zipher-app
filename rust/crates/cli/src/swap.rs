use anyhow::Result;
use serde::Serialize;

use crate::helpers::*;
use crate::{print_ok, Config};

pub async fn cmd_swap_tokens(cfg: &Config) -> Result<()> {
    let tokens = zipher_engine::swap::get_tokens().await?;

    #[derive(Serialize)]
    struct TokenInfo {
        asset_id: String,
        symbol: String,
        blockchain: String,
        decimals: u32,
        price: Option<f64>,
    }

    let list: Vec<TokenInfo> = zipher_engine::swap::swappable_tokens(&tokens)
        .into_iter()
        .map(|t| TokenInfo {
            asset_id: t.asset_id.clone(),
            symbol: t.symbol.clone(),
            blockchain: t.blockchain.clone(),
            decimals: t.decimals,
            price: t.price,
        })
        .collect();

    let zec = zipher_engine::swap::find_zec_token(&tokens);

    #[derive(Serialize)]
    struct TokensResult {
        zec_asset_id: Option<String>,
        available_tokens: Vec<TokenInfo>,
        total: usize,
    }

    let total = list.len();
    print_ok(
        TokensResult {
            zec_asset_id: zec.map(|t| t.asset_id.clone()),
            available_tokens: list,
            total,
        },
        cfg.human,
        |r| {
            if let Some(ref zec_id) = r.zec_asset_id {
                println!("ZEC asset ID: {}", zec_id);
            }
            println!("{} swappable tokens available.", r.total);
            for t in &r.available_tokens {
                let price = t.price.map_or("n/a".into(), |p| format!("${:.2}", p));
                println!("  {} ({}) — {} — {}", t.symbol, t.blockchain, t.asset_id, price);
            }
        },
    );
    Ok(())
}

pub async fn cmd_swap_quote(
    cfg: &Config,
    to_symbol: String,
    chain: Option<String>,
    amount: u64,
    recipient: String,
    slippage: u32,
) -> Result<()> {
    let tokens = zipher_engine::swap::get_tokens().await?;

    let zec = zipher_engine::swap::find_zec_token(&tokens)
        .ok_or_else(|| anyhow::anyhow!("ZEC not found in Near Intents token list"))?;

    let dest = find_destination_token(&tokens, &to_symbol, chain.as_deref())?;

    auto_open(cfg).await?;
    let addresses = zipher_engine::query::get_addresses().await?;
    let refund_addr = addresses
        .first()
        .map(|a| a.address.clone())
        .unwrap_or_default();

    let quote = zipher_engine::swap::get_quote(
        &zec.asset_id,
        &dest.asset_id,
        &amount.to_string(),
        &recipient,
        &refund_addr,
        slippage,
    )
    .await?;

    print_ok(&quote, cfg.human, |q| {
        println!("Swap quote received:");
        println!("  Send:    {} zat ZEC", q.amount_in);
        println!("  Receive: {} {} ({})", q.amount_out, to_symbol, dest.blockchain);
        if let Some(ref min) = q.min_amount_out {
            println!("  Min out: {}", min);
        }
        println!("  Deposit: {}", q.deposit_address);
        println!("  Deadline: {}", q.deadline);
        println!();
        println!("To execute: zipher-cli swap execute --to {} --amount {} --recipient {}", to_symbol, amount, recipient);
    });

    zipher_engine::wallet::close().await;
    Ok(())
}

pub async fn cmd_swap_execute(
    cfg: &Config,
    to_symbol: String,
    chain: Option<String>,
    amount: u64,
    recipient: String,
    slippage: u32,
    context_id: Option<String>,
) -> Result<()> {
    ensure_sapling_params(&cfg.data_dir).await?;
    sync_if_needed(cfg).await?;

    let tokens = zipher_engine::swap::get_tokens().await?;
    let zec = zipher_engine::swap::find_zec_token(&tokens)
        .ok_or_else(|| anyhow::anyhow!("ZEC not found in Near Intents token list"))?;
    let dest = find_destination_token(&tokens, &to_symbol, chain.as_deref())?;

    auto_open(cfg).await?;
    let addresses = zipher_engine::query::get_addresses().await?;
    let refund_addr = addresses
        .first()
        .map(|a| a.address.clone())
        .unwrap_or_default();

    let quote = zipher_engine::swap::get_quote(
        &zec.asset_id,
        &dest.asset_id,
        &amount.to_string(),
        &recipient,
        &refund_addr,
        slippage,
    )
    .await?;

    if quote.deposit_address.is_empty() {
        return Err(anyhow::anyhow!("No deposit address in quote"));
    }

    if cfg.human {
        eprintln!(
            "Sending {} zat to deposit address {} (swap to {} {})",
            amount, quote.deposit_address, to_symbol, dest.blockchain
        );
    }

    let policy = zipher_engine::policy::load_policy(&cfg.data_dir);
    let daily_spent = zipher_engine::audit::daily_spent(&cfg.data_dir).unwrap_or(0);
    if let Err(violation) = zipher_engine::policy::check_proposal(
        &policy, &quote.deposit_address, amount, &context_id, daily_spent,
    ) {
        zipher_engine::audit::log_event(
            &cfg.data_dir, "swap_execute", Some(&quote.deposit_address),
            Some(amount), None, context_id.as_deref(),
            None, Some(&violation.to_string()),
        ).ok();
        return Err(anyhow::anyhow!("{}", violation));
    }
    if let Err(violation) = zipher_engine::policy::check_rate_limit(&policy) {
        zipher_engine::audit::log_event(
            &cfg.data_dir, "swap_execute", Some(&quote.deposit_address),
            Some(amount), None, context_id.as_deref(),
            None, Some(&violation.to_string()),
        ).ok();
        return Err(anyhow::anyhow!("{}", violation));
    }

    let (send_amount, fee, _) =
        zipher_engine::send::propose_send(&quote.deposit_address, amount, None, false).await?;

    let seed = read_seed(&cfg.data_dir)?;
    let txid = match zipher_engine::send::confirm_send(&seed).await {
        Ok(txid) => {
            zipher_engine::policy::record_confirm();
            zipher_engine::audit::log_event(
                &cfg.data_dir, "swap_execute", Some(&quote.deposit_address),
                Some(send_amount), Some(fee), context_id.as_deref(),
                Some(&txid), None,
            ).ok();
            txid
        }
        Err(e) => {
            zipher_engine::audit::log_event(
                &cfg.data_dir, "swap_execute", Some(&quote.deposit_address),
                Some(send_amount), Some(fee), context_id.as_deref(),
                None, Some(&format!("{:#}", e)),
            ).ok();
            return Err(e);
        }
    };

    delete_pending(&cfg.data_dir);

    if let Err(e) = zipher_engine::swap::submit_deposit(&txid, &quote.deposit_address).await {
        if cfg.human {
            eprintln!("Warning: deposit submit notification failed: {}. Swap may still proceed.", e);
        }
    }

    #[derive(Serialize)]
    struct SwapResult {
        txid: String,
        deposit_address: String,
        amount_in: String,
        amount_out: String,
        destination_symbol: String,
        destination_chain: String,
        recipient: String,
        fee: u64,
    }

    print_ok(
        SwapResult {
            txid: txid.clone(),
            deposit_address: quote.deposit_address.clone(),
            amount_in: quote.amount_in.clone(),
            amount_out: quote.amount_out.clone(),
            destination_symbol: to_symbol.clone(),
            destination_chain: dest.blockchain.clone(),
            recipient: recipient.clone(),
            fee,
        },
        cfg.human,
        |r| {
            println!("Swap initiated.");
            println!("  ZEC txid:     {}", r.txid);
            println!("  Deposit addr: {}", r.deposit_address);
            println!("  Amount in:    {} zat", r.amount_in);
            println!("  Amount out:   {} {} ({})", r.amount_out, r.destination_symbol, r.destination_chain);
            println!("  Recipient:    {}", r.recipient);
            println!("  Fee:          {} zat", r.fee);
            println!();
            println!("Check status: zipher-cli swap status --deposit-address {}", r.deposit_address);
        },
    );

    zipher_engine::wallet::close().await;
    Ok(())
}

pub async fn cmd_swap_status(_cfg: &Config, deposit_address: String) -> Result<()> {
    let status = zipher_engine::swap::get_status(&deposit_address).await?;

    print_ok(&status, _cfg.human, |s| {
        println!("Swap status: {}", s.status);
        if let Some(ref h) = s.tx_hash_in {
            println!("  TX in:  {}", h);
        }
        if let Some(ref h) = s.tx_hash_out {
            println!("  TX out: {}", h);
        }
    });
    Ok(())
}

pub fn find_destination_token<'a>(
    tokens: &'a [zipher_engine::swap::SwapToken],
    symbol: &str,
    chain: Option<&str>,
) -> Result<&'a zipher_engine::swap::SwapToken> {
    let matches: Vec<&zipher_engine::swap::SwapToken> = tokens
        .iter()
        .filter(|t| t.symbol.eq_ignore_ascii_case(symbol))
        .filter(|t| {
            chain.map_or(true, |c| t.blockchain.eq_ignore_ascii_case(c))
        })
        .collect();

    match matches.len() {
        0 => Err(anyhow::anyhow!(
            "Token '{}' not found{}",
            symbol,
            chain.map_or(String::new(), |c| format!(" on chain '{}'", c))
        )),
        1 => Ok(matches[0]),
        _ => {
            let chains: Vec<String> = matches.iter().map(|t| t.blockchain.clone()).collect();
            Err(anyhow::anyhow!(
                "'{}' exists on multiple chains: {}. Use --chain to specify.",
                symbol,
                chains.join(", ")
            ))
        }
    }
}
