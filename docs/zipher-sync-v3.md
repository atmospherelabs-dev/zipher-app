# Zipher Sync v3 — Custom High-Performance Sync Engine

**Status:** Design / RFC
**Author:** Atmosphere Labs
**Date:** 2026-05-06

---

## References

- **WarpSync** (Hanh / YWallet / Zkool): [Documentation](https://hhanh00.github.io/zcash-sync/execution_model/) · [Source](https://github.com/nicubarbaros/zcash-sync) · [Decryption deep-dive](https://hhanh00.github.io/zcash-sync/execution_model/tasks/decrypt/) · [Pipeline](https://hhanh00.github.io/zcash-sync/execution_model/tasks/pipeline/)
- **Pepper Sync** (Zingo Labs / Zingo 2.0): [docs.rs](https://docs.rs/pepper-sync/latest/pepper_sync/) · [crates.io](https://crates.io/crates/pepper-sync) · [Source (zingolib)](https://github.com/zingolabs/zingolib) · [ZecHub overview](https://zechub.wiki/zcash-tech/pepper-sync)
- **librustzcash** (ECC / Zcash Foundation): [Source](https://github.com/zcash/librustzcash) · [zcash_client_backend docs](https://docs.rs/zcash_client_backend/0.21.0/) · [zcash_client_sqlite docs](https://docs.rs/zcash_client_sqlite/0.19.0/)
- **Zcash Mobile SDK / ZODL**: [Android SDK](https://github.com/AthensWorks/zcash-android-wallet-sdk) · [Kotlin Synchronizer](https://github.com/AthensWorks/zcash-android-wallet-sdk/tree/main/sdk-lib/src/main/java/cash/z/ecc/android/sdk)

---

## Problem

Zipher's current sync engine (`sync.rs`) is sequential: download a batch → write to cache → `scan_cached_blocks` → delete cache → repeat. No parallelism, no prefetching, no concurrent trial decryption. This makes initial sync and wallet restore significantly slower than WarpSync (YWallet/Zkool) and Pepper Sync (Zingo 2.0).

## Goal

Build a custom sync engine — **Zipher Sync** — that takes the best ideas from WarpSync, Pepper Sync, and the standard librustzcash stack, maintained by us. Target: 3-5x faster initial sync, seamless day-to-day operation, same database (`zcash_client_sqlite`).

## Design Principles

1. **Keep `zcash_client_sqlite`** — no custom database, no migration headaches, upstream improvements land free.
2. **Keep `zcash_client_backend` APIs** — wallet ops, transaction building, PCZT all stay untouched.
3. **Replace the scan pipeline** — the part between "download compact blocks" and "store results in wallet DB" is where the performance lives.
4. **Shared engine** — mobile, CLI, and MCP all use the same code path.
5. **Incremental** — each phase delivers measurable improvement; no big-bang rewrite.

---

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    Coordinator                           │
│  (scan range management, priority scheduling, progress)  │
└──────────┬──────────────────────────────┬───────────────┘
           │                              │
     ┌─────▼─────┐                 ┌──────▼──────┐
     │  Fetcher   │                │  Enhancer    │
     │  (stream   │                │  (memo/tx    │
     │  compact   │                │  recovery,   │
     │  blocks)   │                │  non-blocking)│
     └─────┬─────┘                 └─────────────┘
           │
     ┌─────▼─────┐
     │  Batcher   │
     │  (output-  │
     │  counted   │
     │  batches)  │
     └─────┬─────┘
           │
    ┌──────▼──────────────────────┐
    │   Scan Worker Pool (rayon)   │
    │  ┌────┐ ┌────┐ ┌────┐      │
    │  │ W1 │ │ W2 │ │ WN │      │
    │  └────┘ └────┘ └────┘      │
    │  Parallel trial decryption   │
    │  + note commitment leaves    │
    └──────────┬──────────────────┘
               │
     ┌─────────▼─────────┐
     │  DB Writer         │
     │  (sequential       │
     │   zcash_client_    │
     │   sqlite writes)   │
     └───────────────────┘
```

### Component Breakdown

#### 1. Coordinator
Manages the sync lifecycle. Replaces the current `sync_once`.

- Calls `suggest_scan_ranges()` to get priority-ordered work
- Schedules ranges to the Fetcher based on priority (Verify → ChainTip → Historic)
- Tracks progress, emits events to Dart via existing `SyncEventInfo` broadcast
- Handles reorg detection (verify ranges) and pass timeout/restart
- Decides when to pause scan for maintenance (enhancement, mempool)

#### 2. Fetcher
Streams compact blocks from lightwalletd. Runs as an independent async task.

- Opens its own gRPC connection (no contention with scan)
- Streams blocks via `get_block_range` into a bounded channel
- Prefetches: starts downloading batch N+1 while batch N is still scanning
- Fetches `ChainState` (tree state) for each batch boundary
- Backpressure: bounded channel (e.g., 3 batches ahead) prevents unbounded memory

#### 3. Batcher
Converts raw block stream into fixed-output-count batches (from Pepper Sync).

- Current approach: batch by block count (1000 blocks). Problem: block density varies wildly — early Zcash blocks have few outputs, post-Orchard blocks can have thousands.
- New approach: batch by **output count** (e.g., 50,000 Sapling+Orchard outputs per batch). This gives:
  - Stable memory usage regardless of chain era
  - Predictable scan time per batch
  - Better parallelization (workers get equal-sized work)

#### 4. Scan Worker Pool
The core performance upgrade. Replaces `scan_cached_blocks` for the trial decryption step.

**What `scan_cached_blocks` does today (single-threaded):**
1. For each block, for each transaction, for each output: trial decrypt with each IVK
2. If decrypted: compute note commitment, nullifier, position
3. Update shard trees
4. Write to wallet DB

**What Zipher Sync does (parallel):**
1. Split batch outputs across `rayon` thread pool
2. Each worker: trial decrypt its chunk using `sapling-crypto` / `orchard` crate APIs directly
3. **WarpSync trick**: batch affine normalization — compute `E^IVK` for all outputs using extended coordinates, then batch-normalize to affine with a single field inversion. This is the single biggest speedup WarpSync has over vanilla scanning.
4. Collect results: `Vec<DecryptedNote>` with position, value, nullifier, memo flag
5. Compute note commitment leaves and shard tree retentions (can also be parallelized)
6. Return batch results to DB Writer

**Key insight:** Trial decryption is embarrassingly parallel — each output is independent. The serial part (tree updates, DB writes) is a small fraction of total work.

#### 5. DB Writer
Sequential writer that feeds scan results into `zcash_client_sqlite`.

Two approaches (pick during implementation):

**Option A — Use `scan_cached_blocks` with pre-filtered cache:**
- Only insert blocks that contain our notes into the cache
- Call `scan_cached_blocks` on the filtered set
- Pro: uses battle-tested code path. Con: still single-threaded for found notes, and `scan_cached_blocks` re-does trial decryption.

**Option B — Use `WalletWrite` trait methods directly:**
- Call `put_blocks` with pre-computed scan results
- Requires building the same `ScannedBlock` / `ScannedBundles` structures that `scan_cached_blocks` produces internally
- Pro: no redundant work. Con: tightly coupled to `zcash_client_backend` internals, may break on upgrades.

**Recommended: Option A initially (safe), migrate to Option B once stable.**

Actually, the most pragmatic approach: **keep `scan_cached_blocks` but pipeline around it.** The parallel workers handle the *prefetch and pre-screen* (identify which blocks contain our notes), while `scan_cached_blocks` handles the actual database-safe scanning. The pipeline overlap (download N+1 while scan N) already gives a ~2x speedup even without replacing `scan_cached_blocks`.

#### 6. Enhancer
Non-blocking memo/transaction detail recovery. Already mostly done (current `enhance_transactions_limited`), but decoupled from scan progress.

---

## Phases (Original — Superseded by Unified Roadmap below)

### Phase 1: Download-Scan Pipeline (1-2 days)
**Expected improvement: ~2x initial sync speed**

The single biggest bang-for-buck change. Currently, download and scan are fully sequential within each batch.

Changes:
- Spawn Fetcher as a separate `tokio::spawn` task
- Use `tokio::sync::mpsc` bounded channel (capacity 3) between Fetcher and Scanner
- Fetcher downloads batch N+1 while Scanner processes batch N
- Scanner pulls from channel, calls existing `process_downloaded_range`

This is a minimal change to `sync_once` — same `scan_cached_blocks`, same database writes, just overlapped I/O.

```
BEFORE:  [download 1][scan 1][download 2][scan 2][download 3][scan 3]
AFTER:   [download 1][download 2][download 3][download 4]...
                     [scan 1    ][scan 2    ][scan 3    ]...
```

### Phase 2: Output-Counted Batching (1-2 days)
**Expected improvement: stable memory + predictable batch time**

Replace `split_into_batches(range, block_count)` with output-counted batching:
- Fetcher streams blocks, counting `vtx.iter().map(|tx| tx.outputs.len() + tx.actions.len()).sum()`
- When output count hits threshold (e.g., 50K), emit batch and start next
- Adaptive: if a batch takes >5s to scan, reduce output threshold; if <1s, increase

### Phase 3: Parallel Trial Decryption (1-2 weeks)
**Expected improvement: 2-4x on top of Phase 1-2, depending on core count**

This is the big one. Add `rayon` dependency and implement parallel note scanning.

Two sub-approaches:

**3a. Pre-screen + `scan_cached_blocks` (safer):**
- Parallel rayon workers trial-decrypt all outputs in a batch
- Identify which blocks contain our notes (typically <0.1% of blocks)
- Only insert those blocks (plus surrounding blocks for tree continuity) into BlockCache
- Call `scan_cached_blocks` on the filtered set
- Benefit: `scan_cached_blocks` does much less work. Drawback: still re-decrypts found notes.

**3b. Full parallel scan replacing `scan_cached_blocks` (faster, harder):**
- Parallel workers produce `DecryptedNote` results
- Build `ScannedBlock` structures manually
- Feed into `WalletWrite::put_blocks`
- Requires deep knowledge of `zcash_client_backend` internals
- Risk: may break on crate upgrades

**Recommendation: Start with 3a. Measure. Move to 3b only if 3a isn't fast enough.**

### Phase 4: Chain-Tip Priority Scanning (3-5 days)
**Expected improvement: spend-before-full-sync capability**

Already partially supported by `suggest_scan_ranges()` priority system. Enhancements:

- Detect the chain-tip shard boundary (where the latest Sapling/Orchard subtree ends)
- Prioritize scanning from that boundary to tip (highest priority after Verify)
- Once chain tip is scanned, user can spend immediately even during historic scan
- Background workers continue processing historic ranges
- UI shows "Spendable balance: X ZEC" vs "Scanning history: Y%"

### Phase 5: WarpSync Decryption Optimization (1 week)
**Expected improvement: 30-50% faster trial decryption**

Port Hanh's batch affine normalization trick:

1. For each output, compute `E^IVK` in extended/projective coordinates (no field inversion per-point)
2. Collect all intermediate results
3. Batch-normalize to affine coordinates using Montgomery's trick (one inversion for entire batch)
4. Validate CMU against decrypted note

This is pure math optimization — independent of database or sync architecture. Can be applied to both Sapling (`jubjub` curve) and Orchard (`pallas` curve).

Dependencies: `jubjub` and `pallas` (via `orchard` crate) — both already in our dependency tree.

### Phase 6: Shard-Aware Range Splitting (3-5 days)
**Expected improvement: faster spendability of found notes**

From Pepper Sync: when splitting historic ranges, align batch boundaries with shard boundaries. This ensures that when a note is found, the entire shard containing it gets scanned quickly, making the note spendable sooner.

- Query subtree metadata to get shard boundaries
- Split historic ranges at shard boundaries first, then by output count within shards
- When a note is found in shard N, promote shard N to high priority

---

## What We Keep (unchanged)

- `zcash_client_sqlite` database (wallet DB)
- `zcash_client_backend` wallet traits (`WalletRead`, `WalletWrite`)
- Transaction building (`send.rs`, PCZT)
- Query layer (`query.rs`)
- Enhancement pipeline (`enhance_transactions_limited`)
- Mempool monitor (`mempool_forever`)
- Pending transaction tracking (`pending.rs`)
- All Dart UI/UX code
- CLI and MCP server interfaces
- Event streaming to Dart (`SyncEventInfo`, `SyncProgressInfo`)

## What We Replace

- `sync_once` inner loop → Coordinator + Fetcher + Batcher pipeline
- `BlockCache` insert-scan-delete cycle → streaming pipeline (Phase 1-2)
- Single-threaded trial decryption → rayon parallel workers (Phase 3)
- Block-count batching → output-count batching (Phase 2)

## New Dependencies

| Crate | Purpose | Phase |
|-------|---------|-------|
| `rayon` | Parallel trial decryption | 3 |
| `crossbeam-channel` | Worker communication (optional, `tokio::sync` may suffice) | 3 |
| `zcash_note_encryption` | Direct trial decryption APIs (if bypassing `scan_cached_blocks`) | 3b/5 |

## Risks and Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| `scan_cached_blocks` API changes in future `zcash_client_backend` | Breaks Phase 3a pre-screen approach | Pin crate version; Phase 3b is API-independent |
| Parallel scan produces different tree state than sequential | Corrupted wallet DB | Phase 3a avoids this entirely; Phase 3b needs careful testing |
| `rayon` thread pool contention on mobile | Battery drain, UI jank | Configure pool size based on device (2 threads mobile, N threads desktop/CLI) |
| Output-counted batching misaligns with `ScanRange` boundaries | `suggest_scan_ranges` confusion | Split at ScanRange boundaries first, then subdivide by output count |

## Benchmarking Plan

Measure at each phase:
- **Initial sync time** (new wallet, birthday at genesis)
- **Restore time** (wallet with known history, e.g., 100 txs over 2 years)
- **Catch-up time** (wallet 1000 blocks behind)
- **Routine sync** (wallet 1-3 blocks behind)
- **Peak memory** (mobile-relevant)
- **Time to first spendable balance** (Phase 4 metric)

Test on:
- iPhone 14 (mobile baseline)
- M-series Mac (CLI/MCP baseline)
- Old Android device (resource-constrained)

---

# Part II: Novel Contributions

Phases 1-6 above bring us to parity with WarpSync/Pepper Sync. The phases below are what would make Zipher Sync genuinely **better than anything that exists** for Zcash. None of these are implemented in WarpSync, Pepper Sync, ZODL SDK, or `librustzcash`.

## Reframe: From "Sync the Chain" to "Resolve the Wallet"

Today's mental model is wrong. Light wallets are treated as ignorant clients that must scan from genesis. But a wallet **already knows things**:

- Its viewing keys and diversifiers
- Prior scan results from past sessions
- Whether it's the same key used on another device
- The structure of its receivers

A novel engine doesn't ask "how do I scan faster?" It asks **"what's the minimum work to know my balance and be ready to spend?"** Then it does only that, and lazy-loads the rest.

---

### Phase 7: Persistent Decryption Cache (PDC)
**Effort: 1-2 weeks after custom scanner control. Expected improvement: 5-20x faster repeat scans/restores.**

**The insight:** Trial decryption is deterministic. For a given `(output_ciphertext, ivk)` pair, the result never changes. Yet today, every restore on a new device redoes the same `O(N × K)` work where N = chain outputs and K = wallet keys.

**The design:**
- Maintain a per-wallet on-device cache: `(network, protocol, block_hash, height, tx_index, output_index, output_hash, ivk_fingerprint) → DecryptResult`
- `DecryptResult` is a tiny enum: `NoMatch` | `Match { note_handle: u32 }`
- Store `NoMatch` entries exactly. A lossy Bloom filter can be used only as an advisory pre-check, never as authority to skip decryption.
- Store `Match` entries in a small encrypted SQLite table.
- Encrypt with a key derived from wallet-local secret material; never upload unencrypted cache data.
- Version with chain height + block hash and truncate on reorg.

**On rescan / restore on the same device:**
- Skip outputs whose exact cache key has a verified `NoMatch`.
- Verify outputs marked `Match` against current chain data.
- For unknown outputs: trial decrypt as normal, populate cache.

**Important dependency:** PDC is only useful once Zipher controls trial decryption. The current `scan_cached_blocks` path is a black box, so it cannot consult this cache before decrypting. PDC belongs after the custom scanner exists, or inside the custom scanner as it is built.

**Storage cost (back-of-napkin):**
- ~50M outputs on Zcash mainnet today
- Bloom filter at 1% false positive: ~1.2 bits/output → ~7.5 MB total
- Realistically per-wallet: only outputs in scanned ranges → ~1-3 MB

**Privacy:** PDC never leaves the device unencrypted. If multi-device sync is later added, the encrypted cache blob may reveal approximate wallet age/scan progress through blob size and update timing unless padded or uploaded through a privacy-preserving channel. That must be handled in the multi-device design, not hidden here.

**Why nobody has done this:** Wallet authors think of sync as a one-shot operation. Treating it as cumulative knowledge is a mental shift.

---

### Phase 8: SIMD Trial Decryption
**Status: research/performance spike. Effort unknown until prototype.**

**The insight:** `rayon` parallelizes across cores. But each core can do 4-16 field operations per cycle with SIMD. We're using 1/8th of available compute.

**Targets:**
- **ARM NEON** (all modern Android phones, Apple M-series) — 128-bit vectors
- **Apple AMX** (M1+) — wider matrix units, harder to use but enormous throughput
- **AVX2/AVX-512** (desktop CLI on Linux/Windows) — 256/512-bit vectors

**What to vectorize:**
- Field arithmetic in `jubjub` (Sapling) and `pallas` (Orchard) — multiplication, squaring, inversion
- ChaCha20 stream decryption (already SIMD-friendly, but verify the `chacha20` crate uses platform intrinsics)
- Blake2b hashing

**Implementation strategy:**
- First implement and benchmark rayon + batch affine normalization without SIMD.
- Spike whether the public `jubjub` / `pallas` / `ff` APIs expose enough internals for vectorized field arithmetic.
- If not, options are: upstream PRs, local forks of curve crates, or a dedicated Zipher field-arithmetic module.
- SIMD must be behind platform feature flags and differential tests against upstream scalar implementations.

**Combined with Phase 5 (batch affine):**
- Batch affine normalization → vectorized field inversion → SIMD multiply chains
- Stack the wins multiplicatively

**Reality check:** SIMD is possible, but not a core delivery promise. Rayon + batch affine is implementable today. SIMD is only pursued if benchmarks prove trial decryption remains the bottleneck and the curve APIs make it safe to implement.

---

### Phase 9: Multi-Server Bandwidth Aggregation
**Effort: 1 week. Expected improvement: 3-5x faster initial download on good networks.**

**The insight:** We have 5+ trustworthy lightwalletd servers (CipherScan, zec.rocks regions). Single-server download is artificial scarcity.

**The design:**
- Split scan range across servers: server A gets blocks 1-100K, B gets 100K-200K, etc.
- Each server runs an independent gRPC stream in parallel
- Aggregate bandwidth: 5 servers × 50 Mbps = 250 Mbps effective
- Hedged requests: critical small requests (latest tip, subtree roots) go to multiple servers, take first response

**Trust & verification:**
- Cross-check: sample 1% of blocks from a different server, verify hash match
- If mismatch: drop the deviant server, blacklist for the session
- Worst case: a malicious server can DOS or feed wrong blocks. Tree continuity validation catches this.

**Server discovery:**
- Built-in list (we already have it: CipherScan + 5 zec.rocks regions)
- Optional: well-known DNS-based discovery (`_lightwalletd._tcp.zcash.network`)
- User can add custom servers

**Why nobody has done this:** Light wallets historically had one configured server. The mental model is single-trust-anchor. But for *download* (vs trust), parallelism is free as long as you verify.

---

### Phase 10: Shielded Output Density Map (SODM)
**Effort: 1-2 weeks (Zipher infra side) + 2-3 days client. Expected improvement: faster scheduling and less wasted prefetch.**

**The insight:** ~99% of historical blocks contain zero shielded outputs (early Zcash) or all transparent (current era). Wallets download these blocks for nothing.

**The design:**
- Zipher infra publishes a signed, append-only manifest: `(height_range, sapling_output_count, orchard_action_count)` for every 1000-block range.
- Wallet downloads the manifest (small, <1MB total). This is public chain metadata and is identical for all users.
- Wallet uses the manifest as a **priority hint**: dense ranges first, empty-looking ranges later.
- The manifest is **not authoritative** for fund safety. A compromised or buggy manifest must not be able to make the wallet permanently skip a range that might contain funds.

**Privacy:** Manifest is public, identical for all users, and flows server → client. The wallet sends no addresses, viewing keys, txids, or "interesting ranges" to the density-map service.

**Trust:** Manifest signatures prove origin, not consensus truth. If unavailable, invalid, stale, or inconsistent with downloaded compact blocks, wallet falls back to normal scan ordering. For now, SODM is a scheduler input, not a correctness shortcut.

**Bonus:** Combined with Phase 9 (multi-server), wallets can use the same public priority map, reducing wasted prefetch while preserving a safe fallback path.

**Why nobody has done this:** Requires infrastructure investment. Most wallet teams don't run their own indexer. Zipher does (`cipherscan-rust`), making this almost free.

---

### Phase 11: Lazy Witness Construction
**Effort: 2-3 weeks. Expected improvement: 80% reduction in tree maintenance work for typical wallets.**

**The insight:** Today's wallets eagerly maintain a witness for every spendable note. But a wallet with 50 notes only needs witnesses when it actually spends -- which is maybe 1-2 notes per day for active users.

**The design:**
- Don't build full witnesses during scan. Just record `(commitment, position, height)` per discovered note.
- When user initiates a spend: build the witness on-demand from the cached subtree state + recent commitment additions
- Subtree roots from `zcash_client_backend` give us the anchor; we walk forward only as needed
- Witness building takes ~100-500ms per note vs hours-of-incremental-work upfront

**Tradeoff:** First spend is slightly slower. All subsequent operations are massively faster. For a wallet that rarely spends, this is a huge win.

**Why nobody has done this:** Witness eagerness is baked into `zcash_client_sqlite`'s shard tree. We'd need to either fork the tree management or build a parallel lazy structure. This is the most invasive of the novel phases.

---

### Phase 12: Encrypted Multi-Device Sync
**Effort: 2-3 weeks. Expected improvement: instant sync on second device.**

**The insight:** A user with phone + desktop wallet currently re-scans the entire chain on each device. They have the same keys; they should be able to share scan progress.

**The design:**
- Device A serializes its sync state: `{scanned_ranges, decryption_cache, found_notes_metadata}` (no spending keys)
- Encrypts with a key derived from the wallet seed (ChaCha20-Poly1305)
- Uploads to user-chosen storage: iCloud, Google Drive, S3, IPFS, or Zipher infra
- Device B downloads, decrypts with same seed, jumps to scanned state
- Both devices independently verify by spot-scanning random ranges

**Trust model:** Storage provider sees only encrypted blob. Even Zipher infra can't read it. Compromise of seed → compromise of cache, but seed compromise is already game-over.

**Privacy:** No leakage to network observers. Encrypted blob is small (few MB) and indistinguishable from random data.

**Why nobody has done this:** Wallet teams treat sync as device-local. Cross-device sync is solved at the seed level (BIP-39 backup) but not at the cache level. We're proposing cache-level sharing.

---

### Phase 13: Adaptive Resource Manager (ARM, no relation)
**Effort: 1 week. Expected improvement: better UX, longer battery life, no jank.**

**The insight:** Current sync just runs flat-out. On a phone, this means hot device, drained battery, janky UI. There's no awareness of context.

**The design:**
- Monitor: thermal state, battery level, charging status, network type (cellular vs wifi), foreground vs background
- Throttle worker pool size, batch frequency, and prefetch depth accordingly
- On charger + wifi + foreground: max workers, max prefetch
- On battery + cellular + background: 1 worker, no prefetch, gentle pace
- Surface state to UI: "Sync paused -- tap to resume" when device is hot

**Implementation:** iOS has thermal/battery APIs via Flutter plugins. Android has `BatteryManager`/`PowerManager`. Plumb to Rust engine via FFI.

**Why nobody has done this:** Wallets are usually built by crypto engineers, not mobile platform engineers. The "make it cooperative with the OS" mindset is rare.

---

---

# Part III: Working Roadmap (the actual plan)

The "parity vs novel" split above was a categorization aid, not a build plan. The working plan below is deliberately stricter: no server-provided hint is allowed to hide funds, no lossy cache is allowed to skip decryption, and no speculative SIMD work is promised before a prototype proves it.

| # | Increment | Effort | What's Inside | Risk |
|---|-----------|--------|---------------|------|
| 0 | **Benchmark Harness** | 2-3 days | Reproducible restore/catch-up/routine-sync benchmarks | Low |
| 1 | **Concurrent I/O + Multi-Server** | 1 week | Pipeline + verified multi-server fetching | Low |
| 2 | **Custom Scanner v1** | 2-3 weeks | Output-counted batches + rayon + batch affine | Medium |
| 3 | **Persistent Decryption Cache** | 1-2 weeks | Exact encrypted cache plugged into custom scanner | Low-medium |
| 4 | **Density Map as Priority Hint** | 1-2 weeks | Public signed manifest from Zipher infra, never authoritative | Low |
| 5 | **Smart Prioritization + Resource Manager** | 2 weeks | Tip-first scheduling + shard-aware ranges + mobile throttling | Low |
| 6 | **SIMD Trial Decryption** *(spike)* | Unknown | Prototype NEON/AVX/portable SIMD feasibility | Medium-high |
| 7 | **Multi-Device Sync** *(deferred)* | 2-3 weeks | Encrypted cache/sync-state sharing | Medium |
| 8 | **Lazy Witness Construction** *(research)* | Unknown | Possible upstream/fork work in shard tree logic | High |

## Increment Details

### Increment 0: Benchmark Harness
**Why first:** Without benchmarks, we are guessing. This creates the measurement bed for every later increment.

- Add CLI commands/scripts for repeatable benchmarks:
  - Initial restore from birthday
  - Old wallet with many transactions
  - Catch-up from 1,000 / 10,000 / 100,000 blocks behind
  - Routine sync from 1-3 blocks behind
- Record wall time, download time, scan time, enhancement time, peak memory, and time-to-spendable-balance.
- Use at least one small test wallet, one old busy wallet, and one large restore wallet.
- Current implementation starts with `zipher-cli sync benchmark`, a non-destructive benchmark command for the active wallet. It records starting/final heights, elapsed time, scanned blocks/second, sampled phases, enhancement queue size, and sync errors.

**Outcome:** A baseline and a pass/fail gate for every sync change.

### Increment 1: Concurrent I/O + Multi-Server Download
**Why first:** Highest impact-to-risk ratio. Pure network-layer changes, no scan engine changes. Already-known servers, already-trusted infra.

- Replace single sequential download with: Fetcher task spawns N gRPC streams across configured servers
- Bounded channel between Fetcher and Scanner (3 batches buffered)
- Validate block height/hash continuity before scanning.
- Cross-verify sampled ranges across servers, blacklist deviants for the session.
- Hedge critical small requests (latest tip, subtree roots) across all servers, take first response
- Existing `scan_cached_blocks` continues to handle the actual scanning unchanged

**Security model:** Servers never receive seeds, spending keys, viewing keys, addresses, or txids. A malicious server cannot steal funds or make the wallet sign a wrong transaction. It can try to delay sync, omit data, or feed a bad view of the chain. Mitigations are TLS, continuity checks, multi-server cross-checking, and fallback to a known-good server/full normal scan on mismatch.

**Outcome:** ~2x even on single-server (download/scan overlap), more on good networks when multiple servers are healthy.

### Increment 2: Custom Scanner v1
**Why second:** This is the real sync engine. It gives us control before adding PDC or deeper optimizations.

- Replace block-counted batches with output-counted batches.
- Add rayon worker pool for parallel trial decryption.
- Add batch affine normalization where APIs allow it.
- Initially keep `scan_cached_blocks` as the DB safety path when needed; only move to direct `WalletWrite` integration after differential tests prove equivalence.
- Differential-test custom scanner output against `scan_cached_blocks` on known wallets/ranges.

**Outcome:** A fast scanner that still preserves `zcash_client_sqlite` safety and lets us plug in PDC.

### Increment 3: Persistent Decryption Cache (PDC)
**Why third:** Once the scanner controls trial decryption, cache hits can safely skip repeated work.

- New on-device storage: encrypted SQLite table keyed by exact output identity + IVK fingerprint.
- No lossy negative cache for authoritative skips.
- Wallet checks cache before trial decrypting any output.
- Cache populates as scan progresses.
- Reorg-aware truncation by block hash/height.
- Optional encrypted backup to user-chosen storage (later integration with Increment 6)

**Outcome:** First sync improves only from Increment 2. Repeat scans/restores become much faster.

### Increment 4: Density Map as Priority Hint
**Why fourth:** Useful, but not fund-authoritative. Server work can run in parallel with client work.

- Add `density-map` endpoint to `cipherscan-rust` indexer.
- Manifest format: `(height_range, sapling_outputs, orchard_actions)` per 1000 blocks, signed by Zipher key.
- Wallet downloads manifest at sync start.
- Manifest is used to prioritize dense ranges and postpone empty-looking ranges.
- Manifest never permanently suppresses scanning unless a future cryptographic proof or independent verification scheme makes that safe.

**Outcome:** Faster perceived progress and smarter prefetching without trusting Zipher infra with correctness.

### Increment 5: Smart Prioritization + Adaptive Resource Manager
**Why fifth:** Once scan is fast, the next bottleneck is "scan the *right things first*" and "don't melt the phone."

- Chain-tip priority: scan latest shard first → spendable balance shows up in seconds
- Shard-aware range splitting: align batches with subtree boundaries → faster note-to-spendable time
- Resource manager: monitor thermal/battery/network, throttle workers accordingly
- Surface state to UI: "Sync paused — device hot" vs "Syncing fast — on charger + wifi"

**Outcome:** Spend-before-sync UX, no battery drain complaints, no thermal throttling complaints.

### Increment 6: SIMD Trial Decryption Spike
**Why a spike:** SIMD may require curve-crate internals we do not currently control.

- Prototype one narrow path (Sapling or Orchard trial decryption) with portable SIMD or platform intrinsics.
- Compare against scalar upstream implementation with property tests and known-chain vectors.
- If the prototype is not clearly faster and safe, do not ship SIMD.

**Outcome:** Decision point: upstream PR/fork/dedicated module, or leave scanner at rayon + batch affine.

### Increment 7: Multi-Device Sync (deferred)
**Why deferred:** Trust model needs careful design review. PDC (Increment 3) is the foundation -- once it's stable and proven, sharing it across devices is mostly serialization + encryption work.

- Serialize PDC + scanned-ranges + found-notes-metadata
- Encrypt with seed-derived key
- Upload to user-chosen storage
- Other device downloads, validates spot-checks, and resumes from imported state

### Increment 8: Lazy Witness Construction (research)
**Why last and tagged "research":** Highest risk -- touches `zcash_client_sqlite` shard tree internals. Save for after the rest is proven and we have benchmarks showing witness building is actually a bottleneck.

- Defer witness materialization until spend time
- Build from cached subtree state + recent commitments on-demand
- May require fork or PR to `zcash_client_sqlite`

## What Got Dropped

These ideas from the original plan are not part of the unified roadmap:

- **"Pre-screen + scan_cached_blocks" as a separate phase** — folded into Increment 4 as Stage 4a
- **Pure WarpSync math port (Phase 5 standalone)** — folded into Increment 4 as Stage 4b
- **Standalone rayon parallelism (Phase 3 alone)** — folded into Increment 4 as Stage 4a

The fused approach in Increment 4 is more honest: we build one scanner, not three.

## Realistic Cumulative Performance

If the core increments ship and stack:

- **Initial sync (new wallet, genesis to tip):** target 5-10x faster than today before SIMD
- **Wallet restore / repeat scan (PDC available):** target 10-20x+ faster, depending on cache coverage
- **Routine sync (1-3 blocks behind):** target 2-5x faster plus cleaner UI state
- **Time to first spendable balance:** seconds instead of minutes/hours
- **Network usage:** reduced by smarter scheduling and fewer redundant downloads

These are estimates. Real numbers come from benchmarking each phase.

## What This Becomes

Not "another fast Zcash sync engine." A research-grade contribution to private wallet design that the rest of the ecosystem could borrow from. Specifically:

1. **PDC and multi-device sync** could become a Zcash standard (ZIP proposal worth writing)
2. **SIMD trial decryption** improvements should be upstreamed to `sapling-crypto` and `orchard` crates
3. **Output Density Map** is a public good -- we could publish the manifest and let Zashi/ZODL use it too
4. **Multi-server aggregation** is a pattern other privacy wallets (Monero, etc.) could adopt

Zipher becomes the wallet that **redefined** what "fast Zcash sync" means -- not just by stealing tricks, but by proving that the whole sync model could be smarter.

---

## Honest Assessment

| Phase | Risk | Confidence |
|-------|------|------------|
| 1-6 | Low (proven techniques) | High |
| 7 (PDC) | Low (standard caching) | High |
| 8 (SIMD) | Medium (platform-specific) | Medium-high |
| 9 (Multi-server) | Low (engineering only) | High |
| 10 (Density Map) | Low (we operate the indexer) | High |
| 11 (Lazy Witness) | High (touches `zcash_client_sqlite` internals) | Medium |
| 12 (Multi-device) | Medium (trust model needs review) | Medium-high |
| 13 (ARM) | Low (platform APIs) | High |

**See "Part III: Unified Roadmap" above for the actual shipping plan.** The phase-by-phase risk assessment maps onto increments as follows:

- **Increment 1** (concurrent I/O + multi-server): Low risk — pure network layer
- **Increment 2** (density map): Low risk — additive, falls back to full scan
- **Increment 3** (PDC): Low risk — additive cache layer
- **Increment 4** (parallel SIMD scanner): Medium risk — replaces scan path, but pre-screen approach (Stage 4a) keeps `scan_cached_blocks` as a safety net
- **Increment 5** (prioritization + ARM): Low risk — UX layer
- **Increment 6** (multi-device): Medium risk — trust model review needed
- **Increment 7** (lazy witness): High risk — touches DB internals, save for last

Total effort: **~3-4 months for Increments 1-5** (the core engine). Increments 6-7 are bonus once the foundation is solid.

Within Increments 1-5, the first three weeks (Increment 1 + start of Increment 2) already make Zipher visibly faster than today and competitive with anything else.
