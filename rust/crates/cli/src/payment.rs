use std::io::{self, Read as _};

use anyhow::Result;
use serde::Serialize;
use zcash_protocol::consensus::Network;

use crate::helpers::*;
use crate::market::{run_ows, get_ows_evm_address};
use crate::{print_ok, Config};

fn read_402_body(body: &Option<String>) -> Result<String> {
    if let Some(b) = body {
        return Ok(b.clone());
    }
    let mut buf = String::new();
    io::stdin().lock().read_to_string(&mut buf)?;
    let trimmed = buf.trim().to_string();
    if trimmed.is_empty() {
        return Err(anyhow::anyhow!(
            "No 402 body provided. Pass --body '<JSON>' or pipe via stdin."
        ));
    }
    Ok(trimmed)
}

fn expected_network(cfg: &Config) -> &'static str {
    if cfg.network == Network::TestNetwork {
        "zcash:testnet"
    } else {
        "zcash:mainnet"
    }
}

pub async fn cmd_x402_propose(
    cfg: &Config,
    body: Option<String>,
    context_id: Option<String>,
) -> Result<()> {
    let raw = read_402_body(&body)?;
    let req = zipher_engine::x402::parse_402_response(&raw, expected_network(cfg))?;
    let amount = zipher_engine::x402::amount_zatoshis(&req)?;

    crate::wallet::cmd_send_propose(cfg, req.pay_to, amount, false, None, context_id).await
}

pub async fn cmd_x402_pay(
    cfg: &Config,
    body: Option<String>,
    context_id: Option<String>,
) -> Result<()> {
    ensure_sapling_params(&cfg.data_dir).await?;
    sync_if_needed(cfg).await?;
    let raw = read_402_body(&body)?;
    let req = zipher_engine::x402::parse_402_response(&raw, expected_network(cfg))?;
    let amount = zipher_engine::x402::amount_zatoshis(&req)?;
    let address = req.pay_to.clone();

    let policy = zipher_engine::policy::load_policy(&cfg.data_dir);

    let daily_spent = zipher_engine::audit::daily_spent(&cfg.data_dir).unwrap_or(0);
    if let Err(violation) = zipher_engine::policy::check_proposal(
        &policy, &address, amount, &context_id, daily_spent,
    ) {
        zipher_engine::audit::log_event(
            &cfg.data_dir, "x402_pay", Some(&address),
            Some(amount), None, context_id.as_deref(),
            None, Some(&violation.to_string()),
        ).ok();
        return Err(anyhow::anyhow!("{}", violation));
    }

    if let Err(violation) = zipher_engine::policy::check_rate_limit(&policy) {
        zipher_engine::audit::log_event(
            &cfg.data_dir, "x402_pay", Some(&address),
            Some(amount), None, context_id.as_deref(),
            None, Some(&violation.to_string()),
        ).ok();
        return Err(anyhow::anyhow!("{}", violation));
    }

    auto_open(cfg).await?;

    let (send_amount, fee, _) =
        zipher_engine::send::propose_send(&address, amount, None, false).await?;

    if cfg.human {
        let zec = send_amount as f64 / 1e8;
        let fee_zec = fee as f64 / 1e8;
        eprintln!(
            "x402 payment: {:.8} ZEC + {:.8} fee to {}",
            zec, fee_zec, address
        );
    }

    let seed = read_seed(&cfg.data_dir)?;
    let txid = match zipher_engine::send::confirm_send(&seed).await {
        Ok(txid) => {
            zipher_engine::policy::record_confirm();
            zipher_engine::audit::log_event(
                &cfg.data_dir, "x402_pay", Some(&address),
                Some(send_amount), Some(fee), context_id.as_deref(),
                Some(&txid), None,
            ).ok();
            txid
        }
        Err(e) => {
            zipher_engine::audit::log_event(
                &cfg.data_dir, "x402_pay", Some(&address),
                Some(send_amount), Some(fee), context_id.as_deref(),
                None, Some(&format!("{:#}", e)),
            ).ok();
            return Err(e);
        }
    };

    delete_pending(&cfg.data_dir);

    let payment_signature = zipher_engine::x402::build_payment_signature(&txid, &req);

    #[derive(Serialize)]
    struct X402PayResult {
        txid: String,
        payment_signature: String,
        amount: u64,
        fee: u64,
        address: String,
    }

    print_ok(
        X402PayResult {
            txid: txid.clone(),
            payment_signature: payment_signature.clone(),
            amount: send_amount,
            fee,
            address: address.clone(),
        },
        cfg.human,
        |r| {
            println!("x402 payment broadcast.");
            println!("  txid: {}", r.txid);
            println!("  amount: {:.8} ZEC ({} zat)", r.amount as f64 / 1e8, r.amount);
            println!("  fee:    {:.8} ZEC ({} zat)", r.fee as f64 / 1e8, r.fee);
            println!();
            println!("PAYMENT-SIGNATURE header:");
            println!("  {}", r.payment_signature);
        },
    );

    zipher_engine::wallet::close().await;
    Ok(())
}

// ---------------------------------------------------------------------------
// ZEC payment path (existing)
// ---------------------------------------------------------------------------

async fn pay_with_zec(
    cfg: &Config,
    client: &reqwest::Client,
    url: &str,
    http_method: &str,
    protocol: zipher_engine::payment::PaymentProtocol,
    context_id: Option<String>,
) -> Result<()> {
    let info = protocol.info()?;

    if cfg.human {
        eprintln!(
            "402 detected ({} protocol). {} zat to {}",
            info.protocol, info.amount, info.address
        );
    }

    let address = protocol.address()?;
    let amount = protocol.amount_zatoshis()?;

    let policy = zipher_engine::policy::load_policy(&cfg.data_dir);
    let daily_spent = zipher_engine::audit::daily_spent(&cfg.data_dir).unwrap_or(0);
    if let Err(violation) = zipher_engine::policy::check_proposal(
        &policy, &address, amount, &context_id, daily_spent,
    ) {
        return Err(anyhow::anyhow!("{}", violation));
    }
    if let Err(violation) = zipher_engine::policy::check_rate_limit(&policy) {
        return Err(anyhow::anyhow!("{}", violation));
    }

    auto_open(cfg).await?;

    let (send_amount, fee, _) =
        zipher_engine::send::propose_send(&address, amount, None, false).await?;

    let seed = read_seed(&cfg.data_dir)?;
    let txid = match zipher_engine::send::confirm_send(&seed).await {
        Ok(txid) => {
            zipher_engine::policy::record_confirm();
            zipher_engine::audit::log_event(
                &cfg.data_dir, "pay", Some(&address),
                Some(send_amount), Some(fee), context_id.as_deref(),
                Some(&txid), None,
            ).ok();
            txid
        }
        Err(e) => {
            zipher_engine::audit::log_event(
                &cfg.data_dir, "pay", Some(&address),
                Some(send_amount), Some(fee), context_id.as_deref(),
                None, Some(&format!("{:#}", e)),
            ).ok();
            return Err(e);
        }
    };

    delete_pending(&cfg.data_dir);

    let (cred_header, cred_value) = protocol.build_credential(&txid);

    let retry_resp = match http_method.to_uppercase().as_str() {
        "POST" => client.post(url).header(&cred_header, &cred_value).send().await,
        "PUT" => client.put(url).header(&cred_header, &cred_value).send().await,
        _ => client.get(url).header(&cred_header, &cred_value).send().await,
    }
    .map_err(|e| anyhow::anyhow!("Retry request failed: {}", e))?;

    let retry_status = retry_resp.status();
    let response_body = retry_resp.text().await.unwrap_or_default();

    if cfg.human {
        println!("Payment complete ({} protocol).", info.protocol);
        println!("  txid:   {}", txid);
        println!("  amount: {:.8} ZEC", send_amount as f64 / 1e8);
        println!("  retry:  HTTP {}", retry_status);
        if response_body.len() < 2000 {
            println!("\nResponse:\n{}", response_body);
        } else {
            println!("\nResponse: ({} bytes)", response_body.len());
        }
    } else {
        print_ok(
            serde_json::json!({
                "txid": txid,
                "protocol": info.protocol,
                "amount_zatoshis": send_amount,
                "fee_zatoshis": fee,
                "retry_status": retry_status.as_u16(),
                "response": response_body,
            }),
            false,
            |v| println!("{}", serde_json::to_string_pretty(&v).unwrap()),
        );
    }

    zipher_engine::wallet::close().await;
    Ok(())
}

// ---------------------------------------------------------------------------
// Cross-chain EVM payment path (ZEC → swap → EVM x402)
// ---------------------------------------------------------------------------

async fn pay_cross_chain(
    cfg: &Config,
    _client: &reqwest::Client,
    url: &str,
    http_method: &str,
    evm_info: zipher_engine::evm_pay::EvmPaymentInfo,
    context_id: Option<String>,
) -> Result<()> {
    let ows_wallet = std::env::var("OWS_WALLET").unwrap_or_else(|_| "default".to_string());
    let evm_address = get_ows_evm_address(&ows_wallet).await?;

    if cfg.human {
        eprintln!("  EVM address: {}", evm_address);
    }

    // Step 1: Check if we already have enough of the target token
    let current_balance = zipher_engine::evm_pay::get_erc20_balance(
        &evm_info.chain.rpc_url,
        &evm_info.asset_contract,
        &evm_address,
    )
    .await
    .unwrap_or(0);

    let required: u128 = evm_info
        .amount_raw
        .parse()
        .map_err(|e| anyhow::anyhow!("Invalid amount: {}", e))?;

    if current_balance < required {
        if cfg.human {
            eprintln!(
                "  Need {} {} but have {} → swapping ZEC",
                evm_info.amount_raw, evm_info.asset_symbol, current_balance
            );
        }

        // Step 2: Swap ZEC → target token via NEAR Intents
        let swap_amount_human = zipher_engine::evm_pay::swap_amount_with_buffer(
            &evm_info.amount_raw,
            evm_info.decimals,
        )?;

        let zec_needed = zipher_engine::evm_pay::estimate_zec_needed(
            &evm_info.asset_symbol,
            &evm_info.chain.near_intents_blockchain,
            swap_amount_human,
        )
        .await?;

        if cfg.human {
            eprintln!(
                "  Swapping ~{:.8} ZEC → {} {} on {}",
                zec_needed as f64 / 1e8,
                swap_amount_human,
                evm_info.asset_symbol,
                evm_info.chain.name
            );
        }

        auto_open(cfg).await?;

        let tokens = zipher_engine::swap::get_tokens().await?;

        let zec_token = zipher_engine::swap::find_zec_token(&tokens)
            .ok_or_else(|| anyhow::anyhow!("ZEC not found in swap tokens"))?;

        let dest_token = tokens
            .iter()
            .find(|t| {
                t.symbol.eq_ignore_ascii_case(&evm_info.asset_symbol)
                    && t.blockchain
                        .eq_ignore_ascii_case(&evm_info.chain.near_intents_blockchain)
            })
            .ok_or_else(|| {
                anyhow::anyhow!(
                    "{} on {} not found in swap tokens",
                    evm_info.asset_symbol,
                    evm_info.chain.near_intents_blockchain
                )
            })?;

        let addresses = zipher_engine::query::get_addresses().await?;
        let refund_addr = addresses
            .first()
            .map(|a| a.address.clone())
            .unwrap_or_default();

        let quote = zipher_engine::swap::get_quote(
            &zec_token.asset_id,
            &dest_token.asset_id,
            &zec_needed.to_string(),
            &evm_address,
            &refund_addr,
            100,
        )
        .await?;

        if cfg.human {
            eprintln!("  Swap quote: deposit {} ZEC to {}", quote.amount_in, quote.deposit_address);
        }

        let deposit_amount: u64 = quote.amount_in.parse().unwrap_or(zec_needed);
        let (send_amount, fee, _) = zipher_engine::send::propose_send(
            &quote.deposit_address,
            deposit_amount,
            None,
            false,
        )
        .await?;

        let seed = read_seed(&cfg.data_dir)?;
        let swap_txid = zipher_engine::send::confirm_send(&seed).await?;
        zipher_engine::policy::record_confirm();

        zipher_engine::audit::log_event(
            &cfg.data_dir,
            "pay_cross_chain_swap",
            Some(&quote.deposit_address),
            Some(send_amount),
            Some(fee),
            context_id.as_deref(),
            Some(&swap_txid),
            None,
        )
        .ok();

        if cfg.human {
            eprintln!("  ZEC sent: {} (waiting for swap...)", swap_txid);
        }

        zipher_engine::swap::submit_deposit(&quote.deposit_address, &swap_txid).await.ok();

        // Wait for swap to complete
        for i in 0..30 {
            tokio::time::sleep(tokio::time::Duration::from_secs(10)).await;
            let status = zipher_engine::swap::get_status(&quote.deposit_address).await;
            if let Ok(s) = &status {
                if cfg.human && i % 3 == 0 {
                    eprintln!("  Swap status: {}", s.status);
                }
                if s.is_success() {
                    break;
                }
                if s.is_failed() {
                    return Err(anyhow::anyhow!("Swap failed: {}", s.status));
                }
            }
        }

        if cfg.human {
            eprintln!("  Swap complete. {} available on {}", evm_info.asset_symbol, evm_info.chain.name);
        }

        // Also check we have native gas on the EVM chain
        let native_balance = zipher_engine::myriad::get_bnb_balance(
            &evm_info.chain.rpc_url,
            &evm_address,
        )
        .await
        .unwrap_or(0);

        if native_balance < 100_000_000_000_000 {
            if cfg.human {
                eprintln!("  Warning: low native gas on {}. May need ETH/BNB for tx fees.", evm_info.chain.name);
            }
        }
    } else if cfg.human {
        eprintln!("  Already have enough {} on {}", evm_info.asset_symbol, evm_info.chain.name);
    }

    // Step 3: Delegate to OWS for the actual x402 payment.
    // OWS uses EIP-3009 TransferWithAuthorization (off-chain signature, no gas needed).
    if cfg.human {
        eprintln!("  Paying via OWS (EIP-3009 TransferWithAuthorization)...");
    }

    let ows_output = run_ows(&[
        "pay", "request", url,
        "--wallet", &ows_wallet,
        "--method", http_method,
        "--no-passphrase",
    ]).await?;

    zipher_engine::audit::log_event(
        &cfg.data_dir,
        "pay_cross_chain",
        Some(&evm_info.pay_to),
        None,
        None,
        context_id.as_deref(),
        Some("ows-pay"),
        None,
    )
    .ok();

    if cfg.human {
        println!("Cross-chain payment complete.");
        println!("  chain:  {} ({})", evm_info.chain.name, evm_info.network);
        println!("  asset:  {} ({})", evm_info.asset_symbol, evm_info.asset_contract);
        println!("  funded: ZEC (shielded) → {} via NEAR Intents", evm_info.asset_symbol);
        println!("  paid:   EIP-3009 via OWS (no gas needed)");
        if ows_output.len() < 2000 {
            println!("\nResponse:\n{}", ows_output);
        } else {
            println!("\nResponse: ({} bytes)", ows_output.len());
        }
    } else {
        print_ok(
            serde_json::json!({
                "chain": evm_info.chain.name,
                "asset": evm_info.asset_symbol,
                "amount": evm_info.amount_raw,
                "pay_to": evm_info.pay_to,
                "response": ows_output,
            }),
            false,
            |v| println!("{}", serde_json::to_string_pretty(&v).unwrap()),
        );
    }

    Ok(())
}

pub async fn cmd_pay(
    cfg: &Config,
    url: String,
    context_id: Option<String>,
    http_method: String,
) -> Result<()> {
    ensure_sapling_params(&cfg.data_dir).await?;
    sync_if_needed(cfg).await?;

    let client = reqwest::Client::new();
    let initial_resp = match http_method.to_uppercase().as_str() {
        "POST" => client.post(&url).send().await,
        "PUT" => client.put(&url).send().await,
        _ => client.get(&url).send().await,
    }
    .map_err(|e| anyhow::anyhow!("HTTP request failed: {}", e))?;

    if initial_resp.status() != reqwest::StatusCode::PAYMENT_REQUIRED {
        let status = initial_resp.status();
        let body = initial_resp.text().await.unwrap_or_default();
        if status.is_success() {
            println!("{}", body);
            return Ok(());
        }
        return Err(anyhow::anyhow!("Expected HTTP 402, got {}: {}", status, body));
    }

    let mut headers = std::collections::HashMap::new();
    for (k, v) in initial_resp.headers() {
        if let Ok(val) = v.to_str() {
            headers.insert(k.as_str().to_lowercase(), val.to_string());
        }
    }
    let body = initial_resp.text().await.unwrap_or_default();

    let network = expected_network(cfg);
    let zec_protocol = zipher_engine::payment::detect_protocol(&headers, &body, network);

    match zec_protocol {
        Ok(protocol) => {
            pay_with_zec(cfg, &client, &url, &http_method, protocol, context_id).await
        }
        Err(_zec_err) => {
            match zipher_engine::evm_pay::parse_evm_x402(&body) {
                Ok(evm_info) => {
                    if cfg.human {
                        eprintln!(
                            "402 detected: {} {} on {} (chain {})",
                            evm_info.amount_raw, evm_info.asset_symbol,
                            evm_info.chain.name, evm_info.chain.chain_id
                        );
                        eprintln!("  → cross-chain: ZEC (shielded) → {} on {} → pay", evm_info.asset_symbol, evm_info.chain.name);
                    }
                    pay_cross_chain(cfg, &client, &url, &http_method, evm_info, context_id).await
                }
                Err(_) => {
                    Err(anyhow::anyhow!(
                        "No supported payment method found. Zcash: {}. EVM chains: not matched.",
                        _zec_err
                    ))
                }
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Sweep: EVM chain → ZEC (back to the vault)
// ---------------------------------------------------------------------------

pub async fn cmd_sweep(
    cfg: &Config,
    token_symbol: String,
    chain: String,
    ows_wallet: String,
) -> Result<()> {
    let evm_address = get_ows_evm_address(&ows_wallet).await?;

    let evm_chain = match chain.to_lowercase().as_str() {
        "base" => zipher_engine::evm_pay::BASE_MAINNET,
        "bsc" | "bnb" => zipher_engine::evm_pay::BSC_MAINNET,
        _ => return Err(anyhow::anyhow!("Unsupported chain '{}'. Use: base, bsc", chain)),
    };

    // Find the token contract address from NEAR Intents token list
    let tokens = zipher_engine::swap::get_tokens().await?;
    let token = tokens
        .iter()
        .find(|t| {
            t.symbol.eq_ignore_ascii_case(&token_symbol)
                && t.blockchain.eq_ignore_ascii_case(&evm_chain.near_intents_blockchain)
        })
        .ok_or_else(|| {
            anyhow::anyhow!("{} on {} not found in swap tokens", token_symbol, chain)
        })?;

    let contract = zipher_engine::evm_pay::token_contract(&token_symbol, evm_chain.chain_id)
        .unwrap_or_else(|| {
            if cfg.human {
                eprintln!("Warning: unknown token contract for {} on chain {}. Sweep may not detect balance.", token_symbol, chain);
            }
            ""
        });

    if !contract.is_empty() {
        let balance = zipher_engine::evm_pay::get_erc20_balance(
            evm_chain.rpc_url,
            contract,
            &evm_address,
        )
        .await?;

        let decimals = match token_symbol.to_uppercase().as_str() {
            "USDC" | "USDT" => 6u32,
            _ => 18,
        };
        let human_balance = balance as f64 / 10f64.powi(decimals as i32);

        if cfg.human {
            eprintln!(
                "Balance: {:.6} {} on {} (wallet {})",
                human_balance, token_symbol, evm_chain.name, &evm_address[..10]
            );
        }

        if balance == 0 {
            if cfg.human {
                println!("Nothing to sweep — zero balance.");
            }
            return Ok(());
        }
    }

    // Get ZEC address for receiving the swap
    ensure_sapling_params(&cfg.data_dir).await?;
    auto_open(cfg).await?;

    let addresses = zipher_engine::query::get_addresses().await?;
    let zec_address = addresses
        .first()
        .map(|a| a.address.clone())
        .ok_or_else(|| anyhow::anyhow!("No ZEC address available"))?;

    let zec_token = zipher_engine::swap::find_zec_token(&tokens)
        .ok_or_else(|| anyhow::anyhow!("ZEC not found in swap tokens"))?;

    if cfg.human {
        eprintln!("Sweeping {} on {} → ZEC at {}", token_symbol, evm_chain.name, &zec_address[..20]);
        eprintln!("  This will swap via NEAR Intents back to your shielded wallet.");
        eprintln!();
        eprintln!("  To execute, use NEAR Intents reverse swap:");
        eprintln!("    Origin:      {} on {}", token_symbol, evm_chain.name);
        eprintln!("    Destination: ZEC (shielded)");
        eprintln!("    Recipient:   {}", &zec_address[..30]);
        eprintln!();
        eprintln!("  Note: Reverse swaps (EVM → ZEC) require depositing the ERC-20 token");
        eprintln!("  to a NEAR Intents deposit address on {}.", evm_chain.name);
        eprintln!("  This requires an ERC-20 transfer signed via OWS.");

        // Get a quote for visibility
        if !contract.is_empty() {
            let balance = zipher_engine::evm_pay::get_erc20_balance(
                evm_chain.rpc_url,
                contract,
                &evm_address,
            )
            .await
            .unwrap_or(0);

            if balance > 0 {
                match zipher_engine::swap::get_quote(
                    &token.asset_id,
                    &zec_token.asset_id,
                    &balance.to_string(),
                    &zec_address,
                    &evm_address,
                    100,
                )
                .await
                {
                    Ok(quote) => {
                        eprintln!();
                        eprintln!("  Quote: {} {} → ~{} ZEC", balance, token_symbol, quote.amount_out);
                        eprintln!("  Deposit to: {}", quote.deposit_address);
                    }
                    Err(e) => {
                        eprintln!("  Could not get sweep quote: {}", e);
                    }
                }
            }
        }
    }

    println!("Sweep quote displayed. Execute with: zipher-cli swap execute --to ZEC --chain zcash ...");
    zipher_engine::wallet::close().await;
    Ok(())
}
