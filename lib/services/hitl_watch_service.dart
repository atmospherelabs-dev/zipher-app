import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:go_router/go_router.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../coin/coins.dart';
import '../router.dart';
import '../src/rust/api/engine_api.dart' as rust_engine;
import 'app_log.dart';

final _log = createLogger();

/// Approvals for remote agents (zipher-cli / zipher-mcp-server), protocol v1.
///
/// The relay only carries fixed-size ciphertext in a mailbox that changes every
/// day, reached over Tor by default. The phone's keys and pairing live in
/// platform secure storage; decisions are signed with a key that never leaves
/// this device. Logs never include addresses or amounts.
///
/// Push is opt-in: with it on, the relay keeps this device's push token and
/// Apple sees when a wake-up arrives (never what it is for).
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
  static const _torPref = 'hitl_tor';
  static const _pushPref = 'hitl_push';
  static const _pushRefreshedPref = 'hitl_push_refreshed_day';
  static const _pairedAtPref = 'hitl_paired_at';
  static const _push = MethodChannel('zipher/push');

  Timer? _timer;
  bool _polling = false;
  final _shownIds = <String>{};
  final _openIds = <String>{};
  String? _pairingJson;
  String? _agentName;
  bool _useTor = true;
  bool _pushOn = false;
  String? _stateDir;

  /// Drives the home indicator and the Agent screen.
  final paired = ValueNotifier<bool>(false);

  bool get isPaired => _pairingJson != null;
  int? _pairedAt;
  int? get pairedAt => _pairedAt;
  String? get agentName => _agentName;
  bool get useTor => _useTor;
  bool get pushEnabled => _pushOn;
  /// Push wake-ups need APNs; Android keeps checking while the app is open.
  bool get pushSupported => Platform.isIOS;

  Future<String> _dir() async =>
      _stateDir ??= (await getApplicationDocumentsDirectory()).path;

  @visibleForTesting
  void debugSetPaired(String? agentName) {
    _agentName = agentName;
    _pairingJson = agentName == null ? null : '{}';
    paired.value = agentName != null;
  }

  Future<void> init() async {
    // The pre-v1 plaintext pairing cannot be upgraded; drop it.
    final prefs = await SharedPreferences.getInstance();
    if (prefs.containsKey(_legacyPrefsKey)) {
      await prefs.remove(_legacyPrefsKey);
      _log.i('[HITL] Removed legacy pairing; pair again with `zipher pair`');
    }
    _useTor = prefs.getBool(_torPref) ?? true;
    _pushOn = prefs.getBool(_pushPref) ?? false;
    try {
      _pairingJson = await _storage.read(key: _pairingKey);
      _agentName = _pairingJson == null ? null : _readAgentName(_pairingJson!);
      _pairedAt = prefs.getInt(_pairedAtPref);
      paired.value = _pairingJson != null;
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
  /// Returns the code the operator must see in their terminal.
  ///
  /// Every pairing gets fresh keys, so two agents (or the relay) can't link
  /// this phone across pairings, and an old agent's key is useless here.
  Future<String> completePairing(String uri) async {
    final keys = await rust_engine.hitlGeneratePhoneKeys();
    final pairingJson = await rust_engine.hitlCompletePairing(
        uri: uri, keysHex: keys, stateDir: await _dir(), useTor: _useTor);
    final code = await rust_engine.hitlPairedCode(pairingJson: pairingJson, keysHex: keys);
    final old = _pairingJson;
    await _storage.write(key: _keysKey, value: keys);
    await _storage.write(key: _pairingKey, value: pairingJson);
    _pairingJson = pairingJson;
    _agentName = _readAgentName(pairingJson);
    _pairedAt = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_pairedAtPref, _pairedAt!);
    paired.value = true;
    _shownIds.clear();
    if (old != null) {
      unawaited(rust_engine
          .hitlUnpair(pairingJson: old, stateDir: await _dir(), useTor: _useTor)
          .catchError((_) {}));
    }
    _log.i('[HITL] Paired with an agent');
    start();
    return code;
  }

  Future<void> unpair() async {
    stop();
    final old = _pairingJson;
    _pairingJson = null;
    _agentName = null;
    _pairedAt = null;
    paired.value = false;
    await _storage.delete(key: _pairingKey);
    (await SharedPreferences.getInstance()).remove(_pairedAtPref);
    if (_pushOn) {
      await _setPushPref(false);
      unawaited(_push.invokeMethod('unregister').catchError((_) {}));
    }
    if (old != null) {
      try {
        await rust_engine.hitlUnpair(pairingJson: old, stateDir: await _dir(), useTor: _useTor);
      } catch (_) {
        // The mailboxes also expire on the relay side.
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
    if (_pairingJson != null) {
      poll();
      unawaited(_refreshPushIfDue());
    }
  }

  // ---------------------------------------------------------------------------
  // Settings
  // ---------------------------------------------------------------------------

  Future<void> setUseTor(bool on) async {
    _useTor = on;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_torPref, on);
    _log.i('[HITL] Relay route: ${on ? 'Tor' : 'direct'}');
  }

  Future<void> _setPushPref(bool on) async {
    _pushOn = on;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_pushPref, on);
    if (!on) await prefs.remove(_pushRefreshedPref);
  }

  /// Ask iOS for permission and register this device for wake-ups on the
  /// coming week's mailboxes.
  Future<PushResult> enablePush() async {
    final pairing = _pairingJson;
    if (pairing == null || !pushSupported) return PushResult.failed;
    final String? token;
    try {
      token = await _push.invokeMethod<String>('register');
    } on PlatformException catch (e) {
      return e.code == 'denied' ? PushResult.denied : PushResult.failed;
    }
    if (token == null) return PushResult.failed;
    final sandbox = await _push.invokeMethod<bool>('isSandbox') ?? false;
    await rust_engine.hitlSetPush(
        pairingJson: pairing, apnsToken: token, sandbox: sandbox, stateDir: await _dir(), useTor: _useTor);
    await _setPushPref(true);
    await _markPushRefreshed();
    _log.i('[HITL] Notifications on');
    return PushResult.on;
  }

  /// iOS only asks once; after a refusal the switch lives in Settings.
  Future<void> openNotificationSettings() => _push.invokeMethod('openSettings');

  Future<void> disablePush() async {
    final pairing = _pairingJson;
    await _setPushPref(false);
    unawaited(_push.invokeMethod('unregister').catchError((_) {}));
    if (pairing != null) {
      try {
        await rust_engine.hitlSetPush(
            pairingJson: pairing, apnsToken: null, sandbox: false, stateDir: await _dir(), useTor: _useTor);
      } catch (_) {
        // Tokens on unused mailboxes expire with them.
      }
    }
    _log.i('[HITL] Notifications off');
  }

  int get _today => DateTime.now().toUtc().millisecondsSinceEpoch ~/ 86400000;

  Future<void> _markPushRefreshed() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_pushRefreshedPref, _today);
  }

  /// Push covers a rolling week of mailboxes; extend it once a day.
  Future<void> _refreshPushIfDue() async {
    if (!_pushOn || _pairingJson == null) return;
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getInt(_pushRefreshedPref) == _today) return;
    try {
      await enablePush();
    } catch (_) {
      _log.w('[HITL] Could not refresh notifications');
    }
  }

  Future<void> poll() async {
    final pairing = _pairingJson;
    if (_polling || pairing == null) return;
    _polling = true;
    try {
      final keys = await _storage.read(key: _keysKey);
      if (keys == null) return;
      // Startup replaces the whole screen stack when it lands on the wallet;
      // wait for that, or an approval shown now would be wiped.
      if (!_appReady()) return;
      final requests = await rust_engine.hitlFetchRequests(
          pairingJson: pairing, keysHex: keys, stateDir: await _dir(), useTor: _useTor);
      for (final r in requests) {
        if (!claimHitlRequestForDisplay(
            approvalId: r.approvalId,
            requestNetwork: r.network,
            testnet: isTestnet,
            shownIds: _shownIds)) continue;
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
      stateDir: await _dir(),
      useTor: _useTor,
    );
    _log.i('[HITL] Decision sent (approved=$approved)');
  }

  bool _appReady() {
    final context = rootNavigatorKey.currentContext;
    if (context == null || !context.mounted) return false;
    final path = GoRouter.of(context).routerDelegate.currentConfiguration.uri.path;
    return path.isNotEmpty && path != '/splash' && path != '/';
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

enum PushResult { on, denied, failed }

class HitlPairingArgs {
  final String uri;
  final rust_engine.HitlPairingPreview preview;
  HitlPairingArgs(this.uri, this.preview);
}

/// Whether a fetched approval request should be shown now, marking it shown.
///
/// A request for the other network is left unmarked: it appears once the
/// user switches to that network, instead of being dropped until the app
/// next goes to the background.
@visibleForTesting
bool claimHitlRequestForDisplay({
  required String approvalId,
  required String requestNetwork,
  required bool testnet,
  required Set<String> shownIds,
}) {
  if (requestNetwork != (testnet ? 'test' : 'main')) return false;
  return shownIds.add(approvalId);
}
