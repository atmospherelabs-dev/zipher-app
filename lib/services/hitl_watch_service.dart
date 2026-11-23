import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../coin/coins.dart';
import '../router.dart';
import '../src/rust/api/engine_api.dart' as rust_engine;
import 'app_log.dart';

final _log = createLogger();

/// Approvals for remote agents (zipher-cli / zipher-mcp-server), protocol v1.
///
/// The relay only carries ciphertext. The phone's keys and its relay token live
/// in platform secure storage; approval decisions are signed with a key that
/// never leaves this device. Logs never include addresses or amounts.
class HitlWatchService {
  HitlWatchService._();
  static final instance = HitlWatchService._();

  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
  );
  static const _keysKey = 'hitl_phone_keys_v1';
  static const _pairingKey = 'hitl_pairing_v1';
  static const _legacyPrefsKey = 'hitl_pairing';

  Timer? _timer;
  bool _polling = false;
  final _shownIds = <String>{};
  final _openIds = <String>{};
  String? _pairingJson;
  String? _agentName;

  bool get isPaired => _pairingJson != null;
  String? get agentName => _agentName;

  @visibleForTesting
  void debugSetPaired(String? agentName) {
    _agentName = agentName;
    _pairingJson = agentName == null ? null : '{}';
  }

  Future<void> init() async {
    // The pre-v1 plaintext pairing cannot be upgraded; drop it.
    final prefs = await SharedPreferences.getInstance();
    if (prefs.containsKey(_legacyPrefsKey)) {
      await prefs.remove(_legacyPrefsKey);
      _log.i('[HITL] Removed legacy pairing; pair again with `zipher pair`');
    }
    try {
      _pairingJson = await _storage.read(key: _pairingKey);
      _agentName = _pairingJson == null ? null : _readAgentName(_pairingJson!);
    } on PlatformException catch (e) {
      _log.w('[HITL] Secure storage unavailable: ${e.code}');
    }
  }

  String? _readAgentName(String json) {
    final m = RegExp(r'"agent_name"\s*:\s*"((?:[^"\\]|\\.)*)"').firstMatch(json);
    return m?.group(1);
  }

  /// A `zipher://pair` link was opened or scanned. Never pairs silently:
  /// shows the confirmation screen with the check code.
  Future<void> openPairing(String uri) async {
    final rust_engine.HitlPairingPreview preview;
    try {
      preview = await rust_engine.hitlPreviewPairing(uri: uri);
    } catch (e) {
      _log.w('[HITL] Ignored an invalid pairing link: $e');
      return;
    }
    // A link that launches the app can arrive while it is still unlocking or
    // loading the wallet. Wait for the navigator instead of dropping it.
    var context = rootNavigatorKey.currentContext;
    for (var i = 0; i < 60 && (context == null || !context.mounted); i++) {
      await Future.delayed(const Duration(milliseconds: 500));
      context = rootNavigatorKey.currentContext;
    }
    if (context == null || !context.mounted) {
      _log.w('[HITL] Pairing link arrived but the app never became ready');
      return;
    }
    try {
      GoRouter.of(context).push('/hitl/pair', extra: HitlPairingArgs(uri, preview));
      _log.i('[HITL] Showing pairing confirmation');
    } catch (e) {
      _log.e('[HITL] Could not open pairing confirmation: $e');
    }
  }

  /// Called after the user confirmed the check code and authenticated.
  Future<void> completePairing(String uri) async {
    var keys = await _storage.read(key: _keysKey);
    if (keys == null) {
      keys = await rust_engine.hitlGeneratePhoneKeys();
      await _storage.write(key: _keysKey, value: keys);
    }
    final pairingJson =
        await rust_engine.hitlCompletePairing(uri: uri, keysHex: keys);
    final old = _pairingJson;
    await _storage.write(key: _pairingKey, value: pairingJson);
    _pairingJson = pairingJson;
    _agentName = _readAgentName(pairingJson);
    _shownIds.clear();
    if (old != null) {
      unawaited(rust_engine.hitlUnpair(pairingJson: old).catchError((_) {}));
    }
    _log.i('[HITL] Paired with an agent');
    start();
  }

  Future<void> unpair() async {
    stop();
    final old = _pairingJson;
    _pairingJson = null;
    _agentName = null;
    await _storage.delete(key: _pairingKey);
    if (old != null) {
      try {
        await rust_engine.hitlUnpair(pairingJson: old);
      } catch (_) {
        // The channel also expires on the relay side.
      }
    }
    _log.i('[HITL] Unpaired');
  }

  void start() {
    if (_pairingJson == null || _timer != null) return;
    _timer = Timer.periodic(const Duration(seconds: 5), (_) => poll());
    poll();
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  void onAppResumed() {
    // Requests closed without a decision come back when the app returns.
    // Answered ones are gone from the relay, so they never reappear.
    _shownIds.retainAll(_openIds);
    if (_pairingJson != null) poll();
  }

  Future<void> poll() async {
    final pairing = _pairingJson;
    if (_polling || pairing == null) return;
    _polling = true;
    try {
      final keys = await _storage.read(key: _keysKey);
      if (keys == null) return;
      final requests =
          await rust_engine.hitlFetchRequests(pairingJson: pairing, keysHex: keys);
      final network = isTestnet ? 'test' : 'main';
      for (final r in requests) {
        if (_shownIds.contains(r.approvalId)) continue;
        _shownIds.add(r.approvalId);
        if (r.network != network) {
          _log.w('[HITL] Ignored a request for another network');
          continue;
        }
        _log.i('[HITL] Approval request received');
        _showApproval(r);
      }
    } catch (e) {
      if (e.toString().contains('unpaired')) {
        // The agent closed the channel; stop asking a relay that will never answer.
        _log.i('[HITL] Agent unpaired; clearing local pairing');
        await unpair();
      } else {
        _log.w('[HITL] Poll failed');
      }
    } finally {
      _polling = false;
    }
  }

  /// Sign and send the decision. The caller must have shown the full request
  /// and passed the auth barrier before approving.
  Future<void> submitDecision(rust_engine.HitlRequest request,
      {required bool approved}) async {
    final pairing = _pairingJson;
    final keys = await _storage.read(key: _keysKey);
    if (pairing == null || keys == null) {
      throw StateError('No agent is paired');
    }
    await rust_engine.hitlSubmitDecision(
      pairingJson: pairing,
      keysHex: keys,
      requestJson: request.requestJson,
      approved: approved,
    );
    _log.i('[HITL] Decision sent (approved=$approved)');
  }

  void _showApproval(rust_engine.HitlRequest request) {
    final context = rootNavigatorKey.currentContext;
    if (context == null || !context.mounted) return;
    if (!_openIds.add(request.approvalId)) return;
    GoRouter.of(context).push('/hitl/approve', extra: request);
  }

  /// Called by the approval screen when it goes away, answered or not.
  void approvalClosed(String approvalId) => _openIds.remove(approvalId);
}

class HitlPairingArgs {
  final String uri;
  final rust_engine.HitlPairingPreview preview;
  HitlPairingArgs(this.uri, this.preview);
}
