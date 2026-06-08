import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;

import '../src/rust/api/engine_api.dart' as rust_engine;
import '../src/rust/api/wallet.dart' as rust_wallet;
import 'app_log.dart';
import 'secure_key_store.dart';

final _log = createLogger();

String _redact(String? value, {int keep = 8}) {
  if (value == null || value.isEmpty) return '–';
  if (value.length <= keep * 2) return '${value.substring(0, keep)}…';
  return '${value.substring(0, keep)}…${value.substring(value.length - 4)}';
}

String _hexEncode(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

List<int> _hexDecode(String hex) {
  final normalized = hex.trim();
  if (normalized.length.isOdd) throw FormatException('Invalid hex length');
  final out = <int>[];
  for (var i = 0; i < normalized.length; i += 2) {
    out.add(int.parse(normalized.substring(i, i + 2), radix: 16));
  }
  return out;
}

class FrostInvite {
  final int version;
  final String relay;
  final String sessionId;
  final String label;
  final String coordinatorPubkey;
  final int threshold;
  final int participants;
  final DateTime expiresAt;

  const FrostInvite({
    this.version = 1,
    required this.relay,
    required this.sessionId,
    required this.label,
    required this.coordinatorPubkey,
    required this.threshold,
    required this.participants,
    required this.expiresAt,
  });

  Map<String, dynamic> toJson() => {
        'version': version,
        'relay': relay,
        'session_id': sessionId,
        'label': label,
        'coordinator_pubkey': coordinatorPubkey,
        'threshold': threshold,
        'participants': participants,
        'expires_at': expiresAt.toUtc().toIso8601String(),
      };

  factory FrostInvite.fromJson(Map<String, dynamic> json) {
    return FrostInvite(
      version: json['version'] as int? ?? 1,
      relay: json['relay'] as String,
      sessionId: json['session_id'] as String,
      label: json['label'] as String? ?? 'Shared wallet',
      coordinatorPubkey: json['coordinator_pubkey'] as String,
      threshold: json['threshold'] as int,
      participants: json['participants'] as int,
      expiresAt: DateTime.parse(json['expires_at'] as String),
    );
  }

  String encode() {
    final payload = base64Url.encode(utf8.encode(jsonEncode(toJson())));
    return 'zipher:frost:v$version:${payload.replaceAll('=', '')}';
  }

  static FrostInvite decode(String raw) {
    final parts = raw.trim().split(':');
    if (parts.length != 4 || parts[0] != 'zipher' || parts[1] != 'frost') {
      throw FormatException('Invalid FROST invite');
    }
    final version = int.tryParse(parts[2].replaceFirst('v', '')) ?? 1;
    var payload = parts[3];
    while (payload.length % 4 != 0) {
      payload += '=';
    }
    final json = jsonDecode(utf8.decode(base64Url.decode(payload)))
        as Map<String, dynamic>;
    final invite = FrostInvite.fromJson(json);
    if (invite.version != version) {
      throw FormatException('FROST invite version mismatch');
    }
    return invite;
  }
}

class FrostJoinResponse {
  final int version;
  final String relay;
  final String coordinatorPubkey;
  final String participantPubkey;
  final String participantLabel;
  final String round1Package;

  const FrostJoinResponse({
    this.version = 1,
    required this.relay,
    required this.coordinatorPubkey,
    required this.participantPubkey,
    required this.participantLabel,
    required this.round1Package,
  });

  Map<String, dynamic> toJson() => {
        'version': version,
        'relay': relay,
        'coordinator_pubkey': coordinatorPubkey,
        'participant_pubkey': participantPubkey,
        'participant_label': participantLabel,
        'round1_package': round1Package,
      };

  String encode() {
    final payload = base64Url.encode(utf8.encode(jsonEncode(toJson())));
    return 'zipher:frost-join:v$version:${payload.replaceAll('=', '')}';
  }

  static FrostJoinResponse decode(String raw) {
    final parts = raw.trim().split(':');
    if (parts.length != 4 || parts[0] != 'zipher' || parts[1] != 'frost-join') {
      throw FormatException('Invalid FROST join response');
    }
    final version = int.tryParse(parts[2].replaceFirst('v', '')) ?? 1;
    var payload = parts[3];
    while (payload.length % 4 != 0) {
      payload += '=';
    }
    final json = jsonDecode(utf8.decode(base64Url.decode(payload)))
        as Map<String, dynamic>;
    if ((json['version'] as int? ?? 1) != version) {
      throw FormatException('FROST join response version mismatch');
    }
    return FrostJoinResponse(
      version: version,
      relay: json['relay'] as String,
      coordinatorPubkey: json['coordinator_pubkey'] as String,
      participantPubkey: json['participant_pubkey'] as String,
      participantLabel: json['participant_label'] as String? ?? 'Co-signer',
      round1Package: json['round1_package'] as String,
    );
  }
}

class FrostParticipantPackage {
  final int participantId;
  final String package;

  const FrostParticipantPackage({
    required this.participantId,
    required this.package,
  });

  rust_engine.EngineFrostParticipantPackage toRust() {
    return rust_engine.EngineFrostParticipantPackage(
      participantId: participantId,
      package: package,
    );
  }

  static FrostParticipantPackage fromRust(
    rust_engine.EngineFrostParticipantPackage p,
  ) {
    return FrostParticipantPackage(
      participantId: p.participantId,
      package: p.package,
    );
  }
}

class FrostWalletMetadata {
  final String walletId;
  final String label;
  final String relay;
  final int threshold;
  final int participants;
  final int participantId;
  final String publicKeyPackage;
  final String groupPublicKeyHex;
  final String? relayPublicKeyHex;
  final String? coordinatorPubkey;
  final String? coSignerPubkey;
  final List<String> participantLabels;

  const FrostWalletMetadata({
    required this.walletId,
    required this.label,
    required this.relay,
    required this.threshold,
    required this.participants,
    required this.participantId,
    required this.publicKeyPackage,
    required this.groupPublicKeyHex,
    this.relayPublicKeyHex,
    this.coordinatorPubkey,
    this.coSignerPubkey,
    this.participantLabels = const [],
  });

  Map<String, dynamic> toJson() => {
        'wallet_id': walletId,
        'label': label,
        'relay': relay,
        'threshold': threshold,
        'participants': participants,
        'participant_id': participantId,
        'public_key_package': publicKeyPackage,
        'group_public_key_hex': groupPublicKeyHex,
        'relay_public_key_hex': relayPublicKeyHex,
        'coordinator_pubkey': coordinatorPubkey,
        'co_signer_pubkey': coSignerPubkey,
        'participant_labels': participantLabels,
      };

  factory FrostWalletMetadata.fromJson(Map<String, dynamic> json) {
    return FrostWalletMetadata(
      walletId: json['wallet_id'] as String,
      label: json['label'] as String,
      relay: json['relay'] as String,
      threshold: json['threshold'] as int,
      participants: json['participants'] as int,
      participantId: json['participant_id'] as int,
      publicKeyPackage: json['public_key_package'] as String,
      groupPublicKeyHex: json['group_public_key_hex'] as String,
      relayPublicKeyHex: json['relay_public_key_hex'] as String?,
      coordinatorPubkey: json['coordinator_pubkey'] as String?,
      coSignerPubkey: json['co_signer_pubkey'] as String?,
      participantLabels:
          (json['participant_labels'] as List?)?.cast<String>() ?? const [],
    );
  }
}

class FrostPcztSigningBundle {
  final Uint8List pczt;
  final rust_engine.EngineFrostPcztSigningRequest request;

  const FrostPcztSigningBundle({required this.pczt, required this.request});
}

class FrostLocalDkgResult {
  final rust_engine.EngineFrostDkgCompleteResult participant1;
  final rust_engine.EngineFrostDkgCompleteResult participant2;
  final rust_engine.EngineFrostDkgCompleteResult participant3;
  final rust_engine.EngineFrostWalletView view;

  const FrostLocalDkgResult({
    required this.participant1,
    required this.participant2,
    required this.participant3,
    required this.view,
  });
}

class FrostCoordinatorPending {
  final FrostInvite invite;
  final rust_engine.EngineFrostRelayIdentity identity;
  final rust_engine.EngineFrostDkgRound1Result participant1;
  final rust_engine.EngineFrostDkgRound1Result backupParticipant3;

  const FrostCoordinatorPending({
    required this.invite,
    required this.identity,
    required this.participant1,
    required this.backupParticipant3,
  });
}

class FrostJoinPending {
  final FrostInvite invite;
  final rust_engine.EngineFrostRelayIdentity identity;
  final rust_engine.EngineFrostDkgRound1Result participant2;
  final FrostJoinResponse response;

  const FrostJoinPending({
    required this.invite,
    required this.identity,
    required this.participant2,
    required this.response,
  });
}

class FrostRelayWalletResult {
  final String address;
  final String walletId;
  final String? backupKeyPackage;

  const FrostRelayWalletResult({
    required this.address,
    required this.walletId,
    this.backupKeyPackage,
  });
}

class FrostCoordinatorSigningSession {
  final String sessionId;
  final FrostPcztSigningBundle bundle;
  final FrostWalletMetadata metadata;
  final String relayPrivateKeyHex;

  const FrostCoordinatorSigningSession({
    required this.sessionId,
    required this.bundle,
    required this.metadata,
    required this.relayPrivateKeyHex,
  });
}

class FrostCosignerApprovalState {
  final String sessionId;
  final String coordinatorPubkey;
  final Map<int, String> nonceHandlesByAction;
  final Map<int, String> commitmentsByAction;
  final Map<String, dynamic> request;

  const FrostCosignerApprovalState({
    required this.sessionId,
    required this.coordinatorPubkey,
    required this.nonceHandlesByAction,
    required this.commitmentsByAction,
    required this.request,
  });
}

class FrostRelayClient {
  final Uri baseUrl;
  String? accessToken;
  String? privateKeyHex;
  String? publicKeyHex;

  FrostRelayClient(String baseUrl) : baseUrl = Uri.parse(baseUrl);

  Uri _uri(String path) => baseUrl.resolve(path);

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        if (accessToken != null) 'Authorization': 'Bearer $accessToken',
      };

  Future<Map<String, dynamic>> _post(
    String path, [
    Map<String, dynamic> body = const {},
  ]) async {
    final resp = await http.post(
      _uri(path),
      headers: _headers,
      body: jsonEncode(body),
    );
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw Exception('frostd $path failed (${resp.statusCode}): ${resp.body}');
    }
    if (resp.body.trim().isEmpty) return {};
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  Future<String> challenge() async {
    final json = await _post('/challenge');
    return json['challenge'] as String;
  }

  Future<String> login({
    required String challenge,
    required String pubkey,
    required String signature,
  }) async {
    final json = await _post('/login', {
      'challenge': challenge,
      'pubkey': pubkey,
      'signature': signature,
    });
    accessToken = json['access_token'] as String;
    return accessToken!;
  }

  Future<rust_engine.EngineFrostRelayIdentity> createIdentity() async {
    final identity = await rust_engine.engineFrostRelayGenerateIdentity();
    privateKeyHex = identity.privateKeyHex;
    publicKeyHex = identity.publicKeyHex;
    return identity;
  }

  Future<rust_engine.EngineFrostRelayIdentity> createIdentityAndLogin() async {
    final identity = await createIdentity();
    await loginWithIdentity(
      privateKeyHex: identity.privateKeyHex,
      publicKeyHex: identity.publicKeyHex,
    );
    return identity;
  }

  Future<String> loginWithIdentity({
    String? privateKeyHex,
    String? publicKeyHex,
  }) async {
    final priv = privateKeyHex ?? this.privateKeyHex;
    final pub = publicKeyHex ?? this.publicKeyHex;
    if (priv == null || pub == null) {
      throw StateError('FROST relay identity is missing');
    }
    this.privateKeyHex = priv;
    this.publicKeyHex = pub;
    final c = await challenge();
    final proof = await rust_engine.engineFrostRelaySignChallenge(
      privateKeyHex: priv,
      publicKeyHex: pub,
      challenge: c,
    );
    return login(
      challenge: c,
      pubkey: proof.pubkeyHex,
      signature: proof.signatureHex,
    );
  }

  Future<String> createSession({
    required List<String> pubkeys,
    int messageCount = 1,
  }) async {
    final json = await _post('/create_new_session', {
      'pubkeys': pubkeys,
      'message_count': messageCount,
    });
    return json['session_id'] as String;
  }

  Future<List<String>> listSessions() async {
    final json = await _post('/list_sessions');
    return (json['session_ids'] as List? ?? const []).cast<String>();
  }

  Future<Map<String, dynamic>> getSessionInfo(String sessionId) {
    return _post('/get_session_info', {'session_id': sessionId});
  }

  Future<void> send({
    required String sessionId,
    required List<String> recipients,
    required String messageHex,
  }) async {
    await _post('/send', {
      'session_id': sessionId,
      'recipients': recipients,
      'msg': messageHex,
    });
  }

  Future<void> sendEncrypted({
    required String sessionId,
    required List<String> recipients,
    required String recipientPublicKeyHex,
    required String messageHex,
  }) async {
    final priv = privateKeyHex;
    if (priv == null) throw StateError('FROST relay identity is missing');
    final encrypted = await rust_engine.engineFrostRelayEncrypt(
      senderPrivateKeyHex: priv,
      recipientPublicKeyHex: recipientPublicKeyHex,
      messageHex: messageHex,
    );
    await send(
      sessionId: sessionId,
      recipients: recipients,
      messageHex: encrypted,
    );
  }

  Future<List<Map<String, dynamic>>> receive({
    required String sessionId,
    required bool asCoordinator,
  }) async {
    final json = await _post('/receive', {
      'session_id': sessionId,
      'as_coordinator': asCoordinator,
    });
    return (json['msgs'] as List? ?? const [])
        .cast<Map>()
        .map((m) => m.cast<String, dynamic>())
        .toList();
  }

  Future<List<Map<String, dynamic>>> receiveAndDecrypt({
    required String sessionId,
    required bool asCoordinator,
  }) async {
    final priv = privateKeyHex;
    if (priv == null) throw StateError('FROST relay identity is missing');
    final msgs =
        await receive(sessionId: sessionId, asCoordinator: asCoordinator);
    final out = <Map<String, dynamic>>[];
    for (final msg in msgs) {
      final sender = msg['sender'] as String;
      final encrypted = msg['msg'] as String;
      final decrypted = await rust_engine.engineFrostRelayDecrypt(
        recipientPrivateKeyHex: priv,
        senderPublicKeyHex: sender,
        encryptedHex: encrypted,
      );
      out.add({
        'sender': sender,
        'msg': decrypted,
      });
    }
    return out;
  }

  Future<void> closeSession(String sessionId) async {
    await _post('/close_session', {'session_id': sessionId});
  }
}

class FrostApprovalRequest {
  final String sessionId;
  final String walletId;
  final int zatoshis;
  final String destination;
  final String destinationPreview;
  final String walletLabel;
  final String feeZec;
  final String? memoPreview;

  const FrostApprovalRequest({
    required this.sessionId,
    required this.walletId,
    required this.zatoshis,
    required this.destination,
    required this.destinationPreview,
    this.walletLabel = 'Shared wallet',
    this.feeZec = '–',
    this.memoPreview,
  });

  factory FrostApprovalRequest.fromPeek(
    FrostSigningRequestPeek peek,
    String walletId,
  ) {
    final request = peek.request;
    final destination = request['destination'] as String? ?? '';
    return FrostApprovalRequest(
      sessionId: peek.sessionId,
      walletId: walletId,
      zatoshis: request['zatoshis'] as int? ?? 0,
      destination: destination,
      destinationPreview: _redact(destination, keep: 10),
      walletLabel: request['wallet_label'] as String? ?? 'Shared wallet',
      memoPreview: request['memo_preview'] as String?,
      feeZec: '–',
    );
  }

  factory FrostApprovalRequest.fromPayload(Map<String, String?> payload) {
    final destination = payload['destination'] ?? '';
    return FrostApprovalRequest(
      sessionId: payload['session_id'] ?? '',
      walletId: payload['wallet_id'] ?? '',
      zatoshis: int.tryParse(payload['zatoshis'] ?? '') ?? 0,
      destination: destination,
      destinationPreview:
          payload['destination_preview'] ?? _redact(destination, keep: 10),
      walletLabel: payload['wallet_label'] ?? 'Shared wallet',
      feeZec: payload['fee_zec'] ?? '–',
      memoPreview: payload['memo_preview'],
    );
  }

  Map<String, dynamic> toPushPayload() => {
        'type': 'frost_approval_request',
        'session_id': sessionId,
        'wallet_id': walletId,
        'zatoshis': zatoshis.toString(),
        'destination': destination,
        'destination_preview': destinationPreview,
        'wallet_label': walletLabel,
        if (memoPreview != null) 'memo_preview': memoPreview,
        'fee_zec': feeZec,
      };

  String get localNotificationTitle => 'Shared wallet approval';

  String get localNotificationBody {
    final zec = (zatoshis / 100000000).toStringAsFixed(8);
    return 'Approve $zec ZEC to $destinationPreview';
  }
}

class FrostSigningRequestPeek {
  final String sessionId;
  final String coordinatorPubkey;
  final Map<String, dynamic> request;

  const FrostSigningRequestPeek({
    required this.sessionId,
    required this.coordinatorPubkey,
    required this.request,
  });
}

class FrostService {
  FrostService._();
  static final instance = FrostService._();

  static const defaultRelay = 'https://frost.atmospherelabs.dev';
  static const _metadataKey = 'frost_wallet_metadata_v1';

  final _rng = Random.secure();
  FrostCoordinatorPending? _pendingCoordinator;
  FrostJoinPending? _pendingJoiner;
  FrostCoordinatorSigningSession? _pendingSigningCoordinator;
  FrostCosignerApprovalState? _pendingCosignerApproval;

  String _randomHex(int bytes) {
    return List<int>.generate(bytes, (_) => _rng.nextInt(256))
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  FrostInvite createInvite({
    required String label,
    required int threshold,
    required int participants,
    String relay = defaultRelay,
    Duration ttl = const Duration(minutes: 30),
  }) {
    if (threshold < 2) throw ArgumentError('threshold must be at least 2');
    if (participants < threshold) {
      throw ArgumentError('participants must be >= threshold');
    }
    return FrostInvite(
      relay: relay,
      sessionId: 'sess_${_randomHex(16)}',
      label: label,
      coordinatorPubkey: _randomHex(32),
      threshold: threshold,
      participants: participants,
      expiresAt: DateTime.now().toUtc().add(ttl),
    );
  }

  Future<FrostCoordinatorPending> beginRelayCoordinator({
    required String label,
    String relay = defaultRelay,
  }) async {
    final client = FrostRelayClient(relay);
    final identity = await client.createIdentityAndLogin();
    final p1 = await dkgRound1(participantId: 1, threshold: 2, participants: 3);
    final p3 = await dkgRound1(participantId: 3, threshold: 2, participants: 3);
    final invite = FrostInvite(
      relay: relay,
      sessionId: 'pending',
      label: label,
      coordinatorPubkey: identity.publicKeyHex,
      threshold: 2,
      participants: 3,
      expiresAt: DateTime.now().toUtc().add(const Duration(minutes: 30)),
    );
    final pending = FrostCoordinatorPending(
      invite: invite,
      identity: identity,
      participant1: p1,
      backupParticipant3: p3,
    );
    _pendingCoordinator = pending;
    _log.i(
        '[FROST] relay coordinator started relay=${_redact(relay, keep: 12)} pubkey=${_redact(identity.publicKeyHex)}');
    return pending;
  }

  Future<FrostJoinPending> beginRelayJoin({
    required FrostInvite invite,
    required String participantLabel,
  }) async {
    final client = FrostRelayClient(invite.relay);
    final identity = await client.createIdentityAndLogin();
    final p2 = await dkgRound1(
      participantId: 2,
      threshold: invite.threshold,
      participants: invite.participants,
    );
    final response = FrostJoinResponse(
      relay: invite.relay,
      coordinatorPubkey: invite.coordinatorPubkey,
      participantPubkey: identity.publicKeyHex,
      participantLabel: participantLabel,
      round1Package: p2.round1Package,
    );
    final pending = FrostJoinPending(
      invite: invite,
      identity: identity,
      participant2: p2,
      response: response,
    );
    _pendingJoiner = pending;
    _log.i(
        '[FROST] joiner started label=${_redact(participantLabel, keep: 12)} relay=${_redact(invite.relay, keep: 12)}');
    return pending;
  }

  Future<rust_engine.EngineFrostDkgRound1Result> dkgRound1({
    required int participantId,
    required int threshold,
    required int participants,
  }) {
    return rust_engine.engineFrostDkgInit(
      participantId: participantId,
      maxSigners: participants,
      minSigners: threshold,
    );
  }

  Future<rust_engine.EngineFrostDkgRound2Result> dkgRound2({
    required String secretPackage,
    required List<FrostParticipantPackage> round1Packages,
  }) {
    return rust_engine.engineFrostDkgRound2(
      secretPackage: secretPackage,
      round1Packages: round1Packages.map((p) => p.toRust()).toList(),
    );
  }

  Future<rust_engine.EngineFrostDkgCompleteResult> dkgRound3({
    required String secretPackage,
    required List<FrostParticipantPackage> round1Packages,
    required List<FrostParticipantPackage> round2Packages,
  }) {
    return rust_engine.engineFrostDkgRound3(
      secretPackage: secretPackage,
      round1Packages: round1Packages.map((p) => p.toRust()).toList(),
      round2Packages: round2Packages.map((p) => p.toRust()).toList(),
    );
  }

  Future<FrostLocalDkgResult> createLocal2Of3View({
    required rust_wallet.ChainType chainType,
  }) async {
    final p1 = await dkgRound1(participantId: 1, threshold: 2, participants: 3);
    final p2 = await dkgRound1(participantId: 2, threshold: 2, participants: 3);
    final p3 = await dkgRound1(participantId: 3, threshold: 2, participants: 3);

    final r2_1 = await dkgRound2(
      secretPackage: p1.secretPackage,
      round1Packages: [
        FrostParticipantPackage(participantId: 2, package: p2.round1Package),
        FrostParticipantPackage(participantId: 3, package: p3.round1Package),
      ],
    );
    final r2_2 = await dkgRound2(
      secretPackage: p2.secretPackage,
      round1Packages: [
        FrostParticipantPackage(participantId: 1, package: p1.round1Package),
        FrostParticipantPackage(participantId: 3, package: p3.round1Package),
      ],
    );
    final r2_3 = await dkgRound2(
      secretPackage: p3.secretPackage,
      round1Packages: [
        FrostParticipantPackage(participantId: 1, package: p1.round1Package),
        FrostParticipantPackage(participantId: 2, package: p2.round1Package),
      ],
    );

    String packageFor(List<rust_engine.EngineFrostParticipantPackage> packages,
        int participantId) {
      return packages
          .firstWhere((p) => p.participantId == participantId)
          .package;
    }

    final c1 = await dkgRound3(
      secretPackage: r2_1.secretPackage,
      round1Packages: [
        FrostParticipantPackage(participantId: 2, package: p2.round1Package),
        FrostParticipantPackage(participantId: 3, package: p3.round1Package),
      ],
      round2Packages: [
        FrostParticipantPackage(
          participantId: 2,
          package: packageFor(r2_2.round2Packages, 1),
        ),
        FrostParticipantPackage(
          participantId: 3,
          package: packageFor(r2_3.round2Packages, 1),
        ),
      ],
    );
    final c2 = await dkgRound3(
      secretPackage: r2_2.secretPackage,
      round1Packages: [
        FrostParticipantPackage(participantId: 1, package: p1.round1Package),
        FrostParticipantPackage(participantId: 3, package: p3.round1Package),
      ],
      round2Packages: [
        FrostParticipantPackage(
          participantId: 1,
          package: packageFor(r2_1.round2Packages, 2),
        ),
        FrostParticipantPackage(
          participantId: 3,
          package: packageFor(r2_3.round2Packages, 2),
        ),
      ],
    );
    final c3 = await dkgRound3(
      secretPackage: r2_3.secretPackage,
      round1Packages: [
        FrostParticipantPackage(participantId: 1, package: p1.round1Package),
        FrostParticipantPackage(participantId: 2, package: p2.round1Package),
      ],
      round2Packages: [
        FrostParticipantPackage(
          participantId: 1,
          package: packageFor(r2_1.round2Packages, 3),
        ),
        FrostParticipantPackage(
          participantId: 2,
          package: packageFor(r2_2.round2Packages, 3),
        ),
      ],
    );

    final view = await rust_engine.engineFrostCreateViewFromGroupKey(
      groupPublicKeyHex: c1.groupPublicKeyHex,
      chainType: chainType,
    );
    return FrostLocalDkgResult(
      participant1: c1,
      participant2: c2,
      participant3: c3,
      view: view,
    );
  }

  Future<FrostRelayWalletResult> coordinatorAcceptJoin({
    required FrostJoinResponse response,
    required String walletName,
    required int birthday,
    required rust_wallet.ChainType chainType,
    required Future<String> Function(String ufvk, int birthday) importUfvk,
  }) async {
    final pending = _pendingCoordinator;
    if (pending == null) throw StateError('No pending FROST coordinator setup');
    if (response.coordinatorPubkey != pending.identity.publicKeyHex) {
      throw StateError('Join response is for a different coordinator');
    }

    final client = FrostRelayClient(pending.invite.relay);
    await client.loginWithIdentity(
      privateKeyHex: pending.identity.privateKeyHex,
      publicKeyHex: pending.identity.publicKeyHex,
    );
    final sessionId = await client.createSession(
      pubkeys: [response.participantPubkey],
      messageCount: 1,
    );

    final p1r2 = await dkgRound2(
      secretPackage: pending.participant1.secretPackage,
      round1Packages: [
        FrostParticipantPackage(
            participantId: 2, package: response.round1Package),
        FrostParticipantPackage(
          participantId: 3,
          package: pending.backupParticipant3.round1Package,
        ),
      ],
    );
    final p3r2 = await dkgRound2(
      secretPackage: pending.backupParticipant3.secretPackage,
      round1Packages: [
        FrostParticipantPackage(
          participantId: 1,
          package: pending.participant1.round1Package,
        ),
        FrostParticipantPackage(
            participantId: 2, package: response.round1Package),
      ],
    );

    String r2To(
            List<rust_engine.EngineFrostParticipantPackage> packages, int id) =>
        packages.firstWhere((p) => p.participantId == id).package;

    final msg = jsonEncode({
      'type': 'dkg_coordinator_packages_v1',
      'session_id': sessionId,
      'coordinator_round1': pending.participant1.round1Package,
      'backup_round1': pending.backupParticipant3.round1Package,
      'round2_to_participant2': r2To(p1r2.round2Packages, 2),
      'backup_round2_to_participant2': r2To(p3r2.round2Packages, 2),
      'wallet_name': walletName,
      'birthday': birthday,
    });
    await client.sendEncrypted(
      sessionId: sessionId,
      recipients: [response.participantPubkey],
      recipientPublicKeyHex: response.participantPubkey,
      messageHex: _hexEncode(utf8.encode(msg)),
    );

    Map<String, dynamic>? reply;
    final deadline = DateTime.now().add(const Duration(minutes: 3));
    while (DateTime.now().isBefore(deadline)) {
      final msgs = await client.receiveAndDecrypt(
          sessionId: sessionId, asCoordinator: true);
      for (final m in msgs) {
        final decoded = jsonDecode(utf8.decode(_hexDecode(m['msg'] as String)))
            as Map<String, dynamic>;
        if (decoded['type'] == 'dkg_participant_packages_v1') {
          reply = decoded;
          break;
        }
      }
      if (reply != null) break;
      await Future.delayed(const Duration(seconds: 2));
    }
    if (reply == null) {
      throw TimeoutException('Timed out waiting for co-signer DKG reply');
    }

    final c1 = await dkgRound3(
      secretPackage: p1r2.secretPackage,
      round1Packages: [
        FrostParticipantPackage(
            participantId: 2, package: response.round1Package),
        FrostParticipantPackage(
          participantId: 3,
          package: pending.backupParticipant3.round1Package,
        ),
      ],
      round2Packages: [
        FrostParticipantPackage(
          participantId: 2,
          package: reply['round2_to_participant1'] as String,
        ),
        FrostParticipantPackage(
            participantId: 3, package: r2To(p3r2.round2Packages, 1)),
      ],
    );
    final c3 = await dkgRound3(
      secretPackage: p3r2.secretPackage,
      round1Packages: [
        FrostParticipantPackage(
            participantId: 1, package: pending.participant1.round1Package),
        FrostParticipantPackage(
            participantId: 2, package: response.round1Package),
      ],
      round2Packages: [
        FrostParticipantPackage(
            participantId: 1, package: r2To(p1r2.round2Packages, 3)),
        FrostParticipantPackage(
          participantId: 2,
          package: reply['round2_to_participant3'] as String,
        ),
      ],
    );
    final view = await rust_engine.engineFrostCreateViewFromGroupKey(
      groupPublicKeyHex: c1.groupPublicKeyHex,
      chainType: chainType,
    );
    final walletId = await importUfvk(view.ufvk, birthday);
    await storeWalletShare(
      walletId: walletId,
      keyPackage: c1.keyPackage,
      metadata: FrostWalletMetadata(
        walletId: walletId,
        label: walletName,
        relay: pending.invite.relay,
        threshold: 2,
        participants: 3,
        participantId: c1.participantId,
        publicKeyPackage: c1.publicKeyPackage,
        groupPublicKeyHex: c1.groupPublicKeyHex,
        relayPublicKeyHex: pending.identity.publicKeyHex,
        coSignerPubkey: response.participantPubkey,
        participantLabels: ['This device', response.participantLabel, 'Backup'],
      ),
      relayPrivateKeyHex: pending.identity.privateKeyHex,
    );
    _pendingCoordinator = null;
    _log.i(
        '[FROST] coordinator wallet ready wallet=${_redact(walletId, keep: 6)} address=${_redact(view.address, keep: 10)}');
    return FrostRelayWalletResult(
      address: view.address,
      walletId: walletId,
      backupKeyPackage: c3.keyPackage,
    );
  }

  Future<FrostRelayWalletResult> joinerCompleteFromRelay({
    required String walletName,
    required rust_wallet.ChainType chainType,
    required Future<String> Function(String ufvk, int birthday) importUfvk,
  }) async {
    final pending = _pendingJoiner;
    if (pending == null) throw StateError('No pending FROST join setup');

    final client = FrostRelayClient(pending.invite.relay);
    await client.loginWithIdentity(
      privateKeyHex: pending.identity.privateKeyHex,
      publicKeyHex: pending.identity.publicKeyHex,
    );
    final sessions = await client.listSessions();
    if (sessions.isEmpty) throw StateError('No FROST session found');
    final sessionId = sessions.first;

    Map<String, dynamic>? incoming;
    final deadline = DateTime.now().add(const Duration(minutes: 3));
    while (DateTime.now().isBefore(deadline)) {
      final msgs = await client.receiveAndDecrypt(
        sessionId: sessionId,
        asCoordinator: false,
      );
      for (final m in msgs) {
        final decoded = jsonDecode(utf8.decode(_hexDecode(m['msg'] as String)))
            as Map<String, dynamic>;
        if (decoded['type'] == 'dkg_coordinator_packages_v1') {
          incoming = decoded;
          break;
        }
      }
      if (incoming != null) break;
      await Future.delayed(const Duration(seconds: 2));
    }
    if (incoming == null) {
      throw TimeoutException('Timed out waiting for coordinator DKG packages');
    }

    final r2 = await dkgRound2(
      secretPackage: pending.participant2.secretPackage,
      round1Packages: [
        FrostParticipantPackage(
          participantId: 1,
          package: incoming['coordinator_round1'] as String,
        ),
        FrostParticipantPackage(
          participantId: 3,
          package: incoming['backup_round1'] as String,
        ),
      ],
    );
    String r2To(
            List<rust_engine.EngineFrostParticipantPackage> packages, int id) =>
        packages.firstWhere((p) => p.participantId == id).package;

    final c2 = await dkgRound3(
      secretPackage: r2.secretPackage,
      round1Packages: [
        FrostParticipantPackage(
          participantId: 1,
          package: incoming['coordinator_round1'] as String,
        ),
        FrostParticipantPackage(
          participantId: 3,
          package: incoming['backup_round1'] as String,
        ),
      ],
      round2Packages: [
        FrostParticipantPackage(
          participantId: 1,
          package: incoming['round2_to_participant2'] as String,
        ),
        FrostParticipantPackage(
          participantId: 3,
          package: incoming['backup_round2_to_participant2'] as String,
        ),
      ],
    );

    final reply = jsonEncode({
      'type': 'dkg_participant_packages_v1',
      'round2_to_participant1': r2To(r2.round2Packages, 1),
      'round2_to_participant3': r2To(r2.round2Packages, 3),
    });
    await client.sendEncrypted(
      sessionId: sessionId,
      recipients: const [],
      recipientPublicKeyHex: pending.invite.coordinatorPubkey,
      messageHex: _hexEncode(utf8.encode(reply)),
    );

    final birthday = incoming['birthday'] as int? ?? 0;
    final view = await rust_engine.engineFrostCreateViewFromGroupKey(
      groupPublicKeyHex: c2.groupPublicKeyHex,
      chainType: chainType,
    );
    final walletId = await importUfvk(view.ufvk, birthday);
    await storeWalletShare(
      walletId: walletId,
      keyPackage: c2.keyPackage,
      metadata: FrostWalletMetadata(
        walletId: walletId,
        label: walletName,
        relay: pending.invite.relay,
        threshold: pending.invite.threshold,
        participants: pending.invite.participants,
        participantId: c2.participantId,
        publicKeyPackage: c2.publicKeyPackage,
        groupPublicKeyHex: c2.groupPublicKeyHex,
        relayPublicKeyHex: pending.identity.publicKeyHex,
        coordinatorPubkey: pending.invite.coordinatorPubkey,
        participantLabels: const ['Coordinator', 'This device', 'Backup'],
      ),
      relayPrivateKeyHex: pending.identity.privateKeyHex,
    );
    _pendingJoiner = null;
    _log.i(
        '[FROST] joiner wallet ready wallet=${_redact(walletId, keep: 6)} address=${_redact(view.address, keep: 10)}');
    return FrostRelayWalletResult(address: view.address, walletId: walletId);
  }

  Future<void> storeWalletShare({
    required String walletId,
    required String keyPackage,
    required FrostWalletMetadata metadata,
    String? relayPrivateKeyHex,
  }) async {
    await SecureKeyStore.storeFrostKeyPackage(walletId, keyPackage);
    if (relayPrivateKeyHex != null) {
      await SecureKeyStore.storeFrostRelayPrivateKey(
        walletId,
        relayPrivateKeyHex,
      );
    }
    final prefs = await SharedPreferences.getInstance();
    final all = await loadAllMetadata();
    all[walletId] = metadata;
    await prefs.setString(
        _metadataKey,
        jsonEncode(
          all.map((k, v) => MapEntry(k, v.toJson())),
        ));
  }

  Future<String?> getWalletShare(String walletId) {
    return SecureKeyStore.getFrostKeyPackage(walletId);
  }

  Future<Map<String, FrostWalletMetadata>> loadAllMetadata() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_metadataKey);
    if (raw == null || raw.isEmpty) return {};
    final map = jsonDecode(raw) as Map<String, dynamic>;
    return map.map(
      (k, v) => MapEntry(
        k,
        FrostWalletMetadata.fromJson(v as Map<String, dynamic>),
      ),
    );
  }

  Future<FrostWalletMetadata?> loadMetadata(String walletId) async {
    final all = await loadAllMetadata();
    return all[walletId];
  }

  Future<FrostPcztSigningBundle> createPcztSigningRequest() async {
    final pczt = await rust_engine.engineCreatePczt();
    final request = await rust_engine.engineFrostPcztSigningRequest(
      pcztBytes: pczt,
    );
    return FrostPcztSigningBundle(pczt: pczt, request: request);
  }

  Future<FrostPcztSigningBundle> createShieldPcztSigningRequest() async {
    final pczt = await rust_engine.engineCreateShieldPczt();
    final request = await rust_engine.engineFrostPcztSigningRequest(
      pcztBytes: pczt,
    );
    return FrostPcztSigningBundle(pczt: pczt, request: request);
  }

  Future<rust_engine.EngineFrostSigningRound1Result> signRound1({
    required String keyPackage,
  }) {
    return rust_engine.engineFrostSignRound1(keyPackage: keyPackage);
  }

  Future<String> createSigningPackage({
    required String sighashHex,
    required List<FrostParticipantPackage> commitments,
  }) {
    return rust_engine.engineFrostCreateSigningPackage(
      messageHex: sighashHex,
      commitments: commitments.map((p) => p.toRust()).toList(),
    );
  }

  Future<String> signRound2({
    required String signingPackage,
    required String signingNonces,
    required String keyPackage,
    required String randomizerPointHex,
  }) {
    return rust_engine.engineFrostSignRound2(
      signingPackage: signingPackage,
      signingNonces: signingNonces,
      keyPackage: keyPackage,
      randomizerPointHex: randomizerPointHex,
    );
  }

  Future<rust_engine.EngineFrostAggregateResult> aggregate({
    required String signingPackage,
    required List<FrostParticipantPackage> signatureShares,
    required String publicKeyPackage,
    required String randomizerHex,
  }) {
    return rust_engine.engineFrostAggregate(
      signingPackage: signingPackage,
      signatureShares: signatureShares.map((p) => p.toRust()).toList(),
      publicKeyPackage: publicKeyPackage,
      randomizerHex: randomizerHex,
    );
  }

  Future<Uint8List> applyPcztSignatures({
    required Uint8List pczt,
    required List<rust_engine.EngineFrostActionSignature> signatures,
  }) {
    return rust_engine.engineFrostPcztApplySignatures(
      pcztBytes: pczt,
      orchardSignatures: signatures,
    );
  }

  Future<String> storeSignedPczt(Uint8List pczt) {
    return rust_engine.engineStoreSignedPczt(signedPcztBytes: pczt);
  }

  Future<FrostCoordinatorSigningSession> startSigningSession({
    required String walletId,
    required FrostPcztSigningBundle bundle,
    required String destination,
    required int zatoshis,
    String? memoPreview,
  }) async {
    final metadata = await loadMetadata(walletId);
    if (metadata == null) throw StateError('FROST metadata missing');
    final relayPriv = await SecureKeyStore.getFrostRelayPrivateKey(walletId);
    final relayPub = metadata.relayPublicKeyHex;
    final coSigner = metadata.coSignerPubkey;
    if (relayPriv == null || relayPub == null || coSigner == null) {
      throw StateError('FROST relay identity or co-signer is missing');
    }

    final client = FrostRelayClient(metadata.relay);
    await client.loginWithIdentity(
      privateKeyHex: relayPriv,
      publicKeyHex: relayPub,
    );
    final sessionId = await client.createSession(
      pubkeys: [coSigner],
      messageCount: bundle.request.orchardActions.length,
    );
    final msg = jsonEncode({
      'type': 'frost_sign_request_v1',
      'session_id': sessionId,
      'wallet_id': walletId,
      'wallet_label': metadata.label,
      'destination': destination,
      'zatoshis': zatoshis,
      'memo_preview': memoPreview,
      'actions': bundle.request.orchardActions
          .map((a) => {
                'action_index': a.actionIndex,
                'sighash_hex': a.sighashHex,
                'randomizer_hex': a.randomizerHex,
                'randomizer_point_hex': a.randomizerPointHex,
              })
          .toList(),
    });
    await client.sendEncrypted(
      sessionId: sessionId,
      recipients: [coSigner],
      recipientPublicKeyHex: coSigner,
      messageHex: _hexEncode(utf8.encode(msg)),
    );
    final session = FrostCoordinatorSigningSession(
      sessionId: sessionId,
      bundle: bundle,
      metadata: metadata,
      relayPrivateKeyHex: relayPriv,
    );
    _pendingSigningCoordinator = session;
    _log.i(
        '[FROST] signing session started session=${_redact(sessionId, keep: 6)} wallet=${_redact(walletId, keep: 6)} zat=$zatoshis');
    return session;
  }

  Future<FrostSigningRequestPeek?> peekSigningRequest({
    required String walletId,
  }) async {
    final metadata = await loadMetadata(walletId);
    if (metadata == null) return null;
    if (metadata.participantId == 1) return null;
    final relayPriv = await SecureKeyStore.getFrostRelayPrivateKey(walletId);
    final relayPub = metadata.relayPublicKeyHex;
    if (relayPriv == null || relayPub == null) return null;

    final client = FrostRelayClient(metadata.relay);
    try {
      await client.loginWithIdentity(
        privateKeyHex: relayPriv,
        publicKeyHex: relayPub,
      );
    } catch (e) {
      _log.w('[FROST] relay login failed wallet=${_redact(walletId, keep: 6)}: $e');
      return null;
    }

    final sessions = await client.listSessions();
    if (sessions.isEmpty) return null;

    for (final sessionId in sessions) {
      final msgs = await client.receiveAndDecrypt(
        sessionId: sessionId,
        asCoordinator: false,
      );
      for (final m in msgs) {
        final request = jsonDecode(utf8.decode(_hexDecode(m['msg'] as String)))
            as Map<String, dynamic>;
        if (request['type'] != 'frost_sign_request_v1') continue;
        _log.d('[FROST] peek found session=${_redact(sessionId, keep: 6)}');
        return FrostSigningRequestPeek(
          sessionId: sessionId,
          coordinatorPubkey: m['sender'] as String,
          request: request,
        );
      }
    }
    return null;
  }

  Future<FrostCosignerApprovalState> receiveSigningRequest({
    required String walletId,
  }) async {
    final pending = _pendingCosignerApproval;
    if (pending != null) {
      _log.d('[FROST] reusing pending approval session=${_redact(pending.sessionId, keep: 6)}');
      return pending;
    }
    final metadata = await loadMetadata(walletId);
    if (metadata == null) throw StateError('FROST metadata missing');
    final relayPriv = await SecureKeyStore.getFrostRelayPrivateKey(walletId);
    final relayPub = metadata.relayPublicKeyHex;
    if (relayPriv == null || relayPub == null) {
      throw StateError('FROST relay identity is missing');
    }
    final keyPackage = await getWalletShare(walletId);
    if (keyPackage == null) throw StateError('FROST key share is missing');
    final client = FrostRelayClient(metadata.relay);
    await client.loginWithIdentity(
      privateKeyHex: relayPriv,
      publicKeyHex: relayPub,
    );
    final sessions = await client.listSessions();
    if (sessions.isEmpty) throw StateError('No pending FROST signing sessions');

    for (final sessionId in sessions) {
      final msgs = await client.receiveAndDecrypt(
        sessionId: sessionId,
        asCoordinator: false,
      );
      for (final m in msgs) {
        final request = jsonDecode(utf8.decode(_hexDecode(m['msg'] as String)))
            as Map<String, dynamic>;
        if (request['type'] != 'frost_sign_request_v1') continue;
        final actions = (request['actions'] as List).cast<Map>();
        final nonceHandles = <int, String>{};
        final commitments = <int, String>{};
        for (final action in actions) {
          final round1 = await signRound1(keyPackage: keyPackage);
          final index = action['action_index'] as int;
          nonceHandles[index] = round1.signingNonces;
          commitments[index] = round1.signingCommitments;
        }
        final state = FrostCosignerApprovalState(
          sessionId: sessionId,
          coordinatorPubkey: m['sender'] as String,
          nonceHandlesByAction: nonceHandles,
          commitmentsByAction: commitments,
          request: request,
        );
        _pendingCosignerApproval = state;
        _log.i(
            '[FROST] signing request loaded session=${_redact(sessionId, keep: 6)} actions=${actions.length}');
        return state;
      }
    }
    throw StateError('No signing request message found');
  }

  Future<void> approveSigningRequest({
    required String walletId,
  }) async {
    final state = _pendingCosignerApproval;
    if (state == null) throw StateError('No pending signing request');
    final metadata = await loadMetadata(walletId);
    if (metadata == null) throw StateError('FROST metadata missing');
    final relayPriv = await SecureKeyStore.getFrostRelayPrivateKey(walletId);
    final relayPub = metadata.relayPublicKeyHex;
    if (relayPriv == null || relayPub == null) {
      throw StateError('FROST relay identity is missing');
    }
    final client = FrostRelayClient(metadata.relay);
    await client.loginWithIdentity(
        privateKeyHex: relayPriv, publicKeyHex: relayPub);
    final msg = jsonEncode({
      'type': 'frost_sign_commitments_v1',
      'commitments':
          state.commitmentsByAction.map((k, v) => MapEntry(k.toString(), v)),
    });
    await client.sendEncrypted(
      sessionId: state.sessionId,
      recipients: const [],
      recipientPublicKeyHex: state.coordinatorPubkey,
      messageHex: _hexEncode(utf8.encode(msg)),
    );
    _log.i('[FROST] commitments sent session=${_redact(state.sessionId, keep: 6)}');
  }

  Future<void> cosignerFinishSigning({
    required String walletId,
  }) async {
    final state = _pendingCosignerApproval;
    if (state == null) throw StateError('No pending signing request');
    final metadata = await loadMetadata(walletId);
    if (metadata == null) throw StateError('FROST metadata missing');
    final relayPriv = await SecureKeyStore.getFrostRelayPrivateKey(walletId);
    final relayPub = metadata.relayPublicKeyHex;
    final keyPackage = await getWalletShare(walletId);
    if (relayPriv == null || relayPub == null || keyPackage == null) {
      throw StateError('FROST relay/key material is missing');
    }
    final client = FrostRelayClient(metadata.relay);
    await client.loginWithIdentity(
        privateKeyHex: relayPriv, publicKeyHex: relayPub);

    Map<String, dynamic>? pkg;
    final deadline = DateTime.now().add(const Duration(minutes: 3));
    while (DateTime.now().isBefore(deadline)) {
      final msgs = await client.receiveAndDecrypt(
        sessionId: state.sessionId,
        asCoordinator: false,
      );
      for (final m in msgs) {
        final decoded = jsonDecode(utf8.decode(_hexDecode(m['msg'] as String)))
            as Map<String, dynamic>;
        if (decoded['type'] == 'frost_signing_packages_v1') {
          pkg = decoded;
          break;
        }
      }
      if (pkg != null) break;
      await Future.delayed(const Duration(seconds: 2));
    }
    if (pkg == null)
      throw TimeoutException('Timed out waiting for signing package');

    final shares = <String, String>{};
    final packages = (pkg['packages'] as Map).cast<String, dynamic>();
    for (final entry in packages.entries) {
      final actionIndex = int.parse(entry.key);
      final data = (entry.value as Map).cast<String, dynamic>();
      shares[entry.key] = await signRound2(
        signingPackage: data['signing_package'] as String,
        signingNonces: state.nonceHandlesByAction[actionIndex]!,
        keyPackage: keyPackage,
        randomizerPointHex: data['randomizer_point_hex'] as String,
      );
    }
    final reply = jsonEncode({
      'type': 'frost_signature_shares_v1',
      'shares': shares,
    });
    await client.sendEncrypted(
      sessionId: state.sessionId,
      recipients: const [],
      recipientPublicKeyHex: state.coordinatorPubkey,
      messageHex: _hexEncode(utf8.encode(reply)),
    );
    _pendingCosignerApproval = null;
    _log.i('[FROST] signature shares sent session=${_redact(state.sessionId, keep: 6)}');
  }

  Future<Uint8List> coordinatorFinishSigning() async {
    final session = _pendingSigningCoordinator;
    if (session == null)
      throw StateError('No pending coordinator signing session');
    final relayPub = session.metadata.relayPublicKeyHex!;
    final coSigner = session.metadata.coSignerPubkey!;
    final localKey = await getWalletShare(session.metadata.walletId);
    if (localKey == null) throw StateError('Local FROST key share is missing');
    final client = FrostRelayClient(session.metadata.relay);
    await client.loginWithIdentity(
      privateKeyHex: session.relayPrivateKeyHex,
      publicKeyHex: relayPub,
    );

    Map<String, dynamic>? commitMsg;
    final deadline = DateTime.now().add(const Duration(minutes: 3));
    while (DateTime.now().isBefore(deadline)) {
      final msgs = await client.receiveAndDecrypt(
        sessionId: session.sessionId,
        asCoordinator: true,
      );
      for (final m in msgs) {
        final decoded = jsonDecode(utf8.decode(_hexDecode(m['msg'] as String)))
            as Map<String, dynamic>;
        if (decoded['type'] == 'frost_sign_commitments_v1') {
          commitMsg = decoded;
          break;
        }
      }
      if (commitMsg != null) break;
      await Future.delayed(const Duration(seconds: 2));
    }
    if (commitMsg == null)
      throw TimeoutException('Timed out waiting for commitments');

    final signingPackages = <String, Map<String, dynamic>>{};
    final localNonces = <int, String>{};
    final localCommitments = <int, String>{};
    final remoteCommitments =
        (commitMsg['commitments'] as Map).cast<String, dynamic>();
    for (final action in session.bundle.request.orchardActions) {
      final localRound1 = await signRound1(keyPackage: localKey);
      localNonces[action.actionIndex] = localRound1.signingNonces;
      localCommitments[action.actionIndex] = localRound1.signingCommitments;
      final signingPackage = await createSigningPackage(
        sighashHex: action.sighashHex,
        commitments: [
          FrostParticipantPackage(
            participantId: session.metadata.participantId,
            package: localRound1.signingCommitments,
          ),
          FrostParticipantPackage(
            participantId: 2,
            package: remoteCommitments[action.actionIndex.toString()] as String,
          ),
        ],
      );
      signingPackages[action.actionIndex.toString()] = {
        'signing_package': signingPackage,
        'randomizer_point_hex': action.randomizerPointHex,
      };
    }
    await client.sendEncrypted(
      sessionId: session.sessionId,
      recipients: [coSigner],
      recipientPublicKeyHex: coSigner,
      messageHex: _hexEncode(utf8.encode(jsonEncode({
        'type': 'frost_signing_packages_v1',
        'packages': signingPackages,
      }))),
    );

    Map<String, dynamic>? shareMsg;
    final deadline2 = DateTime.now().add(const Duration(minutes: 3));
    while (DateTime.now().isBefore(deadline2)) {
      final msgs = await client.receiveAndDecrypt(
        sessionId: session.sessionId,
        asCoordinator: true,
      );
      for (final m in msgs) {
        final decoded = jsonDecode(utf8.decode(_hexDecode(m['msg'] as String)))
            as Map<String, dynamic>;
        if (decoded['type'] == 'frost_signature_shares_v1') {
          shareMsg = decoded;
          break;
        }
      }
      if (shareMsg != null) break;
      await Future.delayed(const Duration(seconds: 2));
    }
    if (shareMsg == null)
      throw TimeoutException('Timed out waiting for signature shares');

    final actionSigs = <rust_engine.EngineFrostActionSignature>[];
    final remoteShares = (shareMsg['shares'] as Map).cast<String, dynamic>();
    for (final action in session.bundle.request.orchardActions) {
      final pkg = signingPackages[action.actionIndex.toString()]!;
      final localShare = await signRound2(
        signingPackage: pkg['signing_package'] as String,
        signingNonces: localNonces[action.actionIndex]!,
        keyPackage: localKey,
        randomizerPointHex: action.randomizerPointHex,
      );
      final agg = await aggregate(
        signingPackage: pkg['signing_package'] as String,
        signatureShares: [
          FrostParticipantPackage(
            participantId: session.metadata.participantId,
            package: localShare,
          ),
          FrostParticipantPackage(
            participantId: 2,
            package: remoteShares[action.actionIndex.toString()] as String,
          ),
        ],
        publicKeyPackage: session.metadata.publicKeyPackage,
        randomizerHex: action.randomizerHex,
      );
      actionSigs.add(rust_engine.EngineFrostActionSignature(
        actionIndex: action.actionIndex,
        signatureHex: agg.signatureHex,
      ));
    }
    final signed = await applyPcztSignatures(
      pczt: session.bundle.pczt,
      signatures: actionSigs,
    );
    _pendingSigningCoordinator = null;
    return signed;
  }
}
