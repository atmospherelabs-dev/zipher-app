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
    Err(anyhow::anyhow!(
        "EVM address not found for wallet '{}'",
        wallet
    ))
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
            println!(
                "  ows send-tx --chain zcash:mainnet --wallet <name> --tx {}",
                &r.pczt_hex[..64.min(r.pczt_hex.len())]
            );
        },
    );

    zipher_engine::wallet::close().await;
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
    let m =
        zipher_engine::polymarket::polymarket_gamma_get_market_by_condition(&condition_id).await?;

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
            o.best_bid
                .map(|x| format!("{:.4}", x))
                .unwrap_or_else(|| "—".into()),
            o.best_ask
                .map(|x| format!("{:.4}", x))
                .unwrap_or_else(|| "—".into()),
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
        .duration_since(std::time::UNIX_EPOCH)?
        .as_secs();
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
        .send()
        .await?;

    if !resp.status().is_success() {
        eprintln!(
            "   derive-api-key returned {}, trying create...",
            resp.status()
        );
        resp = client
            .post("https://clob.polymarket.com/auth/api-key")
            .headers(build_header_map(&l1_headers))
            .send()
            .await?;
    }

    let auth_body: serde_json::Value = resp.json().await?;
    eprintln!(
        "   Auth response: {}",
        serde_json::to_string_pretty(&auth_body)?
    );

    let api_key = auth_body["apiKey"]
        .as_str()
        .or_else(|| auth_body["key"].as_str())
        .ok_or_else(|| anyhow::anyhow!("No API key in auth response"))?;
    let api_secret = auth_body["secret"].as_str().unwrap_or("");
    let passphrase = auth_body["passphrase"].as_str().unwrap_or("");

    eprintln!("   API key: {}...", &api_key[..api_key.len().min(16)]);
    eprintln!();

    // 3. Build & sign V2 order
    eprintln!("[3] Building V2 order...");
    let side_int: u8 = if side.eq_ignore_ascii_case("BUY") {
        0
    } else {
        1
    };

    // Fetch tick size for precision rounding
    let tick_size: f64 = {
        let url = format!(
            "https://clob.polymarket.com/tick-size?token_id={}",
            token_id
        );
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
    eprintln!(
        "    Price as ratio: {}/{} = {:.6}",
        price_num,
        price_denom,
        price_num as f64 / price_denom as f64
    );

    let desired_taker = (amount / (price_num as f64 * tick_size) * 1e6).round() as u64;
    let shares_amount_raw = (desired_taker / price_denom) * price_denom;
    let maker_amount_raw = shares_amount_raw * price_num / price_denom;

    let (m_raw, t_raw) = if side_int == 0 {
        (maker_amount_raw.to_string(), shares_amount_raw.to_string())
    } else {
        (shares_amount_raw.to_string(), maker_amount_raw.to_string())
    };

    let salt = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)?
        .as_millis()
        .to_string();
    let timestamp = (std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)?
        .as_secs())
    .to_string();
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
        .duration_since(std::time::UNIX_EPOCH)?
        .as_secs())
    .to_string();
    let hmac_message = format!("{}POST/order{}", hmac_ts, body_str);
    eprintln!(
        "   HMAC message: {}...{}",
        &hmac_message[..60.min(hmac_message.len())],
        &hmac_message[hmac_message.len().saturating_sub(30)..]
    );

    use hmac::{Hmac, Mac};
    use sha2::Sha256;
    type HmacSha256 = Hmac<Sha256>;

    let secret_bytes =
        base64::Engine::decode(&base64::engine::general_purpose::STANDARD, api_secret)
            .unwrap_or_default();
    let mut mac = HmacSha256::new_from_slice(&secret_bytes)
        .map_err(|e| anyhow::anyhow!("HMAC init failed: {}", e))?;
    mac.update(hmac_message.as_bytes());
    let hmac_sig = base64::Engine::encode(
        &base64::engine::general_purpose::URL_SAFE,
        mac.finalize().into_bytes(),
    );

    eprintln!("   HMAC sig: {}...", &hmac_sig[..20.min(hmac_sig.len())]);
    eprintln!(
        "   L2 headers: POLY_ADDRESS={}, POLY_API_KEY={}, POLY_TIMESTAMP={}",
        &address, api_key, &hmac_ts
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
        .send()
        .await?;

    let status = resp.status();
    let resp_body: serde_json::Value = resp
        .json()
        .await
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
        eprintln!(
            "\n  Not enough USDC.e or pUSD. Need {} but have USDC.e={}, pUSD={}",
            amount_micro, usdce_bal, pusd_bal
        );
        return Err(anyhow::anyhow!("Insufficient balance"));
    }

    // -- Only wrap if we don't already have enough pUSD --
    if pusd_bal < amount_micro {
        eprintln!("\n[3] Approving USDC.e → CollateralOnramp...");
        let fees = zipher_engine::evm::suggest_eip1559_fees(POLYGON_RPC, 137).await?;
        let approve_hash = zipher_engine::evm::approve_erc20(
            POLYGON_RPC,
            &seed,
            &address,
            USDCE,
            ONRAMP,
            amount_micro,
            137,
            &fees,
        )
        .await?;
        let r = zipher_engine::evm::wait_for_receipt(POLYGON_RPC, &approve_hash, 60).await?;
        eprintln!(
            "    tx: {} (status: {}, gas: {})",
            approve_hash,
            if r.status { "OK" } else { "REVERTED" },
            r.gas_used
        );
        if !r.status {
            return Err(anyhow::anyhow!("Approve USDC.e reverted"));
        }

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
            137,
            nonce,
            fees.max_priority_fee_per_gas,
            fees.max_fee_per_gas,
            200_000,
            ONRAMP,
            &[0],
            &calldata,
        );
        let wrap_hash =
            zipher_engine::evm::sign_and_broadcast(&seed, &unsigned, POLYGON_RPC).await?;
        eprintln!("    tx: {}", wrap_hash);
        let r = zipher_engine::evm::wait_for_receipt(POLYGON_RPC, &wrap_hash, 60).await?;
        eprintln!(
            "    status: {}, gas: {}",
            if r.status { "OK" } else { "REVERTED" },
            r.gas_used
        );
        if !r.status {
            return Err(anyhow::anyhow!("Wrap USDC.e → pUSD reverted"));
        }

        // Verify pUSD balance
        let new_pusd = zipher_engine::evm::get_erc20_balance(POLYGON_RPC, PUSD, &address).await?;
        eprintln!("    pUSD balance after wrap: {:.6}", new_pusd as f64 / 1e6);
    } else {
        eprintln!("\n[3-4] Already have enough pUSD, skipping wrap.");
    }

    // -- Approve pUSD to exchange with fee buffer --
    let approve_micro = (amount * 1.05 * 1e6) as u128; // 5% buffer for CLOB fees
    eprintln!(
        "[5] Approving {} pUSD → exchange {}...",
        approve_micro as f64 / 1e6,
        &exchange[..10]
    );
    let fees2 = zipher_engine::evm::suggest_eip1559_fees(POLYGON_RPC, 137).await?;
    let approve_hash = zipher_engine::evm::approve_erc20(
        POLYGON_RPC,
        &seed,
        &address,
        PUSD,
        exchange,
        approve_micro,
        137,
        &fees2,
    )
    .await?;
    let r = zipher_engine::evm::wait_for_receipt(POLYGON_RPC, &approve_hash, 60).await?;
    eprintln!(
        "    tx: {} (status: {}, gas: {})",
        approve_hash,
        if r.status { "OK" } else { "REVERTED" },
        r.gas_used
    );
    if !r.status {
        return Err(anyhow::anyhow!("Approve pUSD reverted"));
    }

    // -- L1 auth --
    eprintln!("[6] L1 auth...");
    let client = reqwest::Client::new();
    let ts = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)?
        .as_secs();
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
        .send()
        .await?;
    if !resp.status().is_success() {
        let st = resp.status();
        let body = resp.text().await.unwrap_or_default();
        eprintln!("    derive-api-key: {} — {}", st, body);
        resp = client
            .post("https://clob.polymarket.com/auth/api-key")
            .headers(build_header_map(&l1_headers))
            .send()
            .await?;
    }
    let auth_status = resp.status();
    let auth_body = resp.text().await?;
    if !auth_status.is_success() {
        return Err(anyhow::anyhow!(
            "L1 auth failed ({}): {}",
            auth_status,
            auth_body
        ));
    }
    let creds: serde_json::Value = serde_json::from_str(&auth_body).map_err(|e| {
        anyhow::anyhow!("Failed to parse auth response: {} — body: {}", e, auth_body)
    })?;
    let api_key = creds["apiKey"]
        .as_str()
        .or(creds["key"].as_str())
        .ok_or_else(|| anyhow::anyhow!("No apiKey"))?;
    let api_secret = creds["secret"].as_str().unwrap_or("");
    let passphrase = creds["passphrase"].as_str().unwrap_or("");
    eprintln!("    API key: {}...", &api_key[..16.min(api_key.len())]);

    // -- Fetch tick size & build order --
    eprintln!("[7] Building order...");
    let tick_size: f64 = {
        let url = format!(
            "https://clob.polymarket.com/tick-size?token_id={}",
            token_id
        );
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

    let side_int: u8 = if side.eq_ignore_ascii_case("BUY") {
        0
    } else {
        1
    };

    // Express price as integer ratio for exact tick alignment
    let price_denom = 10u64.pow(tick_decimals as u32);
    let price_num = (price / tick_size).round() as u64;
    eprintln!(
        "    Price as ratio: {}/{} = {:.6}",
        price_num,
        price_denom,
        price_num as f64 / price_denom as f64
    );

    let desired_taker = (amount / (price_num as f64 * tick_size) * 1e6).round() as u64;
    let shares_amount_raw = (desired_taker / price_denom) * price_denom;
    let maker_amount_raw = shares_amount_raw * price_num / price_denom;

    let (m_raw, t_raw) = if side_int == 0 {
        (maker_amount_raw.to_string(), shares_amount_raw.to_string())
    } else {
        (shares_amount_raw.to_string(), maker_amount_raw.to_string())
    };
    eprintln!("    makerAmount: {}, takerAmount: {}", m_raw, t_raw);

    let salt = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)?
        .as_millis()
        .to_string();
    let timestamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)?
        .as_secs()
        .to_string();
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
        .duration_since(std::time::UNIX_EPOCH)?
        .as_secs()
        .to_string();
    let hmac_message = format!("{}POST/order{}", hmac_ts, body_str);

    use hmac::{Hmac, Mac};
    use sha2::Sha256;
    type HmacSha256 = Hmac<Sha256>;

    let secret_bytes =
        base64::Engine::decode(&base64::engine::general_purpose::STANDARD, api_secret)
            .unwrap_or_default();
    let mut mac = HmacSha256::new_from_slice(&secret_bytes)
        .map_err(|e| anyhow::anyhow!("HMAC init failed: {}", e))?;
    mac.update(hmac_message.as_bytes());
    let hmac_sig = base64::Engine::encode(
        &base64::engine::general_purpose::URL_SAFE,
        mac.finalize().into_bytes(),
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
        .send()
        .await?;

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
