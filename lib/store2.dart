import 'dart:async';
import 'dart:math';

import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:get_it/get_it.dart';
import 'package:mobx/mobx.dart';

import 'appsettings.dart';
import 'pages/utils.dart';
import 'accounts.dart';
import 'coin/coins.dart';
import 'generated/intl/messages.dart';
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

void initSyncListener() {}

Timer? syncTimer;
DateTime? _boostUntil;

/// Temporarily force fast (5s) polling for 2 minutes.
/// Call after user-initiated actions like send or opening receive page.
void boostSyncPolling() {
  _boostUntil = DateTime.now().add(const Duration(minutes: 2));
}

Future<void> startAutoSync() async {
  if (syncTimer == null) {
    await syncStatus2.sync();
    _scheduleNextSync();
  }
}

void _scheduleNextSync() {
  final boosted = _boostUntil != null && DateTime.now().isBefore(_boostUntil!);
  final fast = syncStatus2.syncing || boosted;
  final interval = fast ? const Duration(seconds: 5) : const Duration(seconds: 30);
  syncTimer?.cancel();
  syncTimer = Timer(interval, () {
    syncStatus2.sync().then((_) => _scheduleNextSync());
  });
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
  DateTime? timestamp;

  @observable
  bool syncing = false;

  @observable
  bool paused = false;

  @observable
  int downloadedSize = 0;

  @observable
  int trialDecryptionCount = 0;

  @observable
  String? connectionError;

  @computed
  int get changed {
    connected;
    syncedHeight;
    latestHeight;
    syncing;
    paused;
    connectionError;
    return DateTime.now().microsecondsSinceEpoch;
  }

  bool get isSynced {
    final sh = syncedHeight;
    final lh = latestHeight;
    return lh != null && sh >= lh;
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
  }

  @action
  Future<void> update() async {
    try {
      if (!WalletService.instance.isWalletOpen) return;

      final tip = await WalletService.instance.getLatestBlockHeight();
      final oldTip = latestHeight;
      latestHeight = tip;
      if (oldTip == null && latestHeight != null) {
        await aa.update(latestHeight);
      }

      connected = true;
    } catch (e) {
      logger.e('Sync update error: $e');
      connected = false;
    }
  }

  bool _syncStarted = false;
  bool _needsInitialUpdate = true;

  /// Called by the adaptive timer (5s while syncing, 30s when caught up).
  /// Starts the sync engine once, then polls heights and connection status.
  @action
  Future<void> sync() async {
    if (paused) return;
    if (!WalletService.instance.isWalletOpen) return;

    try {
      await update();
    } catch (e) {
      logger.e('Sync update error: $e');
    }

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
          logger.d('[Sync] sync engine already running');
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

      // Surface connection errors from the Rust retry loop
      connectionError = progress.connectionError;
      if (connectionError != null) {
        connected = false;
      } else {
        connected = true;
      }

      final h = await WalletService.instance.getWalletSyncedHeight();
      if (h > syncedHeight) {
        syncedHeight = h;
        eta.checkpoint(syncedHeight, DateTime.now());
      }

      // On first poll after wallet open/switch, refresh balance + txs eagerly
      if (_needsInitialUpdate) {
        _needsInitialUpdate = false;
        await aa.update(syncedHeight);
        logger.d('[Sync] initial update done at $syncedHeight');
      }

      final lh = latestHeight;

      if (lh != null && syncedHeight < lh - 1) {
        // Still catching up
        if (!syncing) {
          syncing = true;
          startSyncedHeight = syncedHeight;
          eta.begin(lh);
          eta.checkpoint(syncedHeight, DateTime.now());
          logger.d('[Sync] catching up from $syncedHeight to $lh');
        }
      } else if (lh != null && syncedHeight >= lh - 1) {
        // Caught up to chain tip
        if (syncing) {
          syncedHeight = lh;
          await WalletService.instance.snapshotAfterSync();
          contacts.fetchContacts();
          marketPrice.update();
          syncing = false;
          eta.end();
          logger.d('[Sync] completed at $syncedHeight');
        }
        // Refresh balance + txs every poll to pick up mempool changes
        await aa.update(syncedHeight);
      }
    } catch (e) {
      logger.d('[Sync] poll error: $e');
    }
  }

  /// Prepare for a rescan from a specific height (e.g. after restore).
  /// The actual sync is kicked off by the auto-sync timer.
  @action
  void prepareRescan(int height) {
    paused = false;
    syncing = false;
    _syncStarted = false;
    isRescan = true;
    syncedHeight = height;
  }

  @action
  void setPause(bool v) {
    paused = v;
    if (v) _syncStarted = false;
  }

  /// Reset sync state for a newly opened wallet so the sync engine restarts.
  @action
  void resetForWalletSwitch() {
    _syncStarted = false;
    syncing = false;
    _needsInitialUpdate = true;
    connectionError = null;
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
