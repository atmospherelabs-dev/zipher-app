import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:shared_preferences/shared_preferences.dart';

import '../accounts.dart';
import '../store2.dart';
import 'app_log.dart';
import 'wallet_service.dart';
import '../src/rust/api/engine_api.dart' as engine;

final _log = createLogger();

class IronwoodWatchService {
  IronwoodWatchService._();
  static final instance = IronwoodWatchService._();

  static const _prefTor = 'ironwood_tor_enabled';
  static const _prefAuto = 'ironwood_auto_migration';
  static const _stateFile = 'ironwood_auto_migration.json';

  Timer? _timer;
  bool _ticking = false;
  bool _walletReady = false;

  AutoMigrationState? _state;

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

  AutoMigrationState? get state => _state;

  bool get isAutoMigrationActive {
    final s = _state;
    if (s == null) return false;
    return s.phase == AutoPhase.migrating;
  }

  Future<AutoMigrationState> startAutoMigration({
    required int orchardBalanceZat,
    required bool torEnabled,
  }) async {
    final denominations = _planSplits(orchardBalanceZat);
    if (denominations.isEmpty) {
      throw Exception('Balance too low to migrate');
    }

    final delays = _generateBroadcastSchedule(denominations.length);
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;

    _state = AutoMigrationState(
      phase: AutoPhase.migrating,
      originalBalanceZat: orchardBalanceZat,
      targets: denominations.map((d) => MigrationTarget(
        denominationZat: d,
        status: TargetStatus.pending,
      )).toList(),
      broadcastDelays: delays,
      nextBroadcastIdx: 0,
      nextBroadcastAt: now + delays[0].round(),
      torEnabled: torEnabled,
      totalFeesZat: 0,
      createdAt: now,
    );

    await _saveState();

    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefAuto, true);

    _log.i('[Ironwood] auto migration started: ${_state!.targets.length} rounds planned');
    _scheduleMigrationBroadcast();
    return _state!;
  }

  Future<void> cancelAutoMigration() async {
    _timer?.cancel();
    _timer = null;
    _state = null;

    try {
      final dataDir = await WalletService.instance.walletDir();
      final file = File('$dataDir/$_stateFile');
      if (await file.exists()) await file.delete();
    } catch (_) {}

    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefAuto, false);
    _log.i('[Ironwood] auto migration cancelled');
  }

  Future<AutoMigrationState?> refreshStatus() async {
    if (!_walletReady) return null;
    await _loadState();
    return _state;
  }

  // ---------------------------------------------------------------------------
  // Split planning
  // ---------------------------------------------------------------------------

  static const List<int> _buckets = [
    500000000000, 200000000000, 100000000000,
    50000000000, 20000000000, 10000000000,
    5000000000, 2000000000, 1000000000,
    500000000, 200000000, 100000000,
    50000000, 20000000, 10000000,
    5000000, 2000000, 1000000,
    500000, 200000, 100000,
  ];

  static const int _migrationFee = 15000;
  static const int _abandonThreshold = 100000;

  List<int> _planSplits(int balanceZat) {
    var remaining = balanceZat;
    final denominations = <int>[];

    while (true) {
      final usable = remaining - _migrationFee;
      if (usable < _abandonThreshold) break;

      int? bucket;
      for (final b in _buckets) {
        if (b <= usable) {
          bucket = b;
          break;
        }
      }
      if (bucket == null) break;

      denominations.add(bucket);
      remaining -= (bucket + _migrationFee);
    }

    return denominations;
  }

  List<double> _generateBroadcastSchedule(int count) {
    final rng = math.Random.secure();
    return List.generate(count, (_) {
      final u = (rng.nextInt(9999) + 1) / 10000.0;
      return -600.0 * (math.log(u) / math.ln2);
    });
  }

  // ---------------------------------------------------------------------------
  // Internal scheduling
  // ---------------------------------------------------------------------------

  Future<void> _resumeIfActive() async {
    await _loadState();
    if (_state == null || _state!.phase != AutoPhase.migrating) return;

    _log.i('[Ironwood] resuming: ${_state!.migrationsConfirmed}/${_state!.targets.length} done');
    _scheduleMigrationBroadcast();
  }

  void _scheduleMigrationBroadcast() {
    _timer?.cancel();
    if (_state == null || _state!.phase == AutoPhase.complete) return;

    final nextAt = _state!.nextBroadcastAt;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;

    Duration delay;
    if (nextAt > 0 && nextAt > now) {
      delay = Duration(seconds: nextAt - now);
    } else {
      delay = const Duration(seconds: 5);
    }

    _log.d('[Ironwood] next broadcast in ${delay.inSeconds}s');
    _timer = Timer(delay, () => _doMigrateStep());
  }

  // ---------------------------------------------------------------------------
  // Migration step
  // ---------------------------------------------------------------------------

  Future<void> _doMigrateStep() async {
    if (_ticking || _state == null) {
      _scheduleMigrationBroadcast();
      return;
    }
    _ticking = true;

    try {
      final idx = _state!.targets.indexWhere((t) => t.status == TargetStatus.pending);
      if (idx == -1) {
        _state!.phase = AutoPhase.complete;
        await _saveState();
        _log.i('[Ironwood] auto migration complete!');
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool(_prefAuto, false);
        return;
      }

      final target = _state!.targets[idx];
      _log.i('[Ironwood] step ${idx + 1}/${_state!.targets.length}: '
          '${(target.denominationZat / 1e8).toStringAsFixed(4)} ZEC');

      final proposal = await engine.engineProposePoolTransfer(
        amount: BigInt.from(target.denominationZat),
        isMax: false,
      );

      final seed = await WalletService.instance.getSeedPhrase();
      if (seed == null) {
        _log.w('[Ironwood] cannot access seed');
        return;
      }

      final txid = await engine.engineConfirmSend(seedPhrase: seed);
      _log.i('[Ironwood] broadcast: txid=$txid');

      _state!.targets[idx] = MigrationTarget(
        denominationZat: target.denominationZat,
        status: TargetStatus.broadcast,
        txid: txid,
      );
      _state!.totalFeesZat += proposal.fee.toInt();

      // Mark previously broadcast as confirmed
      for (var i = 0; i < idx; i++) {
        if (_state!.targets[i].status == TargetStatus.broadcast) {
          _state!.targets[i] = MigrationTarget(
            denominationZat: _state!.targets[i].denominationZat,
            status: TargetStatus.confirmed,
            txid: _state!.targets[i].txid,
          );
        }
      }

      // Schedule next
      _state!.nextBroadcastIdx = idx + 1;
      if (idx + 1 < _state!.broadcastDelays.length) {
        final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        _state!.nextBroadcastAt = now + _state!.broadcastDelays[idx + 1].round();
      }

      await _saveState();
      _scheduleMigrationBroadcast();
    } catch (e) {
      final msg = e.toString();
      if (msg.contains('InsufficientFunds') || msg.contains('insufficient')) {
        _log.i('[Ironwood] waiting for confirmation — retry in 90s');
        _timer = Timer(const Duration(seconds: 90), () => _doMigrateStep());
      } else {
        _log.w('[Ironwood] error: $e');
        _timer = Timer(const Duration(seconds: 120), () => _doMigrateStep());
      }
    } finally {
      _ticking = false;
    }
  }

  // ---------------------------------------------------------------------------
  // State persistence
  // ---------------------------------------------------------------------------

  Future<void> _loadState() async {
    try {
      final dataDir = await WalletService.instance.walletDir();
      final file = File('$dataDir/$_stateFile');
      if (!await file.exists()) {
        _state = null;
        return;
      }
      final json = await file.readAsString();
      _state = AutoMigrationState.fromJson(jsonDecode(json));
    } catch (e) {
      _log.w('[Ironwood] load state failed: $e');
      _state = null;
    }
  }

  Future<void> _saveState() async {
    if (_state == null) return;
    try {
      final dataDir = await WalletService.instance.walletDir();
      final file = File('$dataDir/$_stateFile');
      await file.writeAsString(jsonEncode(_state!.toJson()));
    } catch (e) {
      _log.w('[Ironwood] save state failed: $e');
    }
  }
}

// ---------------------------------------------------------------------------
// Data models
// ---------------------------------------------------------------------------

enum AutoPhase { idle, migrating, complete }

enum TargetStatus { pending, broadcast, confirmed }

class MigrationTarget {
  final int denominationZat;
  final TargetStatus status;
  final String? txid;

  MigrationTarget({
    required this.denominationZat,
    required this.status,
    this.txid,
  });

  Map<String, dynamic> toJson() => {
    'denomination_zat': denominationZat,
    'status': status.name,
    'txid': txid,
  };

  factory MigrationTarget.fromJson(Map<String, dynamic> json) => MigrationTarget(
    denominationZat: json['denomination_zat'] as int,
    status: TargetStatus.values.firstWhere((e) => e.name == json['status']),
    txid: json['txid'] as String?,
  );
}

class AutoMigrationState {
  AutoPhase phase;
  final int originalBalanceZat;
  List<MigrationTarget> targets;
  final List<double> broadcastDelays;
  int nextBroadcastIdx;
  int nextBroadcastAt;
  final bool torEnabled;
  int totalFeesZat;
  final int createdAt;

  AutoMigrationState({
    required this.phase,
    required this.originalBalanceZat,
    required this.targets,
    required this.broadcastDelays,
    required this.nextBroadcastIdx,
    required this.nextBroadcastAt,
    required this.torEnabled,
    required this.totalFeesZat,
    required this.createdAt,
  });

  int get migrationsConfirmed =>
      targets.where((t) => t.status == TargetStatus.confirmed).length;

  int get migrationsBroadcast =>
      targets.where((t) => t.status == TargetStatus.broadcast).length;

  int get migrationsPending =>
      targets.where((t) => t.status == TargetStatus.pending).length;

  int get totalMigratedZat => targets
      .where((t) => t.status != TargetStatus.pending)
      .fold(0, (sum, t) => sum + t.denominationZat);

  int get totalPlannedZat =>
      targets.fold(0, (sum, t) => sum + t.denominationZat);

  double get progress =>
      targets.isEmpty ? 0.0 : (migrationsConfirmed + migrationsBroadcast) / targets.length;

  Duration get timeUntilNextBroadcast {
    if (nextBroadcastAt == 0) return Duration.zero;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final remaining = nextBroadcastAt - now;
    return remaining > 0 ? Duration(seconds: remaining) : Duration.zero;
  }

  Map<String, dynamic> toJson() => {
    'phase': phase.name,
    'original_balance_zat': originalBalanceZat,
    'targets': targets.map((t) => t.toJson()).toList(),
    'broadcast_delays': broadcastDelays,
    'next_broadcast_idx': nextBroadcastIdx,
    'next_broadcast_at': nextBroadcastAt,
    'tor_enabled': torEnabled,
    'total_fees_zat': totalFeesZat,
    'created_at': createdAt,
  };

  factory AutoMigrationState.fromJson(Map<String, dynamic> json) => AutoMigrationState(
    phase: AutoPhase.values.firstWhere((e) => e.name == json['phase']),
    originalBalanceZat: json['original_balance_zat'] as int,
    targets: (json['targets'] as List).map((t) => MigrationTarget.fromJson(t)).toList(),
    broadcastDelays: (json['broadcast_delays'] as List).map((d) => (d as num).toDouble()).toList(),
    nextBroadcastIdx: json['next_broadcast_idx'] as int,
    nextBroadcastAt: json['next_broadcast_at'] as int,
    torEnabled: json['tor_enabled'] as bool,
    totalFeesZat: json['total_fees_zat'] as int,
    createdAt: json['created_at'] as int,
  );
}

enum MigrationRoundOutcome {
  migrated,
  consolidation,
  done,
  skipped,
  error,
}
