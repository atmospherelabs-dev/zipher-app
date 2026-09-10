# Zipher sync: implementation and measurement

Updated 2026-09-10. This replaces the earlier speculative Sync v3 RFC. Its
speed multipliers were targets, not measurements; its proposed filtered-block
scanner and custom cryptographic optimizations are not implemented.

## Architecture

Flutter, CLI, and MCP use `zipher-engine`. Flutter does not launch the CLI.
The engine downloads compact blocks and calls the wallet SDK's
`scan_cached_blocks`, which performs batched trial decryption, continuity
checks, commitment-tree updates, and wallet database writes. Zipher does not
replace the cryptographic scanner or omit blocks believed to be irrelevant.

The shared stack uses stable wallet crates adapted to Zakura Common 1.2.0.
See [the stack audit](cli-engine-stack-audit.md) for the compatibility patches
and the distinction from Zakura's published wallet fork.

## Comparison with Vizor

Source comparison: Vizor commit
[`245f3810659c88193825707800be4e9ac850b862`](https://github.com/chainapsis/vizor-wallet/tree/245f3810659c88193825707800be4e9ac850b862/rust/src/wallet/sync_engine).
This is a source comparison, not a measured ranking of either wallet.

| Area | Zipher before this pass | Change / remaining difference |
| --- | --- | --- |
| Block staging | Encrypt, write, read twice, delete temporary SQLite blocks | In-memory SDK BlockSource, as in Vizor; wallet persistence remains in SQLite |
| Download overlap | Prefetch already overlapped scan work | Preserved; block stream and preceding tree state now requested concurrently, as in Vizor |
| Dense history | Any overlapping range used 100-block batches throughout | Clamp batches at both mainnet density-window boundaries; use normal sizes outside, as in Vizor |
| Peer startup | Connect every alternate before the first batch | Reuse primary channel; connect alternates lazily and quarantine failures for the pass |
| Subtree refresh | Re-download Sapling/Orchard roots from index zero every pass | Use SDK restart indices with overlap, parallel pool requests; include Ironwood after activation |
| Resource policy | Batch feedback changed a counter but left the preplanned pass unchanged | Plan each new batch using current scanner feedback; queued batches remain ordered and bounded. Vizor also has explicit foreground/background policies |
| Session lifecycle | Stop could declare completion after ten seconds with workers still alive | Cancel and join scan/mempool workers; serialize starts and stops |
| Measurement | Single-server flag could auto-enable peers; counters reset per pass; throughput counted only fully scanned height advance | Explicit peer policy, session counters, separate scanned/committed blocks, timing excludes shutdown |

Vizor also has active-account transparent refresh scheduling, chain-tip reuse
for transaction setup, and dedicated recovery logic. Those paths have not been
ported wholesale. Sharing Common cryptography does not make two wallets'
resource use, sync latency, or recovery behavior identical.

## Safety and lifecycle

- The BlockSource supports repeated reads and the SDK's height/limit contract.
  No persistent compact-block cache is needed; restart resumes from SDK wallet
  state and re-downloads uncommitted work.
- Verify ranges are processed first and are bounded like other batches.
- Upcoming batches use the current size limit; the bounded prefetch queue may
  still contain batches downloaded before a slow scan lowered that limit.
- Empty, truncated, duplicate, reordered, excess, and out-of-range block heights
  fail validation. A tree state must immediately precede its requested range.
- The full batch deadline covers serial, verification, prefetch, and fallback
  downloads. Failed alternate peers are removed for the current pass.
- Existing SDK rewind handling and abort-on-drop prefetch cancellation remain.
  Stop joins both scan and mempool workers before a new session can start; an
  SDK scan already executing synchronously is allowed to finish before close.
- Subtree restart indices come from the SDK, which intentionally overlaps a
  recent complete shard. They are not inferred from row counts.
- The queue bounds batches, not absolute bytes. Extremely dense future ranges
  still warrant density-aware memory budgeting. Device background/thermal
  behavior and stop/restart under device suspension still need acceptance
  coverage before claiming optimal mobile behavior.

## Reproduce checks

Run from `rust/`:

```sh
cargo test --locked -p zipher-engine --lib sync::
cargo test --locked -p zipher-engine --lib benchmark_block_staging -- --ignored --nocapture
cargo test --locked -p zipher-engine --lib benchmark_live_disposable_restore -- --ignored --nocapture
ZIPHER_SYNC_BENCH_BLOCKS=20000 cargo test --locked -p zipher-engine --lib benchmark_live_disposable_restore -- --ignored --nocapture
```

The staging benchmark compares the former encrypted SQLite round trip against
in-memory traversal for identical synthetic batches. It excludes downloads,
trial decryption, and persistent wallet updates. Its ratio is **not** a wallet
sync speedup.

The live benchmark creates disposable encrypted wallets with one random seed,
uses one server and a common birthday 2,000 blocks behind the initial tip, and
runs six samples with prefetch depths `0, 3, 3, 0, 0, 3`. It never uses an installed wallet or
submits transactions. Each run has a 180-second limit. It measures the new
engine's configurations, not a before/after or Vizor comparison. Chain growth
and server variance remain potential confounders. The optional
`ZIPHER_SYNC_BENCH_BLOCKS` environment variable selects a larger lookback.

For CLI benchmarks, use a disposable wallet directory explicitly:

```sh
zipher --data-dir /absolute/path/to/disposable-wallet sync benchmark --max-seconds 180 --prefetch-depth 0
```

Single-server is the default for this command. Add `--multi-server` explicitly
for a separate experiment. Every restore run needs a fresh equivalent database;
running twice against an already synced database is not a valid comparison.
Use release builds and record the commit, server, device, power/thermal state,
birthday, final height, scan work, elapsed time, and peak memory.

## Measurements from this pass

[Raw results](benchmarks/sync-2026-09-09.json), recorded with Rust 1.97.1,
`x86_64-apple-darwin`, test profile (`opt-level=1`, debug information enabled).
These are not native mobile or release measurements.

- All 54 workspace tests passed, including compilation of the app's Rust bridge,
  CLI, and MCP. Both manually invoked benchmarks passed separately.
- Six disposable restores from the same birthday, roughly 20,000 blocks behind
  tip, completed successfully. Median elapsed time: **39.228 seconds serial**,
  **31.871 seconds with prefetch depth 3**. The live chain advanced three blocks
  during the samples; raw scanned heights and work counts are preserved.
- This compares two configurations of the new engine. It does not establish a
  speedup over the previous release or over Vizor. The default depth remains 3.
- Adaptive limits now apply to actual batches: the serial runs used 26–27
  batches after reducing the size, instead of retaining the original 20-batch
  plan while reporting a smaller size.
- Synthetic staging of twenty 1,000-block batches took **497.420 ms** through
  encrypted SQLite versus **77.619 ms** through the memory source. This measures
  only staging overhead, not end-to-end wallet sync.

## Acceptance still needed for a superiority claim

1. Compare equivalent release builds of Zipher and Vizor on the same device,
   server, network, birthday, and disposable funded test fixtures. Alternate run
   order and report several runs, not the best sample.
2. Cover recent catch-up, historical restore including dense-era blocks, first
   spendable funds, transaction/memo recovery, and steady-state polling.
3. Measure peak memory, transferred bytes, battery/thermal impact, background
   suspension/resume, server failure, and chain reorg recovery.
4. Verify Sapling, Orchard, and Ironwood balances, spendability, and commitments
   against known fixtures; timing alone cannot establish wallet correctness.

No result currently establishes that Zipher sync is faster overall than Vizor.

## 2026-09-10 selected-peer policy

Current Vizor source was reviewed at
[`123bcef78c03f0ed9b11f1778e5de424ffb9cd5f`](https://github.com/chainapsis/vizor-wallet/tree/123bcef78c03f0ed9b11f1778e5de424ffb9cd5f/rust/src/wallet/sync_engine).
Its scanner prefetches using the selected connection. Zipher's automatic policy
previously rotated every batch across six regional servers, serially paying each
region's latency. Automatic downloads now stay with the selected server, while
known alternates remain available for retry/failover. Explicit multi-server
configuration retains rotation. Custom-server sessions do not inherit public
fallback peers from a previous wallet/server selection.

Six disposable restores compared both policies over the same 6,000-block window
and 93,177 work units per run, using the same random wallet seed and fresh databases.
Median elapsed time was 14.532 seconds with regional rotation and 12.151 seconds
with the selected peer: 16.4% less elapsed time. All six restored to the target tip.
[Raw results](benchmarks/sync-peer-policy-2026-09-10.json) include per-run download,
scan, block and commitment metrics. Reproduce with:

```sh
ZIPHER_SYNC_BENCH_PEERS=1 ZIPHER_SYNC_BENCH_BLOCKS=6000 cargo test --locked -p zipher-engine --lib benchmark_live_disposable_restore -- --ignored --nocapture
```

This is a short modern-history benchmark on a live network, using the x86_64 host
Cargo test profile (opt-level 1), not a full-chain or iPhone release benchmark.
Vizor's debug profile uses opt-level 3; Zipher's release profile uses opt-level 3,
LTO and one codegen unit. These measurements do not establish parity with Vizor.

Live diagnostics now carry the actual active scan target on progress events and
include both prefetched download time and local scan time. Routine empty-batch
account refreshes are throttled, and timed-out downloads shrink their next batch.
