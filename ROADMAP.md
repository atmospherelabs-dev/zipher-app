# Zipher — Roadmap & TODO

Audit and feature plan based on ZIP best practices review, zkool2 comparison,
and ongoing development discussions.

---

## 1. Security & Privacy

### 1.1 Database Encryption at Rest
**Priority: HIGH** — Viewing keys, transaction history, memos, and balances
sit in an unencrypted SQLite file. Seed/spending keys are already in the iOS
Keychain (post-migration), but the privacy layer is exposed.

- [ ] Enable the `sqlcipher` Cargo feature flag in `native/zcash-sync/Cargo.toml`
- [ ] Add a "Set DB password" flow on first launch (or derive a key from biometrics)
- [ ] Call `WarpApi.setDbPasswd()` before any DB operations in `splash.dart`
- [ ] Migrate existing unencrypted DB → encrypted (use `clone_db_with_passwd`)
- [ ] Handle wrong-password / locked-out scenarios gracefully
- [ ] Dart-side `zipher_app.db` (sent memos) — evaluate encrypting with `sqflite_sqlcipher` or merging into the Rust DB

**Reference:** `db/cipher.rs` already has `set_db_passwd()`, `check_passwd()`,
and `clone_db_with_passwd()`. The plumbing exists.

### 1.2 ZIP-315 Compliance — Privacy Warnings
**Priority: MEDIUM** — The privacy warning system exists but messaging is generic.

- [ ] Make `txplan.dart` warning explain *what* is being leaked (e.g. "Sending to a transparent address — amounts and addresses will be publicly visible")
- [ ] Add explicit cross-pool transaction warning
- [ ] Expose `minPrivacyLevel` setting in the UI so users can control their privacy floor

### 1.3 ZIP-315 Compliance — `sweep_tseed` Violation
**Priority: MEDIUM** — `taddr.rs` `sweep_tseed` combines UTXOs from multiple
derived t-addrs into one transaction, linking them on-chain.

- [ ] Option A: Build one shielding tx per t-addr
- [ ] Option B: Show explicit privacy warning before combining ("This will link X transparent addresses on-chain")

### 1.4 ZIP-315 Compliance — Transparent Address Rotation
**Priority: LOW-MEDIUM** — Currently one fixed t-addr per account, never rotated.

- [ ] Auto-rotate change addresses (new t-addr for change outputs)
- [ ] Manual "new receive address" button for transparent
- [ ] Sweep past transparent addresses tool (like zkool2)

### 1.5 ZIP-315 Compliance — Confirmation Policies
**Priority: LOW** — Single global `confirmations = 3` for all notes.

- [ ] Distinguish trusted (self-created) vs untrusted (received) TXOs
- [ ] Trusted: 3 confirmations, Untrusted: 10 confirmations
- [ ] Expose confirmation threshold in settings UI

### 1.6 Screen Protection Hardening
**Status: DONE** — `screen_protector` package is integrated. FLAG_SECURE on
Android, screenshot blocking on iOS for seed display screens.

### 1.7 Seed Phrase Security
**Status: DONE**
- Seeds stored in iOS Keychain / Android EncryptedSharedPreferences
- Cleared from SQLite DB after migration
- Full-page backup quiz prevents cheating
- Seed hidden by default in import flow with reveal toggle
- Spending keys derived in RAM from Keychain on each launch

---

## 2. Features from Zkool2

### 2.1 FROST Multi-Party Signing
**Priority: HIGH — Killer differentiator**

Enables shared wallets (2-of-3), social recovery, and CipherPay escrow.

**Phase 1: PCZT support**
- [ ] Add PCZT (Partially Created Zcash Transaction) parsing/creation to the Rust engine
- [ ] UI for creating unsigned transactions
- [ ] UI for loading, signing, and broadcasting saved transactions
- [ ] Cold wallet / offline signing flow

**Phase 2: Distributed Key Generation (DKG)**
- [ ] Add DB tables: `dkg_params`, `dkg_packages`
- [ ] Implement 3-round DKG protocol (using shielded memos as communication channel)
- [ ] UI: Create shared wallet (set name, N, T threshold, participants)
- [ ] UI: Exchange addresses (QR codes)
- [ ] UI: DKG progress/status screen
- [ ] Result: shared Orchard-only account with threshold signing

**Phase 3: FROST Signing**
- [ ] Add DB tables: `frost_commitments`, `frost_signatures`
- [ ] Coordinator creates tx plan (PCZT) → participants commit → aggregate → broadcast
- [ ] Communication via shielded on-chain memos (private, no server needed)
- [ ] UI: Sign request screen, approval flow

**Dependencies:** `reddsa::frost::redpallas`, `frost-rerandomized`, `pczt` crate.
**Reference:** zkool2 `rust/src/frost/` (~1,000 lines Rust + Flutter UI).

### 2.2 Encrypted Database (see 1.1 above)

### 2.3 Mempool Monitoring
**Priority: MEDIUM** — Show "incoming..." before confirmation.

- [ ] Subscribe to mempool updates from lightwalletd
- [ ] Show pending incoming transactions on home page
- [ ] Show pending outgoing transactions with status

### 2.4 Per-Account Sync Toggle
**Priority: MEDIUM** — Enable/disable accounts from global sync.

- [ ] Add `enabled` flag to account settings
- [ ] Skip disabled accounts during sync
- [ ] UI toggle in account edit screen

### 2.5 TOR Proxy Support
**Priority: MEDIUM** — Aligns with privacy narrative.

- [ ] Add TOR/SOCKS5 proxy configuration in settings
- [ ] Route all lightwalletd connections through proxy
- [ ] Support .onion server URLs

### 2.6 Account Export/Import (Encrypted)
**Priority: LOW-MEDIUM** — Per-account encrypted file export for backup/transfer.

- [ ] Export single account as encrypted file (age encryption already exists in `db/backup.rs`)
- [ ] Import account from encrypted file into current wallet
- [ ] UI in account edit screen

### 2.7 Ledger Hardware Wallet
**Priority: LOW** — Niche but high-trust audience.

- [ ] Get FVK from Ledger device
- [ ] Create view-only account from Ledger FVK
- [ ] Sign transactions via Ledger (USB/Bluetooth)
- [ ] Support all pool types (t2z, z2t, z2z)

**Reference:** zkool2 `rust/src/ledger/` and `rust/src/recover.rs`.

### 2.8 flutter_rust_bridge v2 Migration
**Priority: LOW** — Dev velocity improvement, not user-facing.

- [ ] Replace manual C FFI (`dart_ffi.rs`) with auto-generated bridge
- [ ] Cleaner async Rust↔Dart communication
- [ ] Better type safety and error handling

---

## 3. ZIP Compliance Scorecard

| ZIP | Grade | Notes |
|-----|-------|-------|
| **ZIP-317** (Fees) | **A** | Fully implemented, correct marginal fee math |
| **ZIP-321** (Payment URIs) | **A** | Full support including multi-output |
| **ZIP-315** (Wallet Best Practices) | **B-** | Good foundations; gaps in auto-shielding, privacy warnings, t-addr rotation, confirmation policies |

---

## 4. UX & Polish (Ongoing)

- [x] WCAG 2.2 AA contrast compliance
- [x] Seed backup quiz (full-page, anti-cheat)
- [x] Seed hidden by default in import flow
- [x] Emoji avatars for accounts
- [x] Swap integration (Near Intents)
- [x] Contact address book with chain logos
- [x] Sync status animation (non-disruptive)
- [x] i18n: EN, FR, ES, PT
- [ ] Auto-shielding with configurable threshold
- [ ] Transaction categories and labels
- [ ] Fiat value history per transaction

---

## 6. Agent Wallet (zipher-cli)

**Priority: HIGH — New product line**

Headless, local-first Zcash light wallet for AI agents. Wraps the same
Rust engine as Zipher mobile, repackaged as a standalone CLI binary with
daemon mode, MCP server, and OpenClaw skill.

**Full PRD:** [`docs/agent-wallet-prd.md`](docs/agent-wallet-prd.md)

**Phases:**

- [ ] Phase 0: Cargo workspace restructure — extract engine crate from FFI
- [ ] Phase 1: `zipher-cli` binary (wallet lifecycle + sync + balance + send)
- [ ] Phase 2: Spending policy, audit log, daemon mode, kill switch
- [ ] Phase 3: MCP server + OpenClaw skill (equal priority)
- [ ] Phase 4: CipherPay end-to-end integration (x402 flow)
- [ ] Phase 5: Docker image, ARM builds, testnet CI, note consolidation

---

## 5. Infrastructure

- [x] Bundle ID: `dev.atmospherelabs.zipher`
- [x] CI workflows: `build-android.yml` with inline Flutter build
- [x] App icon and splash screen regenerated from Zipher assets
- [x] Legacy branding (YWallet/ZWallet) fully removed
- [x] Dead code cleanup (`dart analyze` clean)
- [ ] CI: iOS build workflow validation
- [ ] CI: Automated `dart analyze` + test gate
- [ ] Release signing keys (Android keystore, iOS certificates)
