# Stable wallet SDK on Zakura Common

These four crates are the published stable Zcash wallet layer: backend 0.24.0,
SQLite 0.22.0, pool migration 0.1.0 and PCZT 0.9.3. Their source archive URLs and
verified SHA-256 checksums are recorded in `sources.json`. Upstream licenses and
source are retained. They are local patches, not official Zakura wallet releases.

The published Zakura wallet fork omits pool migration and currently pins Common
1.0.0. Zipher needs Ironwood migration storage and the current Common 1.2.0 crypto
family. We therefore retain the stable upstream wallet implementation and make
these limited adaptations, recorded as unified diffs in `patches/`:

- Rename crypto dependencies to `zakura-*` 1.2.0 and matching field/group traits.
- Adapt RNG calls at crypto API boundaries through `zipher-rng-compat`. The
  underlying OS randomness and the SDK's RNG interfaces are unchanged.
- Preserve the stable backend's conservative transaction-size checks with the
  size constants from `zcash_primitives` 0.30.1, which Common 1.2 has not exported.

No proving circuit, key derivation, transaction encoding, database migration or
pool-migration policy inside these four crates is rewritten. Application-side
changes to drive the new SDK live in `crates/engine/src/ironwood_v2.rs`.

To review or reproduce an adaptation, download the matching archive, verify its
checksum, extract it, and apply its `patches/<crate>.patch` using `patch -p1`.
Archive-only `Cargo.lock`, `Cargo.toml.orig` and `.cargo_vcs_info.json` are omitted
from the checked-in copies. All other files must match the patched archive.
When changing a vendored source file, update its patch alongside it.

Verification commands from `rust/`:

```sh
cargo metadata --locked --format-version 1 > target/wallet-stack.json
python3 ../scripts/verify-wallet-stack.py target/wallet-stack.json
cargo check --locked -p rust_lib_zipher -p zipher-cli -p zipher-mcp-server
cargo test --locked -p zipher-engine -p zipher-rng-compat --tests
```

The metadata guard rejects mixed upstream/Zakura crypto families and unexpected
wallet versions. The wallet test uses disposable encrypted databases; it checks
new-wallet creation, reopen, deterministic seed restore and migration-store
availability. It does not establish compatibility with every historical wallet
database or prove live settlement.
