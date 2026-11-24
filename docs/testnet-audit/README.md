# Testnet mode audit — 2026-11-24

Scope: every user-facing feature with Testnet Mode on, read from source and
checked on an iOS 26.2 simulator (debug build of this branch). No mainnet funds
were used; no testnet funds were received either, because the faucet has
paused claims (see below).

## Fixed in this branch

| Area | Problem | Fix |
|---|---|---|
| Network switch | The active account object kept `coin: 0` after switching to testnet, so every balance, address and activity refresh was skipped (`isCurrentWallet` false) and the mainnet receive address stayed on screen. | `_toggleTestnet` pauses sync, clears the account, and installs a new `ActiveAccount2` for the target network. |
| Network switch | The previous network's server selection was used to open the new network's wallet (a custom mainnet server URL would be used for testnet, and the reverse on the splash fallback). | New `applyNetworkMode` loads the target network's saved `CoinSettings` before opening its wallet; used by the toggle and both splash reverts. |
| Settings | `setActiveAccount` replaced saved coin settings (server choice, custom URL, fees) with defaults on every network switch and on every build of the backup page. | Loads the persisted settings; the defaults-only `CoinSettingsExtension.load` is removed. |
| Fiat | The mainnet ZEC price stayed in `marketPrice` on testnet, so Send, Activity and Home could show dollars for TAZ (and PR #14 would stop it ever being cleared). | `MarketPrice.update` clears the price for coins without a market and drops results that arrive after a network switch; switching clears it too. |
| Startup | `_resetTestnetIfStale` deleted every testnet database that had no `.sdk_version` marker, which is every testnet wallet on its first relaunch. The wallet was then rebuilt from the chain tip, hiding earlier TAZ. | Removed; the engine handles its own migrations. |
| Restore | Rebuilding a wallet from its keychain seed (missing or corrupt DB, on both networks) started at the chain tip. | Each wallet's birthday is remembered per network (`WalletBirthdays`); rebuilds start there, or at full history when unknown. |
| Shared/watch-only | Switching network with a FROST or watch-only wallet active created a fresh single-signer seed under the shared wallet's name. | The toggle refuses with an explanation; `createNetworkWalletForProfile` throws for watch-only profiles. |
| Faucet | `testnet.zecfaucet.com` no longer resolves. | Link now goes to `zecfaucet.com` (the same faucet; it shows TAZ). |
| Agent approvals | A request for the other network was marked shown and then ignored, so it never appeared after switching back. The approval screen never said which network. | Other-network requests wait unmarked; the screen shows TESTNET and TAZ for testnet requests. |
| CipherPay | Invoices live on CipherPay's mainnet service. On testnet the user saw a mainnet invoice, passed biometrics, then got a raw IncorrectNetwork error; `zcash-test:` requests with a `CP-` memo were hijacked into a mainnet invoice lookup. | Testnet: only checkout links open the invoice page, which explains CipherPay is mainnet-only and never loads or pays; other shapes are plain sends. |

Tests: `test/testnet_mode_test.dart` (11 tests).

## Verified working on testnet (simulator)

- Switch to testnet: Testnet badge, no fiat, wallet created with an independent
  seed, syncs against `testnet.zec.rocks` to "Synced".
- Receive: `utest1…` shielded address, labelled "Zcash Testnet"; no other chains offered.
- Swap: chat answers "Cross-chain swaps are available on mainnet"; the Swap tab is replaced by Faucet.
- Relaunch on testnet: the wallet opens as-is (log shows `openWalletById`, no reset or restore).
- Switch back to mainnet: fiat returns, Faucet tab and badge disappear.

Screenshots: `01`–`05` in this folder.

## Already correct (code review)

- EVM portfolio, other-chain addresses and NEAR swaps are skipped on testnet (`wallet_chat.dart`).
- Ironwood heights match the engine (`zakura-protocol` 4.0.0: NU6.3 mainnet 3,428,143, testnet 4,134,000); plan/commit capture the network.
- HITL protocol binds `network` into the proposal hash; the phone only signs the decision.
- Restore birthdays: month table is mainnet-only and returns null on testnet; birthday 0 resolves to the network's Sapling activation.
- Sends, shielding and CipherPay confirm the network did not change during authentication.

## Not fixed here (follow-ups)

- **CipherScan testnet lightwalletd** (`lightwalletd.testnet.cipherscan.app`) serves a certificate for `api.testnet.cipherscan.app`, so TLS fails if a user picks it. Server-side fix; PR #16 renames the entry.
- **Faucet has paused claims** (zecfaucet.com "taking a short break"), so funded send/shield on testnet could not be exercised.
- **FROST invites carry no network**: a mainnet coordinator and a testnet joiner can finish DKG with different addresses; the joiner also takes the coordinator's birthday height. Needs a protocol field.
- **FROST approval** opens the profile on whichever network is active (`frost_watch_service.dart`); unreachable today (`remoteSigningEnabled` is false).
- **Explorer links** still point at `testnet.cipherscan.app`; PR #16 moves them to `testnet.zecblock.com`.
- **Units**: the home balance says "ZEC" for testnet funds.
- **Engine server list** for testnet has only `testnet.zec.rocks`, so no alternate-server fallback on testnet.
- **iOS launch crash on `main` (not testnet)**: `AppDelegate.application(_:configurationForConnecting:options:)` calls `super`, which `FlutterAppDelegate` does not implement with Flutter 3.41.1, so debug builds abort at launch. The simulator check used a local, uncommitted patch returning `UISceneConfiguration(name: "flutter", …)`.
