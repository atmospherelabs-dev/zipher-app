# Conversational home

Implemented locally on 2026-09-09. Home (`/account`), `/ask`, and the former
`/account/action` entry point now use the same deterministic wallet chat. The
classic dashboard remains at `/account/overview`; the Swap and More tabs remain.

## Existing Z interface

Home retains the original Z page presentation: quiet top bar, centered expandable
balance, asymmetric message bubbles, shortcuts beneath the opening message,
separate inline cards, pulsing progress dots and the rounded composer. The original presentation is retained in `z_chat_widgets.dart`; the unused legacy
ActionPage and its AI/action executor tree have been removed. Payment routing stays
separate from presentation. Send, Receive and Swap lead the shortcuts. Fiat is the headline when
a price is available, with a ZEC fallback and explicit spendable/confirming details.
The USD headline includes Zcash plus tracked EVM assets, with an explicit incomplete
subtotal when prices or chains are missing. Other fiat currencies remain a Zcash
headline, with EVM rows labeled USD to avoid mixing currencies.
Recent Actions uses the active wallet's transactions and expands in a bounded area.
Details collapse while the keyboard is open so the conversation remains usable.

## Everyday flows

- **Send:** `send` → recipient → amount → review → Send ZEC. Either field can be
  supplied first. `I want to send 0.5 ZEC to u1…` collects both in one message.
  Invalid replies retain the draft; `cancel` discards it.
- **Receive:** `my address` / `receive` → supported-chain buttons → full address,
  QR and Copy. `my Bitcoin address` goes directly to that address. Available
  mainnet derivations: Zcash, Bitcoin, Solana, Ethereum, Base, Arbitrum, Optimism,
  Polygon and BSC. Foreign choices require the wallet's actual derived address;
  testnet only offers Zcash Testnet. Zcash receive activates fast sync polling.
- **Swap:** ZEC amount → token → explicit network selection → recipient (or the
  wallet's matching BTC/SOL/EVM address, where available) → provider quote and
  exact Zcash fee → confirmation → deposit/status updates in chat. The original
  swap page remains available for swaps into ZEC and other advanced options.
- **Balance/history:** local wallet data; total, spendable shielded and confirming
  amounts remain distinct. ZEC remains available when the fiat feed is unavailable.

The command router performs no model inference and sends no conversation text to
an AI service. The unused local-model backend and bindings have been removed. EVM balances load
separately through configured Alchemy RPC or public RPC services, which necessarily
receive the public EVM address; this is disclosed in the expanded balance view. Chat messages/drafts stay in memory and are
reset on wallet changes. Existing swap records remain in local SwapStore.
Provider quotes necessarily disclose recipient/refund addresses to NEAR Intents;
this is described in the review. Cross-chain privacy is not equivalent to a
shielded Zcash transfer.

## Payment correctness

Amounts use exact integer zatoshis. Bare amounts mean ZEC. Dollars, negatives,
scientific notation, ambiguous separators, amounts beyond supply and more than
8 decimal places are rejected rather than converted or rounded. Memo numbers and
address characters cannot become payment amounts. The Rust engine remains the
checksum/network/available-funds authority.

A send review includes the complete recipient, amount, actual fee and total.
Review cards are one-use, including cancellation and taps before a frame rebuild.
Starting another command invalidates the old review. WalletService checks the
proposal revision, wallet and network before accessing signing keys; proposal
creation, confirmation, direct sends and shielding reserve the payment path before
asynchronous key access. Direct send/shielding invalidate old chat proposals.
Multi-recipient input is rejected by the single-recipient engine wrapper, rather
than silently sending only to the first recipient. Oversized UTF-8 memos are
rejected before preparing a chat send. Old swap network/address buttons cannot
answer a replacement draft.
Signing continues through the existing biometric/PIN authorization gate.
Watch-only and shared-wallet signing use the existing dedicated overview flow.

Swaps use exact-input quotes, never a fallback ZEC price or an EVM address for a
BTC/SOL destination. Missing output minimums, mismatched input amounts, expired
quotes and quotes requiring unsupported deposit memos are rejected. Recipient
validation by the quote provider is followed by explicit user review of network
and address; the chat does not provide its own checksum validator for every
foreign chain. Destination tags/memos and swaps into ZEC are outside this chat
flow. A recovery record is saved before broadcasting and updated with the txid.
Post-broadcast storage/notification errors do not offer another send. An ambiguous
broadcast tells the user to check chain history before starting another payment.

## Sync and responsiveness

- `CoalescingRefresh` combines event bursts and serializes database refreshes.
  Events received during a read cause a trailing refresh. Poll and event paths
  share the queue; wallet changes dispose the old queue.
- Explicit send/receive boosts and pending transactions keep the 5-second polling
  fallback even when the event stream was recently active. Other polling remains
  adaptive with jitter.
- `SyncStatusWidget` observes its own state so progress updates without rebuilding
  the entire home screen. Scan, confirmation and disconnected states remain
  visible while using chat.
- Typed NEAR API calls have bounded timeouts; swap status polling cannot overlap.
- Wallet switches invalidate pending sync polls, timers and old event subscriptions;
  chain height and stream-activity timestamps reset with the wallet. Closed wallets
  do not restart polling. Late address/balance reads cannot populate another wallet.
- Spendable uses the engine's current result; old spendable amounts are no longer
  raised over the engine's result during confirmations/rescans.
- EVM prices and six chains load concurrently under bounded timeouts. Duplicate
  requests share an in-flight result; per-screen, per-address snapshots cache for
  60 seconds. Failed chains are explicitly unavailable, and healthy chains remain
  visible. Refreshes avoid hidden/background screens and refresh on resume.
- Native and stablecoin prices are no longer hardcoded. Missing/stale quotes remain
  unpriced, and incomplete USD totals are labeled as subtotals. CoinGecko timestamps
  are checked as described in its [price API](https://docs.coingecko.com/reference/simple-price).
  Bitcoin/Solana balances and arbitrary token discovery are not implemented in
  this header; address support does not imply balance or send support.

These changes reduce application-side latency and redundant reads. They do not
claim a measured improvement to cold-restore scanning throughput.

## Vizor and Zakura assessment

The shared engine now uses stable wallet libraries adapted to Zakura Common 1.2.0,
while preserving the SDK's Ironwood migration store. The app and CLI are separate
clients of this engine. See [CLI/engine stack audit](cli-engine-stack-audit.md) for
versions, the local compatibility patches, verification and remaining limitations.

The existing engine already implements bounded prefetch, peer rotation, idle
timeouts, cancellation and adaptive batches. No new cold-sync benchmark is claimed.

## Verification

Completed locally: 58 regression tests passed, including chat layout and legacy
submission-route tests. Full Flutter analysis reported no issues. This includes exact selected-address
clipboard contents, mainnet/testnet choices, partial-chain failures, stale/missing
prices, coalesced/cached RPC requests, stale-wallet completions, closed-wallet
polling, sync reset state and payment-lock cleanup before native key access.
The final iOS simulator build links the upgraded Common engine successfully.
Phone previews cover the chain picker,
copy flow and expanded multi-chain balance with synthetic wallet data.

## Chat readiness

| Feature | Current verification |
| --- | --- |
| Local routing, guided send/swap collection, cancel/help | Regression tested; no model calls |
| Chain picker, full addresses, QR and exact copy | Widget/model tests with synthetic wallet addresses |
| Zcash + tracked EVM balances | Widget tests and mocked RPC failure/cache/price tests; no live funded-wallet reconciliation |
| History and sync indicators | Connected to wallet data; layout/reset/progress tested |
| ZEC sends and ZEC-out swaps | Reviews, amount/quote checks and locking tested; signing/broadcast/settlement still need live acceptance |
| Direct BTC/SOL/EVM sends, BTC/SOL balances, arbitrary token discovery | Not implemented in this chat |
| Swaps into ZEC, shared-wallet signing | Dedicated existing pages; not certified by these chat tests |
| Markets/bets, sweeps, voting and old AI features | Outside this deterministic chat's supported command set |

No “100% working” settlement or optimal cold-sync throughput claim is made. Native
proof generation, providers, chain confirmation and device background/resume must
be validated with controlled funded-wallet acceptance runs. The unused legacy action executors and funding resolver have been removed.

`flutter test --no-pub test` covers exact amount parsing, guided flow recovery,
address-family collection, local routing, rejected quotes, pending-swap record
updates, one-use review behavior, pre-key-access service guards, coalesced refresh
bursts, full chat layout with keyboard, reactive sync progress and Z/home routing.
`flutter analyze --no-pub` can target the changed files and test directory.

A rendered preview can be created with:

```
flutter test --no-pub --dart-define=CHAT_SCREENSHOT=true test/wallet_chat_test.dart
```

It writes `build/chat-preview.png` using synthetic balances and addresses.
Real testnet send/receive, live mainnet swap settlement, app suspension/restart,
and device sync performance still need device acceptance runs. Tests do not move
funds, initialize a real wallet, or claim settlement/proof-generation verification.
