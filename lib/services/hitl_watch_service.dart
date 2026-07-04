import 'dart:async';
import 'dart:convert';

import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../router.dart';
import 'app_log.dart';

final _log = createLogger();

/// Represents a pending HITL approval request from a remote agent.
class HitlApprovalRequest {
  final String approvalId;
  final String channelId;
  final String address;
  final int amount;
  final double amountZec;
  final String? memoPreview;
  final String? contextId;
  final String toolName;
  final int createdAtUnix;
  final int expiresAtUnix;

  HitlApprovalRequest({
    required this.approvalId,
    required this.channelId,
    required this.address,
    required this.amount,
    required this.amountZec,
    this.memoPreview,
    this.contextId,
    required this.toolName,
    required this.createdAtUnix,
    required this.expiresAtUnix,
  });

  factory HitlApprovalRequest.fromJson(Map<String, dynamic> json) {
    return HitlApprovalRequest(
      approvalId: json['approval_id'] ?? '',
      channelId: json['channel_id'] ?? '',
      address: json['address'] ?? '',
      amount: json['amount'] ?? 0,
      amountZec: (json['amount_zec'] ?? 0).toDouble(),
      memoPreview: json['memo_preview'],
      contextId: json['context_id'],
      toolName: json['tool_name'] ?? '',
      createdAtUnix: json['created_at_unix'] ?? 0,
      expiresAtUnix: json['expires_at_unix'] ?? 0,
    );
  }

  bool get isExpired =>
      DateTime.now().millisecondsSinceEpoch ~/ 1000 > expiresAtUnix;

  int get remainingSecs =>
      (expiresAtUnix - DateTime.now().millisecondsSinceEpoch ~/ 1000)
          .clamp(0, 300);
}

/// Pairing configuration stored in SharedPreferences.
class HitlPairingConfig {
  final String channelId;
  final String relayUrl;
  final String deviceName;
  final int pairedAtUnix;

  HitlPairingConfig({
    required this.channelId,
    required this.relayUrl,
    required this.deviceName,
    required this.pairedAtUnix,
  });

  factory HitlPairingConfig.fromJson(Map<String, dynamic> json) {
    return HitlPairingConfig(
      channelId: json['channel_id'] ?? '',
      relayUrl: json['relay_url'] ?? '',
      deviceName: json['device_name'] ?? '',
      pairedAtUnix: json['paired_at_unix'] ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
        'channel_id': channelId,
        'relay_url': relayUrl,
        'device_name': deviceName,
        'paired_at_unix': pairedAtUnix,
      };
}

/// Service that polls the HITL relay for pending approval requests
/// and shows notifications / approval UI in the mobile app.
class HitlWatchService {
  HitlWatchService._();
  static final instance = HitlWatchService._();

  static const _prefsKey = 'hitl_pairing';

  Timer? _timer;
  bool _polling = false;
  final _notifiedIds = <String>{};
  HitlPairingConfig? _config;

  bool get isPaired => _config != null;
  HitlPairingConfig? get config => _config;

  /// Initialize from stored preferences.
  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw != null) {
      try {
        _config = HitlPairingConfig.fromJson(jsonDecode(raw));
        _log.i('[HITL] Loaded pairing: channel=${_config!.channelId.substring(0, 8)}...');
      } catch (e) {
        _log.w('[HITL] Failed to parse pairing config: $e');
      }
    }
  }

  /// Save pairing from a scanned QR code URI.
  Future<void> pairFromUri(Uri uri) async {
    final channelId = uri.queryParameters['channel'] ?? '';
    final relay = uri.queryParameters['relay'] ?? 'https://relay.atmospherelabs.dev';
    if (channelId.isEmpty) {
      _log.w('[HITL] Invalid pairing URI: missing channel');
      return;
    }

    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    _config = HitlPairingConfig(
      channelId: channelId,
      relayUrl: relay,
      deviceName: 'mobile',
      pairedAtUnix: now,
    );

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, jsonEncode(_config!.toJson()));
    _log.i('[HITL] Paired with channel=${channelId.substring(0, 8)}...');
    start();
  }

  /// Unpair and stop polling.
  Future<void> unpair() async {
    stop();
    _config = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefsKey);
    _log.i('[HITL] Unpaired');
  }

  /// Start polling the relay for pending approvals.
  void start() {
    if (_config == null) return;
    if (_timer != null) return;
    _timer = Timer.periodic(const Duration(seconds: 5), (_) => poll());
    _log.i('[HITL] Watch service started');
    poll();
  }

  /// Stop polling.
  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  void onAppResumed() {
    if (_config != null) poll();
  }

  /// Poll the relay for pending approval requests.
  Future<void> poll() async {
    if (_polling || _config == null) return;
    _polling = true;
    try {
      final url = '${_config!.relayUrl}/api/hitl/pending/${_config!.channelId}';
      final resp = await http.get(Uri.parse(url)).timeout(
        const Duration(seconds: 10),
      );
      if (resp.statusCode != 200) return;

      final List<dynamic> items = jsonDecode(resp.body);
      for (final item in items) {
        final request = HitlApprovalRequest.fromJson(item);
        if (request.isExpired) continue;
        if (_notifiedIds.contains(request.approvalId)) continue;
        _notifiedIds.add(request.approvalId);
        _log.i('[HITL] New approval request: ${request.approvalId} '
            '${request.amountZec} ZEC to ${request.address.substring(0, 12)}...');
        _showApprovalDialog(request);
      }
    } catch (e) {
      _log.w('[HITL] Poll error: $e');
    } finally {
      _polling = false;
    }
  }

  /// Submit an approve/reject decision back to the relay.
  Future<bool> submitDecision(
    String approvalId, {
    required bool approved,
    String? reason,
  }) async {
    if (_config == null) return false;
    try {
      final url = '${_config!.relayUrl}/api/hitl/decision';
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final resp = await http
          .post(
            Uri.parse(url),
            headers: {
              'Content-Type': 'application/json',
              'X-Channel-Id': _config!.channelId,
            },
            body: jsonEncode({
              'approval_id': approvalId,
              'approved': approved,
              'decided_at_unix': now,
              'reason': reason,
            }),
          )
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode == 200) {
        _log.i('[HITL] Decision submitted: $approvalId approved=$approved');
        return true;
      }
      _log.w('[HITL] Decision submit failed: ${resp.statusCode}');
      return false;
    } catch (e) {
      _log.e('[HITL] Decision submit error: $e');
      return false;
    }
  }

  void _showApprovalDialog(HitlApprovalRequest request) {
    final context = rootNavigatorKey.currentContext;
    if (context == null || !context.mounted) return;

    GoRouter.of(context).push(
      '/hitl/approve',
      extra: request,
    );
  }
}
