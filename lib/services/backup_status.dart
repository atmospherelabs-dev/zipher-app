import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../coin/coins.dart' show isTestnet;

/// Whether each wallet's recovery phrase has been backed up, so home can
/// remind newcomers without forcing the phrase onto the screen at creation.
///
/// Stores only booleans and a snooze time, never key material. Keyed by
/// wallet id AND network: a wallet's testnet phrase is independent of its
/// mainnet phrase. A wallet counts as backed up once its 3-word check passes,
/// or when it was restored (the user already had the phrase to restore it).
///
/// The old backup screen saved a single flag shared by every wallet
/// (`seed_verified_<coin>_<id>`, id always 1). It is deliberately ignored:
/// treating it as "backed up" would mark wallets that never were. Erring
/// towards one extra reminder is harmless; a false "backed up" is not.
class BackupStatus {
  BackupStatus._();
  static final instance = BackupStatus._();

  /// How long "Later" hides the reminder.
  static const snooze = Duration(hours: 24);

  /// True when home should show the backup reminder for the open wallet.
  final needsReminder = ValueNotifier<bool>(false);
  String? _walletId;
  bool _testnet = false;

  static String _scope(String walletId, bool testnet) =>
      testnet ? 'testnet_$walletId' : walletId;
  static String verifiedKey(String walletId, {required bool testnet}) =>
      'backup_verified_${_scope(walletId, testnet)}';
  static String _snoozeKey(String walletId, bool testnet) =>
      'backup_snoozed_until_${_scope(walletId, testnet)}';

  /// Re-reads the state for [walletId] on the current network.
  Future<void> load(String? walletId,
      {bool? testnet, DateTime Function()? now}) async {
    final network = testnet ?? isTestnet;
    _walletId = walletId;
    _testnet = network;
    if (walletId == null || walletId.isEmpty) {
      needsReminder.value = false;
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    if (_walletId != walletId || _testnet != network) return;
    final verified =
        prefs.getBool(verifiedKey(walletId, testnet: network)) ?? false;
    final until = prefs.getInt(_snoozeKey(walletId, network)) ?? 0;
    final clock = (now ?? DateTime.now)().millisecondsSinceEpoch;
    needsReminder.value = !verified && clock >= until;
  }

  /// Whether [walletId] has passed the backup check on the given network.
  static Future<bool> isBackedUp(String? walletId, {bool? testnet}) async {
    if (walletId == null || walletId.isEmpty) return false;
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(verifiedKey(walletId, testnet: testnet ?? isTestnet)) ??
        false;
  }

  Future<void> markBackedUp(String? walletId, {bool? testnet}) async {
    if (walletId == null || walletId.isEmpty) return;
    final network = testnet ?? isTestnet;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(verifiedKey(walletId, testnet: network), true);
    if (_walletId == walletId && _testnet == network) {
      needsReminder.value = false;
    }
  }

  Future<void> remindLater(String? walletId,
      {bool? testnet, DateTime Function()? now}) async {
    if (walletId == null || walletId.isEmpty) return;
    final network = testnet ?? isTestnet;
    final prefs = await SharedPreferences.getInstance();
    final until = (now ?? DateTime.now)().add(snooze).millisecondsSinceEpoch;
    await prefs.setInt(_snoozeKey(walletId, network), until);
    if (_walletId == walletId && _testnet == network) {
      needsReminder.value = false;
    }
  }
}
