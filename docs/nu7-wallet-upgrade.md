# NU7 wallet compatibility and transaction review

Implementation date: October 30, 2026. Reference wallet: Vizor v0.0.63,
`15c0c58d032a4dc345641e98a9d9312fe572b46f`. This is local application work,
not a mobile-store release or a deployment receipt.

## Dependency decision

Use released Zakura Common 4.0.0 and `zakura-pczt 0.1.0-rc9`, preserving
Zipher's adapted stable backend 0.24.0 and SQLite 0.22.0. Upgrade the migration
engine to stable `zcash_pool_migration 0.2.0` and adapt its API boundaries.

Vizor's SQLite fork drops the ZIP 318 migration store. Replacing Zipher's store
with that fork would discard state that Zipher uses. Upstream backend 0.25 and
SQLite 0.23 also use newer address/key/tree types that released Common 4 does
not provide. Necessary NU7 timing and retention changes are backported rather
than partially implementing those newer address rules.

See `rust/vendor/README.md`, `rust/vendor/sources.json` and the reproducible
patches for the exact cohort, archive checksums, published dependencies and
upstream backport sources. FROST now uses Common 4's separated
`zakura-reddsa-frost` crate. The root-store update includes `webpki-roots 1.0.11`.

The stack verifier inspects the resolved protocol source for mainnet activation
**3,543,405**, testnet activation **4,465,026** and branch **0x77190AD9**. It also
checks the crypto family, PCZT source, fee relay and retained migration schema.

## Transaction validity and timing

The shared Rust engine owns the policy for mobile, CLI and MCP:

- A normal transaction cannot have an expiry beyond the target branch's last
  height. Ordinary sends pause when that leaves fewer than three blocks of
  expiry margin. Common 4's normal default expiry changes from 40 to 120 blocks
  at NU7, preserving its approximate elapsed-time window.
- Confirmation refreshes the actual endpoint's network and tip, checks the
  reviewed branch and expiry, then checks the signed transaction again before
  submission. All v4 forms are rejected after NU7, including transparent-only
  and Sapling v4 transactions. Historical parsing is retained.
- Every fan-out peer checks its own fresh tip against the wallet's persisted
  chain height. Process-global progress from a different wallet/network is not
  used as chain authority. Missing network identity or fresh height refuses a
  submission.
- A wallet generation identifies each open session and routing change. The
  final submission checks it after asynchronous endpoint reads and pins the
  engine identity during the bounded actual send request. Closing/reopening a
  wallet cannot convert a captured Tor route into a direct connection.
- Per-peer broadcast work is bounded to 20 seconds. A timeout can be an
  ambiguous submission; it does not authorize a replacement payment or release
  the spending-policy reservation.

ZIP 318 migration delays use the released height-aware scheduling APIs. Security
reorg depth remains ten blocks; this task does not equate block count with a
fixed elapsed-time security guarantee. The mobile watcher checks every 25 seconds
and serializes signing/cancellation through the wallet payment gate.

## Fee policy

The additive lightwallet protocol backport supplies `GetStandardFee(Empty)`
with `fee_zat` and `estimator_version`. The returned fee is **zatoshis per logical
action**, not the complete transaction fee.

A fee snapshot binds the recommendation to wallet generation, database, network,
server, privacy setting and target branch. It remains fixed through selection,
change, send-max, proposal review and signing. Review expires after 120 seconds;
long proof work does not retroactively alter a signed transaction's fee. A new
proposal gets a new recommendation. No cross-wallet/server cache is introduced.

Priority uses **10 times the standard marginal fee**. Existing Flutter and CLI
controls retain their review flow; MCP adds an optional `priority` boolean and
returns the choice with the exact proposal totals. Standard remains the default.
MCP checks a pending review before reserving the daily spending budget and
revalidates independently during confirmation.

CLI proposal files also bind priority, exact amount/fee, consensus branch,
network, endpoint, intent and review time. Confirmation re-proposes with the
same priority and refuses any changed total or branch before reading a signing
credential. Legacy unbound records require a fresh review. A private atomic file
claim makes the review single-use before signing, and policy accounting includes
fees and unresolved submission reservations.

Only an explicit gRPC `Unimplemented` response permits the conservative legacy
fallback of **5,000 zat per logical action**. Priority fallback is 50,000 zat per
action. Transient failures, timeouts, zero, malformed or excessive recommendations
refuse a proposal. Standard recommendations above 100,000 zat per action are
rejected; multiplication and monetary-range checks use integers.

This fallback matters because the three configured public endpoints probed on
October 30 returned `Unimplemented`, although lightwalletd v0.6.1 already ships
the relay. Vizor's released fee-switch height also differs from published ZIP
2009. This implementation uses the serving node's recommendation when available
and does not guess a lower fee from an unresolved calendar/height assumption.

Migration builders retain their published ZIP 318/ZIP 317 fee and shape policy.
Ordinary-send fee discovery does not silently replace migration constants.
Multi-step/TEX send proposals are explicitly refused before signing: the current
application does not implement the complete multi-step broadcast lifecycle.

## Restore boundaries

Date-only or unspecified restore birthdays now request full supported history;
they no longer estimate a height using a fixed 75-second interval. Only restore
maps zero to the selected network's authoritative Sapling activation minus one;
new-wallet creation still maps zero to the current tip. Explicit positive prior
tree-state anchors are unchanged. This trades scan time for recovery correctness
until an authoritative date/height map is available. The restore screen explains
the full scan and offers an explicit earlier block height for faster recovery.
See [restore-birthdays.md](restore-birthdays.md).

## Interrupted migration recovery

Old-branch migrations pause before activation. After activation the UI reports
verification in progress until the wallet's **contiguous fully scanned height**
includes the first new-branch block. RPC absence, mempool rejection or a stale tip
cannot release funds.

A narrow typed SQLite adapter then uses one immediate transaction to validate
the account, migration, PCZT-derived transaction identities, raw transactions,
mined records and exact lock ownership. It preserves confirmed parts, caps only
obsolete unmined wallet expiry metadata at the ended branch, retains raw bytes
and hard spend links, releases the affected advisory locks, marks the run
superseded and records a durable upgrade-stop receipt. Signed bytes are never
rewritten. Normal scanner reconciliation can still discover earlier inclusion
after a reorg.

The UI distinguishes `paused_by_upgrade`, `upgrade_review_required` and
`stopped_by_upgrade`. The watcher keeps maintenance checks running through the
verification state. Only the durable stopped state offers a fresh remainder plan;
that plan requires a new review and signing authorization. Cancellation failure
does not clear the screen as though cancellation succeeded.

## Verification and release gates

Local October 30 verification: **144 Rust tests passed**, five explicit live
network tests ignored; the complete Flutter Rust Bridge/CLI/MCP check passed;
**52 selected Flutter tests passed** with no capture-mode requirement; scoped
Dart analysis was clean. The resolved graph/protocol guard and all three vendor
patch reproductions passed. The migration recovery screen was inspected at
360-point phone width. These are local source/test results, not device or
distributed-artifact acceptance.

Run from `rust/`:

```sh
cargo metadata --locked --format-version 1 > target/wallet-stack.json
python3 ../scripts/verify-wallet-stack.py target/wallet-stack.json
cargo check --locked -p rust_lib_zipher -p zipher-cli -p zipher-mcp-server
cargo test --locked -p zipher-engine -p zipher-rng-compat -p zipher-mcp-server -p zipher-cli --lib --tests -- --test-threads=1
```

The native tests include actual loopback gRPC requests and disposable migrated
wallet schemas. Scan coverage and inclusion are modeled in the database tests;
they are not full-node fork or funded settlement proofs.

Before a distributed release: qualify an actual supported lightwalletd/backend
pair and its fee response, build the exact native library into each mobile target,
exercise funded testnet sends and interrupted migrations, restore historical
wallets, and check device suspend/resume and reorg/reconfirmation. This task does
not operate existing user wallets, send real funds, publish app binaries or claim
production activation acceptance.

## References

- [Vizor NU7 lifecycle](https://github.com/chainapsis/vizor-wallet/pull/1039)
- [Vizor migration interruption](https://github.com/chainapsis/vizor-wallet/pull/1099)
- [Vizor privacy time windows](https://github.com/chainapsis/vizor-wallet/pull/1126)
- [NU7 deployment](https://zips.z.cash/zip-0259)
- [Fee relay release](https://github.com/zcash/lightwalletd/releases/tag/v0.6.1)
- [Published fee policy](https://zips.z.cash/zip-2009)
