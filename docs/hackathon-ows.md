# Zipher — OWS Hackathon Submission

## The Core Contribution

We brought **Zcash to the Open Wallet Standard**.

Every other OWS agent uses transparent chains. Every transaction, every balance, every counterparty is public. An agent trading prediction markets? Competitors see its strategy. An agent paying for APIs? Anyone can profile its spending.

**Zipher makes OWS agents invisible.** We forked OWS to add PCZT (Partially Created Zcash Transaction) signing. Through NEAR Intents, the agent can swap ZEC to 140+ assets across any chain — BTC, ETH, SOL, USDT, BNB. The funds originate from Zcash's shielded pool, cross via NEAR's intent infrastructure, and land on the destination chain ready to use. Every chain OWS supports becomes privately fundable through Zcash.

Then we built an autonomous agent stack on top: a prediction market agent with Kelly Criterion analysis, cross-chain swaps, x402/MPP micropayments, a pay-per-call API server, CipherPay payment verification, and a 22-tool MCP surface for LLM orchestration.

**The vault model:** Zcash is the agent's private bank account. Funds leave the shielded pool only when needed — just enough to cover a specific task on a specific chain — and sweep back afterward. The agent's treasury is always invisible.

**OWS fork (PCZT support):** [github.com/Kenbak/core](https://github.com/Kenbak/core/tree/feat/zcash-support) — see `ows/crates/ows-signer/src/chains/zcash.rs`, `ows/crates/ows-lib/src/lwd_grpc.rs`, and `ows/crates/ows-lib/Cargo.toml` for the Zcash PCZT signing, ZIP-32 derivation, and TLS fixes.

---

## Getting Started

### Prerequisites

- Rust 1.75+ with `cargo`
- OWS CLI: `cargo install --git https://github.com/Kenbak/core --branch feat/zcash-support ows-cli`

### Build

```bash
cd rust
cargo build --release -p zipher-cli -p zipher-mcp-server
```

Binaries are in `rust/target/release/`.

### Create a Wallet

One wallet, all chains. OWS derives Zcash (ZIP-32), EVM (BIP-44), Solana, and Bitcoin keys from a single BIP-39 mnemonic:

```bash
# Create the wallet via OWS — one seed for all chains
ows wallet create default --show-mnemonic
# → Save the 24 words securely. This is the only copy.

# Zipher CLI reads the seed from OWS automatically.
# No need to copy it or set ZIPHER_SEED.
zipher-cli sync start
zipher-cli --human balance
```

Zipher resolves the seed in this order:
1. Zipher vault (`~/.zipher/mainnet/vault.enc`) — if `zipher-cli wallet create` was used
2. **OWS vault** (`~/.ows/wallets/`) — if `ows wallet create` was used (recommended)
3. `ZIPHER_SEED` env var — for the MCP server or headless mode
4. Interactive prompt

### Environment Variables

| Variable | Required | Description |
|----------|----------|-------------|
| `ZIPHER_SEED` | For MCP server | 24-word seed phrase (held in memory, never logged) |
| `ZIPHER_DATA_DIR` | No | Wallet data directory (default: `~/.zipher/mainnet`) |
| `ZIPHER_SERVER` | No | Custom lightwalletd URL (default: `lightwalletd.mainnet.cipherscan.app:443`) |
| `ZIPHER_TESTNET` | No | Set to `1` for testnet |
| `FIRECRAWL_API_KEY` | No | Firecrawl API key for web research agent |
| `CIPHERPAY_API_KEY` | No | CipherPay key for payment verification (serve command) |
| `OWS_CLI` | No | Path to OWS binary (default: `ows`) |
| `OWS_WALLET` | No | OWS wallet name (default: `default`) |
| `OWS_PASSPHRASE` | No | OWS vault passphrase (default: empty) |
| `NEAR_INTENTS_KEY` | No | Custom NEAR Intents API key (has built-in default) |

### Run the MCP Server

Add to your Claude Desktop or Cursor MCP config (`mcp-config.example.json` in repo root):

```json
{
  "mcpServers": {
    "zipher": {
      "command": "/path/to/zipher-mcp-server",
      "env": {
        "ZIPHER_SEED": "your 24-word seed phrase",
        "FIRECRAWL_API_KEY": "fc-..."
      }
    }
  }
}
```

A system prompt for multi-agent orchestration is in `docs/mcp-system-prompt.md`.

### Run the Pay-Per-Call API Server

```bash
# Starts x402-gated HTTP API on port 8402
zipher-cli serve --port 8402 --price 10000

# Test the health endpoint (no payment required)
curl http://localhost:8402/health

# Call a paid endpoint without payment → get 402 + x402 body
curl http://localhost:8402/api/research?topic=bitcoin
# Returns: {"x402Version":2, "accepts":[{"scheme":"exact","network":"zcash:mainnet", ...}]}

# Call with payment credential → get research results
curl -H "PAYMENT-SIGNATURE: <base64>" http://localhost:8402/api/research?topic=bitcoin
```

### Run the CLI Market Agent

```bash
# Dry run — scans, researches, analyzes, recommends (no real trades)
zipher-cli --human market agent --dry-run --bankroll 50 --max-bet 5

# List markets
zipher-cli --human market list --keyword bitcoin

# Full agent run (requires funded wallet + OWS)
zipher-cli --human market agent --bankroll 100 --max-bet 10 --ows-wallet default
```

---

## Tracks

### Track 04 — Multi-Agent Systems

> "Build systems where multiple agents coordinate, trade, compete, and form economies."

**What we built:** A prediction market agent system with four specialized roles, coordinated by an LLM via MCP:

| Role | MCP Tool | What it does |
|------|----------|--------------|
| **News Agent** | `market_research` | Searches the web via Firecrawl, gathers news and expert analysis for a market topic |
| **Analysis Agent** | `market_analyze` | Takes the LLM's probability estimate, applies fractional Kelly Criterion, calculates edge and recommended bet size |
| **Trading Agent** | `market_scan`, `swap_execute`, `market_quote` | Discovers markets, executes cross-chain swaps (ZEC → USDT via NEAR Intents), constructs EVM transactions for Myriad on BNB Chain |
| **Risk Agent** | `wallet_status`, policy engine | Enforces per-tx limits, daily caps, rate limiting. Every transaction is logged in an append-only audit log |

**The pipeline:**

```
Scan → Research → Analyze → Execute
```

1. `market_scan` — Fetch open markets, rank by uncertainty
2. `market_research` — Search news for the most contestable markets
3. LLM reads the research, forms a probability estimate
4. `market_analyze` — Fractional Kelly sizing, edge detection, EV calculation
5. If positive EV: `swap_execute` (ZEC → USDT) → `market_quote` → place bet

**What makes it different:**
- Privacy. Every other OWS agent leaks its strategy on a block explorer. Zcash shielded transactions make the agent's financial activity invisible.
- Kelly Criterion. Not random bet sizes — mathematically optimal position sizing with conservative fractional Kelly (quarter to half Kelly by confidence).
- Cross-chain from a single treasury. ZEC → any asset via NEAR Intents. One wallet, 140+ destination tokens.

**Matches track item:** #09 — "Prediction market agent swarm"

**Demo:**

```bash
# MCP: connect to Claude/Cursor with mcp-config.example.json, use docs/mcp-system-prompt.md
# CLI: zipher-cli --human market agent --dry-run --bankroll 50 --max-bet 5
```

---

### Track 03 — Pay-Per-Call Services

> "Wrap any API, dataset, model, or capability behind x402/MPP micropayments."

**What we built:** A complete pay-per-call stack — both the consumer side (agent that pays) and the provider side (API that charges) — with shielded Zcash settlement. No API keys, no accounts, no KYC. Just a wallet and an HTTP request.

#### The Stack

```
┌─────────────────────┐         ┌────────────────────────┐
│  AGENT (consumer)    │         │  API SERVER (provider)  │
│                      │         │                         │
│  zipher-cli pay_url  │──GET──→│  @cipherpay/x402        │
│  or pay_x402 MCP     │←─402──│  Express middleware      │
│                      │         │  or zipher-cli serve    │
│  OWS signs shielded  │──ZEC──→│                         │
│  ZEC payment          │         │  Calls CipherPay       │
│                      │──retry─→│  POST /api/x402/verify │
│  Gets content        │←─200──│  Trial-decrypts Orchard │
│                      │         │  outputs via CipherScan │
└─────────────────────┘         └────────────────────────┘
```

#### Three Ways to Gate an API

**1. `@cipherpay/x402` — npm middleware (any Express server)**

```bash
npm install @cipherpay/x402
```

```javascript
import { zcashPaywall } from '@cipherpay/x402/express';

app.use('/api/paid', zcashPaywall({
  payTo: 'u1youraddress...',
  amount: 0.0001,  // ZEC per call
  network: 'zcash:mainnet',
  apiKey: process.env.CIPHERPAY_API_KEY,
}));
```

Any route behind the middleware returns 402 with x402/MPP challenge. After payment, CipherPay verifies via Orchard trial decryption. Supports x402 headers, MPP `WWW-Authenticate`, prepaid sessions, and replay rejection.

Published: [`@cipherpay/x402` on npm](https://www.npmjs.com/package/@cipherpay/x402)

**2. `zipher-cli serve` — Rust pay-per-call server (agent selling its own tools)**

```bash
zipher-cli serve --port 8402 --price 10000
```

| Endpoint | What it returns |
|----------|-----------------|
| `GET /api/research?topic=` | Web research via Firecrawl |
| `GET /api/markets` | Prediction markets scan |
| `GET /api/analyze?market_id=&prob=&confidence=` | Kelly Criterion trade signal |
| `GET /health` | Server status (free) |

Verifies payments via CipherPay's `POST /api/x402/verify`. Demo mode available without `CIPHERPAY_API_KEY`.

**3. `@cipherpay/mcp` — MCP server for AI-driven verification**

```json
{
  "mcpServers": {
    "cipherpay": {
      "command": "npx",
      "args": ["-y", "@cipherpay/mcp"],
      "env": { "CIPHERPAY_API_KEY": "..." }
    }
  }
}
```

8 MCP tools: `create_invoice`, `get_invoice_status`, `verify_payment`, `open_session`, `get_session_status`, `close_session`, `get_product_info`, `get_exchange_rates`.

An LLM can use `verify_payment` to confirm shielded ZEC payments in real time, or `open_session` for prepaid API access.

#### How Payment Verification Actually Works

CipherPay doesn't just check a balance — it does **Orchard trial decryption**:

1. Fetch raw transaction hex from CipherScan API
2. Parse as a Zcash Nu5 transaction, extract Orchard bundle
3. Trial-decrypt each Orchard action with the merchant's incoming viewing key (from UFVK)
4. Sum decrypted amounts — accept if total ≥ 99.5% of expected (slippage tolerance)

This means: the payment is **shielded on-chain** (invisible to everyone), but the merchant can cryptographically prove it received the exact amount. Privacy for the payer, certainty for the payee.

#### The Consumer Side

The agent (Zipher) has two tools for paying x402 APIs:

- **`pay_url`** MCP tool / CLI command — auto-detects x402 or MPP protocol, pays with shielded ZEC, retries with credential
- **`pay_x402`** MCP tool — for explicit x402 payment when you already have the 402 body

Both use the Zcash shielded pool via the engine's `propose_send` → `confirm_send` flow. OWS signs the transaction in CLI mode.

#### The Vault Model

Zcash is the agent's private bank account. Funds leave the shielded pool only for specific tasks — cross-chain swaps to BSC for prediction markets, API payments via x402/MPP — and sweep back afterward. The agent's treasury is always invisible.

```bash
# Pay any x402/MPP API with shielded ZEC
zipher-cli --human pay <url>

# Sweep remaining funds on any EVM chain back to ZEC
zipher-cli --human sweep --token USDT --chain bsc
```

**Matches track items:** #01 (Zero-account API gateway), #05 (Paid MCP server toolkit)

**Demo:**

```bash
# Terminal 1: start the paid API
zipher-cli serve --port 8402

# Terminal 2: agent pays for research
curl http://localhost:8402/api/research?topic=bitcoin
# → 402 with x402 body

# Or: gate any Express API with one line
npm install @cipherpay/x402
```

---

### Track 05 — Creative / Unhinged

> "Your craziest ideas. The only rule: it must use an OWS wallet and x402/MPP payments."

**The Ghost Agent.**

An autonomous trader that's invisible on-chain. It researches prediction markets, sizes bets with Kelly Criterion, swaps ZEC to USDT via NEAR Intents, trades on Myriad (BNB Chain), and manages its own treasury.

On the BNB side, you see the trades: ERC-20 approvals, market bets, token transfers. Standard on-chain activity.

But trace where the funds came from. You can't.

The USDT arrived from a NEAR Intents cross-chain swap. The swap was funded by a Zcash shielded transaction. Zcash shielded transactions encrypt the sender, receiver, and amount on-chain. There's no input to trace. No origin address. No funding pattern. The agent's treasury, its total balance, its spending history — all invisible.

Every other OWS agent is financially naked. The Ghost Agent is the first one that isn't.

**What makes it unhinged:** We gave an AI agent the ability to earn money, spend money, and pay for services — with complete financial privacy. Its treasury is a Zcash shielded wallet (the vault). When it needs to act on another chain, it moves just enough to cover the task and sweeps the rest back. The agent can operate indefinitely without anyone knowing how much it has, how much it spends, or who it pays. It's the economic equivalent of a ghost.

---

## Architecture

```
rust/crates/
├── engine/          # Shared Rust wallet engine (16 modules)
│   ├── evm_pay.rs   # Multi-chain EVM x402 payments (NEW — vault model)
│   ├── myriad.rs    # Myriad API, Kelly Criterion, EVM tx building
│   ├── research.rs  # Firecrawl web search, news agent
│   ├── swap.rs      # NEAR Intents cross-chain swaps (140+ tokens)
│   ├── x402.rs      # x402 payment protocol (client)
│   ├── mpp.rs       # MPP payment protocol (client)
│   ├── payment.rs   # Protocol auto-detection (ZEC + EVM fallback)
│   ├── policy.rs    # Spending policy engine
│   ├── audit.rs     # Append-only audit log (SQLite)
│   └── ...          # wallet, sync, send, vault, query, session, types
│
├── cli/src/         # zipher-cli binary (10 modules)
│   ├── serve.rs     # HTTP API server with x402 gating
│   ├── market.rs    # Prediction market commands + OWS signing
│   ├── payment.rs   # x402 payments: ZEC direct + cross-chain EVM + sweep
│   └── ...          # wallet, swap, session, policy, daemon, helpers
│
└── mcp-server/      # MCP server binary (22 tools over stdio)
    └── main.rs
```

## MCP Tools (22)

| Domain | Tools |
|--------|-------|
| Wallet | `wallet_status`, `get_balance`, `validate_address`, `sync_status`, `get_transactions` |
| Send | `propose_send`, `confirm_send`, `shield_funds` |
| Payments | `pay_x402`, `pay_url` |
| Swaps | `swap_tokens`, `swap_quote`, `swap_execute`, `swap_status` |
| Sessions | `session_open`, `session_request`, `session_list`, `session_close` |
| Market | `market_scan`, `market_research`, `market_analyze`, `market_quote` |

## Built With

- [Open Wallet Standard (OWS)](https://openwallet.sh) — multi-chain wallet + Zcash PCZT signing (our fork)
- [librustzcash](https://github.com/zcash/librustzcash) — Zcash protocol libraries
- [rmcp](https://github.com/anthropics/rmcp) — MCP server SDK
- [NEAR Intents](https://near.org/intents) — cross-chain swaps
- [Myriad Markets](https://myriad.markets) — prediction markets on BNB Chain
- [Firecrawl](https://firecrawl.dev) — web search API
- [CipherPay](https://cipherpay.app) — Zcash payment verification (Orchard trial decryption via CipherScan)
- [`@cipherpay/x402`](https://www.npmjs.com/package/@cipherpay/x402) — Express middleware for x402/MPP paywalls with Zcash
- [`@cipherpay/mcp`](https://www.npmjs.com/package/@cipherpay/mcp) — MCP server for payment verification, invoices, sessions
- [Axum](https://github.com/tokio-rs/axum) — HTTP server for pay-per-call API
