# Wallet restore start heights

A remembered date (year, month or exact day) maps to a block height through a
table of **observed** mainnet heights: the first block of every UTC month since
Sapling activation (`lib/services/restore_checkpoints.dart`, from verified
canonical chain records retrieved 2026-11-23). Scanning starts at the beginning
of the month *before* the chosen month, so a misremembered date or a timezone
edge can't skip early payments. Zipher still never converts a date using an
assumed 75- or 25-second block time: production is variable and such an
estimate can skip the wallet's first payments, particularly across NU7 (which
halved the block time in November 2026, visible in the table). Dates before the
table, testnet, and "Not sure" use full history; dates after the table use its
last month. An explicit block height always wins. Refresh the table with each
release (one `SELECT` of the first block height per UTC month).

The existing Rust restore API now treats birthday `0` as full supported shielded
history. It uses the selected network's Sapling activation from the linked
protocol library, fetching the tree state immediately **before** activation so
the first Sapling block is scanned. This applies to seed and viewing-key restore.
New-wallet creation keeps its separate `0` = current-tip behavior.

No tree state is requested from the server for an anchor before Sapling: every
shielded tree is empty there by definition, so the engine builds that chain state
locally and fetches only the anchor block's hash (`GetBlock`). Zebra-backed
lightwalletd servers reject `GetTreeState` at pre-Sapling heights
("z_gettreestate did not return treestate"), which made every full-history
restore fail on them (fixed 2026-11-23). Restore failures are shown as a short
sentence; the raw engine error goes to the debug log only.

An explicit positive restore height retains the existing API meaning: it is the
prior tree-state anchor, and scanning begins with the following block. Choose an
anchor before the first expected payment. Explicit anchors are never advanced to
Sapling activation; the existing transparent UTXO/history recovery is unchanged.
No network activation heights or block-spacing schedules are copied into Dart.

The restore screen asks "When did you start using it?" with year chips, an
optional month row, an exact-date picker and a block-height option, and states
where scanning will start.
