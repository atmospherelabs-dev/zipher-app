import 'dart:math';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:logger/logger.dart';

final _logger = Logger();

class SecureKeyStore {
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
  );

  static String _seedKey(int coin, int accountId) =>
      'seed_${coin}_$accountId';

  static String _indexKey(int coin, int accountId) =>
      'seed_index_${coin}_$accountId';

  static Future<void> storeSeed(
      int coin, int accountId, String seed, int index) async {
    await _storage.write(key: _seedKey(coin, accountId), value: seed);
    await _storage.write(
        key: _indexKey(coin, accountId), value: index.toString());
  }

  static Future<String?> getSeed(int coin, int accountId) async {
    try {
      return await _storage.read(key: _seedKey(coin, accountId));
    } on PlatformException catch (e) {
      _logger.e('Keystore read failed for account $coin/$accountId: $e');
      return null;
    }
  }

  static Future<int> getIndex(int coin, int accountId) async {
    try {
      final v = await _storage.read(key: _indexKey(coin, accountId));
      return v != null ? int.parse(v) : 0;
    } on PlatformException catch (e) {
      _logger.e('Keystore index read failed for $coin/$accountId: $e');
      return 0;
    }
  }

  static Future<void> deleteSeed(int coin, int accountId) async {
    await _storage.delete(key: _seedKey(coin, accountId));
    await _storage.delete(key: _indexKey(coin, accountId));
  }

  static Future<bool> hasSeed(int coin, int accountId) async {
    try {
      final v = await _storage.read(key: _seedKey(coin, accountId));
      return v != null && v.isNotEmpty;
    } on PlatformException catch (e) {
      _logger.e('Keystore probe failed for $coin/$accountId: $e');
      return false;
    }
  }

  /// Returns true if the platform keystore is readable/writable.
  static Future<bool> isKeystoreHealthy() async {
    const testKey = '_zipher_keystore_probe';
    try {
      await _storage.write(key: testKey, value: 'ok');
      final v = await _storage.read(key: testKey);
      await _storage.delete(key: testKey);
      return v == 'ok';
    } on PlatformException catch (e) {
      _logger.e('Keystore health check failed: $e');
      return false;
    }
  }

  // ── DB encryption key ──

  static const _dbKeyPrefix = 'db_cipher_key_';

  static Future<String> getOrCreateDbKey(int coin) async {
    final key = '$_dbKeyPrefix$coin';
    try {
      final existing = await _storage.read(key: key);
      if (existing != null && existing.isNotEmpty) return existing;
    } on PlatformException catch (e) {
      _logger.e('Keystore read DB key failed: $e');
    }
    final rng = Random.secure();
    final bytes = List<int>.generate(32, (_) => rng.nextInt(256));
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    await _storage.write(key: key, value: hex);
    return hex;
  }
}
