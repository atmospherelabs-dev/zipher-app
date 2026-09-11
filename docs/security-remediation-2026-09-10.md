# Security remediation — 2026-09-10

Addresses the findings in `security-review-2026-09-10.md` against commit `da0501e`. These changes are local source changes until a new application build is distributed. They do not patch the installed build 739 remotely.

| Finding | Resolution |
| --- | --- |
| S1: unverified FROST approvals | **Mitigated by disabling signature release.** Both Flutter approval paths and the public Rust round-two signing API reject requests. Remote approval polling is paused. The raw signing primitive is only available inside native unit tests. Shared-wallet balances and recovery material remain accessible; shared-wallet signing has not been restored. |
| S2: legacy signing authentication | Submission requires fresh device authorization and the wallet/network/revision captured when the exact proposal was reviewed. Missing review identity is rejected by WalletService. Direct navigation to the old submit route without typed review state cannot sign. Invoice payment also binds its wallet/network and rejects changes during authentication. |
| S3: MCP self-approval/unlock | Removed `wallet_unlock` and `approve_send` from the tool router. The server no longer retains a vault passphrase for later unlock. Locking clears its seed and pending review; a trusted operator must restart it to restore access. Threshold payments cannot be approved by the same agent. |
| S4: spending caps | Every MCP ZEC confirmation uses a durable reservation for amount plus fee before signing. SQLite immediate transactions enforce the rolling budget atomically. Ambiguous failures retain their budget. Successful reservations and audit rows are deduplicated by transaction ID. Legacy approved sends and both x402 action names count. Unknown historical successful-send amounts and unreadable/corrupt policy files fail closed. |
| S5: migration authentication | Initial commitment requires device authorization bound to wallet/network/revision. Rust retains the actual SDK plan shown for review, checks its wallet database and ten-minute expiry, consumes it once, and signs that plan rather than generating a replacement. WalletService reserves the payment path across key access and commit. |
| S6: shared-wallet deletion | Explicit deletion removes mainnet/testnet shares, relay keys, metadata and in-memory approval/setup state. A persisted deletion retry queue allows interrupted key removal to finish on startup. Deletion holds the wallet-operation lock. **Missing or corrupt account lists never authorize key destruction.** Retained keys from older deletions without a deletion record are preserved rather than guessed to be disposable. |
| S7: backup exposure | Reveals reset when interrupted. Reveal, verification, copy and QR entry use fresh authorization bound to the original wallet/network and lifecycle. Copy retains timed clipboard clearing. A dedicated recovery QR screen has no copy/image-export actions, hides on interruption and stays hidden on resume until reauthorized. |
| S8: database key replacement | Read failures and an existing empty key stop initialization without writing a replacement. Concurrent callers share one key-creation operation. |
| S9: HTTP/2 dependency | Updated `h2` from 0.4.15 to 0.4.16. The post-change RustSec scan no longer reports RUSTSEC-2026-0258. |

## Additional corrections found while checking the fixes

- MCP confirmations now require the exact unpredictable `proposal_id` returned by `propose_send`. A replaced proposal cannot be signed using a previous confirmation, even when both requests omit a context ID.
- All MCP tools that replace or consume ZEC proposals share an operation lock. `wallet_lock` waits for an in-flight payment to finish before reporting success; it does not claim to cancel an already-started broadcast.
- Removed agent-accessible Polymarket order signing, which lacked an asset-specific spending policy and could release a signature after wallet lock. Read-only market functions remain. Agent shielding returns an explicit unsupported response until its fee spending has an exact reviewed policy path; authenticated wallet shielding remains available.
- Startup cleanup was deliberately revised during review: inferring deleted wallets from a missing registry could erase valid retained iOS Keychain shares. Cleanup now acts only on recorded deletion instructions.

## NEAR swap behavior

The chat recognizes the provider's bounded numeric bridge-minimum response and asks for a new ZEC amount, keeping the selected chain and recipient. It no longer presents that minimum rejection as a connection error. A new amount still requires a fresh provider quote and normal payment review; the app never automatically sends the provider's suggested minimum.

Native ZEC is selected using its canonical asset ID, chain and decimals rather than token symbol ordering. Returned quote requests must match the requested assets, amount, recipient, refund address, routing types, slippage and configured fees. The [documented 50/50 revenue split](https://docs.near-intents.org/integration/distribution-channels/1click-api/fee-config) is accepted only with the observed protocol account and unchanged total; arbitrary additional fee recipients are rejected. The actual quote must supply its own valid deadline; a requested deadline cannot stand in for a missing provider deadline.

## Verification

- Complete Flutter suite: **114 passed**, including legacy-screen authorization, interrupted deletion retry, quote tampering and recovery QR lifecycle regressions.
- Final Flutter static analysis: no issues found.
- Native engine suite: 59 passed, 3 ignored. Includes disabled production FROST signing, fee-inclusive accounting, unknown historical amount rejection and concurrent reservation tests.
- Rust wallet bridge and MCP compile check passed.
- MCP tests: 2 passed, including rejection of replaced proposal IDs and absence of unsafe operator/order-signing tools.
- iOS debug simulator build passed for both native architectures; the final incremental build also passed with all source fixes included (`build/ios/iphonesimulator/Runner.app`). This is not a signed device release or an App Store upload.
- Live unfunded NEAR quote: asset/amount/recipient/refund/routing fields matched; provider fee splitting was verified and covered by regression tests (9 quote tests passed).
- No actual payment, funded swap, wallet-secret extraction or installed-wallet mutation was used for verification.

## Remaining boundaries

This remediation closes or blocks the reported attack paths; it is not a proof that the entire wallet is unexploitable. FROST signing requires a future implementation that independently derives and verifies PCZT outputs, fee, change, network and signing digest on each co-signer before it can be reenabled. Do not remove the native guard merely after adding a passcode prompt or comparing coordinator-provided hashes.

The dependency scan still reports the previously documented `rsa 0.9.10` / RUSTSEC-2023-0071 advisory through Arti/Tor, with no patched version listed. This review did not establish an exposed private-RSA operation in Zipher or a Zcash spending-key extraction path. The advisory is not suppressed. Maintenance/yanked-package warnings also remain recorded in the initial audit.

Historical MCP sends whose amounts were never logged cannot be reconstructed reliably from the audit table alone. Such recent unknown entries block policy-controlled spending until reconciled or outside the rolling window. Uncertain broadcast reservations are intentionally conservative and are not automatically refunded to the daily budget on an exception.
