# Shared wallet stack upgrade — 2026-09-09

The Flutter app calls `zipher-engine` through Flutter Rust Bridge. The CLI and MCP
server link the same engine directly. The app does not execute the CLI. Each client
must be rebuilt to receive an engine update; Dart chat routing and UI polling are
still app responsibilities.

## Dependency change

| Component | Before | Now resolved in Cargo.lock |
| --- | --- | --- |
| Wallet backend | 0.24.0-rc.6, git f370a1f2 | 0.24.0 stable, locally adapted |
| Wallet SQLite | 0.22.0-rc.6, same git pin | 0.22.0 stable, locally adapted |
| Pool migration | 0.1.0-rc.5 | 0.1.0 stable, locally adapted |
| PCZT | Older git-patched family | 0.9.3, locally adapted |
| Protocol | 0.10.3; older second parser family | 0.10.6, shared clients |
| Crypto | Upstream Orchard/Sapling family | Zakura Common 1.2.0 |
| CLI / MCP / npm package | Installed CLI reported 0.1.0 | Installed native clients 0.3.0 |

Versions were checked against published crate archives on September 9. Sources:
[wallet backend](https://crates.io/crates/zcash_client_backend/versions),
[SQLite](https://crates.io/crates/zcash_client_sqlite/versions),
[pool migration](https://crates.io/crates/zcash_pool_migration/versions),
[Common Orchard](https://crates.io/crates/zakura-orchard/versions).

[Zakura Common](https://zakura.com/announcements/zakura-common/) includes
wallet-relevant cryptography. The published
[Zakura wallet fork](https://github.com/zakura-core/wallet-libraries/blob/main/README.md)
omits pool migration and pins Common 1.0.0. It cannot directly replace Zipher's
wallet SQLite crate while retaining Ironwood.

The integration therefore preserves four stable upstream wallet crates and adapts
their dependency boundaries to Common 1.2.0. This is a **local compatibility layer**,
not a released or audited Zakura wallet distribution. Source archives, checksums,
licenses and reproducible patch files are in [rust/vendor](../rust/vendor/README.md).
The patches rename dependencies, bridge RNG trait versions and preserve upstream
transaction-size safety constants. They do not rewrite circuits, key derivation,
transaction encoding, database migrations or the SDK migration policy.

`zipher-rng-compat` forwards all bytes to the original generator and only preserves
the cryptographic RNG marker when the original generator has it. Central workspace
dependencies and `scripts/verify-wallet-stack.py` reject a mixed upstream/Common
crypto graph or unexpected wallet versions. CI, release and mobile Cargokit builds use `--locked`.

## Engine adaptations and fixes

Ironwood uses the stable SDK's `advance_migration` driver and SQLite store. The
integration serializes mutations, uses fully scanned heights, retains cancellation
history, releases reservations through the SDK, and stores a transaction before
broadcast for recovery after an ambiguous response. It uses canonical preparation
and transfer fee shapes and reports crossing values rather than funding-note
values. A replan requires review instead of automatically signing a replacement.
The current UI and watch service continue calling this shared engine.

PCZT proving selects the Orchard circuit from the transaction's consensus branch,
uses Common's cached proving keys, includes Ironwood proofs, and only loads Sapling
parameters when needed. Signature extraction allows the SDK to choose the branch's
Orchard verification key. Max-send input selection includes Ironwood.

A FROST round trip exposed a real scalar/point mismatch. Signing now receives the
randomizer scalar required by the FROST API. Encrypted peer signing packages use
`frost_signing_packages_v2`; both peers must update and restart an old signing
session. The scalar travels through the existing encrypted peer channel.

Broadcast fanout uses one captured Tor transport for the attempt. The Ironwood
submission path checks the wallet identity and avoids recursively locking the
engine while retaining the exact stored transaction for reconciliation.

## Sync and performance

The shared engine already provides bounded prefetch, adaptive scan batches,
alternate lightwalletd peers, stream idle timeouts and cancellation. Those paths
remain shared by app and CLI. App polling and database refreshes are coalesced,
and wallet generations reject late responses from an old wallet. See
[chat behavior](chat-home.md).

Common's proving-key cache and conditional Sapling loading remove repeated setup
work. No cold-restore, memory, battery or time-to-spend benchmark was run, so there
is no measured claim that sync is now optimal or faster than Vizor.

## CLI packaging

The npm package previously tracked stale executables under `bin/`, while its
installer downloaded `zipher-cli` to a different filename. Updating the package
could therefore continue running an old binary.

The public commands now use small Node launchers that execute the installed files
under `native/`. Installation requires both CLI and MCP artifacts, verifies their
SHA-256 checksums and bounds downloads. On Apple Silicon it selects the native
ARM artifact even when Node itself runs through Rosetta. CI creates the matching checksums. The
launcher's argument forwarding, failure status and missing-binary behavior are
regression tested. MCP help/version exit before opening a wallet or loading keys. Download verification detects corruption; it is not independent
release signing or reproducible-build attestation.

For a local source build on Apple Silicon, from `rust/`:

```sh
cargo build --locked --release --target aarch64-apple-darwin -p zipher-cli -p zipher-mcp-server
mkdir -p ../npm/native
cp target/aarch64-apple-darwin/release/zipher-cli target/aarch64-apple-darwin/release/zipher-mcp-server ../npm/native/
cd ..
npm install -g ./npm --ignore-scripts
zipher --version
```

On machines with multiple Node installations, check `command -v zipher` against
`npm prefix -g` first and pass the intended `--prefix` to installation. Here the
active commands use `/Users/imaginarium/.nvm/versions/node/v22.22.1`; the local
0.3.0 package was installed there explicitly, and both native artifact hashes
match the new ARM64 release build.

`--ignore-scripts` deliberately uses the locally built artifacts; it avoids trying
to download an unpublished 0.3.0 release. No public package or GitHub release has
been published by this work.

## Verification and remaining acceptance work

See [code audit](code-audit-2026-09-09.md) for final local check results.
The disposable database test checks encrypted create/reopen, idempotent SDK
initialization, deterministic seed restoration and Ironwood store availability.
It does not validate upgrading every historical wallet database.

Headless Ironwood plan/status use the new SDK. CLI/MCP confirm/pause/resume remain
explicitly unavailable: they previously wrote obsolete schedule JSON rather than
driving a durable runner. They must not be advertised as working execution controls.

Required before release certification: a historical RC wallet upgrade fixture;
controlled testnet sync/reorg, send/receive and restart recovery; migration
prove/broadcast/confirm through a funded test wallet; mixed-device FROST; and
mobile background/resume plus measured restore benchmarks. No real user wallet
or funds were used for these checks.
