import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Whether each wallet's recovery phrase has been backed up, so home can
/// remind newcomers without forcing the phrase onto the screen at creation.
///
/// Stores only booleans and a snooze time per wallet id, never key material.
/// A wallet counts as backed up once its 3-word check passes, or when it was
/// restored (the user already had the phrase to restore it).
class BackupStatus {
  BackupStatus._();
  static final instance = BackupStatus._();

  static const _verifiedKey = 'backup_verified_';
  static const _snoozeKey = 'backup_snoozed_until_';

  /// How long "Later" hides the reminder.
  static const snooze = Duration(hours: 24);

  /// True when home should show the backup reminder for the open wallet.
  final needsReminder = ValueNotifier<bool>(false);
  String? _walletId;

  /// Re-reads the state for [walletId] (call when the active wallet changes).
  Future<void> load(String? walletId, {DateTime Function()? now}) async {
    _walletId = walletId;
    if (walletId == null || walletId.isEmpty) {
      needsReminder.value = false;
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    if (_walletId != walletId) return;
    var verified = prefs.getBool('$_verifiedKey$walletId') ?? false;
    if (!verified && _legacyVerified(prefs)) {
      // Before per-wallet records, the backup screen saved one shared flag.
      // Honour it once for the wallet open now rather than nag a user who
      // already passed the check.
      verified = true;
      await prefs.setBool('$_verifiedKey$walletId', true);
      if (_walletId != walletId) return;
    }
    final until = prefs.getInt('$_snoozeKey$walletId') ?? 0;
    final clock = (now ?? DateTime.now)().millisecondsSinceEpoch;
    needsReminder.value = !verified && clock >= until;
  }

  static bool _legacyVerified(SharedPreferences prefs) => prefs
      .getKeys()
      .any((k) => k.startsWith('seed_verified_') && (prefs.getBool(k) ?? false));

  Future<void> markBackedUp(String? walletId) async {
    if (walletId == null || walletId.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('$_verifiedKey$walletId', true);
    if (_walletId == walletId) needsReminder.value = false;
  }

  Future<void> remindLater(String? walletId, {DateTime Function()? now}) async {
    if (walletId == null || walletId.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final until = (now ?? DateTime.now)().add(snooze).millisecondsSinceEpoch;
    await prefs.setInt('$_snoozeKey$walletId', until);
    if (_walletId == walletId) needsReminder.value = false;
  }
}
