import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;

import '../src/rust/api/engine_api.dart' as rust_engine;
import 'secure_key_store.dart';

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

class FrostRelayClient {
  final Uri baseUrl;
  String? accessToken;

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

  Future<void> closeSession(String sessionId) async {
    await _post('/close_session', {'session_id': sessionId});
  }
}

class FrostApprovalRequest {
  final String sessionId;
  final String walletId;
  final int zatoshis;
  final String destinationPreview;

  const FrostApprovalRequest({
    required this.sessionId,
    required this.walletId,
    required this.zatoshis,
    required this.destinationPreview,
  });

  Map<String, dynamic> toPushPayload() => {
        'type': 'frost_approval_request',
        'session_id': sessionId,
        'wallet_id': walletId,
      };

  String get localNotificationTitle => 'Shared wallet approval';

  String get localNotificationBody {
    final zec = (zatoshis / 100000000).toStringAsFixed(8);
    return 'Approve $zec ZEC to $destinationPreview';
  }
}

class FrostService {
  FrostService._();
  static final instance = FrostService._();

  static const defaultRelay = 'https://frost.atmospherelabs.dev';
  static const _metadataKey = 'frost_wallet_metadata_v1';

  final _rng = Random.secure();

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
    required rust_engine.ChainType chainType,
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

  Future<void> storeWalletShare({
    required String walletId,
    required String keyPackage,
    required FrostWalletMetadata metadata,
  }) async {
    await SecureKeyStore.storeFrostKeyPackage(walletId, keyPackage);
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
}
