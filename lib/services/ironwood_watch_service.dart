import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';

import 'app_log.dart';
import 'wallet_service.dart';
import '../src/rust/api/engine_api.dart' as engine;

final _log = createLogger();

/// Manages the Ironwood pool migration lifecycle using the official SDK
/// (`zcash_pool_migration` crate). The SDK handles denomination decomposition,
/// preparation transactions, PCZT signing, and state persistence in the wallet DB.
///
/// This service only needs to:
/// 1. Call `commit()` once to start the migration
/// 2. Call `tick()` periodically to prove+broadcast due transactions
/// 3. Call `status()` to read progress
class IronwoodWatchService {
  IronwoodWatchService._();
  static final instance = IronwoodWatchService._();

  static const _prefTor = 'ironwood_tor_enabled';
  static const _tickInterval = Duration(seconds: 75);

  Timer? _timer;
  bool _ticking = false;
  bool _walletReady = false;

  engine.IronwoodSdkProgress? _lastProgress;

  Future<void> start() async {
    _log.i('[Ironwood] watch service started');
  }

  Future<void> onWalletReady() async {
    _walletReady = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedTor = prefs.getBool(_prefTor) ?? false;
      if (savedTor) {
        try {
          final dataDir = await WalletService.instance.walletDir();
          await engine.engineEnableTor(dataDir: dataDir);
          _log.i('[Ironwood] Tor re-enabled from saved preference');
        } catch (e) {
          _log.w('[Ironwood] Tor re-enable failed: $e');
        }
      }
    } catch (e) {
      _log.w('[Ironwood] onWalletReady prefs error: $e');
    }

    await _resumeIfActive();
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _log.i('[Ironwood] watch service stopped');
  }

  void onAppResumed() {
    if (_walletReady) {
      _resumeIfActive();
    }
  }

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  bool get isRoundInProgress => _ticking;
  void markRoundStarted() => _ticking = true;
  void markRoundEnded() => _ticking = false;

  engine.IronwoodSdkProgress? get progress => _lastProgress;

  bool get isAutoMigrationActive {
    final p = _lastProgress;
    if (p == null) return false;
    return p.status == 'committed' || p.status == 'in_progress';
  }

  /// Plan a migration (preview only, not committed).
  Future<engine.IronwoodSdkPlan> planMigration() async {
    final seed = await WalletService.instance.getSeedPhrase();
    if (seed == null) throw Exception('Cannot access seed');
    return engine.engineIronwoodSdkPlan(seedPhrase: seed);
  }

  /// Commit the migration: plans, builds and signs all PCZTs in one pass.
  /// After this, call tick() periodically.
  Future<engine.IronwoodSdkProgress> commitMigration() async {
    final seed = await WalletService.instance.getSeedPhrase();
    if (seed == null) throw Exception('Cannot access seed');

    _log.i('[Ironwood] calling SDK commit...');
    final result = await engine.engineIronwoodSdkCommit(seedPhrase: seed);
    _lastProgress = result;
    _log.i('[Ironwood] committed: ${_fmtProgress(result)}');

    _startTickLoop();
    return result;
  }

  /// Cancel an in-progress migration.
  Future<void> cancelMigration() async {
    _timer?.cancel();
    _timer = null;
    await engine.engineIronwoodSdkCancel();
    _lastProgress = null;
    _log.i('[Ironwood] migration cancelled');
  }

  /// Read-only status refresh.
  Future<engine.IronwoodSdkProgress> refreshStatus() async {
    final result = await engine.engineIronwoodSdkStatus();
    _lastProgress = result;
    _log.d('[Ironwood] refreshStatus: ${_fmtProgress(result)}');
    return result;
  }

  // ---------------------------------------------------------------------------
  // Internal
  // ---------------------------------------------------------------------------

  Future<void> _resumeIfActive() async {
    try {
      final status = await engine.engineIronwoodSdkStatus();
      _lastProgress = status;

      if (status.status == 'committed' || status.status == 'in_progress') {
        _log.i('[Ironwood] resuming: ${_fmtProgress(status)}');
        _startTickLoop();
      } else {
        _log.d('[Ironwood] not resuming, status=${status.status}');
      }
    } catch (e) {
      _log.d('[Ironwood] no active migration: $e');
    }
  }

  void _startTickLoop() {
    _timer?.cancel();
    _timer = Timer.periodic(_tickInterval, (_) => _doTick());
    // Also fire immediately
    _doTick();
  }

  Future<void> _doTick() async {
    if (_ticking) return;
    _ticking = true;

    try {
      final seed = await WalletService.instance.getSeedPhrase();
      if (seed == null) {
        _log.w('[Ironwood] tick: cannot access seed');
        return;
      }

      _log.d('[Ironwood] tick: calling SDK...');
      final result = await engine.engineIronwoodSdkTick(seedPhrase: seed);
      _lastProgress = result;

      _log.i('[Ironwood] tick result: ${_fmtProgress(result)}');

      if (result.status == 'complete') {
        _timer?.cancel();
        _timer = null;
        _log.i('[Ironwood] migration complete!');
      }
    } catch (e) {
      final msg = e.toString();
      if (msg.contains('No transfer in progress')) {
        _timer?.cancel();
        _timer = null;
        _lastProgress = null;
        _log.d('[Ironwood] tick: no transfer in progress, stopping timer');
      } else {
        _log.w('[Ironwood] tick error: $e');
      }
    } finally {
      _ticking = false;
    }
  }

  static String _fmtProgress(engine.IronwoodSdkProgress p) {
    final zec = BigInt.from(100000000);
    final crossings = p.crossingValues.map((v) => '${v ~/ zec}.${(v % zec).toString().padLeft(8, '0')}').join(', ');
    return 'status=${p.status} '
        'txs=${p.confirmedCount}/${p.totalTxCount} '
        'broadcast=${p.broadcastCount} '
        'planned=${p.totalPlannedZat ~/ zec}.${(p.totalPlannedZat % zec).toString().padLeft(8, '0')}ZEC '
        'confirmed=${p.totalConfirmedZat ~/ zec}.${(p.totalConfirmedZat % zec).toString().padLeft(8, '0')}ZEC '
        'nextDueH=${p.nextDueHeight} '
        'fees=${p.feesPaidZat}zat '
        'crossings=[$crossings]';
  }
}
