import 'dart:collection';
import 'package:flutter/foundation.dart';
import 'package:logger/logger.dart';

class AppLog {
  AppLog._();
  static final AppLog instance = AppLog._();

  static const int _maxEntries = 2000;
  final _entries = Queue<LogEntry>();

  List<LogEntry> get entries => _entries.toList();

  void add(Level level, String message) {
    _entries.addLast(LogEntry(DateTime.now(), level, message));
    while (_entries.length > _maxEntries) {
      _entries.removeFirst();
    }
  }

  void clear() => _entries.clear();
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
    final level = event.level;
    for (final line in event.lines) {
      final trimmed = line.trimLeft();
      if (trimmed.isEmpty) continue;
      if (trimmed.startsWith('┌') ||
          trimmed.startsWith('├') ||
          trimmed.startsWith('└') ||
          trimmed.startsWith('───')) continue;
      var clean = trimmed;
      if (clean.startsWith('│ ')) clean = clean.substring(2);
      if (clean.startsWith('│')) clean = clean.substring(1);
      if (clean.trim().isEmpty) continue;
      AppLog.instance.add(level, clean);
    }
  }
}

/// Create a Logger that outputs to both the console and the in-app ring buffer.
/// Uses [_AlwaysOnFilter] so logs work in release/TestFlight builds.
Logger createLogger() {
  return Logger(
    filter: _AlwaysOnFilter(),
    printer: SimplePrinter(printTime: false),
    output: MultiOutput([ConsoleOutput(), _appLogOutput]),
  );
}
