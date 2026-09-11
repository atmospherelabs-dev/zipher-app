# Wallet security follow-up — 2026-09-11

The preceding remediation was committed as `6c0d7c9`. This second bounded pass fixes additional payment and data-handling problems. Neither commit changes installed build 739 until a new release is distributed.

| Severity | Location (file:line) | Finding |
| --- | --- | --- |
| High | `rust/crates/engine/src/evm_swap.rs:265` | Provider-controlled spender and transaction contents could be approved/signed without independent validation. **Mitigated:** both CLI and native execution now reject before network/signing operations. Dormant approvals use exact amounts. ParaSwap execution must remain disabled until chain, router, spender, calldata, recipient and amounts are independently verified. |
| High | `rust/crates/engine/src/swap.rs:243` | Native NEAR quotes lacked the mobile path's request binding. **Fixed:** require canonical native ZEC, matching request fields and fee recipients, positive exact input/output/minimum amounts, actual unexpired provider deadline and a usable deposit address without a required memo. Funding rechecks amount and deadline immediately before CLI/MCP confirmation. The documented, pinned NEAR fee split is accepted; arbitrary recipients are rejected. |
| High | `lib/pages/accounts/split.dart:1241` | A one-recipient split could sign without normal review/authentication. **Fixed:** hand off recipient, amount and memo to the existing authenticated send review. Multiple-recipient execution, already unsupported by the current engine, returns an explicit message instead of dropping outputs or bypassing review. |
| Medium | `lib/pages/main/home.dart:715` | Shielding could act on the account selected after authentication started. **Fixed:** capture wallet, network and wallet generation first; service rejects mismatches before key access, and duplicate authentication is blocked. |
| Medium | `rust/crates/engine/src/query.rs:227` | Incoming Unicode memo could panic in byte-based log truncation, and private plaintext was logged. **Fixed:** remove memo plaintext logging. An actual SQLite history test exercises a Unicode character crossing byte 40 and captures logs to verify plaintext is absent. |
| Medium | `rust/crates/engine/src/sync.rs:2016` | Unicode server errors could panic during log truncation. **Fixed:** truncate only at UTF-8 boundaries. ParaSwap error snippets are also character-safe. |
| Medium | `rust/crates/engine/src/mpp.rs:181` | Unterminated quoted merchant authentication headers could panic. **Fixed:** reject malformed quotes, dangling escapes, ambiguous duplicates and missing separators; correctly decode escaped quoted values. |
| Medium | `lib/services/wallet_registry.dart:151` | Malformed account metadata was treated as an empty registry and could be overwritten by account creation. **Fixed:** preserve unreadable data and stop the mutation; invalidate the registry cache on failed saves. |
| Low | `lib/pages/accounts/send.dart:105` | Default memo overwrote a supplied payment memo. **Fixed:** apply defaults before supplied payment data. |

## Verification

- Complete Flutter suite: **120 passed**.
- Flutter static analysis: **no issues found**.
- Native engine suite: **66 passed, 3 ignored** (manual tests).
- CLI, MCP server and Flutter Rust bridge compile checks passed offline.
- Independent focused security recheck found no remaining blocker in these changes.
- `git diff --check` passed.
- No real transfer, ERC20 approval, wallet-secret extraction or installed-wallet mutation was performed. This follow-up did not build or distribute a new iOS package; the prior simulator build validates the preceding commit only.

## Remaining limitations

FROST signing and ParaSwap execution are intentionally unavailable. Quote validation cannot establish that an external swap provider is honest or solvent. The existing RSA advisory through Arti/Tor remains documented in the preceding remediation. This is a bounded code review with regression tests, not a complete independent wallet audit or proof against every vulnerability.
