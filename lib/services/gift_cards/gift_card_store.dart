import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'gift_card_order.dart';

/// Where codes live. Separate so tests can use memory.
abstract class GiftCardSecrets {
  Future<void> write(String key, String value);
  Future<String?> read(String key);
  Future<void> delete(String key);
}

class KeychainGiftCardSecrets implements GiftCardSecrets {
  const KeychainGiftCardSecrets();
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions:
        IOSOptions(accessibility: KeychainAccessibility.first_unlock_this_device),
  );
  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);
  @override
  Future<String?> read(String key) => _storage.read(key: key);
  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

/// A delivered card: what the user needs at the till.
class GiftCardRedemption {
  const GiftCardRedemption({this.code, this.pin, this.url, this.instructions});
  final String? code;
  final String? pin;
  final String? url;
  final String? instructions;

  bool get isEmpty =>
      (code == null || code!.isEmpty) && (url == null || url!.isEmpty);

  Map<String, dynamic> toJson() => {
        if (code != null) 'code': code,
        if (pin != null) 'pin': pin,
        if (url != null) 'url': url,
        if (instructions != null) 'instructions': instructions,
      };

  static GiftCardRedemption fromJson(Map<String, dynamic> j) =>
      GiftCardRedemption(
          code: j['code'] as String?,
          pin: j['pin'] as String?,
          url: j['url'] as String?,
          instructions: j['instructions'] as String?);
}

/// Device-local order history. Order records (no codes) sit in
/// SharedPreferences so the list renders without a Keychain prompt; codes and
/// PINs are written to the Keychain / Android Keystore only.
///
/// Nothing here leaves the device.
class GiftCardStore {
  GiftCardStore({GiftCardSecrets? secrets})
      : _secrets = secrets ?? const KeychainGiftCardSecrets();

  static final instance = GiftCardStore();
  static const _key = 'gift_card_orders_v1';
  final GiftCardSecrets _secrets;

  static String _codeKey(String provider, String id) =>
      'giftcard_code_${provider}_$id';

  Future<List<GiftCardOrder>> orders({String? walletId}) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return [];
    final list = (jsonDecode(raw) as List)
        .map((e) => GiftCardOrder.fromJson(e as Map<String, dynamic>))
        .where((o) => walletId == null || o.walletId == walletId)
        .toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return list;
  }

  Future<GiftCardOrder?> find(String provider, String id) async {
    for (final o in await orders()) {
      if (o.provider == provider && o.id == id) return o;
    }
    return null;
  }

  /// Insert or replace by (provider, id). Must complete before signing so an
  /// interrupted payment is still recoverable from history.
  Future<void> save(GiftCardOrder order) async {
    final prefs = await SharedPreferences.getInstance();
    final all = await orders();
    all.removeWhere((o) => o.provider == order.provider && o.id == order.id);
    all.add(order);
    final ok = await prefs.setString(
        _key, jsonEncode(all.map((o) => o.toJson()).toList()));
    if (!ok) throw StateError('The gift card order could not be saved.');
  }

  Future<void> saveRedemption(
      GiftCardOrder order, GiftCardRedemption redemption) async {
    await _secrets.write(
        _codeKey(order.provider, order.id), jsonEncode(redemption.toJson()));
  }

  Future<GiftCardRedemption?> redemption(GiftCardOrder order) async {
    final raw = await _secrets.read(_codeKey(order.provider, order.id));
    if (raw == null) return null;
    return GiftCardRedemption.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  /// Removes the record and its code. Only for orders the user chose to
  /// forget; a code that was never used is lost with it.
  Future<void> remove(GiftCardOrder order) async {
    final prefs = await SharedPreferences.getInstance();
    final all = await orders()
      ..removeWhere((o) => o.provider == order.provider && o.id == order.id);
    await prefs.setString(_key, jsonEncode(all.map((o) => o.toJson()).toList()));
    await _secrets.delete(_codeKey(order.provider, order.id));
  }
}
