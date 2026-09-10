# Conversational home

Updated locally on 2026-09-10. Home (`/account`), `/ask`, and the former
`/account/action` entry point now use the same deterministic wallet chat. The
classic dashboard remains at `/account/overview`; mainnet navigation is Home and More. Legacy swap entry points redirect into chat.

## Existing Z interface

Home uses one dollar portfolio total. Tapping it expands asset rows; holding the
amount or tapping the ZEC row opens the pool sheet. Unknown prices are not guessed
or added to the total. USD Zcash quotes are kept separate from other fiat settings.
The top-left account control opens the existing account switcher. A top-right
shield lights up for fully shielded ZEC, alongside a green/yellow/red sync dot with
its current percentage. Both controls open their details.

Shared opaque surface and text tokens keep sheets, chat cards, inputs and pages
consistent. The pool sheet uses the root navigator and an opaque surface, covering
the composer and bottom navigation. Pool colors use the shared pool tokens.
Home has two mutually exclusive tabs: Chat and Activity. Chat is the default and
contains messages, action shortcuts and the composer. Activity uses the full
remaining height, with pending Zcash transfers and active NEAR Intents swaps
first, followed by recent transactions and completed swap results. Chat controls
are hidden in Activity; returning to Chat preserves its messages, draft and scroll.
The Activity badge counts pending items. New events update the badge without
changing the user's selected tab. Each row opens its transaction or swap details;
swap funding transactions are represented once by the swap row.
The tab bar hides while the keyboard is open to leave room for the conversation.

Swap tracking survives chat clearing and restores on wallet changes/restart. New
records include wallet and network ownership; legacy records require an exact
funding-transaction match. Provider status polls every 15 seconds while the wallet
is visible and the app is active. Failures remain pending with a retry label;
terminal results are cached. Incoming activity depends on what the wallet has
actually detected; the panel does not predict undiscovered transfers.

## Everyday flows

- **Send:** `send` → recipient → amount → review → Send ZEC → device authentication. Either field can be
  supplied first. `I want to send 0.5 ZEC to u1…` collects both in one message.
  Invalid replies retain the draft; `cancel` discards it.
- **Receive:** `my address` / `receive` → supported-chain buttons → full address,
  QR and Copy. `my Bitcoin address` goes directly to that address. Available
  mainnet derivations: Zcash, Bitcoin, Solana, Ethereum, Base, Arbitrum, Optimism,
  Polygon and BSC. Foreign choices require the wallet's actual derived address;
  testnet only offers Zcash Testnet. Zcash receive activates fast sync polling.
- **Swap:** ZEC amount → token → explicit network selection → recipient (or the
  wallet's matching BTC/SOL/EVM address, where available) → provider quote and
  exact Zcash fee → confirmation → deposit/status updates in chat. Standalone swap navigation has been removed; reverse swaps are not implemented in chat.
- **Balance:** local wallet data; total, spendable shielded and confirming
  amounts remain distinct. ZEC remains available when the fiat feed is unavailable.
- **Activity:** pending and completed transfers in one tab. `history` opens that tab;
  there is no duplicate home shortcut or More entry.
- **Contacts:** `add contact` → chain → name → address → Save contact. Chain, name
  and address persist together in secure storage, including multiple chains using
  the same EVM address. `contacts` opens saved entries with copy and Zcash send.
  Zcash addresses are engine-validated; foreign addresses receive format validation.
- **Accounts:** `accounts` opens the picker. `rename account` asks for the new name
  and updates the header without clearing chat. `delete account` lists inactive
  wallets, explains local key removal, then requires a separate button and device
  authentication. The active wallet cannot be deleted through chat.
- **Scan:** the composer QR button or `scan` opens the existing camera/gallery/manual
  scanner. A Zcash address or supported single-recipient URI starts a draft/review;
  it never signs automatically. Unsupported parameters, multiple payments and
  wrong-network URI schemes are rejected. While adding a contact, scanning supplies
  the address for the selected chain. Back/cancel reliably returns to the chat.
- **More:** contacts, preferences, about, pool migration, recovery, shared wallets,
  diagnostics/network selection and backup remain. Duplicate Action/Activity/Memos
  links, promotional badges and the old app-reset entry were removed.

The command router performs no model inference and sends no conversation text to
an AI service. The unused local-model backend and bindings have been removed. EVM balances load
separately through configured Alchemy RPC or public RPC services, which necessarily
receive the public EVM address; these reads remain separate from private Zcash scanning. Chat messages/drafts stay in memory and are
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
Signing requires the existing biometric/device-passcode authorization gate after review. The legacy protection opt-out no longer bypasses this gate.
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
- The small sync indicator observes engine events, including the active scan target.
  Recovery clears stale error state immediately. Routine historic-batch balance
  refreshes are throttled; transaction events remain immediate.
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
  unpriced, and incomplete totals are marked. CoinGecko timestamps
  are checked as described in its [price API](https://docs.coingecko.com/reference/simple-price).
  Native Bitcoin and Solana balances are included. Arbitrary EVM/SPL token discovery
  and sending from those chains are not implemented by this chat.

These changes reduce application-side latency and redundant reads. They do not
claim a measured improvement to cold-restore scanning throughput.

## Vizor and Zakura assessment

The shared engine now uses stable wallet libraries adapted to Zakura Common 1.2.0,
while preserving the SDK's Ironwood migration store. The app and CLI are separate
clients of this engine. See [CLI/engine stack audit](cli-engine-stack-audit.md) for
versions, the local compatibility patches, verification and remaining limitations.

The existing engine already implements bounded prefetch, peer rotation, idle
timeouts, cancellation and adaptive batches. The selected-peer versus regional-rotation benchmark is documented in
[the sync report](zipher-sync-v3.md#2026-09-10-selected-peer-policy). It is not a Vizor comparison.

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

### 2026-09-10 verification

71 Flutter tests pass. Live simulator checks confirmed asset balances, address
copy, pool details, recovered-transaction navigation, opaque modal coverage, and
the sync percentage. No real payment was submitted. Full-chain restore and a
matched release-build comparison against Vizor remain unverified.

## Compact send review and fee selection

Spendable shielded ZEC appears below the dollar total and in send prompts. ZEC
formatting removes only trailing zeros, including pool breakdowns and transaction
details; integer zatoshi formatting preserves all eight meaningful decimals.
Home uses underlined tabs, three primary actions, and quieter secondary tools.

The send review leads with the amount and an expandable recipient, with aligned
fee and total rows. Cancel and Send share one row. The standard review fits within
a 360-point chat viewport including card padding; expanding an address or long
memo can require scrolling. Opening a review dismisses the keyboard.

Priority is off by default. Switching it rebuilds the SDK proposal with a 20,000
zat marginal fee (standard is 5,000), updates the exact fee/total in place, and
blocks signing during recalculation or after failure. The chosen fee rule is also
used for transaction construction and PCZT generation. Higher fees do not promise
confirmation timing and differ from the standard fee fingerprint.

Validation: 43 focused Flutter tests passed and 55 engine tests passed (three
manual tests excluded). In the rebuilt simulator, an unsigned 0.001 ZEC review
changed from a 0.0001 ZEC fee to 0.0004 ZEC and back. No additional funds were sent.

### Account and chat management verification (2026-09-10)

Focused Flutter regression coverage includes contact chain persistence, guided
contact entry, cancellation disabling old save buttons, QR request parsing and
scanner cancellation, mandatory authentication despite the old opt-out setting,
and the History-to-Activity route. Simulator verification includes a live account
rename and restoration of its original label. No account was deleted or payment
sent for these checks. Physical camera capture still requires device testing.
