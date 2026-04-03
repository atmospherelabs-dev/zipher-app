# Zipher

> Making Zcash accessible. For everyone.

Zipher is a privacy-first Zcash wallet — for humans and AI agents. One Rust engine, two interfaces: a mobile app for everyday use and a headless CLI + MCP server for autonomous agents. Built with [Open Wallet Standard (OWS)](https://openwallet.sh) for multi-chain signing and [CipherPay](https://cipherpay.app) for private payment infrastructure.

Built by [Atmosphere Labs](https://atmospherelabs.dev).

> **OWS Hackathon judges:** Start with [`docs/hackathon-ows.md`](docs/hackathon-ows.md) for the submission narrative, tracks, and demo instructions. The relevant code is in `rust/crates/{engine,cli,mcp-server}`. The mobile app uses the same Rust engine via FFI but is not part of this submission.

---

## Why Zcash

Zcash is the only production chain with mathematically proven transaction privacy. Not mixers. Not optional privacy. Shielded by default, enforced by zero-knowledge proofs.

We brought Zcash to the Open Wallet Standard — making it a first-class citizen alongside Ethereum and Solana. Every other OWS wallet and agent uses transparent chains: every transaction, every balance, every counterparty is public. With Zcash on OWS:

- **No one sees the balance** — not competitors, not chain analysts, not MEV bots
- **No one sees the counterparties** — who it pays, who pays it
- **No one sees the strategy** — transaction amounts, timing, and destinations are encrypted on-chain
- **Any chain is reachable** — NEAR Intents bridges ZEC to 140+ assets, so privacy extends to every destination chain

This isn't a privacy wrapper on top of a transparent chain. It's the real thing — and now it's available in OWS.

---

## zipher-cli

Headless, local-first Zcash light wallet for AI agents. No full node. No cloud custody. Keys never leave the machine.

```
zipher-cli wallet create
zipher-cli --human balance
zipher-cli --human market agent --dry-run --ows-wallet default
```

- **Light client** — syncs in minutes, runs on a $5 VPS or Raspberry Pi
- **Two-step send** — propose (no seed) then confirm (seed required), safe for agent workflows
- **Cross-chain swaps** — ZEC to any asset via NEAR Intents (BTC, ETH, SOL, USDT, BNB, 140+ tokens)
- **Prediction markets** — autonomous scan-research-analyze-execute pipeline with Kelly Criterion bet sizing
- **x402/MPP payments** — `pay_url` auto-detects x402 or MPP paywalls, pays, retries with credential
- **OWS signing** — PCZT transactions signed via OWS, EVM transactions for BSC, all from one seed
- **Spending policy** — per-tx limits, daily caps, allowlist, rate limiting, approval thresholds
- **Audit log** — every spend recorded with timestamps, context IDs, and error tracking
- **Daemon mode** — background sync with IPC socket, kill switch to zeroize seed in memory
- **Prepaid sessions** — deposit ZEC once via CipherPay, get a bearer token for instant API calls
- **Pay-per-call API server** — `serve` command starts an HTTP server gating agent tools behind x402 micropayments

## MCP Server — 22 Tools for LLM Orchestration

The MCP server exposes the full agent toolkit over stdio, compatible with Claude, Cursor, and any MCP client. See `mcp-config.example.json` for a ready-to-paste config and `docs/mcp-system-prompt.md` for multi-agent orchestration instructions.

| Domain | Tools |
|--------|-------|
| **Wallet** | `wallet_status`, `get_balance`, `validate_address`, `sync_status`, `get_transactions` |
| **Send** | `propose_send`, `confirm_send`, `shield_funds` |
| **Payments** | `pay_x402`, `pay_url` |
| **Swaps** | `swap_tokens`, `swap_quote`, `swap_execute`, `swap_status` |
| **Sessions** | `session_open`, `session_request`, `session_list`, `session_close` |
| **Market Agent** | `market_scan`, `market_research`, `market_analyze`, `market_quote` |

The server holds the seed in memory — tools never accept seed as an argument. Policy engine enforces spending limits on every transaction.

## Prediction Market Agent

The agent follows a structured pipeline, whether invoked from CLI or orchestrated by an LLM via MCP:

```
  Scan           Research         Analyze          Execute
  ─────          ────────         ───────          ───────
  Fetch markets  Search news      Kelly Criterion  ZEC → USDT swap
  Rank by        via Firecrawl    Fractional Kelly BNB gas funding
  uncertainty    Build context    Edge detection   ERC-20 approve
  Filter open    for LLM          EV calculation   Place bet via Myriad
```

**Agent roles in the MCP flow:**

- **News Agent** (`market_research`) — fetches web data via Firecrawl search API. When `FIRECRAWL_API_KEY` is set, pulls real news and analysis. Falls back to market data when unavailable.
- **Analysis Agent** (`market_analyze`) — takes the LLM's probability estimate and confidence, applies fractional Kelly Criterion (quarter to half Kelly), calculates edge, expected value, and recommended bet size. Hard risk cap via `max_bet_usdt`.
- **Trading Agent** (`market_scan`, `market_quote`, `swap_execute`) — handles market discovery, quote fetching, cross-chain swaps (ZEC → USDT via NEAR Intents), and EVM transaction construction for Myriad on BNB Chain.
- **Risk Agent** (`wallet_status`, policy engine, audit log) — spending policy enforces per-tx limits, daily caps, and rate limiting. Every transaction is logged. The LLM can check balance and policy before committing.

**CLI agent mode** runs the full pipeline autonomously with heuristic probability estimation. **MCP mode** lets the LLM read the research and form its own probability estimate — a stronger approach because the LLM brings world knowledge.

## CipherPay — Private Payment Infrastructure

[CipherPay](https://cipherpay.app) is the merchant and verification side of the payment stack. It verifies shielded Zcash payments using Orchard trial decryption — privacy for the payer, certainty for the payee.

- [`@cipherpay/x402`](https://www.npmjs.com/package/@cipherpay/x402) — Express middleware to gate any API behind x402/MPP micropayments with Zcash
- [`@cipherpay/mcp`](https://www.npmjs.com/package/@cipherpay/mcp) — MCP server with 8 tools for AI-driven payment verification

MCP tools:

| Tool | What it does |
|------|--------------|
| `create_invoice` | Create a Zcash payment invoice with ZIP-321 URI |
| `get_invoice_status` | Check if an invoice has been paid (pending/detected/confirmed) |
| `verify_payment` | Verify a shielded ZEC payment by txid — for x402/MPP resource servers |
| `open_session` | Open a prepaid session with deposit txid, get bearer token |
| `get_session_status` | Check session balance and status |
| `close_session` | Close session, get usage summary |
| `get_product_info` | Get product details and pricing |
| `get_exchange_rates` | Current ZEC/fiat rates (USD, EUR, BRL, GBP, etc.) |

**The full loop:** An agent pays for an API via `pay_url` (zipher side). The API server calls `verify_payment` (CipherPay side) to confirm the shielded ZEC payment landed. No accounts, no API keys, no KYC — just cryptographic proof of payment.

---

## Zipher Mobile

Fast, shielded Zcash wallet built for simplicity and privacy. Forked from [YWallet](https://github.com/hhanh00/zwallet) by Hanh Huynh Huu — redesigned with a modern UI, secure architecture, and developer-friendly features.

- **Shielded by Default** — sends from shielded pool only, with one-tap shielding for transparent funds
- **Cross-Chain Swaps** — swap ZEC to BTC, ETH, SOL and more via NEAR Intents
- **Secure Seed Storage** — seeds in iOS Keychain / Android Keystore, keys derived in RAM, wiped on close
- **Multi-Wallet** — manage multiple wallets from a single app, with optional watch-only import
- **Testnet Mode** — full testnet with integrated faucet, built for developers

**Requirements:** iOS 16.4+ / Android 7.0+

---

## Architecture

```
rust/crates/
├── engine/              # Shared wallet engine (16 modules)
│   ├── wallet.rs        # Wallet lifecycle, key derivation, open/close
│   ├── sync.rs          # lightwalletd sync (Sapling + Orchard)
│   ├── send.rs          # Transaction construction, PCZT creation
│   ├── myriad.rs        # Myriad API, Kelly Criterion, EVM tx building
│   ├── research.rs      # Firecrawl web search, news agent
│   ├── swap.rs          # NEAR Intents cross-chain swaps
│   ├── evm_pay.rs       # Multi-chain EVM x402 detection, cross-chain funding
│   ├── x402.rs          # x402 payment protocol
│   ├── mpp.rs           # MPP payment protocol
│   ├── payment.rs       # Protocol auto-detection (x402 vs MPP)
│   ├── session.rs       # CipherPay prepaid sessions
│   ├── policy.rs        # Spending policy engine
│   ├── audit.rs         # Append-only audit log
│   ├── vault.rs         # AES-256-GCM encrypted seed storage
│   ├── query.rs         # Balance, addresses, transactions, viewing keys
│   └── types.rs         # Shared types
│
├── cli/src/             # zipher-cli binary (10 modules)
│   ├── main.rs          # CLI definitions, config, dispatch
│   ├── helpers.rs       # Sapling params, vault, seed, sync helpers
│   ├── wallet.rs        # Wallet/sync/balance/send commands
│   ├── payment.rs       # x402 + pay_url commands
│   ├── swap.rs          # Cross-chain swap commands
│   ├── session.rs       # CipherPay session commands
│   ├── policy.rs        # Policy + audit commands
│   ├── daemon.rs        # Background sync daemon with IPC
│   ├── market.rs        # Prediction market commands + OWS signing
│   └── serve.rs         # Pay-per-call HTTP API with x402 gating
│
└── mcp-server/          # MCP server binary (22 tools)
    └── main.rs          # Tool definitions, server setup

rust/src/                # Flutter Rust Bridge (mobile app FFI)
```

The engine crate is the single source of truth for wallet logic. Every consumer — mobile app, CLI, MCP server — uses the same Rust code for key derivation, proof generation, and transaction construction.

## Built With

- [Open Wallet Standard (OWS)](https://openwallet.sh) — multi-chain wallet and signing (Zcash PCZT + EVM)
- [librustzcash](https://github.com/zcash/librustzcash) — Zcash protocol libraries and light client SDK
- [rmcp](https://github.com/anthropics/rmcp) — Model Context Protocol server SDK
- [NEAR Intents](https://near.org/intents) — cross-chain swap infrastructure
- [Myriad Markets](https://myriad.markets) — prediction markets on BNB Chain
- [Firecrawl](https://firecrawl.dev) — web search and scraping API
- [CipherPay](https://cipherpay.app) — Zcash payment infrastructure ([`@cipherpay/x402`](https://www.npmjs.com/package/@cipherpay/x402) middleware, [`@cipherpay/mcp`](https://www.npmjs.com/package/@cipherpay/mcp) server)
- [Flutter](https://flutter.dev) — mobile UI (iOS & Android)

## Privacy

- No data collection, no analytics, no tracking
- All data recoverable from seed phrase
- Customizable `lightwalletd` server URL
- Shielded pool used by default for all operations
- Seeds in platform secure storage, keys derived in RAM, wiped on close

Default servers powered by [CipherScan](https://cipherscan.app) infrastructure.

## Ecosystem

| Project | Role | Status |
|---------|------|--------|
| **Zipher** | The Wallet — financial privacy, user-friendly | Beta |
| **zipher-cli** | The Agent Wallet — headless, MCP + OWS | Alpha |
| **zipher-mcp-server** | LLM orchestration — 22 tools for autonomous agents | Alpha |
| [**CipherScan**](https://cipherscan.app) | The Explorer — mainnet and testnet | Live |
| [**CipherPay**](https://cipherpay.app) | The Infrastructure — invoices, x402 verify, sessions | Live |

## License

[MIT](LICENSE.md)
