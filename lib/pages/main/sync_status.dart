import 'package:flutter/material.dart';

import '../../generated/intl/messages.dart';
import '../../store2.dart';
import '../../zipher_theme.dart';
import '../utils.dart';

class SyncStatusWidget extends StatefulWidget {
  SyncStatusState createState() => SyncStatusState();
}

class SyncStatusState extends State<SyncStatusWidget>
    with SingleTickerProviderStateMixin {
  var display = 0;

  @override
  void initState() {
    super.initState();
    Future(() async {
      try {
        await startAutoSync();
      } catch (e) {
        logger.e('Sync status init error: $e');
      }
    });
  }

  String getSyncText(int syncedHeight) {
    final s = S.of(context);
    if (!syncStatus2.connected) {
      if (syncStatus2.connectionError != null) {
        return 'Connection lost — retrying...';
      }
      return s.connectionError;
    }
    final latestHeight = syncStatus2.latestHeight;
    if (latestHeight == null) return '';

    if (syncStatus2.paused) return s.syncPaused;
    if (!syncStatus2.syncing && syncStatus2.isMaintaining) {
      final queue = syncStatus2.maintenanceQueueLen;
      if (queue > 0) return 'Recovering transaction details ($queue left)';
      return 'Recovering transaction details';
    }
    if (!syncStatus2.syncing) return '';

    final phase = syncStatus2.phase;
    // For sub-phases that are not block scanning, show their own copy
    // and skip the percentage rotation — those phases don't have meaningful
    // block-progress numbers.
    if (phase == 'refreshing_utxos') return 'Refreshing transparent funds';
    if (phase == 'updating_roots') return 'Updating wallet checkpoints';
    if (phase == 'enhancing') return 'Recovering transaction details';

    // Drive the user-facing percentage off block-progress so phase 1
    // (ChainTip pre-scan) and phase 2 (Historic fill) both move the bar.
    // Falls back to the height-based ETA when the engine hasn't reported
    // block totals yet (single-pass tip-following case).
    final blocksProgress = syncStatus2.blocksProgress;
    final blocksScanned = syncStatus2.blocksScanned;
    final blocksTotal = syncStatus2.blocksTotal;
    final etaProgress = syncStatus2.eta.progress;
    final percent = blocksProgress != null
        ? (blocksProgress * 100).round()
        : (etaProgress ?? 0);
    final remaining = blocksProgress != null
        ? (blocksTotal - blocksScanned)
        : syncStatus2.eta.remaining;

    switch (display % 3) {
      case 0:
        return 'Syncing $percent%';
      case 1:
        if (remaining != null && remaining > 0) {
          return '${_formatBlocks(remaining)} blocks remaining';
        }
        return 'Syncing $percent%';
      case 2:
        return syncStatus2.eta.timeRemaining;
    }
    return '';
  }

  String _formatBlocks(int n) {
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(0)}k';
    return '$n';
  }

  @override
  Widget build(BuildContext context) {
    final syncing = syncStatus2.syncing;
    final connected = syncStatus2.connected;
    final maintaining = syncStatus2.isMaintaining;
    final visible = syncing || !connected || maintaining;

    final syncedHeight = syncStatus2.syncedHeight;
    final text = visible ? getSyncText(syncedHeight) : '';
    // Prefer block-based progress (smooth across phase 1 and phase 2).
    // Fall back to height-based ETA progress if the engine hasn't reported
    // block totals yet.
    final value = syncing
        ? (syncStatus2.blocksProgress ??
            syncStatus2.eta.progress?.let((x) => x.toDouble() / 100.0))
        : null;

    return AnimatedSize(
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeInOut,
      alignment: Alignment.topCenter,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 200),
        opacity: visible ? 1.0 : 0.0,
        child: visible
            ? GestureDetector(
                onTap: _onSync,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          if (!connected)
                            Icon(Icons.cloud_off_outlined,
                                size: 14,
                                color: ZipherColors.red.withValues(alpha: 0.8))
                          else
                            SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(
                                strokeWidth: 1.5,
                                color: ZipherColors.text40,
                              ),
                            ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              text,
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w400,
                                color: !connected
                                    ? ZipherColors.red.withValues(alpha: 0.8)
                                    : ZipherColors.text40,
                              ),
                            ),
                          ),
                        ],
                      ),
                      if (syncing && value != null) ...[
                        const SizedBox(height: 8),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(ZipherRadius.xxs),
                          child: SizedBox(
                            height: 2,
                            child: LinearProgressIndicator(
                              value: value.clamp(0, 1),
                              backgroundColor:
                                  ZipherColors.cyan.withValues(alpha: 0.15),
                              valueColor: const AlwaysStoppedAnimation<Color>(
                                  ZipherColors.cyan),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              )
            : const SizedBox.shrink(),
      ),
    );
  }

  _onSync() {
    // If disconnected, tap = force-restart sync immediately (skip backoff)
    if (!syncStatus2.connected) {
      if (syncStatus2.paused) syncStatus2.paused = false;
      Future(() => syncStatus2.sync(restart: true));
      return;
    }
    if (syncStatus2.syncing) {
      setState(() {
        display = (display + 1) % 3;
      });
    } else {
      if (syncStatus2.paused) syncStatus2.paused = false;
      Future(() => syncStatus2.sync());
    }
  }
}
