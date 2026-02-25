# Zipher

> Making Zcash accessible. For everyone.

Zipher is a fast, shielded Zcash wallet built for simplicity and privacy. Forked from [YWallet](https://github.com/hhanh00/zwallet) by Hanh Huynh Huu — redesigned from the ground up with a modern UI, secure architecture, and developer-friendly features.

Built by [Atmosphere Labs](https://atmospherelabs.dev).

## Features

- **Warp Sync** — processes ~10,000 blocks per second
- **Cross-Chain Swaps** — swap ZEC to BTC, ETH, SOL and more via NEAR Intents
- **Shielded by Default** — fully private transactions with automatic shielding
- **Secure Seed Storage** — seeds in iOS Keychain / Android Keystore, keys derived in RAM, wiped on close
- **Multi-Account** — manage multiple wallets from a single app
- **Testnet Support** — full testnet mode with integrated faucet, built for developers
- **Memo Inbox** — receive and read encrypted on-chain memos
- **Privacy Health Bar** — see your privacy status at a glance
- **Contact Book** — save and manage addresses
- **Coin Control** — view and manage individual notes
- **Fiat Conversion** — display balances in 70+ currencies
- **QR Scanner** — scan addresses and payment URIs

## Privacy

- No data collection, no analytics, no tracking
- All data recoverable from seed phrase
- Customizable `lightwalletd` server URL
- Shielded pool used by default for all operations

## Built With

- [Flutter](https://flutter.dev) — mobile UI (iOS & Android)
- [Warp Sync Engine](https://github.com/hhanh00/zcash-sync) — Rust-based sync by Hanh Huynh Huu
- [librustzcash](https://github.com/zcash/librustzcash) — Zcash protocol libraries
- [NEAR Intents](https://near.org/intents) — cross-chain swap infrastructure

## Requirements

- iOS 16.4+
- Android 7.0+ / 2 GB RAM

## Ecosystem

Zipher is part of the [Atmosphere Labs](https://atmospherelabs.dev) suite:

| Project | Description |
|---------|-------------|
| **Zipher** | The Wallet — financial privacy, finally user-friendly |
| [**CipherScan**](https://cipherscan.app) | The Explorer — mainnet and testnet |
| [**CipherPay**](https://cipherpay.app) | The Infrastructure — private payments, a few lines away |

## Credits

Zipher is built on top of YWallet's Warp sync engine and Rust backend, created by **Hanh Huynh Huu**. The original project is licensed under MIT. We are grateful for his work on making Zcash wallets fast.

## License

[MIT](LICENSE.md)
