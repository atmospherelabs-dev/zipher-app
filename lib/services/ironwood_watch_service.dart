import 'dart:async';

import '../store2.dart';
import 'app_log.dart';

final _log = createLogger();

/// Periodically checks if Ironwood transfer parts are due for broadcast
/// and advances the schedule. Called on app foreground and via periodic timer.
class IronwoodWatchService {
  IronwoodWatchService._();
  static final instance = IronwoodWatchService._();

  Timer? _timer;
  bool _ticking = false;

  void start() {
    if (_timer != null) return;
    _timer = Timer.periodic(const Duration(minutes: 5), (_) => tick());
    _log.i('[Ironwood] watch service started');
    tick();
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _log.i('[Ironwood] watch service stopped');
  }

  void onAppResumed() => tick();

  Future<void> tick() async {
    if (_ticking) return;
    _ticking = true;
    try {
      final height = syncStatus2.syncedHeight;

      _log.d('[Ironwood] tick at height $height');
    } catch (e) {
      _log.w('[Ironwood] tick error: $e');
    } finally {
      _ticking = false;
    }
  }
}
