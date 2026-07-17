import 'dart:async';

import '../accounts.dart';
import '../store2.dart';
import 'app_log.dart';
import 'wallet_service.dart';
import '../src/rust/api/engine_api.dart' as engine;

final _log = createLogger();

/// Implements the Shielded Labs migration timing algorithm.
///
/// Two triggers cause a migration round:
/// 1. User-triggered: user taps "Migrate Now" in the UI.
/// 2. Randomly triggered: exponential delay D = -600 * log2(U) seconds (median 10 min).
///
/// On app foreground, if a migration is active, the timer is checked/resumed.
class IronwoodWatchService {
  IronwoodWatchService._();
  static final instance = IronwoodWatchService._();

  Timer? _timer;
  bool _ticking = false;
  bool _migrationActive = false;
  DateTime? _nextRoundAt;

  void start() {
    _log.i('[Ironwood] watch service started');
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _migrationActive = false;
    _log.i('[Ironwood] watch service stopped');
  }

  void onAppResumed() {
    if (_migrationActive) {
      _scheduleNextRound();
    }
  }

  /// Start the automated migration process.
  void startMigration({bool torEnabled = false}) {
    _migrationActive = true;
    _log.i('[Ironwood] migration started (tor=$torEnabled)');
    _scheduleNextRound();
  }

  /// Stop the automated migration (user paused).
  void stopMigration() {
    _migrationActive = false;
    _timer?.cancel();
    _timer = null;
    _log.i('[Ironwood] migration paused by user');
  }

  bool get isMigrationActive => _migrationActive;
  DateTime? get nextRoundAt => _nextRoundAt;

  /// Perform a single migration round immediately (user-triggered).
  Future<MigrationRoundOutcome> triggerRound() async {
    return _doRound();
  }

  void _scheduleNextRound() {
    _timer?.cancel();

    if (!_migrationActive) return;

    // Generate random delay using the Shielded Labs algorithm:
    // D = -600 * log2(U) where U is uniform (0, 1]
    // We call the engine for CSPRNG-quality randomness
    engine.engineMigrationRandomDelay().then((delaySeconds) {
      final delay = Duration(seconds: delaySeconds.round());
      _nextRoundAt = DateTime.now().add(delay);
      _log.d('[Ironwood] next round in ${delay.inSeconds}s (${delay.inMinutes}min)');

      _timer = Timer(delay, () {
        if (_migrationActive) {
          _doRound().then((_) {
            if (_migrationActive) {
              _scheduleNextRound();
            }
          });
        }
      });
    });
  }

  Future<MigrationRoundOutcome> _doRound() async {
    if (_ticking) return MigrationRoundOutcome.skipped;
    _ticking = true;

    try {
      final balance = aa.poolBalances;
      final orchardBalance = balance.totalOrchard;

      if (orchardBalance == 0) {
        _migrationActive = false;
        _log.i('[Ironwood] migration complete — no Orchard balance remaining');
        return MigrationRoundOutcome.done;
      }

      // Query the engine for the next round action
      final round = await engine.engineMigrationNextRound(
        orchardBalanceZat: BigInt.from(orchardBalance),
        largestNoteZat: BigInt.from(orchardBalance), // Approximation until we have per-note data
        noteCount: 1, // Approximation
      );

      if (round.action == 'done') {
        _migrationActive = false;
        _log.i('[Ironwood] migration complete (balance below abandon threshold)');
        return MigrationRoundOutcome.done;
      }

      if (round.action == 'consolidate') {
        _log.i('[Ironwood] consolidation round needed (${round.consolidateCount} notes)');
        // For now, consolidation is a send-to-self in Orchard
        // This will be wired when we have per-note data from the SDK
        return MigrationRoundOutcome.consolidation;
      }

      // Migrate round: propose + confirm
      _log.i('[Ironwood] migration round: ${round.amountZat} zat (${round.amountZat.toInt() / 1e8} ZEC)');

      final proposal = await engine.engineProposePoolTransfer(
        amount: round.amountZat,
        isMax: false,
      );

      final seed = await WalletService.instance.getSeedPhrase();
      if (seed == null) {
        _log.w('[Ironwood] cannot access seed — skipping round');
        return MigrationRoundOutcome.skipped;
      }

      final txid = await engine.engineConfirmSend(seedPhrase: seed);
      _log.i('[Ironwood] round broadcast: txid=$txid');

      // Record the round
      try {
        final dataDir = await WalletService.instance.walletDir();
        final height = syncStatus2.syncedHeight;
        await engine.engineMigrationRecordRound(
          dataDir: dataDir,
          amountZat: BigInt.from(proposal.sendAmount.toInt()),
          feeZat: BigInt.from(proposal.fee.toInt()),
          height: height,
        );
      } catch (_) {
        // Recording is best-effort
      }

      return MigrationRoundOutcome.migrated;
    } catch (e) {
      _log.w('[Ironwood] round error: $e');
      return MigrationRoundOutcome.error;
    } finally {
      _ticking = false;
    }
  }
}

enum MigrationRoundOutcome {
  migrated,
  consolidation,
  done,
  skipped,
  error,
}
