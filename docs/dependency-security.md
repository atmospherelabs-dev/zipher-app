# Dependency security maintenance

Local changes qualified October 31, 2026. This page records source changes and
local verification, not a released binary or a complete security certification.
The same narrowly scoped changes are applied in the main `feat/ironwood`
checkout and the isolated `codex/zipher-nu7-vizor` checkout. Existing unrelated
working changes and the pinned OWS submodule are preserved.

## November 4 isolated release candidate

The current fixes are isolated on `codex/nu7-security-release-2026-11-04`, based
on `2e7ccd3c332e94aa496abff0b52b331726e9cb6b`. This branch contains NU7 and
security changes, including the credential/session and saved-Tor-policy
prerequisites; it excludes the pending trading and payment feature work.
The main checkout and the older full-state NU7 worktree are separate from this
release. Planned artifacts are CLI/MCP **0.3.1-rc.1** and iOS **1.16.0 (741)**.

- `crypto-bigint` is now **0.7.10** throughout the resolved graph, with
  `k256 0.14` and `coins-bip32/39 0.17.1`. Published BIP-32, address and signature
  vectors are retained. The OWS signer passes all **204** of its unit tests.
- RSA is **0.10.0-rc.20**, published November 3. Its source revision
  `ea2c88b582846ff3bfb779a6f9ce04ad9fbfffb2` descends from the November 1
  [implicit-rejection fix](https://github.com/RustCrypto/RSA/pull/749)
  `0eb430ca6d27ec52a02e8bc23be878d41fcfef41` and includes subsequent blinding
  and arithmetic hardening. All **8** selected upstream implicit-rejection
  regressions pass. The registry archive SHA-256 is
  `2389407c34c6039d7c8740520ec758090883c5b92df93a5edada2779256bf2e0`.
- RustSec's current record still lists `patched=[]` for RSA. Raw `cargo audit`
  therefore still reports RUSTSEC-2023-0071. The release gate keeps that report
  and admits only this exact published version after checking the registry
  archive and all reviewed Rust source files plus its manifest. It rejects
  older RSA, changed source, any old crypto-bigint copy, new advisories, and
  unsound warnings. This is a documented source-reviewed exception, not a
  blanket advisory ignore or a claim that RustSec declares this RC patched.
- Six narrowly scoped compatibility adapters preserve Arti's 0.35 networking
  APIs and OWS storage/wire contracts while selecting the newer cryptography.
  Their origins, source hashes and reproducible patches are in
  `rust/vendor/security-adapters.json` and `security-patches/`. Arti's RSA DER
  adapter strips fixed-width zero padding so established relay fingerprints
  remain canonical. The upstream Tor identity/signature vector is included in
  the engine's regression suite. Upstream standalone lockfiles are omitted;
  the application's `rust/Cargo.lock` is authoritative. Unused upstream SSH
  private-key integration fixtures are omitted from the vendored distribution
  to preserve repository push protection; runtime library code is unchanged.
- A fresh pub.dev advisory query covered **188** locked hosted dependencies;
  none of their locked versions is in the published affected-version lists.
  Unmaintained Rust package warnings remain for atomic-polyfill, bincode and
  paste; no additional vulnerability finding remains beyond the RSA record
  described above.

Current local checks: **142 Flutter tests**, **16 security-gate tests**, scoped
analysis and native Flutter Rust Bridge/CLI/MCP compilation pass. The full isolated Rust regression suite passes **331 tests**, with three
explicit live-network tests ignored. Device artifact builds are being recorded
separately.
Distribution still requires successful signed artifacts and upload evidence.

The October 31 record below is historical; its unresolved crypto entries are
superseded by this candidate's exact dependency/source checks.

## Build authority

Run Cargo in `rust/`. Its `Cargo.toml` and `Cargo.lock` are authoritative for
Flutter Rust Bridge, CLI and MCP builds. The obsolete repository-root Cargo
manifest and lockfile were removed: they conflicted with the standalone Rust
workspace and reported old dependencies that could not actually resolve there.
The pinned OWS checkout has its own standalone lockfile; Zipher's path imports
resolve using **Zipher's** lockfile. This maintenance does not update or qualify
standalone OWS releases.

## Reported issues

- **rustls:** active resolution already used **0.23.46**. The stale root lockfile
  used **0.23.37**. The engine manifest now requires at least **0.23.46**, covering
  the [TLS handshake fix](https://rustsec.org/advisories/RUSTSEC-2026-0285.html)
  and [session Debug redaction fix](https://rustsec.org/advisories/RUSTSEC-2026-0346.html).
- **ZIP symlink escape:** no Rust `zip` package is resolved. Dart `archive`
  **4.0.7** was present through asset/code-generation tools. It is now **4.5.2**,
  with an explicit development dependency floor. The [4.5.0 upstream fix](https://pub.dev/packages/archive/changelog#450)
  defers symlinks and rejects paths through another link. No application
  extraction-to-disk consumer was found; this distinction limits demonstrated
  exposure without excusing the old dependency.
- **rmcp DNS rebinding:** active and committed lockfiles already resolved
  **1.8.0**, above the [advisory's 1.4.0 fix](https://github.com/modelcontextprotocol/rust-sdk/security/advisories/GHSA-89vp-x53w-74fx).
  Zipher uses stdio; the affected Streamable HTTP server feature is absent.
  The manifest now requires **1.8** and disables default features while retaining
  the explicit server/macros/stdio/schema features. No HTTP transport was added.

## Additional compatible maintenance

The lockfile audit also identified old compression dependencies and an unused
optional `rkyv` integration. Targeted parent updates use `rust_decimal 1.43.0`,
`async-compression 0.4.51` and `compression-codecs 0.4.46`, resolving
`zstd 0.14.3`, `zstd-safe 8.2.0` and `zstd-sys 2.1.2`. The old `rkyv` family is
removed. The audit's Tokio I/O-safety warning is addressed with **1.53.3**.
These changes preserve the wallet crypto cohort and OWS revision.

## Gates and verification

`scripts/verify-dependency-security.py` checks the actual resolved Cargo graph,
all copies of rustls/rmcp, the rmcp transport feature set, the exact Dart archive
lockfile block, and absence of the conflicting root workspace. It rejects
unreviewed major versions and is intentionally narrower than a full advisory
audit. Existing wallet-cohort checks remain independent. Both regression CI
and CLI release builds run the new graph gate. A separate regression CI job
uses locked Flutter dependencies and tests async/sync extraction boundaries
and ordinary ZIP content. The four extraction tests use disposable local
fixtures and never touch wallets or existing files. The same async/sync
containment cases fail on cached archive 4.0.7 and pass on 4.5.2. The eleven
guard tests include old duplicate dependencies, missing metadata and unexpected HTTP.

Local regression results on the final NU7 dependency graph: **144 Rust tests
passed**, five live-network tests intentionally ignored; **4 Flutter archive
tests passed**; **11 dependency-guard tests passed**; **3 npm artifact tests
passed**. The archive test's negative control fails both containment cases on
4.0.7 and passes them on 4.5.2. Scoped Dart analysis is clean, and the existing
wallet-cohort guard plus the new dependency gate pass in both checkouts.
The final Flutter Rust Bridge/CLI/MCP compilation check passes in both the
main Common 1.2 checkout and the separate NU7 Common 4 checkout. The main
checkout also passes the four archive regressions. This verifies source
compatibility; no release artifact or mobile device was qualified here.

## Remaining audit findings

No audit ignore or suppression was added. The local audit still reports:

- [crypto-bigint 0.5.5 timing variability](https://rustsec.org/advisories/RUSTSEC-2026-0387.html):
  fixed in 0.7.6, while the current elliptic-curve/k256/coins-bip32/OWS cohort
  requires 0.5. It participates in real multichain key derivation/signing.
  Resolution needs a coordinated upstream cohort upgrade or reviewed backport;
  adding a second direct dependency would not fix the affected copy.
- [RSA's Marvin timing issue](https://rustsec.org/advisories/RUSTSEC-2023-0071.html):
  the advisory lists no patched version. It is transitive through Arti. No
  application RSA signing/decryption oracle was identified; this is not a
  proved exemption. Preserve Tor while evaluating upstream remediation.

Unmaintained-package warnings also remain for atomic-polyfill, bincode and
paste. A passing targeted gate must not be described as a clean full audit.
Before distribution, qualify exact rebuilt native/mobile artifacts and retain
the funded/device gates in the NU7 upgrade documentation.
