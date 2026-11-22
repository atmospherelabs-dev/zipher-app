import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../src/rust/api/engine_api.dart' as engine;
import 'app_log.dart';
import 'wallet_service.dart';

enum NetworkPrivacyState { direct, connecting, tor, error }

/// Covers the native Zcash transport. External VPNs
/// cannot be verified; prices and other-chain balance clients remain separate.
class NetworkPrivacy extends ChangeNotifier {
  NetworkPrivacy({
    required this.enable,
    required this.disable,
    required this.verify,
    required this.savePreference,
    this.loadPreference = _loadPreference,
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
      if (!await prefs.setBool(preferenceKey, enabled)) {
        throw StateError('The connection preference could not be saved.');
      }
    },
  );

  final Future<void> Function() enable;
  final Future<void> Function() disable;
  final Future<int> Function() verify;
  final Future<void> Function(bool) savePreference;
  final Future<bool> Function() loadPreference;
  static Future<bool> _loadPreference() async =>
      (await SharedPreferences.getInstance()).getBool(preferenceKey) ?? false;
  bool _ready = false;
  String? _serverUrl;
  Future<void>? _preparation;
  int _walletEpoch = 0;

  /// A reopened native wallet must pass the saved-policy gate again.
  void invalidateWallet() {
    _walletEpoch++;
    _ready = false;
    _serverUrl = null;
    verifiedHeight = null;
  }

  NetworkPrivacyState state = NetworkPrivacyState.direct;
  int? verifiedHeight;
  bool get busy => state == NetworkPrivacyState.connecting;
  String get label => switch (state) {
        NetworkPrivacyState.direct => 'Direct connection',
        NetworkPrivacyState.connecting => 'Connecting to Tor',
        NetworkPrivacyState.tor => 'Tor · Zcash',
        NetworkPrivacyState.error => 'Tor needs attention',
      };

  /// Establish the saved route before the first wallet network operation.
  /// The pre-wallet verifier uses the guarded height API, which needs no DB.
  Future<void> ensureReady({
    String? serverUrl,
    Future<int> Function()? verifyConnection,
  }) async {
    final epoch = _walletEpoch;
    final pending = _preparation;
    if (pending != null) await pending;
    _requireWalletEpoch(epoch);
    if (_ready && (serverUrl == null || serverUrl == _serverUrl)) return;
    final preparation = restore(verifyConnection: verifyConnection);
    _preparation = preparation;
    try {
      await preparation;
      _requireWalletEpoch(epoch);
      _serverUrl = serverUrl;
    } finally {
      if (identical(_preparation, preparation)) _preparation = null;
    }
  }

  Future<void> restore({Future<int> Function()? verifyConnection}) async {
    final epoch = _walletEpoch;
    _ready = false;
    verifiedHeight = null;
    final bool enabled;
    try {
      enabled = await loadPreference();
      _requireWalletEpoch(epoch);
    } catch (_) {
      state = NetworkPrivacyState.error;
      notifyListeners();
      rethrow;
    }
    // Apply direct explicitly as well: another wallet may have required Tor.
    // Errors propagate, so lifecycle/autosync cannot proceed after a failure.
    await setTor(enabled, verifyConnection: verifyConnection);
  }

  Future<void> setTor(bool enabled,
      {Future<int> Function()? verifyConnection}) async {
    final epoch = _walletEpoch;
    if (busy) throw StateError('A connection change is already in progress.');
    _ready = false;
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
        _requireWalletEpoch(epoch);
        await enable();
        _requireWalletEpoch(epoch);
        final height = await (verifyConnection ?? verify)()
            .timeout(const Duration(seconds: 40));
        _requireWalletEpoch(epoch);
        verifiedHeight = height;
      } else {
        await disable();
        _requireWalletEpoch(epoch);
        await savePreference(false);
        _requireWalletEpoch(epoch);
      }
      state = enabled ? NetworkPrivacyState.tor : NetworkPrivacyState.direct;
      _ready = true;
      AppLog.instance
          .event('privacy', enabled ? 'tor_verified' : 'direct_enabled');
    } catch (error) {
      verifiedHeight = null;
      state = NetworkPrivacyState.error;
      AppLog.instance
          .event('privacy', 'connection_change_failed', detail: '$error');
      rethrow;
    } finally {
      notifyListeners();
    }
  }

  void _requireWalletEpoch(int epoch) {
    if (epoch != _walletEpoch) {
      throw StateError('Wallet changed while preparing its connection. Retry.');
    }
  }
}
