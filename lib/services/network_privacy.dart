import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../src/rust/api/engine_api.dart' as engine;
import 'app_log.dart';
import 'wallet_service.dart';

enum NetworkPrivacyState { direct, connecting, tor, error }

/// Only describes Zipher's Zcash transport. An external VPN cannot be verified
/// here, and market prices, other chains and swap providers use separate clients.
class NetworkPrivacy extends ChangeNotifier {
  NetworkPrivacy({
    required this.enable,
    required this.disable,
    required this.verify,
    required this.savePreference,
  });

  static const preferenceKey =
      'ironwood_tor_enabled'; // Preserve existing choice.
  static final instance = NetworkPrivacy(
    enable: () async => engine.engineEnableTor(
        dataDir: await WalletService.instance.walletDir()),
    disable: engine.engineDisableTor,
    verify: () async => (await engine.engineVerifyTor()).toInt(),
    savePreference: (enabled) async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(preferenceKey, enabled);
    },
  );

  final Future<void> Function() enable;
  final Future<void> Function() disable;
  final Future<int> Function() verify;
  final Future<void> Function(bool) savePreference;
  NetworkPrivacyState state = NetworkPrivacyState.direct;
  int? verifiedHeight;
  bool get busy => state == NetworkPrivacyState.connecting;
  String get label => switch (state) {
        NetworkPrivacyState.direct => 'Direct connection',
        NetworkPrivacyState.connecting => 'Connecting to Tor',
        NetworkPrivacyState.tor => 'Tor · Zcash',
        NetworkPrivacyState.error => 'Tor needs attention',
      };

  Future<void> restore() async {
    final prefs = await SharedPreferences.getInstance();
    verifiedHeight = null;
    state = NetworkPrivacyState.direct;
    notifyListeners();
    if (prefs.getBool(preferenceKey) ?? false) {
      try {
        await setTor(true);
      } catch (_) {
        // Keep the user's preference and the engine's fail-closed policy.
      }
    }
  }

  Future<void> setTor(bool enabled) async {
    if (busy) throw StateError('A connection change is already in progress.');
    verifiedHeight = null;
    state = NetworkPrivacyState.connecting;
    notifyListeners();
    AppLog.instance
        .event('privacy', enabled ? 'tor_requested' : 'direct_requested');
    try {
      // Persist the intent even if bootstrap fails. Restart must not silently
      // turn an unavailable private route into a direct connection.
      if (enabled) {
        await savePreference(true);
        await enable();
        verifiedHeight = await verify().timeout(const Duration(seconds: 40));
      } else {
        await disable();
        await savePreference(false);
      }
      state = enabled ? NetworkPrivacyState.tor : NetworkPrivacyState.direct;
      AppLog.instance
          .event('privacy', enabled ? 'tor_verified' : 'direct_enabled');
    } catch (error) {
      state = NetworkPrivacyState.error;
      AppLog.instance
          .event('privacy', 'connection_change_failed', detail: '$error');
      rethrow;
    } finally {
      notifyListeners();
    }
  }
}
