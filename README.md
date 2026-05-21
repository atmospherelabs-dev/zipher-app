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
zipher-cli wallet init
zipher-cli --human balance
zipher-cli --human polymarket list --keyword bitcoin
```

- **Light client** — syncs in minutes, runs on a $5 VPS or Raspberry Pi
- **Two-step send** — propose (no seed) then confirm (seed required), safe for agent workflows
- **Cross-chain swaps** — ZEC to any asset via NEAR Intents (BTC, ETH, SOL, USDT, BNB, 140+ tokens)
- **Prediction markets** — Polymarket discovery, position lookup, and alpha trade tooling
- **x402/MPP payments** — `pay_url` auto-detects x402 or MPP paywalls, pays, retries with credential
- **OWS vault** — `wallet init` stores the mnemonic in the encrypted OWS vault; CLI/MCP decrypt it when needed
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
| **Market Agent** | `market_research` (web research for prediction markets, generic) |

The server holds the seed in memory — tools never accept seed as an argument. Policy engine enforces spending limits on every transaction.

## Prediction Markets — Polymarket

Polymarket (Polygon, CLOB, USDC) is the active prediction-market venue. Discovery, position lookup, and alpha bet/sell tooling run in the mobile app's Action Wallet and via `zipher-cli polymarket`.

- **Discovery** — Gamma API event listing with quality filters (volume, spread, distinct outcome prices).
- **Research** — `market_research` (Firecrawl) for news context; supplies the LLM with a probability-estimate grounding.
- **Funding** — automatic cross-chain bridge from ZEC → USDC on Polygon via NEAR Intents, then on-chain USDC → USDC.e via ParaSwap. ZEC stays shielded until the exact moment of bridging.
- **Trade** — CLOB order placement (EIP-712 signature) for limit/market BUY, ERC-1155 `setApprovalForAll` for sells.
- **Risk** — spending policy enforces per-tx caps and daily limits before any signing.

Earlier builds also targeted Myriad on BSC. That venue was removed in 2026-05 due to thin liquidity and weak AMM UX — the Rust module, FRB surface, CLI subcommand, and MCP tools were deleted in commit `e62c30b`.

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
│   ├── polymarket.rs    # Polymarket CLOB, EIP-712 signing, quality filters
│   ├── evm.rs           # Shared EVM helpers (RPC, RLP, EIP-1559 fees)
│   ├── evm_swap.rs      # ParaSwap aggregator client (quote/approve/build/sign)
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
│   ├── market.rs        # Polymarket commands (discovery + trade) + OWS signing
│   └── serve.rs         # Pay-per-call HTTP API with x402 gating
│
└── mcp-server/          # MCP server binary (29 tools)
    └── main.rs          # Tool definitions, server setup

rust/src/                # Flutter Rust Bridge (mobile app FFI)
```

The engine crate is the single source of truth for wallet logic. Every consumer — mobile app, CLI, MCP server — uses the same Rust code for key derivation, proof generation, and transaction construction.

## Built With

- [Open Wallet Standard (OWS)](https://openwallet.sh) — multi-chain wallet and signing (Zcash PCZT + EVM)
- [librustzcash](https://github.com/zcash/librustzcash) — Zcash protocol libraries and light client SDK
- [rmcp](https://github.com/anthropics/rmcp) — Model Context Protocol server SDK
- [NEAR Intents](https://near.org/intents) — cross-chain swap infrastructure
- [Polymarket](https://polymarket.com) — prediction markets on Polygon (CLOB + Gamma APIs)
- [ParaSwap](https://paraswap.io) — DEX aggregator for same-chain EVM swaps (USDC.e bridging)
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
