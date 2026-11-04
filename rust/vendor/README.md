# Stable wallet store on released Zakura Common 4

Zipher keeps the stable upstream backend **0.24.0** and SQLite **0.22.0**,
including their typed Ironwood migration store. Their limited local adaptations
now use the exact published **Zakura Common 4.0.0** crypto/protocol family and the
published **zakura-pczt 0.1.0-rc9**. The latter replaces Zipher's local PCZT fork.
The pool-migration engine is the published stable **0.2.0** source, adapted to
this retained wallet store and the Common 4 APIs. This is a coordinated local
compatibility cohort, not an officially published combined wallet SDK.

`sources.json` records verified source-archive SHA-256 checksums, the exact
published Common/PCZT dependency checksums from Cargo.lock, and the source of
each NU7 backport. Upstream licenses are retained. `patches/<crate>.patch`
reproduces each local crate from its matching archive with `patch -p1`.
Archive-only Cargo.lock, Cargo.toml.orig and .cargo_vcs_info.json are omitted.

## Why the wallet store stays

Vizor v0.0.63 is the reference for Common 4 and NU7 lifecycle behavior. Its
Zakura SQLite fork deliberately removes the ZIP 318 pool-migration engine and
runs a migration dropping its tables. Zipher uses that engine and retains active
migration state. Replacing the store with Vizor's fork would discard that state.

The newer upstream backend 0.25 / SQLite 0.23 train also adopts ZIP 316 revision
2, newer key/address types, incrementalmerkletree 0.9 and zip32 0.3. Released
Common 4 uses the earlier address/key API and tree types. We do not suppress or
partially implement the newer address-expiry rules to force those crates onto
Common 4. A later full wallet train upgrade remains a separate compatibility
migration.

## NU7 changes

- Resolve the actual released Common 4 protocol, with mainnet activation
  3,543,405, testnet activation 4,465,026, branch 0x77190AD9 and V6 support.
- Use the released pool-migration 0.2 scheduler. BlockSpacing/AnchorGrid preserve
  ZIP 318 delays, anchor retention and expiry durations across 25-second blocks.
- Backport the stable backend 0.25 anchor-retention policy and its network-aware
  migration parameters to the retained backend. Backport SQLite 0.23's
  height-aware unknown-expiry and transparent-history behavior, adapting to
  Common 4's network/height helper signature. Published historical schema
  migrations retain their historical constants.
- Add a narrow typed upgrade-stop adapter under SQLite's migration store.
  It requires the wallet's own fully scanned chain to include the new branch,
  reconciles mined parts first, validates stored PCZT/raw transaction identity,
  and retires only the exact old-branch unmined records and their advisory
  owners. Raw bytes and spend links remain available to reorg recovery. An
  optional `orchard_ironwood_migration_upgrade_stops` receipt table is created
  atomically when needed. This is a local database behavior extension; the
  published 0.22 schema migrations themselves remain registered unchanged.
- Add exactly StandardFee.fee_zat (protobuf field 1), estimator_version (field 2)
  and the GetStandardFee unary client method from lightwallet-protocol v0.6.0.
  The exact reference proto and checksum are included. This is an additive
  protocol backport, not regeneration of every protocol type.
- Keep one crypto family. Common 4's separated reddsa-frost package replaces the
  former reddsa frost feature. RNG adapters preserve the existing random stream
  at old SDK interfaces. Common 4's published PCZT finalizer, signer and prover
  obtain randomness from their OS CSPRNG; the adapted migration 0.2 API retains
  its RNG argument while calling those released roles.

The application owns activation holds, proposal expiry caps, fee review snapshots
and migration interruption UX. Migration 0.2's builder fee policy remains its
published ZIP 317 policy unless explicitly replaced with a separately reviewed
fee-policy API; normal-send fee discovery does not change that library constant.

## Verification

From rust/:

```sh
cargo metadata --locked --format-version 1 > target/wallet-stack.json
python3 ../scripts/verify-wallet-stack.py target/wallet-stack.json
cargo check --locked -p rust_lib_zipher -p zipher-cli -p zipher-mcp-server
cargo test --locked -p zipher-engine -p zipher-rng-compat --tests
```

The graph guard rejects mixed upstream/Common types, checks resolved protocol
activation/branch source and requires the retained migration store. Engine
boundary and disposable-wallet tests are needed in addition to graph checks.
No graph or unit test alone establishes compatibility with every historical
wallet database, live settlement, reorg recovery, or mobile background operation.
