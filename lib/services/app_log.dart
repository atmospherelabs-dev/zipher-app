import 'dart:collection';
import 'package:logger/logger.dart';

class AppLog {
  AppLog._();
  static final AppLog instance = AppLog._();

  static const int _maxEntries = 500;
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

class AppLogOutput extends LogOutput {
  @override
  void output(OutputEvent event) {
    final level = event.level;
    for (final line in event.lines) {
      // ignore the box-drawing frames from PrettyPrinter
      if (line.startsWith('│') ||
          line.startsWith('├') ||
          line.startsWith('└') ||
          line.startsWith('┌') ||
          line.isEmpty) continue;
      AppLog.instance.add(level, line);
    }
  }
}
