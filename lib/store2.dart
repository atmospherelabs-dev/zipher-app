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

void initSyncListener() {
  // With pepper-sync, progress is driven by periodic polling rather than
  // a native port callback. No-op for now — sync status is updated
  // when syncAndAwait completes.
}

Timer? syncTimer;

Future<void> startAutoSync() async {
  if (syncTimer == null) {
    await syncStatus2.update();
    await syncStatus2.sync(false, auto: true);
    syncTimer = Timer.periodic(Duration(seconds: 15), (timer) {
      syncStatus2.sync(false, auto: true);
    });
  }
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

  @computed
  int get changed {
    connected;
    syncedHeight;
    latestHeight;
    syncing;
    paused;
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
  }

  @action
  Future<void> update() async {
    try {
      if (!WalletService.instance.isWalletOpen) return;
      final info = await WalletService.instance.getServerInfo();
      // Server info is a JSON string — parse latest height from it
      try {
        final parsed = _parseServerInfoHeight(info);
        if (parsed != null) {
          final lh = latestHeight;
          latestHeight = parsed;
          if (lh == null && latestHeight != null) {
            await aa.update(latestHeight);
          }
        }
      } catch (_) {}
      connected = true;
    } catch (e) {
      logger.e('Sync update error: $e');
      connected = false;
    }
  }

  int? _parseServerInfoHeight(String info) {
    // zingolib's do_info returns a JSON-like string with "latest_block_height"
    final match = RegExp(r'"latest_block_height"\s*:\s*(\d+)').firstMatch(info);
    if (match != null) return int.tryParse(match.group(1)!);
    return null;
  }

  @action
  Future<void> sync(bool rescan, {bool auto = false}) async {
    logger.d('R/A/P/S $rescan $auto $paused $syncing');
    if (paused) return;
    if (syncing) return;
    if (!WalletService.instance.isWalletOpen) return;
    try {
      await update();
      final lh = latestHeight;
      if (lh == null) return;
      if (isSynced && !rescan) return;
      syncing = true;
      isRescan = rescan;
      startSyncedHeight = syncedHeight;
      eta.begin(lh);
      eta.checkpoint(syncedHeight, DateTime.now());

      final preBalance = AccountBalanceSnapshot(
          coin: aa.coin, id: aa.id, balance: aa.poolBalances.confirmed);

      final result = rescan
          ? await WalletService.instance.rescan()
          : await WalletService.instance.syncAndAwait();

      syncedHeight = result.endHeight;
      latestHeight = result.endHeight;

      await aa.update(result.endHeight);
      contacts.fetchContacts();
      marketPrice.update();

      final postBalance = AccountBalanceSnapshot(
          coin: aa.coin, id: aa.id, balance: aa.poolBalances.confirmed);
      if (preBalance.sameAccount(postBalance) &&
          preBalance.balance != postBalance.balance) {
        final s = GetIt.I.get<S>();
        final ticker = coins[aa.coin].ticker;
        if (preBalance.balance < postBalance.balance) {
          final amount =
              amountToString2(postBalance.balance - preBalance.balance);
          showLocalNotification(
            id: result.endHeight,
            title: s.incomingFunds,
            body: s.received(amount, ticker),
          );
        } else {
          final amount =
              amountToString2(preBalance.balance - postBalance.balance);
          showLocalNotification(
            id: result.endHeight,
            title: s.paymentMade,
            body: s.spent(amount, ticker),
          );
        }
      }
    } catch (e) {
      logger.e('Sync error: $e');
    } finally {
      syncing = false;
      eta.end();
    }
  }

  @action
  Future<void> rescan(int height) async {
    paused = false;
    await sync(true);
  }

  @action
  void setPause(bool v) {
    paused = v;
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
