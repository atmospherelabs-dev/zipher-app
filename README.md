# Zipher

> Making Zcash accessible. For everyone.

Zipher is a privacy-first Zcash wallet — for humans and AI agents. One Rust engine, two interfaces: a mobile app for everyday use and a headless CLI for autonomous agents.

Built by [Atmosphere Labs](https://atmospherelabs.dev).

---

## Zipher Mobile

Fast, shielded Zcash wallet built for simplicity and privacy. Forked from [YWallet](https://github.com/hhanh00/zwallet) by Hanh Huynh Huu — redesigned with a modern UI, secure architecture, and developer-friendly features.

- **Shielded by Default** — fully private transactions with automatic shielding
- **Cross-Chain Swaps** — swap ZEC to BTC, ETH, SOL and more via NEAR Intents
- **Secure Seed Storage** — seeds in iOS Keychain / Android Keystore, keys derived in RAM, wiped on close
- **Multi-Account** — manage multiple wallets from a single app
- **Testnet Support** — full testnet mode, built for developers
- **Memo Inbox** — receive and read encrypted on-chain memos
- **Privacy Health Bar** — see your privacy status at a glance
- **Contact Book, Coin Control, QR Scanner, Fiat Conversion** — the full toolkit

**Requirements:** iOS 16.4+ / Android 7.0+

## zipher-cli

Headless, local-first Zcash light wallet for AI agents. No full node. No cloud custody. Keys never leave the machine.

```
zipher-cli wallet create
zipher-cli sync start
zipher-cli send propose --to <ADDRESS> --amount 100000
ZIPHER_SEED="..." zipher-cli send confirm
```

- **Light client** — syncs in minutes, runs on a $5 VPS or Raspberry Pi
- **Two-step send** — propose (no seed) then confirm (seed required), safe for agent workflows
- **Spending policy** — per-tx limits, daily caps, allowlist, rate limiting
- **Audit log** — every spend recorded with timestamps and context IDs
- **Daemon mode** — background sync with IPC, kill switch to zeroize seed in memory
- **MCP server** — 8 tools for Cursor, Claude Desktop, and any MCP-compatible client
- **OpenClaw skill** — guarded send flow with preflight checks

**[Quickstart](docs/QUICKSTART.md)** · **[Full PRD](docs/agent-wallet-prd.md)** · **[CLI Reference](skills/zipher-operator/references/cli-commands.md)**

---

## Architecture

```
rust/
├── crates/
│   ├── engine/         # Shared wallet engine (Sapling + Orchard proofs, sync, send)
│   ├── cli/            # zipher-cli binary
│   └── mcp-server/     # MCP server binary
└── src/                # Flutter Rust Bridge (mobile app FFI)

skills/
└── zipher-operator/    # OpenClaw agent skill
```

The engine crate is the single source of truth for wallet logic. Every consumer — mobile app, CLI, MCP server — uses the same Rust code for key derivation, proof generation, and transaction construction.

## Built With

- [Flutter](https://flutter.dev) — mobile UI (iOS & Android)
- [librustzcash](https://github.com/zcash/librustzcash) — Zcash protocol libraries and light client SDK
- [rmcp](https://github.com/anthropics/rmcp) — Model Context Protocol server SDK
- [NEAR Intents](https://near.org/intents) — cross-chain swap infrastructure

## Privacy

- No data collection, no analytics, no tracking
- All data recoverable from seed phrase
- Customizable `lightwalletd` server URL
- Shielded pool used by default for all operations

Default servers powered by [CipherScan](https://cipherscan.app) infrastructure.

## Ecosystem

| Project | Role | Status |
|---------|------|--------|
| **Zipher** | The Wallet — financial privacy, user-friendly | Beta |
| **zipher-cli** | The Agent Wallet — headless, MCP + OpenClaw | Alpha |
| [**CipherScan**](https://cipherscan.app) | The Explorer — mainnet and testnet | Live |
| [**CipherPay**](https://cipherpay.app) | The Infrastructure — private payments, a few lines away | Live |

## Credits

Zipher is built on top of YWallet's Rust backend, created by **Hanh Huynh Huu**. The original project is licensed under MIT. We are grateful for his work on making Zcash wallets fast.

## License

[MIT](LICENSE.md)
