import 'package:flutter_test/flutter_test.dart';
import 'package:logger/logger.dart';
import 'package:zipher/services/app_log.dart';

void main() {
  setUp(() => AppLog.instance.clear());
  test('copied logs remove ANSI, backtraces and private request identifiers',
      () {
    final message =
        '\u001b[38;5;208m[W]\u001b[0m download timeout range=100..500\n'
        'rpc=https://example.com/private-api-key address=0x${'a' * 40}\n'
        'Stack backtrace:\n0: noise';
    final clean = AppLog.sanitize(message);
    expect(clean, contains('range=100..500'));
    expect(clean, isNot(contains('208m')));
    expect(clean, isNot(contains('private-api-key')));
    expect(clean, isNot(contains('a' * 40)));
    expect(clean, isNot(contains('backtrace')));
  });
  test('logs notify the debug view and preserve action outcomes', () {
    var updates = 0;
    void listener() {
      updates++;
    }

    AppLog.instance.addListener(listener);
    AppLog.instance.event('chat', 'command', detail: 'command=receive');
    AppLog.instance
        .event('balance', 'refresh_failed', error: StateError('timeout'));
    expect(updates, 2);
    expect(AppLog.instance.entries.last.level, Level.warning);
    expect(AppLog.instance.entries.first.message, contains('command=receive'));
    AppLog.instance.removeListener(listener);
  });
  test('logger capture does not fill the ring with backtrace lines', () {
    createLogger().w('timeout\nStack backtrace:\n0: noise\n1: noise');
    expect(AppLog.instance.entries.length, 1);
    expect(AppLog.instance.entries.single.message, 'timeout');
  });
}
