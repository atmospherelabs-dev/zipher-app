import 'dart:convert';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

class AccountEntry {
  final int accountIndex;
  String name;
  int lastBalance;
  bool isHidden;

  AccountEntry({
    required this.accountIndex,
    required this.name,
    this.lastBalance = 0,
    this.isHidden = false,
  });

  Map<String, dynamic> toJson() => {
        'accountIndex': accountIndex,
        'name': name,
        'lastBalance': lastBalance,
        'isHidden': isHidden,
      };

  factory AccountEntry.fromJson(Map<String, dynamic> json) => AccountEntry(
        accountIndex: json['accountIndex'] as int,
        name: json['name'] as String? ?? 'Account ${(json['accountIndex'] as int) + 1}',
        lastBalance: json['lastBalance'] as int? ?? 0,
        isHidden: json['isHidden'] as bool? ?? false,
      );
}

class WalletProfile {
  final String id;
  String name;
  final DateTime createdAt;
  final bool isWatchOnly;
  DateTime lastOpenedAt;
  int lastBalance;
  int lastSyncHeight;
  List<AccountEntry>? _accounts;

  WalletProfile({
    required this.id,
    required this.name,
    required this.createdAt,
    this.isWatchOnly = false,
    DateTime? lastOpenedAt,
    this.lastBalance = 0,
    this.lastSyncHeight = 0,
    List<AccountEntry>? accounts,
  })  : lastOpenedAt = lastOpenedAt ?? createdAt,
        _accounts = accounts;

  List<AccountEntry> get accounts {
    _accounts ??= [AccountEntry(accountIndex: 0, name: name)];
    return _accounts!;
  }
  set accounts(List<AccountEntry> v) => _accounts = v;

  List<AccountEntry> get visibleAccounts =>
      accounts.where((a) => !a.isHidden).toList();

  AccountEntry? accountAt(int index) {
    try {
      return accounts.firstWhere((a) => a.accountIndex == index);
    } catch (_) {
      return null;
    }
  }

  int get nextAccountIndex {
    if (accounts.isEmpty) return 0;
    return accounts.map((a) => a.accountIndex).reduce(max) + 1;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'createdAt': createdAt.toIso8601String(),
        'isWatchOnly': isWatchOnly,
        'lastOpenedAt': lastOpenedAt.toIso8601String(),
        'lastBalance': lastBalance,
        'lastSyncHeight': lastSyncHeight,
        'accounts': accounts.map((a) => a.toJson()).toList(),
      };

  factory WalletProfile.fromJson(Map<String, dynamic> json) {
    final List<AccountEntry> accts;
    if (json['accounts'] != null) {
      accts = (json['accounts'] as List)
          .map((e) => AccountEntry.fromJson(e as Map<String, dynamic>))
          .toList();
    } else {
      accts = [AccountEntry(accountIndex: 0, name: json['name'] as String)];
    }
    return WalletProfile(
      id: json['id'] as String,
      name: json['name'] as String,
      createdAt: DateTime.parse(json['createdAt'] as String),
      isWatchOnly: json['isWatchOnly'] as bool? ?? false,
      lastOpenedAt: json['lastOpenedAt'] != null
          ? DateTime.parse(json['lastOpenedAt'] as String)
          : null,
      lastBalance: json['lastBalance'] as int? ?? 0,
      lastSyncHeight: json['lastSyncHeight'] as int? ?? 0,
      accounts: accts,
    );
  }
}

class WalletRegistry {
  WalletRegistry._();
  static final instance = WalletRegistry._();

  static const _profilesKey = 'wallet_profiles';
  static const _activeKey = 'active_wallet_id';
  static const _migratedKey = 'wallet_migration_v1_done';

  List<WalletProfile>? _cache;

  Future<List<WalletProfile>> getAll() async {
    if (_cache != null) return _cache!;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_profilesKey);
    if (raw == null) {
      _cache = [];
      return _cache!;
    }
    try {
      final list = jsonDecode(raw) as List;
      _cache = list
          .map((e) => WalletProfile.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      _cache = [];
    }
    return _cache!;
  }

  Future<WalletProfile?> getById(String id) async {
    final all = await getAll();
    try {
      return all.firstWhere((w) => w.id == id);
    } catch (_) {
      return null;
    }
  }

  Future<WalletProfile> create(String name, {bool watchOnly = false}) async {
    final profile = WalletProfile(
      id: _generateUuid(),
      name: name,
      createdAt: DateTime.now(),
      isWatchOnly: watchOnly,
    );
    final all = await getAll();
    all.add(profile);
    await _persist(all);
    return profile;
  }

  Future<void> rename(String id, String name) async {
    final all = await getAll();
    final profile = all.where((w) => w.id == id).firstOrNull;
    if (profile == null) return;
    profile.name = name;
    if (profile.accounts.length == 1) {
      profile.accounts.first.name = name;
    }
    await _persist(all);
  }

  Future<void> delete(String id) async {
    final all = await getAll();
    all.removeWhere((w) => w.id == id);
    await _persist(all);

    final prefs = await SharedPreferences.getInstance();
    final activeId = prefs.getString(_activeKey);
    if (activeId == id) {
      if (all.isNotEmpty) {
        await prefs.setString(_activeKey, all.first.id);
      } else {
        await prefs.remove(_activeKey);
      }
    }
  }

  Future<void> setActive(String id) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_activeKey, id);
    final all = await getAll();
    final profile = all.where((w) => w.id == id).firstOrNull;
    if (profile != null) {
      profile.lastOpenedAt = DateTime.now();
      await _persist(all);
    }
  }

  Future<String?> getActiveId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_activeKey);
  }

  Future<void> updateSnapshot(String id,
      {int? balance, int? syncHeight}) async {
    final all = await getAll();
    final profile = all.where((w) => w.id == id).firstOrNull;
    if (profile == null) return;
    if (balance != null) profile.lastBalance = balance;
    if (syncHeight != null) profile.lastSyncHeight = syncHeight;
    await _persist(all);
  }

  /// Insert a pre-built profile (used during migration).
  Future<void> addProfile(WalletProfile profile) async {
    final all = await getAll();
    if (all.any((w) => w.id == profile.id)) return;
    all.add(profile);
    await _persist(all);
  }

  /// Add a derived account entry to a wallet profile.
  Future<AccountEntry?> addAccount(String walletId, {String? name}) async {
    final all = await getAll();
    final profile = all.where((w) => w.id == walletId).firstOrNull;
    if (profile == null) return null;
    final idx = profile.nextAccountIndex;
    final entry = AccountEntry(
      accountIndex: idx,
      name: name ?? 'Account ${idx + 1}',
    );
    profile.accounts.add(entry);
    await _persist(all);
    return entry;
  }

  /// Hide (soft-remove) an account within a wallet.
  Future<void> hideAccount(String walletId, int accountIndex) async {
    final all = await getAll();
    final profile = all.where((w) => w.id == walletId).firstOrNull;
    if (profile == null) return;
    final acct = profile.accountAt(accountIndex);
    if (acct != null) {
      acct.isHidden = true;
      await _persist(all);
    }
  }

  /// Unhide an account within a wallet.
  Future<void> unhideAccount(String walletId, int accountIndex) async {
    final all = await getAll();
    final profile = all.where((w) => w.id == walletId).firstOrNull;
    if (profile == null) return;
    final acct = profile.accountAt(accountIndex);
    if (acct != null) {
      acct.isHidden = false;
      await _persist(all);
    }
  }

  /// Update a specific account's cached balance.
  Future<void> updateAccountBalance(
      String walletId, int accountIndex, int balance) async {
    final all = await getAll();
    final profile = all.where((w) => w.id == walletId).firstOrNull;
    if (profile == null) return;
    final acct = profile.accountAt(accountIndex);
    if (acct != null) {
      acct.lastBalance = balance;
      await _persist(all);
    }
  }

  /// Rename an account within a wallet.
  Future<void> renameAccount(
      String walletId, int accountIndex, String newName) async {
    final all = await getAll();
    final profile = all.where((w) => w.id == walletId).firstOrNull;
    if (profile == null) return;
    final acct = profile.accountAt(accountIndex);
    if (acct != null) {
      acct.name = newName;
      await _persist(all);
    }
  }

  /// Get a flat list of all visible accounts across all wallets.
  Future<List<FlatAccount>> getAllVisibleAccounts() async {
    final all = await getAll();
    final result = <FlatAccount>[];
    var idx = 0;
    for (final profile in all) {
      for (final acct in profile.visibleAccounts) {
        result.add(FlatAccount(
          walletId: profile.id,
          walletName: profile.name,
          walletBalance: profile.lastBalance,
          account: acct,
          flatIndex: idx,
        ));
        idx++;
      }
    }
    return result;
  }

  Future<bool> isMigrated() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_migratedKey) ?? false;
  }

  Future<void> markMigrated() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_migratedKey, true);
  }

  void invalidateCache() => _cache = null;

  Future<void> _persist(List<WalletProfile> profiles) async {
    _cache = profiles;
    final prefs = await SharedPreferences.getInstance();
    final json = jsonEncode(profiles.map((p) => p.toJson()).toList());
    await prefs.setString(_profilesKey, json);
  }

  static String _generateUuid() {
    final rng = Random.secure();
    final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-'
        '${hex.substring(20)}';
  }
}

/// A flattened view of a single account with its parent wallet context.
class FlatAccount {
  final String walletId;
  final String walletName;
  final int walletBalance;
  final AccountEntry account;
  final int flatIndex;

  static const _defaultNames = {
    'Main Wallet', 'Restored Wallet', 'Testnet Wallet', 'Main',
  };

  FlatAccount({
    required this.walletId,
    required this.walletName,
    required this.walletBalance,
    required this.account,
    required this.flatIndex,
  });

  int get accountIndex => account.accountIndex;
  int get lastBalance => walletBalance;

  /// Show "Account 1", "Account 2", ... unless the user explicitly renamed it.
  String get displayName {
    if (!_defaultNames.contains(walletName)) return walletName;
    return 'Account ${flatIndex + 1}';
  }
}
