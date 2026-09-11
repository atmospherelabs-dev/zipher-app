# Wallet security review and NEAR quote diagnosis — 2026-09-10

Reviewed source: `da0501ee003360dda62f1ffca289edc74e5018cf`, branch `feat/ironwood`, version `1.16.0+739`.

**Assessment: do not give this revision a security sign-off.** This review found concrete authorization, shared-wallet approval, agent-policy and key-lifecycle defects. It does not establish that the user's wallet has been compromised. No funds were transferred, no real transaction was signed, and no user seed was accessed during this review. Application code was not changed or deployed.

## NEAR swap failure

The screenshot shows a quote request for **0.0001 ZEC → SOL**, failing before transaction review. On September 10 at approximately 08:02 UTC, the public 1Click service rejected a simulated request at that amount with:

> Amount is too low for bridge, try at least 132000

ZEC uses eight decimal places, so this is **0.00132 ZEC**. This minimum belongs to the tested route and current provider conditions; it must not be hardcoded as a permanent universal minimum.

| Dry exact-input request | Provider result |
| --- | --- |
| 10,000 zat / 0.0001 ZEC | Below minimum; try at least 132,000 zat |
| 100,000 zat / 0.001 ZEC | Same minimum rejection |
| 1,000,000 zat / 0.01 ZEC | Quote succeeds; amountOut 119,234,939 lamports; minAmountOut 118,042,589 lamports |

Requests used disposable generated address strings, `dry: true`, native asset IDs `nep141:zec.omft.near` and `nep141:sol.omft.near`, and the app's quote configuration. They did not create funded swaps or use the user's recipient/refund addresses. The [official SDK documentation](https://docs.near-intents.org/integration/distribution-channels/1click-api/sdk) describes dry quotes as simulations without a deposit address.

`lib/pages/action/wallet_chat.dart:267–276` replaces every error other than insufficient balance or sync errors with connection advice. This hides the provider's actionable minimum response. The live reproduction explains the screenshot's amount; the actual phone's debug response was not captured, so a separate failure on that device cannot be ruled out.

Recommended correction: classify typed provider errors, extract validated numeric minimums in native units, display a concise amount prompt and preserve retry state. Do not expose arbitrary raw provider responses, which may contain addresses or other request details.

Two additional integration hardening items:

- `lib/services/near_intents.dart:46–49` selects the first token whose symbol is ZEC. The live token list contains wrapped ZEC on other chains. Match native chain and canonical asset ID instead of relying on response ordering.
- `lib/services/near_intents.dart:247–254` checks amount, deposit address presence, minimum output and expiry, but not the echoed origin/destination asset IDs, recipient or refund address. Bind these to the reviewed request. This is provider-response validation hardening; no independent attacker path through it was demonstrated.

The [1Click design](https://docs.near-intents.org/integration/distribution-channels/1click-api/about-1click-api) also temporarily entrusts deposited assets to its swapping agent. Wallet-side review cannot remove that external trust dependency.

## Findings

Severities below reflect impact and prerequisites in this application, not proof that exploitation occurred. Mobile findings and optional CLI/MCP findings are separated explicitly.

### S1 — High: shared-wallet approval is not bound to the transaction signed

Locations: `lib/pages/frost/frost_approve.dart:92–99`, `lib/services/frost_service.dart:1270–1285`, `:1380–1397`, `:1475–1485`, `rust/crates/engine/src/frost.rs:591–608`.

The co-signer displays destination and amount supplied as coordinator JSON, then signs a later signing package and randomizer from the coordinator. It does not receive and independently inspect the transaction PCZT to derive the approved outputs, fee, change, network and signing digest.

A malicious or compromised coordinator in an existing shared wallet can present a benign payment while requesting a share for a different transaction. Relay encryption does not protect against that participant. FROST threshold cryptography itself is not shown broken; the defect is authorization of what is signed.

Recommendation: block remote FROST signing until co-signers locally derive and authorize transaction details from a validated PCZT and bind all subsequent packages to that digest. Merely comparing two coordinator-provided hashes is insufficient. Also bind pending state to wallet, network, session and expected sender: `receiveSigningRequest` currently reuses a global pending approval at `frost_service.dart:1352–1355` without checking these identities. Discard state on switch, rejection and expiry.

### S2 — High: legacy mobile sends and FROST approvals omit mandatory authentication

Locations: `lib/pages/accounts/send.dart:560–573`, `lib/pages/accounts/submit.dart:28–32`, `lib/pages/splash.dart:626–633`, `lib/pages/frost/frost_approve.dart:67–75`.

QuickSend's confirmation enters a page that immediately calls `confirmSend()` without authentication or expected proposal revision/wallet/network. The payment-URI route is reachable and authenticates only when the legacy `protectSend` setting is true. An already-open legacy send flow has no fresh authorization after its recap. FROST approval also releases signing shares without device authentication.

Prerequisite: access to the unlocked app; a legacy false setting or existing send screen avoids the optional entry barrier. This is not a bypass of the iPhone lock screen and is not a zero-click Internet attack.

Recommendation: route legacy payments through the guarded chat review or require fresh authentication plus immutable proposal identity at every submission boundary. Make missing identity/authorization fail closed rather than optional. FROST still needs S1's transaction validation even after authentication is added.

### S3 — High: MCP clients can unlock themselves and self-approve threshold payments

Locations: `rust/crates/mcp-server/src/main.rs:447–460`, `:488–524`, `:630–660`.

`wallet_unlock` decrypts from the configured seed source without an operator credential. `approve_send` accepts the approval ID returned to the same MCP client by `propose_send`. Descriptions saying “operator-only” do not enforce a separate authority.

Prerequisite: access to the configured MCP connection, including a compromised or prompt-injected agent. Such a client can restore wallet access and bypass the intended human-approval threshold. **This affects the optional agent wallet/MCP server, not ordinary mobile chat.**

Recommendation: remove these capabilities from the agent-facing interface or require an independently authenticated, transaction-bound operator approval channel that the agent cannot invoke itself.

### S4 — High: MCP daily spending accounting omits successful payments

Locations: `rust/crates/mcp-server/src/main.rs:608–612`, `:663–666`, `rust/crates/engine/src/audit.rs:124–131`.

Ordinary successful `confirm_send` records a null amount. `daily_spent` sums only positive amounts and excludes `approve_send` entirely. The proposal path additionally treats audit errors as zero spent (`main.rs:482`).

Reproduction: executing the exact production SQL in an isolated in-memory SQLite database containing one normal confirmed-send record with null amount and one approved-send record of 20,000,000 zat returns **0** spent. No wallet database was used. An unlocked MCP client can repeatedly spend beyond the intended cap, subject to other independent constraints.

Recommendation: persist exact amount, fee and immutable proposal identity for all spend paths; reserve budget atomically before signing; reconcile broadcast outcomes; fail closed on accounting errors. Enforce policy again at the authorized transaction boundary. Scope is optional CLI/MCP.

### S5 — Medium: Ironwood migration signs without device authorization

Locations: `lib/pages/more/ironwood.dart:159–166`, `lib/services/ironwood_watch_service.dart:79–84`.

The initial commit reads the seed and builds/signs the migration after a UI confirmation but without authentication. Someone with access to the unlocked app can start fund migration and incur fees.

Recommendation: authenticate against the reviewed wallet, network, migration plan and fee bound before committing. Background execution can continue under that specific authorization; it need not prompt on every scheduled tick.

### S6 — Medium: deleting a shared wallet retains its signing material

Locations: `lib/services/wallet_service.dart:478–499`, `lib/services/secure_key_store.dart:110–145`, `lib/services/frost_service.dart:1126–1146`.

Deletion removes wallet directories, registry entry and mnemonic entries, but not the FROST key package, relay private key or FROST metadata. Later access to retained keychain/app data can recover a supposedly deleted signing share. A single threshold share does not by itself imply the entire shared wallet can be spent.

Recommendation: remove both networks' FROST material, metadata, pending approvals and watcher state; include orphan cleanup and verify deletion failures are surfaced.

### S7 — Medium: backup reveal survives background/resume

Locations: `lib/pages/more/backup.dart:173–179`, `:669–676`, navigation authentication at `lib/pages/more/more.dart:190–194`.

The Backup page obscures content while inactive but automatically unhides it on resume and retains reveal state. No global resume authentication barrier was found; `protectOpen` applies at startup. Reveal/export callbacks do not require fresh authentication.

Prerequisite: Backup remains open after the owner authenticated, then another person obtains the already-unlocked device. This does not bypass the OS lock screen.

Recommendation: clear reveal state on backgrounding and require fresh authentication before exposing/exporting the seed again. Keep route-level authentication and clipboard clearing as additional controls.

### S8 — Medium: transient keychain read failure can overwrite a database key

Locations: `lib/services/secure_key_store.dart:153–165`, `lib/services/wallet_service.dart:115–116`, `:370–375`.

`getOrCreateDbKey` catches a read exception and falls through to creating and writing a new key to the same keychain entry. If the read fails transiently but the subsequent write succeeds, existing encrypted databases lose their stored decryption key. The key is shared per coin, increasing the affected scope.

This is a conditional availability/data-loss defect, not demonstrated theft. Separately stored mnemonics can restore on-chain funds, but database-only state and scan progress may be lost. No keychain failure was induced on a real device.

Recommendation: fail closed on read errors, create only after a successful “not found” result, and serialize initialization to prevent concurrent creation races.

### S9 — Low: vulnerable HTTP/2 dependency remains pinned

Location: `rust/Cargo.lock:2421` (`h2 0.4.15`).

`cargo audit` reports [RUSTSEC-2026-0258](https://rustsec.org/advisories/RUSTSEC-2026-0258.html): unbounded empty DATA frames can exhaust memory or panic when streams are not drained. The advisory rates this low and fixes it in **0.4.16**. The package is in the iOS target dependency graph through tonic/hyper/reqwest. A malicious peer exercising the affected HTTP/2 behavior is required; no app-level exploit was run.

Recommendation: update the lockfile to a patched compatible version and verify native builds and networking.

## Other dependency results

The same lockfile scan reports `rsa 0.9.10`, [RUSTSEC-2023-0071](https://rustsec.org/advisories/RUSTSEC-2023-0071.html), a private-key timing advisory with no patched version listed. It enters the iOS graph through Arti/Tor and SSH key dependencies. The inspected Tor RSA module describes public signature verification as its client use, with private RSA operations for other roles. **An exposed private-RSA operation in Zipher was not established, and this is not evidence that Zcash spending keys can be extracted.** Review enabled features and eliminate unnecessary private-RSA capabilities rather than claiming the audit alert alone proves wallet-key theft.

Additional lockfile warnings: unmaintained `atomic-polyfill 1.0.3`, `bincode 2.0.1`, `paste 1.0.15`; yanked `chacha20 0.10.1`. These require dependency maintenance and reachability review; maintenance/yank status alone is not an exploit demonstration.

## Positive controls, validation and limits

Ordinary chat enforces device authentication after review, wallet/network/proposal revision checks, and one-submit behavior. Payment operations reserve their signing path before asynchronous seed access. Seed storage uses platform secure storage; database encryption plumbing is present. Rust FROST nonce handles are consumed once. Tor-required Zcash connections fail closed; swaps, prices and other-chain RPC clients are separate direct connections, so Tor is not whole-app VPN coverage.

Validation in this review: source tracing including an independent security-review pass; live unfunded provider simulation; exact production audit SQL reproduction in isolated SQLite; `cargo audit` against the current advisory database; iOS-target reverse dependency trees; **20 existing focused proposal/review/quote tests passed** (`wallet_service_review_test.dart`, `wallet_review_card_test.dart`, `near_quote_test.dart`). The first invocation referenced a nonexistent quote-test filename; the corrected invocation passed. These checks do not validate every device authentication interaction or every transaction path.

This is a targeted source and dependency review, **not** a formal cryptographic audit, complete third-party dependency audit, release-binary reverse engineering exercise, device penetration test, fuzzing campaign or proof of non-exploitability. Previously passing tests and release-signing verification do not establish absence of vulnerabilities. Before broader use, prioritize S1–S4, then the remaining authorization/key-lifecycle defects and patched dependency, with regression tests covering bypass paths rather than only the main chat path.
