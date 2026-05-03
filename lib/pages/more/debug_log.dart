import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:logger/logger.dart';

import '../../services/app_log.dart';
import '../../store2.dart';
import '../../zipher_theme.dart';

class DebugLogPage extends StatefulWidget {
  const DebugLogPage({super.key});

  @override
  State<DebugLogPage> createState() => _DebugLogPageState();
}

class _DebugLogPageState extends State<DebugLogPage> {
  final _scrollController = ScrollController();
  bool _autoScroll = true;
  Level _minLevel = Level.debug;

  List<LogEntry> get _filtered =>
      AppLog.instance.entries.where((e) => e.level.index >= _minLevel.index).toList();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    if (_autoScroll && _scrollController.hasClients) {
      _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
    }
  }

  @override
  Widget build(BuildContext context) {
    final entries = _filtered;
    final syncPhase = syncStatus2.phase;
    final syncedH = syncStatus2.syncedHeight;
    final latestH = syncStatus2.latestHeight ?? 0;
    final connected = syncStatus2.connected;
    final error = syncStatus2.connectionError;
    final queueLen = syncStatus2.maintenanceQueueLen;

    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());

    return Scaffold(
      backgroundColor: ZipherColors.bg,
      appBar: AppBar(
        backgroundColor: ZipherColors.bg,
        title: const Text('Debug Log', style: TextStyle(fontSize: 16)),
        actions: [
          PopupMenuButton<Level>(
            icon: Icon(Icons.filter_list, color: ZipherColors.text60, size: 20),
            onSelected: (level) => setState(() => _minLevel = level),
            itemBuilder: (_) => [
              for (final l in [Level.trace, Level.debug, Level.info, Level.warning, Level.error])
                PopupMenuItem(value: l, child: Text(_levelName(l))),
            ],
          ),
          IconButton(
            icon: Icon(Icons.copy, color: ZipherColors.text60, size: 20),
            onPressed: () {
              final text = entries.map((e) =>
                '${_ts(e.time)} [${_levelTag(e.level)}] ${e.message}').join('\n');
              Clipboard.setData(ClipboardData(text: text));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Log copied to clipboard')),
              );
            },
          ),
          IconButton(
            icon: Icon(Icons.delete_outline, color: ZipherColors.text60, size: 20),
            onPressed: () {
              AppLog.instance.clear();
              setState(() {});
            },
          ),
          IconButton(
            icon: Icon(Icons.refresh, color: ZipherColors.text60, size: 20),
            onPressed: () => setState(() {}),
          ),
        ],
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            color: ZipherColors.cardBg,
            child: DefaultTextStyle(
              style: TextStyle(
                fontFamily: 'JetBrains Mono',
                fontSize: 11,
                color: ZipherColors.text60,
                height: 1.5,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Icon(
                      connected ? Icons.cloud_done_outlined : Icons.cloud_off_outlined,
                      size: 14,
                      color: connected ? ZipherColors.green : ZipherColors.red,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      connected ? 'Connected' : 'Disconnected',
                      style: TextStyle(
                        color: connected ? ZipherColors.green : ZipherColors.red,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text('phase: $syncPhase'),
                  ]),
                  const SizedBox(height: 4),
                  Text('height: $syncedH / $latestH   queue: $queueLen'),
                  if (error != null) ...[
                    const SizedBox(height: 4),
                    Text('error: $error',
                        style: TextStyle(color: ZipherColors.red, fontSize: 10)),
                  ],
                ],
              ),
            ),
          ),
          Expanded(
            child: entries.isEmpty
                ? Center(
                    child: Text('No log entries',
                        style: TextStyle(color: ZipherColors.text40)))
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    itemCount: entries.length,
                    itemBuilder: (context, index) {
                      final e = entries[index];
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 1),
                        child: Text(
                          '${_ts(e.time)} ${_levelTag(e.level)} ${e.message}',
                          style: TextStyle(
                            fontFamily: 'JetBrains Mono',
                            fontSize: 10,
                            height: 1.4,
                            color: _levelColor(e.level),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  String _ts(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}';

  String _levelTag(Level l) {
    switch (l) {
      case Level.trace: return 'TRC';
      case Level.debug: return 'DBG';
      case Level.info: return 'INF';
      case Level.warning: return 'WRN';
      case Level.error: return 'ERR';
      case Level.fatal: return 'FTL';
      default: return '???';
    }
  }

  String _levelName(Level l) {
    switch (l) {
      case Level.trace: return 'Trace';
      case Level.debug: return 'Debug';
      case Level.info: return 'Info';
      case Level.warning: return 'Warning';
      case Level.error: return 'Error';
      default: return l.name;
    }
  }

  Color _levelColor(Level l) {
    switch (l) {
      case Level.error:
      case Level.fatal:
        return ZipherColors.red;
      case Level.warning:
        return ZipherColors.orange;
      case Level.info:
        return ZipherColors.cyan;
      default:
        return ZipherColors.text40;
    }
  }
}
