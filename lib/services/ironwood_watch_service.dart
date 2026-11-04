import 'dart:async';

import 'network_privacy.dart';

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

  // Polling cadence is independent of the consensus block spacing. The SDK
  // determines due heights; this remains responsive with 25-second blocks.
  static const _tickInterval = Duration(seconds: 25);

  Timer? _timer;
  bool _ticking = false;
  bool _walletReady = false;
  int _generation = 0;

  engine.IronwoodSdkProgress? _lastProgress;

  Future<void> start() async {
    _log.i('[Ironwood] watch service started');
  }

  Future<void> onWalletReady() async {
    final generation = ++_generation;
    _walletReady = false;
    await NetworkPrivacy.instance.ensureReady();
    if (generation != _generation) return;
    _walletReady = true;
    await _resumeIfActive();
  }

  void stop() {
    _generation++;
    _walletReady = false;
    _lastProgress = null;
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
    return p.status == 'committed' ||
        p.status == 'in_progress' ||
        p.status == 'paused_by_upgrade' ||
        p.status == 'upgrade_review_required';
  }

  /// Plan a migration (preview only, not committed).
  Future<engine.IronwoodSdkPlan> planMigration() async {
    return WalletService.instance.planMigration();
  }

  /// Commit the migration: plans, builds and signs all PCZTs in one pass.
  /// After this, call tick() periodically.
  Future<engine.IronwoodSdkProgress> commitMigration({
    required int expectedRevision,
    required String expectedWalletId,
    required bool expectedTestnet,
  }) async {
    final generation = _generation;
    _log.i('[Ironwood] calling SDK commit...');
    final result = await WalletService.instance.commitMigration(
        expectedRevision: expectedRevision,
        expectedWalletId: expectedWalletId,
        expectedTestnet: expectedTestnet);
    if (generation != _generation)
      throw StateError('Wallet changed during migration.');
    _lastProgress = result;
    _log.i('[Ironwood] committed: ${_fmtProgress(result)}');

    _startTickLoop();
    return result;
  }

  /// Cancel an in-progress migration.
  Future<void> cancelMigration() async {
    final generation = _generation;
    await WalletService.instance.cancelMigration();
    if (generation != _generation)
      throw StateError('Wallet changed during migration.');
    _timer?.cancel();
    _timer = null;
    _lastProgress = null;
    _log.i('[Ironwood] migration cancelled');
  }

  /// Read-only status refresh.
  Future<engine.IronwoodSdkProgress> refreshStatus() async {
    final generation = _generation;
    final result = await engine.engineIronwoodSdkStatus();
    if (generation != _generation)
      throw StateError('Wallet changed during migration.');
    _lastProgress = result;
    _log.d('[Ironwood] refreshStatus: ${_fmtProgress(result)}');
    return result;
  }

  // ---------------------------------------------------------------------------
  // Internal
  // ---------------------------------------------------------------------------

  Future<void> _resumeIfActive() async {
    final generation = _generation;
    try {
      final status = await engine.engineIronwoodSdkStatus();
      if (generation != _generation || !_walletReady) return;
      _lastProgress = status;

      if (status.status == 'committed' ||
          status.status == 'in_progress' ||
          status.status == 'paused_by_upgrade' ||
          status.status == 'upgrade_review_required') {
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
    if (_ticking || !_walletReady || WalletService.instance.isBusy) return;
    _ticking = true;
    final generation = _generation;

    try {
      _log.d('[Ironwood] tick: calling SDK...');
      final result = await WalletService.instance.tickMigration();
      if (generation != _generation || !_walletReady) return;
      _lastProgress = result;

      _log.i('[Ironwood] tick result: ${_fmtProgress(result)}');

      if (result.status == 'complete' ||
          result.status == 'stopped_by_upgrade') {
        _timer?.cancel();
        _timer = null;
        _log.i('[Ironwood] automatic migration stopped: ${result.status}');
      }
    } catch (e) {
      if (generation != _generation || !_walletReady) return;
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
    final crossings = p.crossingValues
        .map((v) => '${v ~/ zec}.${(v % zec).toString().padLeft(8, '0')}')
        .join(', ');
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
