# Wallet UX, sync and privacy audit — 2026-09-10

## Sync findings

The monitored historical restore advanced normally but slowed sharply in the sandblasting interval. The old logs showed sub-second download/scan times while committed batches took several seconds. Those per-batch scan measurements excluded progress bookkeeping.

Zipher called `get_wallet_summary` several times per batch merely to obtain its fully scanned height, plus once for weighted scan progress. That SDK call calculates balances and subtree estimates. The new path reads `block_fully_scanned`, preserving the SDK's birthday-minus-one fallback, and refreshes the expensive weighted summary at most every 15 seconds. Committed heights and block counts still update each batch. Summary elapsed time is now logged separately. A regression test checks heights before scanning, after scanning, after rewind, and after rescanning.

Vizor uses this lightweight height-query approach too, as well as a coalesced wallet-summary cache. Both implementations prefetch and use 100-block sandblasting batches; Zipher already uses the selected server with fallback on failure. Neither skips trial decryption of old shielded history. Vizor's development Rust build uses optimization level 3; Zipher's current development build uses level 1, with level 3 in release. The debug simulator therefore cannot establish release-speed parity. No matched full-history Vizor/Zipher benchmark has been completed. The prior 16.4% short-window result concerned server rotation only, not this change or spam-era performance.

Source reviewed: [Vizor sync](https://github.com/chainapsis/vizor-wallet/blob/123bcef78c03f0ed9b11f1778e5de424ffb9cd5f/rust/src/wallet/sync/mod.rs), [sync engine](https://github.com/chainapsis/vizor-wallet/blob/123bcef78c03f0ed9b11f1778e5de424ffb9cd5f/rust/src/wallet/sync_engine/mod.rs), [summary cache](https://github.com/chainapsis/vizor-wallet/blob/123bcef78c03f0ed9b11f1778e5de424ffb9cd5f/rust/src/wallet/wallet_summary_cache.rs).

## Network privacy

Home has a key icon next to the shield and sync indicator. `privacy`, `enable Tor`, `activate Tor`, `disable Tor`, and the buttons use one shared controller with the migration page. The icon describes the built-in Zcash route; it does not claim whole-device VPN protection.

- Tor bootstrap and verification replace existing sync/mempool channels, rather than leaving a previously opened direct channel alive.
- A requested but unavailable Tor route blocks new Zcash sync/broadcast connections. It is not silently downgraded to direct. The user's preference survives failure.
- Normal and migration broadcasts check the same transport requirement.
- Startup restores the saved Tor choice before starting sync.
- Prices, other-chain RPCs, swap-provider APIs and external browser traffic are separate connections. External VPN/Nym status is explicitly unverified.

Nozy's reviewed Nym path is opt-in remote `sendrawtransaction` via a `nym-smolmix-broadcast-spike` helper subprocess, not a universal built-in VPN. Local/LAN RPC stays direct; its source distinguishes mixnet broadcast from an external NymVPN. This helper cannot simply be dropped into the iOS app as a desktop executable. Zipher does not include Nym transport in this change.

Source: [Nozy helper](https://github.com/LEONINE-DAO/Nozy-wallet/blob/e65643c7116e5a5ebca3b5d70c4c55b50bbf777c/src/nym_mixnet_broadcast.rs), [Nozy connection labels](https://github.com/LEONINE-DAO/Nozy-wallet/blob/e65643c7116e5a5ebca3b5d70c4c55b50bbf777c/src/send_egress.rs).

## Transaction fingerprint

This is a source audit of construction defaults, not an on-chain classification of this user's transactions. The pasted percentage/usage table was not independently reproduced.

| Field | Ordinary Zipher send | Comparison / qualification |
| --- | --- | --- |
| Fee | ZIP-317, 5,000 zat per logical action, standard minimum rules | Same fee family as Vizor/SDK wallets; not a flat 5,000-zat transaction fee |
| Expiry | SDK target height + 40 blocks | Same usual delta; Vizor also refreshes its live target before construction. Delta is not necessarily 40 relative to the eventual mined block |
| Locktime | 0 | Standard shielded builder default |
| Orchard / Ironwood padding | Default minimum of 2 actions for each non-empty bundle | A minimum, not exactly 2 actions in every transaction. Extra inputs/outputs or pools can increase the visible action count |
| ZIP-318 migrations | Canonical rolling expiry and specialized bundle shape | Do not compare these to ordinary sends |

Zipher's pinned Zakura primitives implement `BundlePadding::DEFAULT` and the 40-block expiry. The adapted wallet backend uses these for ordinary software and PCZT sends. The migration SDK uses default Orchard padding and a single unpadded Ironwood output for canonical crossing transactions; preparation transactions vary with the denomination plan. This is not equivalent to claiming that every migration has the table's 11–16 actions.

The ordinary defaults place Zipher in the common SDK fingerprint family, but they cannot guarantee indistinguishability. Amounts crossing pools, action counts, timing, fee selection, address type and server observations also matter. Tor changes network visibility, not the serialized transaction's fee or padding. No arbitrary padding or fee randomization was added.

## Account isolation and switching

Vizor carries an explicit account UUID through its providers and reads. Zipher currently opens separate wallet databases when switching profiles. A race allowed an old `ActiveAccount2` to request the newly opened engine's balance before the UI selection changed. Other asynchronous transaction reads could also repopulate the shared memo cache after close.

The switch now pauses refreshes before changing the engine; balance/address/transaction/memo reads reject changed wallet identities and generations. The new account publishes before loading its data, with the switch sheet blocking actions during the transition. No pool allocation is invented from a cached total. Failed opens do not leave a closed wallet's balances actionable.

Picker snapshots have a network and timestamp, are labeled last known, and unknown/legacy snapshots show a dash. They store total funds consistently with Home, rather than substituting only spendable funds. A derived account no longer inherits the profile's entire balance. Legacy derived-account APIs are stubs in this engine; unsupported derivation is hidden and unsupported selections are blocked rather than showing account 0's money as another account. Separate wallet profiles remain supported.

## Chat and activity

- `clear chat` discards the conversation and draft, returning to the greeting and shortcuts. It does not delete wallet history or undo submitted payments. Help also exposes this action.
- `memos`, `latest memos`, `show my messages` and related local phrases show the latest memo-bearing transactions. Memo previews are plain text and open the corresponding transaction.
- Activity rows share one component across the header, history replies and memos: direction/type, amount, date/time, confirmation state and memo availability.
- Help has tappable actions and short examples. Loading messages name the current operation rather than simulating AI typing.
- Payment review and one-submit guards remain in place. Clearing or switching invalidates drafts.

## Verification

81 Flutter tests passed; static analysis clean. 54 engine tests passed, with manual network/staging checks excluded. A separate live Tor smoke test succeeded in 29.6 seconds, fetching mainnet height 3,477,913 without wallet keys or transactions. Regression coverage includes a delayed native balance response across wallet close, foreign wallet identity rejection, network-specific snapshots, Tor verification/failure behavior, clear chat, memo previews, narrow layouts, and stable transaction selection after list sorting.

The arm64 iOS simulator build succeeded and was installed without resetting either wallet. The final frontend was hot-reloaded. An iPhone-sized memo/activity screenshot was rendered and visually inspected.

Live simulator validation subsequently completed with the user's authorization:

- Switching between the two separate wallets showed distinct balances and transaction histories. One wallet was funded and the receiving wallet initially had zero.
- A 0.0001 ZEC internal send, with a reviewed 0.0001 ZEC standard fee and a test memo, was signed and broadcast through chat. The receiving wallet showed the exact amount confirmed, and opening its transaction displayed the correct memo and matching transaction ID.
- The source's final total decreased by exactly the payment plus the reviewed fee. Its pool sheet distinguished spendable funds from change still awaiting the wallet's confirmation threshold.
- Chat clearing restored the greeting and shortcuts. The memo command displayed the newly received memo. Root pool details showed the actual Ironwood allocation.
- `enable Tor` completed in the simulator, changing the Home indicator from connecting to verified `Tor · Zcash`; the scope explanation and turn-off control appeared in chat. The original direct-connection preference was restored after testing.
- A 32-block catch-up pass took about one second, with 111 ms download and 28 ms scan time. This is a near-tip observation, not a full-history performance benchmark.
- Live inspection found and fixed long replies opening at their oldest entries, and fee-only transactions displaying a negative zero send. Long replies now reveal their beginning; fee-only rows show the cost without inferring an unsupported transaction type. All 23 affected chat/activity tests passed, including two new regressions; targeted static analysis was clean. The newest memo was then visually verified in the simulator.

No NEAR swap or full-history Vizor comparison was performed in this validation.

### Subsequent fee-control update

Priority-fee selection is now functional in chat. The previous native priority
flag still used the standard fee. It now uses the SDK's custom ZIP-317 marginal
fee through input selection, change calculation and transaction construction.
Standard remains the default (5,000 zat/action); optional priority uses 20,000
zat/action and therefore does not share the standard-fee fingerprint. This does
not change the default expiry or bundle-padding settings described above.
The simulator verified standard → priority → standard exact review totals without
broadcasting another transaction.

### Build 739 release checks

All 102 Flutter tests passed before release packaging; full Flutter analysis was clean. The release includes account/contact chat commands, scanner cancellation and payment-request parsing, mandatory device authentication after payment review, and the compact asset list.
