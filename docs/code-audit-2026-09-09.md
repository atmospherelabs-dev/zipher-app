# Code audit and cleanup — 2026-09-09

This work combines repository-wide dependency, reachability and placeholder scans
with manual review of chat payments, sync lifecycle, signing, Ironwood integration,
local storage and CLI packaging. It is not a formal cryptographic audit or proof
that every application feature is production-ready.

## Concrete findings fixed

| Finding | Result |
| --- | --- |
| npm launched tracked old binaries instead of the download | Small launchers execute `native/`; checksum verification and launcher regression tests |
| Wallet SDK pinned to older release candidates | Stable wallet layer on one Zakura Common 1.2.0 family, preserving Ironwood storage |
| FROST received a randomizer point where a scalar was required | Correct scalar through encrypted v2 signing packages; signing round-trip regression |
| PCZT proof/extraction used an old Orchard key unconditionally | Consensus-branch circuit selection, cached keys, Ironwood proving, conditional Sapling loading |
| Legacy submit routes returned `stub_tx_id` and showed success | Unsupported legacy routes display unavailable; normal submission requires `confirmSend()` result |
| Migration status used funding values and zero fees | Crossing values and canonical fees for mined preparation/transfer transactions |
| Old migration handlers edited obsolete schedule JSON | SDK plan/status; unsupported headless controls report unavailable |
| Migration submission could relock the same engine mutex | Captured Tor transport; checked wallet identity; SDK transaction storage before submission |
| Contacts never loaded or persisted, shared ID zero, edits appended | Secure-storage address book, serialized writes, distinct IDs, replacement edits, visible errors |
| Recovery offered ignored dates/heights and hid failures | Saved-birthday recovery only; explicit confirmation, one running attempt, visible retryable failure |
| Wallet changes could accept stale sync/balance replies | Generation checks and coalesced refreshes; SDK remains spendable-balance authority |
| Registry snapshots omitted Ironwood and could finish after a wallet switch | Include Ironwood and check captured wallet/network before saving |
| Chat proposals and direct payments could overlap or reuse reviews | Payment reservation before key access, one-use reviews, wallet/network/proposal revision checks |
| Fiat totals could use guessed prices or conceal chain failures | Timestamped prices and explicit partial totals; bounded cached EVM requests |
| Engine initialization wrote logs into CLI stdout | Structured tracing instead of raw stdout |
| Release/test CI masked errors or resolved unlocked dependencies | Error-masking removed; locked builds and wallet graph guard |

## Simplification

Removed 28 unused or unfinished source files, including the old ActionPage routing
and executor tree, local LLM code, unused funding/market confirmation widgets,
legacy Rust API/database files, disabled governance implementation and unfinished
wallet utility pages. The existing Z chat appearance is preserved in reusable
widgets. Active CLI market/EVM features remain because they have real consumers.

Removed 17 unused Flutter packages, unused direct bridge-crate dependencies, the
unused Candle/tokenizer family and disabled optional voting dependencies. The
native Flutter plugin remains: it is required even without a direct Dart import.
Dart and Rust Flutter Rust Bridge versions are pinned together at 2.11.1.

Old links to removed operations display a short unavailable message. The app no
longer offers no-op governance results, fake transaction plans, contact backup to
chain, ineffective key tools or an incomplete animated-QR submission flow.
Backward-compatible voting and legacy wallet FFI methods still return explicit
unsupported errors. The always-enabled SQLite engine remains the active path;
these ABI shims do not enable another backend.

The address book now persists contact names and addresses in platform secure
storage. Existing address-to-chain labels still use their separate SharedPreferences
store; this work does not claim those labels are encrypted. Contacts are an app-wide
address book, not a per-wallet on-chain identity or backup service.

## Reproducibility

The four local wallet SDK adaptations retain upstream source and licenses.
Recorded patches were applied to fresh copies of the original extracted archives;
every resulting file matched its vendored counterpart. See
[the compatibility notes](../rust/vendor/README.md) and
[stack/version audit](cli-engine-stack-audit.md).

Both FRB and Dart/MobX sources were regenerated. App analysis excludes only the
independently vendored Cargokit package, which has its own pubspec. App source and
tests remain included. Mobile Cargokit debug/profile/release builds also use
`--locked` through `rust/cargokit.yaml`.

## Local verification

- `flutter analyze --no-pub`: no issues.
- `flutter test --no-pub`: 58 passed.
- `cargo test --locked --workspace --exclude rust_lib_zipher`: 44 passed;
  CLI/MCP test targets and engine/RNG doctest targets also compiled.
- `cargo clippy --locked -p zipher-cli -p zipher-mcp-server -p zipher-engine`:
  passed with 40 style/maintainability warnings, no errors. This is not a
  warning-free Rust lint result.
- `cargo check --locked -p rust_lib_zipher -p zipher-cli -p zipher-mcp-server`:
  passed during integration; subsequent changes are covered by final tests/builds.
- `node --test npm/test/install.test.js`: 3 passed, including Rosetta detection.
- Wallet graph guard and exact reproduction of all four source patches: passed.
- `git diff --check`: passed.

- Apple Silicon release CLI and MCP build: passed (`--locked`, release/LTO).
- Final iOS simulator debug build: passed for the updated app and engine. The first
  run exhausted disk space during `lipo`; after clearing disposable compiler
  caches, the complete retry succeeded.
- Installed `zipher` and `zipher-mcp-server`: both report 0.3.0 and execute ARM64
  binaries byte-for-byte identical to the staged release copies. Help/version exit
  successfully without creating a wallet directory.

The installed package is under the existing NVM v22.22.1 prefix used by PATH.
npm itself defaults to a separate Homebrew prefix on this machine, so installation
used the explicit NVM prefix. The temporary extra Homebrew installation was removed.
A fresh temporary npm cache avoided an inaccessible entry in the existing cache.
The local package is `/tmp/zipher-local-package/cipherpay-zipher-cli-0.3.0.tgz`;
no release was published. Verified installed SHA-256 digests:

| Artifact | SHA-256 |
| --- | --- |
| CLI | `58d2edec61f237c764f410bf6800e58b9b9682564c641e539f116d47f9a930b1` |
| MCP | `7f3ec7ab68e8264bbd4c29ae36511c2adb48e7fa3f6423fc9523e1dd95abc108` |

No checks send real funds or open a user's wallet. Synthetic/mock tests establish
specific behavior; they are not evidence of mainnet settlement.

## Remaining limitations

- Historical RC wallet-database upgrades, live reorg handling, funded Ironwood
  migration, device FROST signing and restart/background recovery need controlled
  acceptance runs. New encrypted wallet create/reopen/restore is covered locally.
- CLI/MCP Ironwood execution and pause/resume are unavailable until a durable
  headless runner is integrated. The existing mobile runner is adapted to the SDK.
- Chat supports ZEC send and ZEC-out swap review. It does not implement direct
  foreign-chain payments, BTC/SOL balances, arbitrary token discovery, destination
  memos/tags or every CLI market feature. See [chat readiness](chat-home.md).
- This initial audit did not run performance benchmarks. A subsequent
  [sync optimization pass](zipher-sync-v3.md) adds engine changes and disposable
  benchmark measurements; “optimal sync” remains unproven.
- Local builds do not publish or deploy a release. The compatibility patches need
  review and the acceptance checks above before release certification.
