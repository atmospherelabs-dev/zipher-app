import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:timeago/timeago.dart' as timeago;

import '../../generated/intl/messages.dart';
import '../../store2.dart';
import '../../zipher_theme.dart';
import '../utils.dart';

class SyncStatusWidget extends StatefulWidget {
  SyncStatusState createState() => SyncStatusState();
}

class SyncStatusState extends State<SyncStatusWidget> {
  var display = 0;

  @override
  void initState() {
    super.initState();
    Future(() async {
      try {
        await syncStatus2.update();
        await startAutoSync();
      } catch (e) {
        logger.e('Sync status init error: $e');
      }
    });
  }

  String getSyncText(int syncedHeight) {
    final s = S.of(context);
    if (!syncStatus2.connected) return s.connectionError;
    final latestHeight = syncStatus2.latestHeight;
    if (latestHeight == null) return '';

    if (syncStatus2.paused) return s.syncPaused;
    if (!syncStatus2.syncing) return '';

    final timestamp = syncStatus2.timestamp?.let(timeago.format) ?? s.na;
    final downloadedSize = syncStatus2.downloadedSize;
    final trialDecryptionCount = syncStatus2.trialDecryptionCount;

    final remaining = syncStatus2.eta.remaining;
    final percent = syncStatus2.eta.progress;
    final downloadedSize2 = NumberFormat.compact().format(downloadedSize);
    final trialDecryptionCount2 =
        NumberFormat.compact().format(trialDecryptionCount);

    switch (display) {
      case 0:
        return 'Syncing $syncedHeight / $latestHeight';
      case 1:
        final m = syncStatus2.isRescan ? s.rescan : s.catchup;
        return '$m $percent%';
      case 2:
        return remaining != null ? '$remaining remaining' : '';
      case 3:
        return timestamp;
      case 4:
        return '${syncStatus2.eta.timeRemaining}';
      case 5:
        return '\u{2193} $downloadedSize2';
      case 6:
        return '\u{2192} $trialDecryptionCount2';
    }
    throw Exception('Unreachable');
  }

  @override
  Widget build(BuildContext context) {
    final syncing = syncStatus2.syncing;
    final connected = syncStatus2.connected;

    // Hidden when fully synced and connected — clean Phantom-style
    if (!syncing && connected) return const SizedBox.shrink();

    final syncedHeight = syncStatus2.syncedHeight;
    final text = getSyncText(syncedHeight);
    final value = syncStatus2.eta.progress?.let((x) => x.toDouble() / 100.0);

    return GestureDetector(
      onTap: _onSync,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
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
            // Subtle progress bar
            if (syncing && value != null) ...[
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: SizedBox(
                  height: 2,
                  child: LinearProgressIndicator(
                    value: value.clamp(0, 1),
                    backgroundColor: ZipherColors.cyan.withValues(alpha: 0.15),
                    valueColor: const AlwaysStoppedAnimation<Color>(
                        ZipherColors.cyan),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  _onSync() {
    if (syncStatus2.syncing) {
      setState(() {
        display = (display + 1) % 7;
      });
    } else {
      if (syncStatus2.paused) syncStatus2.setPause(false);
      Future(() => syncStatus2.sync(false));
    }
  }
}
