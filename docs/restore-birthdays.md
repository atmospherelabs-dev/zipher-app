# Wallet restore start heights

Date-only restoration uses a full history scan. Zipher does not convert a date
into a block height using an assumed 75- or 25-second block time: production is
variable and such an estimate can skip the wallet's first payments, particularly
across NU7. This costs more scan time. Enter a known earlier block height when a
shorter recovery scan is needed.

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

An authoritative local date-to-height map can restore date-based acceleration in
a later change. The current UI states that a date-only restore scans full history.
