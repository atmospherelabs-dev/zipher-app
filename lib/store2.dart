import 'dart:async';
import 'dart:math';

import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:mobx/mobx.dart';

import 'appsettings.dart';
import 'pages/utils.dart';
import 'accounts.dart';
import 'coin/coins.dart';
import 'services/wallet_service.dart';

part 'store2.g.dart';
part 'store2.freezed.dart';

var appStore = AppStore();

class AppStore = _AppStore with _$AppStore;

abstract class _AppStore with Store {
  bool initialized = false;
  String dbPassword = '';

  @observable
  bool flat = false;
}

StreamSubscription<dynamic>? _syncEventSubscription;

void initSyncListener() {
  _syncEventSubscription ??= WalletService.instance.syncEvents().listen(
        syncStatus2.applyEngineEvent,
        onError: (Object e) => logger.d('[Sync] event stream error: $e'),
      );
}

Timer? syncTimer;
DateTime? _boostUntil;
DateTime? _lastSyncEventAt;

/// Temporarily force fast (5s) polling for 2 minutes.
/// Call after user-initiated actions like send or opening receive page.
void boostSyncPolling() {
  _boostUntil = DateTime.now().add(const Duration(minutes: 2));
  syncTimer?.cancel();
  syncTimer = null;
  Future(() async {
    await syncStatus2.sync();
    _scheduleNextSync();
  });
}

/// True while we're in the post-action "fast poll" window. Used by
/// [ActiveAccount2.updateBalance] to detect "transient" state windows where
/// a brief all-zero balance reading from the engine should not overwrite the
/// previously-known good balance.
bool isSyncBoosted() {
  final until = _boostUntil;
  return until != null && DateTime.now().isBefore(until);
}

Future<void> startAutoSync() async {
  if (syncTimer == null) {
    initSyncListener();
    await syncStatus2.sync();
    _scheduleNextSync();
  }
}

void _scheduleNextSync() {
  final now = DateTime.now();
  final streamRecentlyActive = _lastSyncEventAt != null &&
      now.difference(_lastSyncEventAt!) < const Duration(seconds: 60);
  final boosted = isSyncBoosted() || _hasPendingZcashActivity();
  final fast = syncStatus2.syncing || syncStatus2.isMaintaining || boosted;
  final base = streamRecentlyActive
      ? const Duration(seconds: 60)
      : fast
          ? const Duration(seconds: 5)
          : const Duration(seconds: 30);
  final jitter = 0.75 + Random().nextDouble() * 0.5;
  final interval =
      Duration(milliseconds: (base.inMilliseconds * jitter).round());
  syncTimer?.cancel();
  syncTimer = Timer(interval, () {
    syncStatus2.sync().then((_) => _scheduleNextSync());
  });
}

bool _hasPendingZcashActivity() {
  return aa.txs.items.any((tx) => tx.height <= 0 && !tx.expiredUnmined);
}

var syncStatus2 = SyncStatus2();

class SyncStatus2 = _SyncStatus2 with _$SyncStatus2;

abstract class _SyncStatus2 with Store {
  int startSyncedHeight = 0;
  bool isRescan = false;
  ETA eta = ETA();

  @observable
  bool connected = true;

  @observable
  int syncedHeight = 0;

  @observable
  int? latestHeight;

  @observable
  bool syncing = false;

  @observable
  bool paused = false;

  @observable
  String? connectionError;

  @observable
  String? maintenanceError;

  @observable
  String phase = 'idle';

  @observable
  int maintenanceQueueLen = 0;

  @computed
  int get changed {
    connected;
    syncedHeight;
    latestHeight;
    syncing;
    paused;
    connectionError;
    maintenanceError;
    phase;
    maintenanceQueueLen;
    return DateTime.now().microsecondsSinceEpoch;
  }

  bool get isSynced {
    final sh = syncedHeight;
    final lh = latestHeight;
    return lh != null && sh >= lh;
  }

  bool get isMaintaining {
    return phase == 'enhancing' ||
        phase == 'mempool' ||
        maintenanceQueueLen > 0;
  }

  int? get confirmHeight {
    final lh = latestHeight;
    if (lh == null) return null;
    final ch = lh - appSettings.anchorOffset;
    return max(ch, 0);
  }

  @action
  void reset() {
    isRescan = false;
    syncing = false;
    paused = false;
    connectionError = null;
    maintenanceError = null;
    phase = 'idle';
    maintenanceQueueLen = 0;
  }

  bool _syncStarted = false;
  bool _needsInitialUpdate = true;
  bool _syncInProgress = false;
  DateTime? _lastAccountUpdateAt;

  /// Called by the adaptive timer (5s while syncing, 30s when caught up).
  /// Starts the sync engine once, then polls heights and connection status.
  @action
  Future<void> sync({bool restart = false}) async {
    if (paused) return;
    if (!WalletService.instance.isWalletOpen) return;
    if (_syncInProgress) return;
    _syncInProgress = true;

    try {
      if (restart) {
        // Force-restart the sync engine to skip the current backoff window
        try {
          await WalletService.instance.stopSync();
          await Future.delayed(const Duration(milliseconds: 200));
        } catch (_) {}
        _syncStarted = false;
        connectionError = null;
        connected = true;
        logger.d('[Sync] manual restart requested');
      }
      await _syncInternal();
    } finally {
      _syncInProgress = false;
    }
  }

  Future<void> _syncInternal() async {
    // Start sync once — it runs forever after this
    if (!_syncStarted) {
      _syncStarted = true;
      try {
        logger.d('[Sync] starting sync engine');
        await WalletService.instance.startSync();
      } catch (e) {
        final msg = e.toString();
        final lower = msg.toLowerCase();
        if (lower.contains('already') || lower.contains('syncalreadyrunning')) {
          logger
              .d('[Sync] sync still running from previous wallet, stopping...');
          await WalletService.instance.stopSync();
          await Future.delayed(const Duration(milliseconds: 500));
          try {
            await WalletService.instance.startSync();
            logger.d('[Sync] sync restarted for current wallet');
          } catch (e2) {
            logger.e('[Sync] restart failed: $e2');
            _syncStarted = false;
            return;
          }
        } else {
          logger.e('[Sync] start error: $e');
          _syncStarted = false;
          return;
        }
      }
    }

    // Poll progress and connection status
    try {
      final progress = await WalletService.instance.getEngineSyncProgress();

      connectionError = progress.connectionError;
      maintenanceError = progress.maintenanceError;
      phase = progress.phase;
      maintenanceQueueLen = progress.maintenanceQueueLen;
      connected = connectionError == null;
      if (connectionError != null) {
        logger.w('[Sync] connection error: $connectionError');
      }
      if (maintenanceError != null) {
        logger.d('[Sync] maintenance retry pending: $maintenanceError');
      }

      // Use the engine's chain tip instead of a separate LWD call
      if (progress.latestHeight > 0) {
        latestHeight = progress.latestHeight;
      }

      final h = await WalletService.instance.getWalletSyncedHeight();
      final effectiveH = progress.syncedHeight > 0
          ? progress.syncedHeight
          : progress.scanningUpTo > 0
              ? progress.scanningUpTo
              : h;
      logger.d(
          '[Sync] poll: synced=${progress.syncedHeight} scanning=${progress.scanningUpTo} latest=${progress.latestHeight} isSyncing=${progress.isSyncing} walletH=$h localH=$syncedHeight effectiveH=$effectiveH');
      if (effectiveH > 0 && effectiveH < syncedHeight && progress.isSyncing) {
        syncedHeight = effectiveH;
        eta.checkpoint(syncedHeight, DateTime.now());
      } else if (effectiveH > syncedHeight) {
        syncedHeight = effectiveH;
        eta.checkpoint(syncedHeight, DateTime.now());
      }

      if (_needsInitialUpdate) {
        _needsInitialUpdate = false;
        await aa.update(syncedHeight);
        _lastAccountUpdateAt = DateTime.now();
        logger.d('[Sync] initial update done at $syncedHeight');
      }

      final lh = latestHeight;

      if (lh != null && syncedHeight < lh - 1) {
        if (!syncing) {
          syncing = true;
          startSyncedHeight = syncedHeight;
          eta.begin(lh);
          eta.checkpoint(syncedHeight, DateTime.now());
          logger.d('[Sync] catching up from $syncedHeight to $lh');
        }
        if (_shouldRefreshAccountWhileSyncing()) {
          await aa.update(syncedHeight);
          _lastAccountUpdateAt = DateTime.now();
        }
      } else if (lh != null && syncedHeight >= lh - 1) {
        if (syncing || isRescan) {
          syncedHeight = lh;
          await WalletService.instance.snapshotAfterSync();
          contacts.fetchContacts();
          marketPrice.update();
          syncing = false;
          isRescan = false;
          eta.end();
          logger.d('[Sync] completed at $syncedHeight');
        }
        await aa.update(syncedHeight);
        _lastAccountUpdateAt = DateTime.now();
      }
    } catch (e) {
      logger.d('[Sync] poll error: $e');
    }
  }

  @action
  void applyEngineEvent(dynamic event) {
    _lastSyncEventAt = DateTime.now();
    final eventType = event.eventType as String;
    if (eventType == 'phase_changed' || eventType == 'connection_error') {
      final eventPhase = event.phase as String?;
      if (eventPhase != null && eventPhase.isNotEmpty) {
        phase = eventPhase;
      }
      final eventLatest = event.latestHeight as int;
      if (eventLatest > 0) latestHeight = eventLatest;
      final eventSynced = event.syncedHeight as int;
      if (eventSynced > 0 && eventSynced >= syncedHeight) {
        syncedHeight = eventSynced;
        eta.checkpoint(syncedHeight, DateTime.now());
      }
      maintenanceQueueLen = event.maintenanceQueueLen as int;
      if (eventType == 'connection_error') {
        connectionError = event.message as String?;
        connected = connectionError == null;
      }
    } else if (eventType == 'transaction_updated' ||
        eventType == 'balance_maybe_changed') {
      Future(() async {
        if (!WalletService.instance.isWalletOpen) return;
        await aa.update(syncedHeight);
        _lastAccountUpdateAt = DateTime.now();
      });
    }
  }

  bool _shouldRefreshAccountWhileSyncing() {
    final last = _lastAccountUpdateAt;
    if (last == null) return true;
    final hasPending = _hasPendingZcashActivity();
    final interval =
        hasPending ? const Duration(seconds: 5) : const Duration(seconds: 15);
    return DateTime.now().difference(last) >= interval;
  }

  /// Trigger a real rescan: stops sync, truncates wallet DB to birthday,
  /// and restarts. The auto-sync timer picks up the new state.
  @action
  Future<void> triggerRescan() async {
    isRescan = true;
    syncing = false;
    _syncStarted = false;
    try {
      await WalletService.instance.rescanFromBirthday();
    } catch (e) {
      logger.e('[Sync] rescan failed: $e');
    }
  }

  /// Reset sync state for a newly opened wallet so the sync engine restarts.
  /// Also cancels the auto-sync timer so [startAutoSync] re-arms it.
  @action
  void resetForWalletSwitch() {
    _syncStarted = false;
    syncing = false;
    _needsInitialUpdate = true;
    connectionError = null;
    maintenanceError = null;
    phase = 'idle';
    maintenanceQueueLen = 0;
    syncedHeight = 0;
    _lastAccountUpdateAt = null;
    eta.end();
    syncTimer?.cancel();
    syncTimer = null;
    _syncEventSubscription?.cancel();
    _syncEventSubscription = null;
  }

  @action
  void setProgress(int height) {
    syncedHeight = height;
    eta.checkpoint(syncedHeight, DateTime.now());
  }
}

class ETA {
  int endHeight = 0;
  ETACheckpoint? start;
  ETACheckpoint? prev;
  ETACheckpoint? current;

  void begin(int height) {
    end();
    endHeight = height;
  }

  void end() {
    start = null;
    prev = null;
    current = null;
  }

  void checkpoint(int height, DateTime timestamp) {
    prev = current;
    current = ETACheckpoint(height, timestamp);
    if (start == null) start = current;
  }

  @computed
  int? get remaining {
    return current?.let((c) => endHeight - c.height);
  }

  @computed
  String get timeRemaining {
    final defaultMsg = "Calculating ETA";
    final p = prev;
    final c = current;
    if (p == null || c == null) return defaultMsg;
    if (c.timestamp.millisecondsSinceEpoch ==
        p.timestamp.millisecondsSinceEpoch) return defaultMsg;
    final speed = (c.height - p.height) /
        (c.timestamp.millisecondsSinceEpoch -
            p.timestamp.millisecondsSinceEpoch);
    if (speed == 0) return defaultMsg;
    final eta = (endHeight - c.height) / speed;
    if (eta <= 0) return defaultMsg;
    final duration =
        Duration(milliseconds: eta.floor()).toString().split('.')[0];
    return "ETA: $duration";
  }

  @computed
  bool get running => start != null;

  @computed
  int? get progress {
    if (!running) return null;
    final sh = start!.height;
    final ch = current!.height;
    final total = endHeight - sh;
    final percent = total > 0 ? 100 * (ch - sh) ~/ total : 0;
    return percent;
  }
}

class ETACheckpoint {
  int height;
  DateTime timestamp;

  ETACheckpoint(this.height, this.timestamp);
}

var marketPrice = MarketPrice();

class MarketPrice = _MarketPrice with _$MarketPrice;

abstract class _MarketPrice with Store {
  @observable
  double? price;

  @action
  Future<void> update() async {
    try {
      final c = coins[aa.coin];
      price = await getFxRate(c.currency, appSettings.currency);
    } catch (e) {
      logger.d('Market price update error: $e');
    }
  }

  int? lastChartUpdateTime;
}

var contacts = ContactStore();

class ContactStore = _ContactStore with _$ContactStore;

abstract class _ContactStore with Store {
  @observable
  ObservableList<Contact> contacts = ObservableList<Contact>.of([]);

  @action
  void fetchContacts() {
    // Contacts are stored in SharedPreferences in the new engine
    // TODO: migrate contact storage
  }

  @action
  void add(Contact c) {
    contacts.add(c);
  }

  @action
  void remove(Contact c) {
    contacts.removeWhere((contact) => contact.id == c.id);
  }
}

class AccountBalanceSnapshot {
  final int coin;
  final int id;
  final int balance;
  AccountBalanceSnapshot({
    required this.coin,
    required this.id,
    required this.balance,
  });

  bool sameAccount(AccountBalanceSnapshot other) =>
      coin == other.coin && id == other.id;

  @override
  String toString() => '($coin, $id, $balance)';
}

@freezed
class SeedInfo with _$SeedInfo {
  const factory SeedInfo({
    required String seed,
    required int index,
  }) = _SeedInfo;
}

@freezed
class TxMemo with _$TxMemo {
  const factory TxMemo({
    required String address,
    required String memo,
  }) = _TxMemo;
}

@freezed
class SwapAmount with _$SwapAmount {
  const factory SwapAmount({
    required String amount,
    required String currency,
  }) = _SwapAmount;
}

@freezed
class SwapQuote with _$SwapQuote {
  const factory SwapQuote({
    required String estimated_amount,
    required String rate_id,
    required String valid_until,
  }) = _SwapQuote;

  factory SwapQuote.fromJson(Map<String, dynamic> json) =>
      _$SwapQuoteFromJson(json);
}

@freezed
class SwapRequest with _$SwapRequest {
  const factory SwapRequest({
    required bool fixed,
    required String rate_id,
    required String currency_from,
    required String currency_to,
    required double amount_from,
    required String address_to,
  }) = _SwapRequest;

  factory SwapRequest.fromJson(Map<String, dynamic> json) =>
      _$SwapRequestFromJson(json);
}

@freezed
class SwapLeg with _$SwapLeg {
  const factory SwapLeg({
    required String symbol,
    required String name,
    required String image,
    required String validation_address,
    required String address_explorer,
    required String tx_explorer,
  }) = _SwapLeg;

  factory SwapLeg.fromJson(Map<String, dynamic> json) =>
      _$SwapLegFromJson(json);
}

@freezed
class SwapResponse with _$SwapResponse {
  const factory SwapResponse({
    required String id,
    required String timestamp,
    required String currency_from,
    required String currency_to,
    required String amount_from,
    required String amount_to,
    required String address_from,
    required String address_to,
  }) = _SwapResponse;

  factory SwapResponse.fromJson(Map<String, dynamic> json) =>
      _$SwapResponseFromJson(json);
}

@freezed
class Election with _$Election {
  const factory Election({
    required int id,
    required String name,
    required int start_height,
    required int end_height,
    required int close_height,
    required String submit_url,
    required String question,
    required List<String> candidates,
    required String status,
  }) = _Election;

  factory Election.fromJson(Map<String, dynamic> json) =>
      _$ElectionFromJson(json);
}

@freezed
class Vote with _$Vote {
  const factory Vote({
    required Election election,
    required List<int> notes,
    int? candidate,
  }) = _Vote;
}
