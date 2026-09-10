import 'dart:collection';
import 'package:flutter/foundation.dart';
import 'package:logger/logger.dart';

class AppLog extends ChangeNotifier {
  AppLog._();
  static final AppLog instance = AppLog._();

  static const int _maxEntries = 2000;
  final _entries = Queue<LogEntry>();

  List<LogEntry> get entries => _entries.toList();

  void add(Level level, String message) {
    final clean = sanitize(message);
    if (clean.isEmpty) return;
    _entries.addLast(LogEntry(DateTime.now(), level, clean));
    while (_entries.length > _maxEntries) {
      _entries.removeFirst();
    }
    notifyListeners();
  }

  static String sanitize(String message) => message
      .replaceAll(RegExp(r'\x1B\[[0-?]*[ -/]*[@-~]'), '')
      .replaceAll(RegExp(r'\[38;5;\d+m|\[0m'), '')
      .split('Stack backtrace:')
      .first
      .replaceAllMapped(RegExp(r'https?://[^\s\)]+'),
          (m) => Uri.tryParse(m[0]!)?.host ?? '[endpoint]')
      .replaceAll(RegExp(r'\b0x[0-9a-fA-F]{40,}\b'), '[address]')
      .replaceAll(
          RegExp(r'\b(?:u1|utest1|zs1|bc1|tb1|t1|t3)[a-zA-Z0-9]{20,}\b'),
          '[address]')
      .replaceAll(RegExp(r'\b[A-Za-z0-9]{43,}\b'), '[identifier]')
      .replaceAll(RegExp(r'\[(?:T|D|I|W|E|F)\]\s*'), '')
      .trim();

  void event(String scope, String action, {String? detail, Object? error}) {
    add(error == null ? Level.info : Level.warning,
        '[$scope] $action${detail == null ? '' : ' $detail'}${error == null ? '' : ' error=${sanitize(error.toString())}'}');
  }

  void clear() {
    _entries.clear();
    notifyListeners();
  }
}

class LogEntry {
  final DateTime time;
  final Level level;
  final String message;
  const LogEntry(this.time, this.level, this.message);
}

/// Log filter that works in both debug and release builds.
/// In debug mode: show everything (debug+).
/// In release mode: show info+ (skip trace/debug noise).
class _AlwaysOnFilter extends LogFilter {
  @override
  bool shouldLog(LogEvent event) {
    if (kReleaseMode) {
      return event.level.index >= Level.info.index;
    }
    return event.level.index >= Level.debug.index;
  }
}

/// Shared output that captures log lines into the in-app ring buffer.
final _appLogOutput = _RingBufferOutput();

class _RingBufferOutput extends LogOutput {
  @override
  void output(OutputEvent event) {
    final message = event.lines
        .where((line) =>
            !line.trimLeft().startsWith('┌') &&
            !line.trimLeft().startsWith('├') &&
            !line.trimLeft().startsWith('└'))
        .map((line) => line.replaceFirst(RegExp(r'^\s*│ ?'), ''))
        .join('\n');
    AppLog.instance.add(event.level, message);
  }
}

/// Create a Logger that outputs to both the console and the in-app ring buffer.
/// Uses [_AlwaysOnFilter] so logs work in release/TestFlight builds.
Logger createLogger() {
  return Logger(
    filter: _AlwaysOnFilter(),
    printer: SimplePrinter(printTime: false, colors: false),
    output: MultiOutput([ConsoleOutput(), _appLogOutput]),
  );
}
