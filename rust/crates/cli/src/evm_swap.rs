//! CLI handler for `zipher-cli evm-swap`.
//!
//! Interactive flow: chain → balances → source token → dest token → amount → quote → confirm → execute.
//! Verbose step-by-step output for debugging swap issues.

use std::io::{self, Write as _};

use anyhow::Result;
use secrecy::{ExposeSecret, SecretString};

use zipher_engine::evm::{self, ChainConfig, PARASWAP_NATIVE};
use zipher_engine::evm_swap;

use crate::market::get_ows_evm_address;
use crate::Config;

// ---------------------------------------------------------------------------
// OWS seed helper
// ---------------------------------------------------------------------------

fn read_ows_seed(wallet: &str) -> Result<SecretString> {
    let passphrase = std::env::var("OWS_PASSPHRASE").unwrap_or_default();
    let exported = ows_lib::export_wallet(wallet, Some(&passphrase), None)
        .map_err(|e| anyhow::anyhow!("Failed to export OWS wallet '{}': {}", wallet, e))?;

    if exported.contains(' ') && !exported.starts_with('{') {
        Ok(SecretString::new(exported))
    } else {
        Err(anyhow::anyhow!(
            "OWS wallet '{}' does not contain a mnemonic (needed for EVM signing)",
            wallet
        ))
    }
}

// ---------------------------------------------------------------------------
// Public entry point
// ---------------------------------------------------------------------------

pub async fn cmd_evm_swap(
    _cfg: &Config,
    chain: Option<String>,
    from: Option<String>,
    to: Option<String>,
    amount: Option<String>,
    slippage: u32,
    yes: bool,
    ows_wallet: String,
) -> Result<()> {
    eprintln!();

    // ── Step 1: Resolve EVM address from OWS ─────────────────────────────
    eprintln!("[1/7] Resolving EVM address from OWS wallet '{}'...", ows_wallet);
    let address = get_ows_evm_address(&ows_wallet).await?;
    let seed = read_ows_seed(&ows_wallet)?;
    eprintln!("      {}", address);
    eprintln!();

    // ── Step 2: Resolve chain ────────────────────────────────────────────
    let chain_cfg = resolve_chain(chain.as_deref())?;
    eprintln!("[2/7] Fetching balances on {} ({})...", chain_cfg.name, chain_cfg.chain_id);

    let tokens = evm::known_tokens(chain_cfg.chain_id);
    let mut balances: Vec<(String, String, u128, u8)> = Vec::new(); // (symbol, address, raw, decimals)

    for t in &tokens {
        let raw = if t.address == PARASWAP_NATIVE {
            evm::get_native_balance(chain_cfg.rpc_url, &address).await.unwrap_or(0)
        } else {
            evm::get_erc20_balance(chain_cfg.rpc_url, t.address, &address).await.unwrap_or(0)
        };
        let human = evm::format_token_amount(raw, t.decimals);
        let label = if t.address == PARASWAP_NATIVE {
            format!("{} (native)", t.symbol)
        } else {
            t.symbol.to_string()
        };
        eprintln!("      {:12} {}", label, human);
        balances.push((t.symbol.to_string(), t.address.to_string(), raw, t.decimals));
    }
    eprintln!();

    // ── Step 3: Source token ─────────────────────────────────────────────
    let src = resolve_token(&balances, from.as_deref(), "Source token")?;
    let src_balance = balances.iter().find(|b| b.0 == src.0).map(|b| b.2).unwrap_or(0);
    if src_balance == 0 {
        return Err(anyhow::anyhow!("Zero balance for {}. Nothing to swap.", src.0));
    }

    // ── Step 4: Dest token ───────────────────────────────────────────────
    let dst = resolve_token(&balances, to.as_deref(), "Dest token")?;
    if src.1 == dst.1 {
        return Err(anyhow::anyhow!("Source and destination tokens are the same."));
    }

    // ── Step 5: Amount ───────────────────────────────────────────────────
    let amount_raw = resolve_amount(amount.as_deref(), &src.0, src.2, src_balance)?;
    let amount_human = evm::format_token_amount(amount_raw, src.2);

    eprintln!("  Source:  {} ({})", src.0, if src.1 == PARASWAP_NATIVE { "native" } else { &src.1 });
    eprintln!("  Dest:   {} ({})", dst.0, if dst.1 == PARASWAP_NATIVE { "native" } else { &dst.1 });
    eprintln!("  Amount: {} {}", amount_human, src.0);
    eprintln!();

    // ── Step 6: Get quote ────────────────────────────────────────────────
    eprintln!("[3/7] Getting ParaSwap quote...");
    let quote = evm_swap::get_quote(
        chain_cfg.chain_id,
        &src.1,
        src.2 as u32,
        &dst.1,
        dst.2 as u32,
        &amount_raw.to_string(),
        &address,
    ).await?;

    let dest_human = evm::format_token_amount(
        quote.dest_amount.parse::<u128>().unwrap_or(0),
        dst.2,
    );
    eprintln!("      Expected output: {} {}", dest_human, dst.0);
    eprintln!("      Slippage: {}%", slippage as f64 / 100.0);
    eprintln!();

    // ── Confirm ──────────────────────────────────────────────────────────
    if !yes {
        eprint!("Proceed? [y/N] ");
        io::stderr().flush()?;
        let mut line = String::new();
        io::stdin().read_line(&mut line)?;
        if !line.trim().eq_ignore_ascii_case("y") {
            eprintln!("Cancelled.");
            return Ok(());
        }
    }

    // ── Step 7: Dynamic gas fees ─────────────────────────────────────────
    eprintln!("[4/7] Fetching dynamic gas fees...");
    let fees = evm::suggest_eip1559_fees(chain_cfg.rpc_url, chain_cfg.chain_id).await?;
    eprintln!("      {}", fees);
    eprintln!();

    // ── Step 8: Approve if ERC-20 ────────────────────────────────────────
    let is_native = src.1.eq_ignore_ascii_case(PARASWAP_NATIVE);
    if !is_native && !quote.token_transfer_proxy.is_empty() {
        let allowance = evm::get_erc20_allowance(
            chain_cfg.rpc_url,
            &src.1,
            &address,
            &quote.token_transfer_proxy,
        ).await.unwrap_or(0);

        if allowance < amount_raw {
            eprintln!("      Approving {} for spending (allowance {} < needed {})...", quote.token_transfer_proxy, allowance, amount_raw);
            evm::approve_erc20(
                chain_cfg.rpc_url,
                seed.expose_secret(),
                &address,
                &src.1,
                &quote.token_transfer_proxy,
                u128::MAX,
                chain_cfg.chain_id,
                &fees,
            ).await?;
            eprintln!("      Approved.");
        } else {
            eprintln!("      Allowance OK ({} >= {})", allowance, amount_raw);
        }
        eprintln!();
    }

    // ── Step 9: Build swap tx ────────────────────────────────────────────
    eprintln!("[5/7] Building unsigned EIP-1559 tx...");
    let swap_tx = evm_swap::build_swap_tx(
        chain_cfg.chain_id,
        &quote,
        &address,
        slippage,
    ).await?;

    let nonce = evm::get_nonce(chain_cfg.rpc_url, &address).await?;
    eprintln!("      nonce: {}", nonce);

    let gas_with_buffer = swap_tx.gas_estimate + swap_tx.gas_estimate / 5;
    eprintln!("      gas limit: {} (estimate {} + 20%)", gas_with_buffer, swap_tx.gas_estimate);

    let unsigned = evm::build_unsigned_eip1559_tx(
        chain_cfg.chain_id,
        nonce,
        fees.max_priority_fee_per_gas,
        fees.max_fee_per_gas,
        gas_with_buffer,
        &swap_tx.to,
        &swap_tx.value_wei,
        &swap_tx.data,
    );

    eprintln!("      unsigned hex ({} bytes): 0x{}", unsigned.len(), hex::encode(&unsigned));
    eprintln!();

    // ── Step 10: Sign and broadcast ──────────────────────────────────────
    eprintln!("[6/7] Signing and broadcasting...");
    let signed = zipher_engine::ows::sign_evm_tx(seed.expose_secret(), &unsigned)?;
    eprintln!("      signed hex ({} bytes): 0x{}...{}", signed.len(), &hex::encode(&signed)[..20], &hex::encode(&signed)[signed.len()*2-20..]);

    let tx_hash = evm::sign_and_broadcast(seed.expose_secret(), &unsigned, chain_cfg.rpc_url).await?;
    eprintln!("      tx hash: {}", tx_hash);
    eprintln!("      explorer: {}{}", chain_cfg.explorer_tx, tx_hash);
    eprintln!();

    // ── Step 11: Wait for receipt ────────────────────────────────────────
    eprintln!("[7/7] Waiting for receipt...");
    match evm::wait_for_receipt(chain_cfg.rpc_url, &tx_hash, 120).await {
        Ok(receipt) => {
            if receipt.status {
                eprintln!("      Block: {}, status: SUCCESS, gas used: {}", receipt.block_number, receipt.gas_used);
                eprintln!();
                eprintln!("Swap complete: {} {} -> ~{} {}", amount_human, src.0, dest_human, dst.0);
            } else {
                eprintln!("      Block: {}, status: REVERTED, gas used: {}", receipt.block_number, receipt.gas_used);
                return Err(anyhow::anyhow!("Swap transaction reverted in block {}", receipt.block_number));
            }
        }
        Err(e) => {
            eprintln!("      WARNING: {}", e);
            eprintln!("      The tx may still confirm. Check the explorer:");
            eprintln!("      {}{}", chain_cfg.explorer_tx, tx_hash);
            return Err(e);
        }
    }

    Ok(())
}

// ---------------------------------------------------------------------------
// Interactive helpers
// ---------------------------------------------------------------------------

fn resolve_chain(name: Option<&str>) -> Result<&'static ChainConfig> {
    if let Some(n) = name {
        return evm::chain_by_name(n).ok_or_else(|| {
            anyhow::anyhow!(
                "Unknown chain '{}'. Supported: polygon, bsc, ethereum, base, arbitrum",
                n
            )
        });
    }

    eprintln!("Choose a chain:");
    eprintln!("  1) Polygon (137)");
    eprintln!("  2) BNB Smart Chain (56)");
    eprintln!("  3) Ethereum (1)");
    eprintln!("  4) Base (8453)");
    eprintln!("  5) Arbitrum (42161)");
    eprint!("> ");
    io::stderr().flush().ok();

    let mut line = String::new();
    io::stdin().read_line(&mut line)?;
    match line.trim() {
        "1" | "polygon" => Ok(&evm::POLYGON),
        "2" | "bsc" => Ok(&evm::BSC),
        "3" | "ethereum" | "eth" => Ok(&evm::ETHEREUM),
        "4" | "base" => Ok(&evm::BASE),
        "5" | "arbitrum" | "arb" => Ok(&evm::ARBITRUM),
        other => Err(anyhow::anyhow!("Invalid selection: {}", other)),
    }
}

fn resolve_token(
    balances: &[(String, String, u128, u8)],
    name: Option<&str>,
    prompt: &str,
) -> Result<(String, String, u8)> {
    if let Some(n) = name {
        let upper = n.to_uppercase();
        if let Some(b) = balances.iter().find(|b| b.0.to_uppercase() == upper) {
            return Ok((b.0.clone(), b.1.clone(), b.3));
        }
        // Maybe it's a raw address
        let lower = n.to_lowercase();
        if let Some(b) = balances.iter().find(|b| b.1.to_lowercase() == lower) {
            return Ok((b.0.clone(), b.1.clone(), b.3));
        }
        return Err(anyhow::anyhow!("Token '{}' not found in known token list", n));
    }

    eprintln!("{} (enter symbol or number):", prompt);
    for (i, b) in balances.iter().enumerate() {
        let human = evm::format_token_amount(b.2, b.3);
        eprintln!("  {}) {} — {}", i + 1, b.0, human);
    }
    eprint!("> ");
    io::stderr().flush().ok();

    let mut line = String::new();
    io::stdin().read_line(&mut line)?;
    let input = line.trim();

    if let Ok(idx) = input.parse::<usize>() {
        if idx >= 1 && idx <= balances.len() {
            let b = &balances[idx - 1];
            return Ok((b.0.clone(), b.1.clone(), b.3));
        }
    }

    let upper = input.to_uppercase();
    if let Some(b) = balances.iter().find(|b| b.0.to_uppercase() == upper) {
        return Ok((b.0.clone(), b.1.clone(), b.3));
    }

    Err(anyhow::anyhow!("Invalid token selection: {}", input))
}

fn resolve_amount(
    input: Option<&str>,
    symbol: &str,
    decimals: u8,
    max_raw: u128,
) -> Result<u128> {
    if let Some(s) = input {
        if s.eq_ignore_ascii_case("max") || s.eq_ignore_ascii_case("all") {
            return Ok(max_raw);
        }
        return evm::parse_token_amount(s, decimals);
    }

    let max_human = evm::format_token_amount(max_raw, decimals);
    eprintln!("Amount of {} to swap (max: {}):", symbol, max_human);
    eprint!("> ");
    io::stderr().flush().ok();

    let mut line = String::new();
    io::stdin().read_line(&mut line)?;
    let input = line.trim();

    if input.eq_ignore_ascii_case("max") || input.eq_ignore_ascii_case("all") {
        return Ok(max_raw);
    }

    evm::parse_token_amount(input, decimals)
}
