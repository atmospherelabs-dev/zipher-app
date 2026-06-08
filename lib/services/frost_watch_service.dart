import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../pages/frost/frost_approve.dart';
import '../router.dart';
import 'app_log.dart';
import 'frost_push_service.dart';
import 'frost_service.dart';
import 'wallet_registry.dart';
import 'wallet_service.dart';

final _log = createLogger();

/// Polls FROST co-signer wallets for pending signing requests and surfaces
/// local notifications + deep links to the approval screen.
class FrostWatchService {
  FrostWatchService._();
  static final instance = FrostWatchService._();

  Timer? _timer;
  bool _polling = false;
  final _notifiedSessions = <String>{};

  void start() {
    if (_timer != null) return;
    _timer = Timer.periodic(const Duration(seconds: 20), (_) => poll());
    _log.i('[FROST] watch service started');
    poll();
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _log.i('[FROST] watch service stopped');
  }

  void onAppResumed() => poll();

  Future<void> poll() async {
    if (_polling) return;
    _polling = true;
    try {
      final all = await FrostService.instance.loadAllMetadata();
      for (final entry in all.entries) {
        if (entry.value.participantId == 1) continue;
        final peek = await FrostService.instance
            .peekSigningRequest(walletId: entry.key);
        if (peek == null) continue;
        if (_notifiedSessions.contains(peek.sessionId)) continue;
        _notifiedSessions.add(peek.sessionId);
        final request = FrostApprovalRequest.fromPeek(peek, entry.key);
        _log.i(
            '[FROST] approval request detected session=${peek.sessionId.substring(0, 6)}… wallet=${entry.key.substring(0, 6)}…');
        await FrostPushService.instance.showApprovalRequest(request);
      }
    } catch (e) {
      _log.w('[FROST] watch poll error: $e');
    } finally {
      _polling = false;
    }
  }

  void handleNotificationPayload(String? payload) {
    if (payload == null) return;
    if (!FrostPushService.instance.isFrostApprovalPayload(payload)) return;
    final params = Uri.splitQueryString(payload);
    openApprovalFromPayload(params);
  }

  Future<void> openApprovalFromPayload(Map<String, String?> payload) async {
    final request = FrostApprovalRequest.fromPayload(payload);
    if (request.sessionId.isEmpty || request.walletId.isEmpty) return;

    final context = rootNavigatorKey.currentContext;
    if (context == null) {
      _log.w('[FROST] cannot open approval — no navigator context');
      return;
    }

    await _ensureWalletActive(context, request.walletId);

    if (!context.mounted) return;
    GoRouter.of(context).push(
      '/frost/approve',
      extra: FrostApprovalArgs(
        sessionId: request.sessionId,
        walletName: request.walletLabel,
        destination: request.destination,
        zatoshis: request.zatoshis,
        feeZec: request.feeZec,
        memoPreview: request.memoPreview,
      ),
    );
  }

  Future<void> openApprovalFromUri(Uri uri) async {
    if (uri.scheme != 'zipher') return;
    if (uri.host != 'frost') return;
    if (uri.pathSegments.isEmpty || uri.pathSegments.first != 'approve') {
      return;
    }
    await openApprovalFromPayload(uri.queryParameters);
  }

  Future<void> _ensureWalletActive(
    BuildContext context,
    String walletKey,
  ) async {
    final profileId = _profileIdFromWalletKey(walletKey);
    final registry = WalletRegistry.instance;
    final profiles = await registry.getAll();
    final profile = profiles.where((p) => p.id == profileId).firstOrNull;
    if (profile == null) {
      _log.w('[FROST] wallet profile missing for approval');
      return;
    }
    if (WalletService.instance.activeWalletId == profile.id) return;
    await WalletService.instance.openWalletById(profile.id);
  }

  static String _profileIdFromWalletKey(String walletKey) {
    const suffix = '_testnet';
    if (walletKey.endsWith(suffix)) {
      return walletKey.substring(0, walletKey.length - suffix.length);
    }
    return walletKey;
  }
}
