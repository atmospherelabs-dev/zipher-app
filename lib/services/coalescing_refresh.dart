import 'dart:async';

/// Collapses bursts into one refresh and permits one trailing refresh when
/// changes arrive during I/O. At most one callback runs at any time.
class CoalescingRefresh {
  final Future<void> Function() refresh;
  Future<void>? _running;
  bool _dirty = false;
  bool _disposed = false;
  CoalescingRefresh(this.refresh);

  Future<void> request() {
    if (_disposed) return Future.value();
    _dirty = true;
    return _running ??= Future<void>(() async {
      try {
        while (_dirty && !_disposed) {
          _dirty = false;
          await refresh();
        }
      } finally {
        _running = null;
      }
    });
  }

  void dispose() {
    _disposed = true;
    _dirty = false;
  }
}
