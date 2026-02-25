# Zipher

> A privacy-first Zcash wallet by [Cipherscan](https://cipherscan.app)

Zipher is a fast, shielded Zcash wallet built for simplicity and privacy. It is a fork of [YWallet](https://github.com/nickyee/ywallet) by Hanh Huynh Huu, with a redesigned UI, streamlined features, and tighter integration with the Cipherscan block explorer.

## Features

- **Warp Sync** — processes ~10,000 blocks per second
- **Encrypted Messaging** — send private memos via shielded transactions, permanently stored on chain
- **Shielded by Default** — fully private transactions with automatic shielding
- **Multi-Account** — manage multiple wallets from a single app
- **Privacy Health Bar** — see your privacy status at a glance
- **Contact Book** — save addresses and message contacts directly
- **Coin Control** — view and manage individual notes
- **Cold Wallet** — prepare unsigned transactions for offline signing
- **Fiat Conversion** — display balances in 70+ currencies
- **QR Scanner** — scan addresses and payment URIs

## Privacy

- No data collection, no analytics, no tracking
- All data recoverable from seed phrase or secret key
- Customizable `lightwalletd` server URL
- Shielded pool used by default for all operations

## Built With

- [Flutter](https://flutter.dev) — cross-platform UI
- [Warp Sync Engine](https://github.com/nickyee/ywallet) — Rust-based sync by Hanh Huynh Huu
- [librustzcash](https://github.com/zcash/librustzcash) — Zcash protocol libraries

## Requirements

- iOS 16.4+
- Android 7.0+ / 2 GB RAM

## Credits

Zipher is built on top of YWallet's Warp sync engine and Rust backend, created by **Hanh Huynh Huu**. The original project is licensed under MIT and we are grateful for his incredible work on making Zcash wallets fast and accessible.

## License

[MIT](LICENSE.md) — Original copyright Hanh Huynh Huu, 2023
