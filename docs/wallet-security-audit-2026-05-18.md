# Zipher Wallet Security Audit

Date: 2026-05-18

Scope: current `zipher-app` working tree, including Flutter mobile wallet, Rust engine/FRB, CLI, MCP server, Action Wallet, Polymarket/EVM paths, x402/session tooling, local storage, and sync/privacy behavior.

This is a fix-oriented engineering audit, not a formal cryptographic audit. Severity is based on realistic exploitability, user-fund impact, seed/key exposure, and privacy harm.

## Executive Summary

Zipher has several strong foundations: seed storage uses platform secure storage on mobile, the Rust Zcash send path spends shielded funds by default, Zcash send proposals require sync freshness, seed bytes are zeroized after Zcash USK derivation, wallet DB encryption is wired through SQLCipher, and the agent wallet has spending policies plus lock/unlock.

The highest-risk issues are outside the core Zcash transaction builder:

- Action Wallet execution paths can sign and broadcast swaps, Polymarket trades, shielding, and sweep operations without honoring the app's `protectSend` authentication setting.
- Seed/export UX allows copying seed phrases and viewing keys to the system clipboard and QR screens after only one navigation-time auth.
- Mainnet/testnet seed separation is inconsistent: new/restored mobile wallets currently store the same seed under both network keys.
- Several EVM signing paths pass seed phrases as ordinary strings and expose broad "sign arbitrary tx/order" FRB functions without a central policy/auth gate.
- CLI/MCP/agent features rely on empty default passphrases, plaintext audit/session artifacts, and a pay-per-call demo mode that accepts any payment credential if `CIPHERPAY_API_KEY` is missing.

Recommended first sprint: lock down all signing behind one policy/auth gate, remove cross-network seed copying, replace clipboard/key export UX, and disable insecure agent/server defaults.

## Findings

### High 1: Action Wallet Bypasses Send Authentication

Evidence:

- `lib/pages/settings.dart` exposes `protectSend` as "Biometric or device PIN before sending or swapping funds".
- Normal send surfaces use a send confirmation flow, but Action Wallet confirmations directly execute signing flows. Examples:
  - `lib/pages/action/widgets/polymarket_bet_confirmation.dart` calls `ActionExecutor.instance.executeBetPolymarket(...)` from `Confirm Bet`.
  - `lib/pages/action/widgets/polymarket_sell_confirmation.dart` calls `executeSellPolymarket(...)`.
  - `lib/pages/action/widgets/evm_swap_confirmation.dart` calls `engineEvmSwapExecute(...)` after reading the seed.
  - `lib/pages/action/widgets/sweep_confirmation.dart` calls `executeSweepBnbToZec(...)` / `executeSweepTokenToZec(...)`.
  - `lib/pages/action/action.dart` calls `WalletService.instance.shieldFunds()` for shielding.

Impact:

If a device is unlocked, if Action Wallet parsing is wrong, or if a user taps through a conversational card, funds can move cross-chain or trades can be placed without the configured biometric/PIN barrier. This is especially risky because some flows do multiple irreversible operations: ZEC bridge, ERC-20 approval, swap, wrap, order placement.

Fix:

Add a single `WalletService.requireSigningAuthorization(context, actionSummary)` gate and require it before every path that reads seed material or calls a signing FRB function. Enforce the same gate for normal sends, shield, swap, Polymarket buy/sell, sweep, approvals, and future CipherPay payments. Make `protectSend` default-on for new wallets.

### High 2: Seed and Viewing-Key Export UX Leaks Through Clipboard/QR

Evidence:

- `lib/pages/more/more.dart` gates `/more/backup` behind `_navSecured`, but once inside, seed reveal/copy/QR actions have no second auth.
- `lib/pages/more/backup.dart` copies seed phrases to clipboard via `Clipboard.setData(...)`.
- The same page copies viewing keys and exposes QR rendering through `_showQR(...)`.
- UFVK is marked "Read-only access — safe to share for auditing" and `alwaysVisible: true`.

Impact:

Clipboard contents are available to other apps and keyboard/clipboard managers on many platforms. QR rendering is easy to capture. UFVKs are not spend keys, but they reveal wallet transaction history and future inbound activity, so describing them as "safe to share" understates privacy harm.

Fix:

Treat seed, UFVK, UIVK, spending keys, and session tokens as sensitive exports. Require per-action biometric/PIN, show explicit consequences, avoid clipboard by default, clear clipboard after a short timeout when copy is used, and make UFVK hidden by default with copy/QR behind an explicit "auditor can see full history" warning.

### High 3: Mobile Encrypted Backup Format Is Not Authenticated

Evidence:

- `lib/services/encrypted_backup.dart` creates backups containing `seed` and `ufvk`.
- Encryption is AES-256-CBC with PKCS7 and PBKDF2-SHA256 at 100,000 iterations.
- There is no HMAC or AEAD tag.
- Backup files are written under `getTemporaryDirectory()`.

Impact:

CBC without authentication is malleable and cannot reliably distinguish tampering from corruption. If this code is wired into UI later, it can create seed-bearing backup files in a temporary directory with weaker lifecycle/file-protection guarantees.

Fix:

Replace with an authenticated format: XChaCha20-Poly1305 or AES-256-GCM, Argon2id or scrypt with versioned parameters, associated data for version/network/birthday, and atomic writes into a user-selected protected destination. Do not include UFVK unless explicitly requested.

### High 4: Mobile Mainnet/Testnet Seed Separation Is Broken for New/Restored Wallets

Evidence:

- `WalletService.createNewWallet()` stores the same seed under both `profile.id` and `${profile.id}_testnet`.
- `WalletService.restoreWallet()` does the same.
- `createNetworkWalletForProfile()` later claims it creates an independent seed for the current network if no seed exists.

Impact:

This contradicts the stated invariant that testnet seeds are independent from mainnet. A user who switches to testnet may unknowingly use the same mnemonic, increasing exposure through test workflows, screenshots, faucets, debugging, or lower-care testing behavior.

Fix:

Stop pre-populating the other network's seed key. On first switch, create or restore a separate network wallet after a clear prompt. Add a migration that detects identical mainnet/testnet seed keys, warns the user, and offers to rotate the testnet wallet.

### High 5: Wallet Deletion Leaves Testnet Seed Material Behind

Evidence:

- `WalletService.deleteWalletById()` deletes wallet directories for both networks but only calls `SecureKeyStore.deleteSeedForWallet(walletId)`.
- It does not delete `SecureKeyStore.deleteSeedForWallet('${walletId}_testnet')`.

Impact:

Deleting a wallet can leave seed material in platform secure storage. This violates user expectations and creates residual recovery/exfiltration risk, especially after the cross-network copy issue above.

Fix:

Delete both mainnet and testnet seed keys. Add a secure-storage cleanup migration for orphaned `${walletId}_testnet` entries when the wallet profile no longer exists.

### High 6: Broad FRB Signing Surface Uses Plain Seed Strings

Evidence:

- `rust/src/api/engine_api.rs` exposes `engine_sign_evm_tx`, `engine_sign_and_broadcast_evm_tx`, `engine_polymarket_sign_auth`, `engine_polymarket_sign_order`, `engine_evm_swap_execute`, `engine_confirm_send`, `engine_send_payment`, and `engine_shield_funds` with `seed_phrase: String`.
- `lib/services/action_executor.dart` and EVM widgets pull the seed from `SecureKeyStore` and pass it across FRB as a Dart string.
- `rust/crates/engine/src/ows.rs` derives EVM keys from `&str`; `rust/crates/engine/src/polymarket.rs` returns raw private key bytes as `Vec<u8>` and does not zeroize them.

Impact:

Any future Dart code path or compromised plugin with access to the app process can request arbitrary signing if it can reach these service functions. Seed/private-key material lives in garbage-collected strings/Vecs without deterministic wiping.

Fix:

Move signing policy into Rust: expose typed operations only (`signApprovedPolymarketOrder`, `executeBoundedSwap`, `confirmPendingZecSend`) and require an operation digest produced by the proposal step. Use `SecretString`/`SecretVec` at FFI boundaries where possible, zeroize EVM private key buffers, and avoid exposing generic EVM signing to Dart.

### High 7: EVM Approval Scope Is Too Broad

Evidence:

- `rust/crates/engine/src/evm_swap.rs` approves ParaSwap's token transfer proxy with `u128::MAX` when allowance is below needed.
- Polymarket sell flow uses ERC-1155 `setApprovalForAll` for CTF/neg-risk operator approval.
- Mobile buy flow approves pUSD for roughly the current trade, which is better, but same-chain swap and sell approvals are broader.

Impact:

Unlimited approvals and setApprovalForAll increase blast radius if ParaSwap/Polymarket operators, spender contracts, or user chain state are compromised. These approvals can persist beyond the wallet session and are not surfaced as durable risk in the UI.

Fix:

Prefer exact-amount approvals plus optional post-trade revoke. Where setApprovalForAll is unavoidable, show persistent approval state, add a "Revoke approvals" screen, and include spender contract, token contract, and chain in the confirmation.

### High 8: CLI/MCP Vault Defaults Allow Empty Passphrases

Evidence:

- `rust/crates/engine/src/vault.rs` explicitly supports empty passphrases.
- CLI `vault_passphrase()` defaults to empty `ZIPHER_VAULT_PASS`.
- MCP `resolve_seed()` defaults `OWS_PASSPHRASE` and `ZIPHER_VAULT_PASS` to empty strings.
- `wallet init` and `wallet create` print seed phrases.

Impact:

Agent wallets are likely to run on developer laptops/VPSes. Empty passphrase vaults reduce protection to local file permissions and whatever OWS provides with an empty passphrase. Compromise of the machine or backups can expose the seed.

Fix:

Require an explicit passphrase or OS keychain-backed secret for wallet creation in CLI/MCP. Allow `--unsafe-empty-passphrase` only for demos and testnets. Make MCP start locked by default unless configured otherwise.

### High 9: Pay-Per-Call Server Accepts Fake Payments in Demo Mode

Evidence:

- `rust/crates/cli/src/serve.rs` binds to `0.0.0.0`.
- If `CIPHERPAY_API_KEY` is not set, `verify_payment()` accepts any `PAYMENT-SIGNATURE` header.
- CORS is permissive.

Impact:

If someone runs `zipher-cli serve` without a CipherPay key on a reachable host, the paid API is free to anyone who sends a syntactically valid header. This is a direct revenue/security bypass for the served tool.

Fix:

Fail closed by default. Require `--demo-accept-unverified` for demo mode, bind to `127.0.0.1` unless `--listen 0.0.0.0` is explicit, and restrict CORS.

### Medium 1: Session Bearer Tokens Are Stored in Plaintext

Evidence:

- `rust/crates/engine/src/session.rs` stores `bearer_token` in `sessions.json`.
- `session_list` returns sessions including the token.

Impact:

Anyone with filesystem access can spend/use remaining prepaid session credit. Session tokens are payment credentials and should be treated like API keys.

Fix:

Encrypt sessions with the same vault/OS keychain model. Redact bearer tokens from list/status output by default.

### Medium 2: Release/TestFlight Logs Capture Sensitive Metadata and Are Clipboard-Copyable

Evidence:

- `lib/services/app_log.dart` logs info+ in release and writes to console plus an in-app ring buffer.
- `lib/pages/more/debug_log.dart` exposes and copies logs to clipboard.
- Logs include server URLs, wallet IDs, deposit addresses, txids, Polymarket auth signature prefixes, API response bodies, ParaSwap quote URLs, and other behavioral metadata.

Impact:

Debug logs can reveal addresses, transaction timing, market/trading behavior, URLs accessed by agents, and provider error bodies. Clipboard export amplifies leakage.

Fix:

Add a redacting logger. Strip seeds, keys, bearer tokens, signatures, full addresses, txids, memos, URLs with query strings, and provider response bodies. Hide debug log behind developer mode plus auth, and warn before copying.

### Medium 3: Privacy-Sensitive App Data Uses SharedPreferences

Evidence:

- `lib/services/local_storage.dart` stores contacts, send templates, txid read status, swap history, addresses, amounts, and memos in `SharedPreferences`.
- `lib/services/action_history.dart` stores cross-chain action history in `SharedPreferences`.
- `lib/services/wallet_registry.dart` stores wallet names, balances, sync heights, and account names in `SharedPreferences`.

Impact:

These are not spending keys, but they reveal social graph, counterparties, amounts, trading behavior, wallet count, balances, and transaction history to backups or device compromise.

Fix:

Move privacy-sensitive metadata into encrypted storage or the SQLCipher DB. Keep only low-risk UI settings in `SharedPreferences`.

### Medium 4: Transparent Address Scanning Leaks Address-Level Queries to Lightwalletd

Evidence:

- `rust/crates/engine/src/sync.rs` handles `TransactionsInvolvingAddress` by calling `get_taddress_txids` with a specific transparent address and range.

Impact:

Transparent funds are public on-chain, but this query pattern tells the configured lightwalletd server which transparent address belongs to this wallet and when it is being checked.

Fix:

Keep shielded-by-default UX. Add a privacy warning when users receive or keep transparent funds. Prefer local filtering if feasible, or batch/proxy t-address checks through a privacy-preserving mode.

### Medium 5: Audit Logs Are Plaintext and Include Spend Metadata

Evidence:

- `rust/crates/engine/src/audit.rs` writes `audit.sqlite` with action, address, amount, context_id, txid, and error.

Impact:

The audit log is useful for agent accountability but contains a detailed local spending trail. On a shared machine or backup, it can expose wallet behavior.

Fix:

Encrypt `audit.sqlite`, redact errors, and add retention controls. Treat `context_id` as sensitive since agents may encode business/user intent there.

### Medium 6: Default Mobile Auth Settings Appear Off

Evidence:

- `AppSettings.defaults()` does not set `protectSend` or `protectOpen`.
- Protobuf bool defaults are false unless explicitly set.

Impact:

New users can have no biometric/PIN gate for app open or signing unless they opt in.

Fix:

Default `protectSend` on. Consider defaulting `protectOpen` on after first backup verification. At minimum, prompt during onboarding.

### Medium 7: Error Responses Can Expose Provider Bodies and Behavioral Data

Evidence:

- Polymarket CLOB auth/order failures include raw response bodies in logs/errors.
- ParaSwap failures include response body excerpts.
- MCP `err_response` serializes full errors to the LLM client.

Impact:

Provider bodies can include order details, addresses, route data, account identifiers, or tokens depending on upstream behavior.

Fix:

Map provider failures to redacted error types. Keep full bodies only behind a local, opt-in debug export with redaction.

### Medium 8: Seed Text Controllers Are Not Cleared Before Disposal

Evidence:

- `RestoreAccountPage` disposes seed word controllers but does not overwrite/clear their text first.
- Backup verification controllers similarly dispose without clearing.

Impact:

Flutter/Dart memory is not deterministic. This is a defense-in-depth gap for seed material entered on device.

Fix:

Clear all seed-related controllers and local strings before dispose/navigation where possible. Keep seed input lifetime minimal.

## Positive Controls Observed

- Mobile seed storage uses `FlutterSecureStorage` with Android encrypted shared preferences and iOS Keychain.
- Restore and backup screens enable `ScreenProtector.protectDataLeakageOn()`.
- Rust Zcash send proposal calls `ensure_synced()` before proposing spends.
- Rust Zcash send code zeroizes derived BIP39 seed bytes after USK derivation.
- The core send flow uses `ShieldedProtocol::Orchard` and does not directly spend transparent funds for normal sends.
- Pending broadcast transactions are recorded in the encrypted wallet DB when `db_cipher_key` is provided.
- MCP server calls process hardening to disable core dumps / block ptrace where supported.
- MCP wallet lock clears the in-memory seed option and signing tools check locked state.
- SQL queries inspected in audit/pending paths use parameterized statements.

## Fix Plan

### Sprint 0: Stop the Biggest Footguns

1. Gate all mobile signing paths behind biometric/PIN and a typed action summary.
2. Stop storing mainnet seeds under testnet keys; delete both keys on wallet deletion.
3. Disable/replace seed clipboard copy; make UFVK hidden and clearly privacy-sensitive.
4. Make `serve` fail closed unless an explicit demo flag is set.
5. Remove unlimited ParaSwap approvals or add revocation immediately after swaps.

### Sprint 1: Key-Material Handling

1. Replace seed-string FRB signing APIs with typed, policy-checked operations.
2. Zeroize EVM private keys and derived secret buffers.
3. Require non-empty vault passphrases or OS keychain-backed secrets in CLI/MCP.
4. Encrypt `sessions.json` and `audit.sqlite`, or move them into the encrypted wallet DB.

### Sprint 2: Privacy Hardening

1. Move contacts/templates/action history out of `SharedPreferences`.
2. Add redacting logger and reduce release logging.
3. Add transparent-address privacy warnings and lightwalletd privacy documentation in-app.
4. Add explicit export flows for UFVK/UIVK with consequences and retention guidance.

## Audit Questions Still Open

- Confirm whether `encrypted_backup.dart` is dead code or a planned UI path. If dead, remove it; if planned, replace format before shipping.
- Verify SQLCipher is enabled in all mobile builds. If a build lacks SQLCipher support, `PRAGMA key` may not encrypt as expected.
- Review OWS vault internals directly to verify encryption and passphrase behavior, especially empty passphrase handling.
- Threat-model third-party Flutter plugins and FRB surface exposure inside the app process.
- Decide whether agent audit logs should favor compliance detail or privacy minimization by default.
