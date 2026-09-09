import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:zipher/services/coalescing_refresh.dart';

void main() {
  test('event burst produces one database refresh', () async {
    var reads = 0;
    final queue = CoalescingRefresh(() async {
      reads++;
    });
    await Future.wait(List.generate(100, (_) => queue.request()));
    expect(reads, 1);
  });
  test('events during I/O produce one trailing read, never overlap', () async {
    var reads = 0;
    var concurrent = 0;
    final started = Completer<void>();
    final release = Completer<void>();
    final queue = CoalescingRefresh(() async {
      concurrent++;
      expect(concurrent, 1);
      reads++;
      if (reads == 1) {
        started.complete();
        await release.future;
      }
      concurrent--;
    });
    final first = queue.request();
    await started.future;
    final rest = List.generate(100, (_) => queue.request());
    release.complete();
    await Future.wait([first, ...rest]);
    expect(reads, 2);
  });
  test('failed read can be retried', () async {
    var reads = 0;
    final queue = CoalescingRefresh(() async {
      if (++reads == 1) throw StateError('offline');
    });
    await expectLater(queue.request(), throwsStateError);
    await queue.request();
    expect(reads, 2);
  });
  test('disposed wallet has no trailing refresh', () async {
    var reads = 0;
    final started = Completer<void>();
    final release = Completer<void>();
    final queue = CoalescingRefresh(() async {
      reads++;
      started.complete();
      await release.future;
    });
    final first = queue.request();
    await started.future;
    queue.request();
    queue.dispose();
    release.complete();
    await first;
    await queue.request();
    expect(reads, 1);
  });
}
