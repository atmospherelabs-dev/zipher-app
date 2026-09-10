import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:tuple/tuple.dart';
import 'package:mobx/mobx.dart';

import 'appsettings.dart';
import 'coin/coins.dart';
import 'pages/utils.dart';
import 'services/wallet_service.dart';
import 'src/rust/api/engine_api.dart' as rust_engine;
import 'src/rust/api/wallet.dart' as rust_wallet;

part 'accounts.g.dart';

/// Pool balance — replaces old FlatBuffer PoolBalanceT.
class PoolBalance {
  int transparent;
  int sapling;
  int orchard;
  int ironwood;
  int totalTransparent;
  int totalSapling;
  int totalOrchard;
  int totalIronwood;
  int unconfirmedTransparent;
  int unconfirmedSapling;
  int unconfirmedOrchard;
  int unconfirmedIronwood;

  PoolBalance({
    this.transparent = 0,
    this.sapling = 0,
    this.orchard = 0,
    this.ironwood = 0,
    this.totalTransparent = 0,
    this.totalSapling = 0,
    this.totalOrchard = 0,
    this.totalIronwood = 0,
    this.unconfirmedTransparent = 0,
    this.unconfirmedSapling = 0,
    this.unconfirmedOrchard = 0,
    this.unconfirmedIronwood = 0,
  });

  factory PoolBalance.fromRust(rust_wallet.WalletBalance b) {
    final transparent = b.transparent.toInt();
    final sapling = b.sapling.toInt();
    final orchard = b.orchard.toInt();
    final ironwood = b.ironwood.toInt();
    final totalTransparent = b.totalTransparent.toInt();
    final totalSapling = b.totalSapling.toInt();
    final totalOrchard = b.totalOrchard.toInt();
    final totalIronwood = b.totalIronwood.toInt();
    return PoolBalance(
      transparent: transparent,
      sapling: sapling,
      orchard: orchard,
      ironwood: ironwood,
      totalTransparent: totalTransparent,
      totalSapling: totalSapling,
      totalOrchard: totalOrchard,
      totalIronwood: totalIronwood,
      unconfirmedTransparent: max(0, totalTransparent - transparent),
      unconfirmedSapling: max(0, totalSapling - sapling),
      unconfirmedOrchard: max(0, totalOrchard - orchard),
      unconfirmedIronwood: max(0, totalIronwood - ironwood),
    );
  }

  int get confirmed => transparent + sapling + orchard + ironwood;
  int get shielded => sapling + orchard + ironwood;
  int get totalShielded => totalSapling + totalOrchard + totalIronwood;
  int get unconfirmedShielded =>
      unconfirmedSapling + unconfirmedOrchard + unconfirmedIronwood;
  int get unconfirmed =>
      unconfirmedTransparent +
      unconfirmedSapling +
      unconfirmedOrchard +
      unconfirmedIronwood;
  int get total =>
      totalTransparent + totalSapling + totalOrchard + totalIronwood;
  bool get hasUnconfirmed => unconfirmed > 0;
  bool get hasTransparent => totalTransparent > 0;
  bool get hasSpendableTransparent => transparent > 0;
  bool get hasIronwood => totalIronwood > 0;

  PoolBalance withStableShieldedSpendable(int stableShielded) {
    final stable = max(0, min(stableShielded, totalShielded));
    var remaining = stable;
    final stableIronwood = min(totalIronwood, remaining);
    remaining -= stableIronwood;
    final stableOrchard = min(totalOrchard, remaining);
    remaining -= stableOrchard;
    final stableSapling = min(totalSapling, remaining);

    return PoolBalance(
      transparent: transparent,
      sapling: stableSapling,
      orchard: stableOrchard,
      ironwood: stableIronwood,
      totalTransparent: totalTransparent,
      totalSapling: totalSapling,
      totalOrchard: totalOrchard,
      totalIronwood: totalIronwood,
      unconfirmedTransparent: max(0, totalTransparent - transparent),
      unconfirmedSapling: max(0, totalSapling - stableSapling),
      unconfirmedOrchard: max(0, totalOrchard - stableOrchard),
      unconfirmedIronwood: max(0, totalIronwood - stableIronwood),
    );
  }
}

final ActiveAccount2 nullAccount = ActiveAccount2(
  coin: 0,
  id: 0,
  name: '',
  address: '',
  canPay: false,
);

ActiveAccount2 aa = nullAccount;

AASequence aaSequence = AASequence();

class AASequence = _AASequence with _$AASequence;

abstract class _AASequence with Store {
  @observable
  int seqno = 0;

  @observable
  int settingsSeqno = 0;
}

void setActiveAccount(int coin, int id, {bool? canPayOverride}) {
  coinSettings = CoinSettingsExtension.load(coin);
  coinSettings.account = id;
  coinSettings.save(coin);
  aaSequence.seqno = DateTime.now().microsecondsSinceEpoch;
}

class ActiveAccount2 extends _ActiveAccount2 with _$ActiveAccount2 {
  ActiveAccount2({
    required int coin,
    required int id,
    required String name,
    required String address,
    required bool canPay,
    String walletId = '',
    int accountIndex = 0,
  }) : super(
          coin: coin,
          id: id,
          name: name,
          address: address,
          canPay: canPay,
          walletId: walletId,
          accountIndex: accountIndex,
        );

  /// Create from wallet service data (new engine).
  factory ActiveAccount2.fromWallet({
    required int coin,
    required String address,
    required rust_wallet.WalletBalance balance,
    String? walletName,
    String walletId = '',
    int accountIndex = 0,
  }) {
    final account = ActiveAccount2(
      coin: coin,
      id: 1,
      name: walletName ?? 'Main',
      address: address,
      canPay: true,
      walletId: walletId,
      accountIndex: accountIndex,
    );
    account.poolBalances = PoolBalance.fromRust(balance);
    account.diversifiedAddress = address;
    return account;
  }

  static ActiveAccount2? fromPrefs(SharedPreferences prefs) {
    final wallet = WalletService.instance;
    if (!wallet.isWalletOpen) return null;
    return ActiveAccount2(
      coin: activeCoin.coin,
      id: 1,
      name: 'Main',
      address: '',
      canPay: true,
    );
  }

  Future<void> save(SharedPreferences prefs) async {
    await prefs.setInt('coin', coin);
    await prefs.setInt('account', id);
  }

  bool get hasUA => coins[coin].supportsUA;
}

abstract class _ActiveAccount2 with Store {
  final int coin;
  final int id;
  String name;
  final String address;
  final bool canPay;
  String walletId;
  int accountIndex;

  _ActiveAccount2({
    required this.coin,
    required this.id,
    required this.name,
    required this.address,
    required this.canPay,
    this.walletId = '',
    this.accountIndex = 0,
  })  : notes = Notes(),
        txs = Txs(),
        messages = Messages();

  @observable
  String diversifiedAddress = '';

  @observable
  int height = 0;

  @observable
  String currency = '';

  @observable
  PoolBalance poolBalances = PoolBalance();

  @observable
  rust_engine.EngineMultiChainAddresses? chainAddresses;

  Notes notes;
  Txs txs;
  Messages messages;

  List<dynamic> spendings = [];
  List<TimeSeriesPoint<double>> accountBalances = [];

  @action
  void reset(int resetHeight) {
    poolBalances = PoolBalance();
    chainAddresses = null;
    notes.clear();
    txs.clear();
    messages.clear();
    spendings = [];
    accountBalances = [];
    height = resetHeight;
  }

  bool get isCurrentWallet => identical(aa, this) &&
      !WalletService.instance.isBusy &&
      (walletId.isEmpty || walletId == WalletService.instance.activeWalletId) &&
      coin == activeCoin.coin;

  @action
  Future<void> updateBalance() async {
    if (id == 0 || !isCurrentWallet) return;
    final generation = WalletService.instance.walletGeneration;
    final walletId = WalletService.instance.activeWalletId;
    final network = isTestnet;
    try {
      final balance = await WalletService.instance.getBalance();
      if (!isCurrentWallet ||
          generation != WalletService.instance.walletGeneration ||
          walletId != WalletService.instance.activeWalletId ||
          network != isTestnet) return;
      final next = PoolBalance.fromRust(balance);

      // Spendable must reflect the engine's current note/anchor eligibility.
      // Inflating it from a previous snapshot makes a send appear affordable
      // while those notes are confirming, spent or being rescanned.
      poolBalances = next;
    } catch (_) {
      logger.d('[AA] balance refresh unavailable; retaining last snapshot');
    }
  }

  @action
  Future<void> updateAddress() async {
    if (id == 0 || !isCurrentWallet) return;
    final generation = WalletService.instance.walletGeneration;
    final walletId = WalletService.instance.activeWalletId;
    final network = isTestnet;
    for (int attempt = 0; attempt < 3; attempt++) {
      if (!isCurrentWallet ||
          generation != WalletService.instance.walletGeneration ||
          walletId != WalletService.instance.activeWalletId ||
          network != isTestnet) return;
      try {
        final addrs = await WalletService.instance.getAddresses();
        if (!isCurrentWallet ||
          generation != WalletService.instance.walletGeneration ||
            walletId != WalletService.instance.activeWalletId ||
            network != isTestnet) return;
        if (addrs.isNotEmpty) {
          diversifiedAddress = addrs.first.address;
          return;
        }
      } catch (e) {
        logger.e('updateAddress error (attempt $attempt): $e');
      }
      if (attempt < 2) {
        await Future.delayed(const Duration(milliseconds: 500));
      }
    }
  }

  @action
  Future<void> updateChainAddresses() async {
    if (id == 0 || !isCurrentWallet) return;
    final generation = WalletService.instance.walletGeneration;
    final owner = WalletService.instance.activeWalletId;
    final network = isTestnet;
    try {
      final seed = await WalletService.instance.getSeedPhrase();
      if (seed == null) return;
      final derived = await rust_engine.engineDeriveMultiChainAddresses(
        seedPhrase: seed,
      );
      if (WalletService.instance.activeWalletId == owner &&
          isTestnet == network &&
          isCurrentWallet && generation == WalletService.instance.walletGeneration) {
        chainAddresses = derived;
      }
    } catch (e) {
      logger.d('[AA] chain addresses unavailable');
    }
  }

  @action
  Future<void> updateTransactions() async {
    if (id == 0 || !isCurrentWallet) return;
    final generation = WalletService.instance.walletGeneration;
    final network = isTestnet;
    try {
      // Use aa.height if set; otherwise fetch from wallet so confirmations are correct
      var latestHeight = height;
      if (latestHeight <= 0) {
        try {
          latestHeight = await WalletService.instance.getWalletSyncedHeight();
        } catch (_) {}
      }
      final h = latestHeight > 0 ? latestHeight : null;

      if (!isCurrentWallet || generation != WalletService.instance.walletGeneration || network != isTestnet) return;
      final records = await WalletService.instance.getTransactions();
      if (!isCurrentWallet || generation != WalletService.instance.walletGeneration || network != isTestnet) return;
      final memos = WalletService.instance.memosByTxid;
      final newTxs = <Tx>[];
      final newMessages = <ZMessage>[];
      var msgId = 0;
      for (var i = 0; i < records.length; i++) {
        final r = records[i];
        final timestamp =
            DateTime.fromMillisecondsSinceEpoch(r.timestamp.toInt() * 1000);
        final memo = memos[r.txid];
        newTxs.add(Tx.from(
          h,
          i,
          r.height,
          timestamp,
          r.txid.substring(0, min(12, r.txid.length)),
          r.txid,
          r.value / ZECUNIT,
          null,
          null,
          memo,
          [],
          kind: r.kind,
          rawValue: r.rawValue.toDouble() / ZECUNIT,
          expiredUnmined: r.status == 'expired',
          fee: r.fee == null ? null : r.fee!.toDouble() / ZECUNIT,
        ));
        if (memo != null && memo.isNotEmpty) {
          final incoming = r.value > 0;
          newMessages.add(ZMessage(
            msgId++,
            i,
            incoming,
            null,
            null,
            '',
            '',
            memo,
            timestamp,
            r.height,
            false,
          ));
        }
      }
      txs.items = newTxs;
      messages.items = newMessages;
      logger.d(
          '[AA] updateTransactions: ${txs.items.length} txs, ${messages.items.length} memos loaded');
    } catch (e) {
      logger.e('updateTransactions error: $e');
    }
  }

  @action
  Future<void> update(int? newHeight) async {
    if (id == 0 || !isCurrentWallet) return;
    final generation = WalletService.instance.walletGeneration;
    await updateAddress();
    if (!isCurrentWallet || generation != WalletService.instance.walletGeneration) return;
    await updateBalance();
    if (!isCurrentWallet || generation != WalletService.instance.walletGeneration) return;
    await updateTransactions();
    if (!isCurrentWallet || generation != WalletService.instance.walletGeneration) return;
    if (chainAddresses == null) await updateChainAddresses();
    if (!isCurrentWallet || generation != WalletService.instance.walletGeneration) return;
    currency = appSettings.currency;
    if (newHeight != null) height = newHeight;
  }
}

class Notes extends _Notes with _$Notes {
  Notes();
}

abstract class _Notes with Store {
  _Notes();

  @observable
  List<Note> items = [];
  SortConfig2? order;

  @action
  void read(int? height) {
    // Notes are not yet available from the engine's direct API
    // Will be populated when we add note-level querying
  }

  @action
  void clear() {
    items.clear();
  }

  @action
  void setSortOrder(String field) {
    final r = _sort(field, order, items);
    order = r.item1;
    items = r.item2;
  }
}

class Txs extends _Txs with _$Txs {
  Txs();
}

abstract class _Txs with Store {
  _Txs();

  @observable
  List<Tx> items = [];
  SortConfig2? order;

  @action
  void read(int? height) {
    // Transactions are loaded via updateTransactions()
  }

  @action
  void clear() {
    items.clear();
  }

  @action
  void setSortOrder(String field) {
    final r = _sort(field, order, items);
    order = r.item1;
    items = r.item2;
  }
}

class Messages extends _Messages with _$Messages {
  Messages();
}

abstract class _Messages with Store {
  _Messages();

  @observable
  List<ZMessage> items = [];
  SortConfig2? order;

  @action
  void read(int? height) {
    // Messages will be populated from transaction memos
  }

  @action
  void clear() {
    items.clear();
  }

  @action
  void setSortOrder(String field) {
    final r = _sort(field, order, items);
    order = r.item1;
    items = r.item2;
  }
}

Tuple2<SortConfig2?, List<T>> _sort<T extends HasHeight>(
    String field, SortConfig2? order, List<T> items) {
  if (order == null)
    order = SortConfig2(field, 1);
  else
    order = order.next(field);

  final o = order;
  if (o == null)
    items.sort((a, b) => b.height.compareTo(a.height));
  else {
    items.sort((a, b) {
      final ra = reflector.reflect(a);
      final va = ra.invokeGetter(field)! as dynamic;
      final rb = reflector.reflect(b);
      final vb = rb.invokeGetter(field)! as dynamic;
      return va.compareTo(vb) * o.orderBy;
    });
  }
  return Tuple2(o, items);
}

class SortConfig2 {
  String field;
  int orderBy; // 1: asc, -1: desc
  SortConfig2(this.field, this.orderBy);

  SortConfig2? next(String newField) {
    if (newField == field) {
      if (orderBy > 0) return SortConfig2(field, -orderBy);
      return null;
    }
    return SortConfig2(newField, 1);
  }

  String indicator(String field) {
    if (this.field != field) return '';
    if (orderBy > 0) return ' \u2191';
    return ' \u2193';
  }
}

// ---------------------------------------------------------------------------
// Account emoji avatar (SharedPreferences)
// ---------------------------------------------------------------------------

class AccountEmojiStore {
  static const _prefix = 'account_emoji_';

  static String _key(int coin, int id) => '$_prefix${coin}_$id';

  static Future<String?> get(int coin, int id) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_key(coin, id));
  }

  static Future<void> set(int coin, int id, String emoji) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key(coin, id), emoji);
  }

  static Future<void> remove(int coin, int id) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key(coin, id));
  }

  static Future<Map<String, String>> loadAll() async {
    final prefs = await SharedPreferences.getInstance();
    final map = <String, String>{};
    for (final key in prefs.getKeys()) {
      if (key.startsWith(_prefix)) {
        final v = prefs.getString(key);
        if (v != null) map[key.substring(_prefix.length)] = v;
      }
    }
    return map;
  }
}
