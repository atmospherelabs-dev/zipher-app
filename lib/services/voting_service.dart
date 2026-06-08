import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'app_log.dart';

import '../src/rust/api/engine_api.dart' as rust_engine;

final _log = createLogger();

// =========================================================================
// Data models
// =========================================================================

class VoteServer {
  final String url;
  final String label;
  VoteServer({required this.url, required this.label});
  factory VoteServer.fromJson(Map<String, dynamic> json) =>
      VoteServer(url: json['url'] as String, label: json['label'] as String);
}

class PirEndpoint {
  final String url;
  final String label;
  PirEndpoint({required this.url, required this.label});
  factory PirEndpoint.fromJson(Map<String, dynamic> json) =>
      PirEndpoint(url: json['url'] as String, label: json['label'] as String);
}

class VoteProposal {
  final int id;
  final String title;
  final List<VoteOption> options;
  VoteProposal({required this.id, required this.title, required this.options});
  factory VoteProposal.fromJson(Map<String, dynamic> json) => VoteProposal(
        id: json['id'] as int,
        title: json['title'] as String,
        options: (json['options'] as List)
            .map((o) => VoteOption.fromJson(o))
            .toList(),
      );
}

class VoteOption {
  final int index;
  final String label;
  VoteOption({required this.index, required this.label});
  factory VoteOption.fromJson(Map<String, dynamic> json) =>
      VoteOption(index: json['index'] as int? ?? 0, label: json['label'] as String);
}

/// Merged config: dynamic config (servers/PIR) + chain round data.
class VoteConfig {
  final List<VoteServer> voteServers;
  final List<PirEndpoint> pirEndpoints;
  final String voteRoundId; // hex, 64 chars
  final String voteRoundIdB64; // base64 as returned by chain
  final String title;
  final String description;
  final int snapshotHeight;
  final int voteEndTime;
  final List<VoteProposal> proposals;
  final int status; // 1=ACTIVE, 2=TALLYING, 3=FINALIZED, 4=PENDING
  final String eaPk; // base64
  final String ncRoot; // base64
  final String nullifierImtRoot; // base64

  VoteConfig({
    required this.voteServers,
    required this.pirEndpoints,
    required this.voteRoundId,
    required this.voteRoundIdB64,
    required this.title,
    required this.description,
    required this.snapshotHeight,
    required this.voteEndTime,
    required this.proposals,
    required this.status,
    required this.eaPk,
    required this.ncRoot,
    required this.nullifierImtRoot,
  });

  bool get isActive => status == 1;
  bool get isExpired =>
      DateTime.now().millisecondsSinceEpoch ~/ 1000 > voteEndTime;

  String get statusLabel {
    switch (status) {
      case 1: return 'Active';
      case 2: return 'Tallying';
      case 3: return 'Finalized';
      case 4: return 'Pending';
      default: return 'Unknown';
    }
  }
}

class VotingEligibility {
  final BigInt eligibleWeight;
  final int noteCount;
  final int bundleCount;

  VotingEligibility({
    required this.eligibleWeight,
    required this.noteCount,
    required this.bundleCount,
  });

  double get eligibleZec => eligibleWeight.toDouble() / 100000000;
  bool get isEligible => eligibleWeight > BigInt.zero;
}

// =========================================================================
// Service
// =========================================================================

class VotingService {
  VotingService._();
  static final instance = VotingService._();

  static const _stagingStaticUrl =
      'https://raw.githubusercontent.com/valargroup/token-holder-voting-config/refs/heads/main/stage/static-voting-config.json';
  static const _productionStaticUrl =
      'https://raw.githubusercontent.com/valargroup/token-holder-voting-config/refs/heads/main/production/static-voting-config.json';

  VoteConfig? _config;
  VoteConfig? get config => _config;

  VotingEligibility? _eligibility;
  VotingEligibility? get eligibility => _eligibility;

  bool _cachesWarmed = false;

  DateTime? _lastConfigAttempt;
  static const _configCooldown = Duration(minutes: 5);

  /// Warm the proving key caches in a background isolate.
  Future<void> warmCaches() async {
    if (_cachesWarmed) return;
    _log.i('[VotingService] Warming proving caches...');
    try {
      await rust_engine.engineVoteWarmCaches();
      _cachesWarmed = true;
      _log.i('[VotingService] Proving caches warmed');
    } catch (e) {
      _log.e('[VotingService] Cache warm failed: $e');
    }
  }

  /// Full discovery: static config -> dynamic config -> chain active round.
  /// Pass [force] to bypass the cooldown.
  Future<VoteConfig?> discover({bool staging = false, bool force = false}) async {
    if (_config != null && !force) return _config;
    if (!force && _lastConfigAttempt != null &&
        DateTime.now().difference(_lastConfigAttempt!) < _configCooldown) {
      return null;
    }
    _lastConfigAttempt = DateTime.now();

    try {
      // 1. Fetch static config
      final staticUrl = staging ? _stagingStaticUrl : _productionStaticUrl;
      final staticResp = await http.get(Uri.parse(staticUrl))
          .timeout(const Duration(seconds: 15));
      if (staticResp.statusCode != 200) {
        _log.w('[VotingService] Static config not available (${staticResp.statusCode})');
        return null;
      }
      final staticJson = jsonDecode(staticResp.body) as Map<String, dynamic>;
      final dynamicUrl = staticJson['dynamic_config_url'] as String?;
      if (dynamicUrl == null || dynamicUrl.isEmpty) {
        _log.w('[VotingService] No dynamic_config_url in static config');
        return null;
      }

      // 2. Fetch dynamic config
      final dynResp = await http.get(Uri.parse(dynamicUrl))
          .timeout(const Duration(seconds: 15));
      if (dynResp.statusCode != 200) {
        _log.w('[VotingService] Dynamic config not available (${dynResp.statusCode})');
        return null;
      }
      final dynJson = jsonDecode(dynResp.body) as Map<String, dynamic>;

      final voteServers = (dynJson['vote_servers'] as List)
          .map((s) => VoteServer.fromJson(s as Map<String, dynamic>))
          .toList();
      final pirEndpoints = (dynJson['pir_endpoints'] as List)
          .map((p) => PirEndpoint.fromJson(p as Map<String, dynamic>))
          .toList();
      final roundsMap = dynJson['rounds'] as Map<String, dynamic>? ?? {};

      if (voteServers.isEmpty) {
        _log.w('[VotingService] No vote servers in dynamic config');
        return null;
      }

      _log.i('[VotingService] Dynamic config: ${voteServers.length} servers, ${pirEndpoints.length} PIR, ${roundsMap.length} rounds');

      // 3. Query chain for active round
      final serverUrl = voteServers.first.url;
      final roundResp = await http
          .get(Uri.parse('$serverUrl/shielded-vote/v1/rounds/active'))
          .timeout(const Duration(seconds: 15));

      if (roundResp.statusCode != 200) {
        _log.w('[VotingService] Active round fetch failed (${roundResp.statusCode})');
        return null;
      }

      final roundJson = jsonDecode(roundResp.body) as Map<String, dynamic>;
      final round = roundJson['round'] as Map<String, dynamic>?;
      if (round == null) {
        _log.i('[VotingService] No active round on chain');
        return null;
      }

      final roundIdB64 = round['vote_round_id'] as String? ?? '';
      final roundIdHex = _b64ToHex(roundIdB64);
      final status = round['status'] as int? ?? 0;
      final snapshotHeight = round['snapshot_height'] as int? ?? 0;
      final voteEndTime = round['vote_end_time'] as int? ?? 0;
      final title = round['title'] as String? ?? 'Governance Vote';
      final description = round['description'] as String? ?? '';
      final proposals = (round['proposals'] as List?)
              ?.map((p) => VoteProposal.fromJson(p as Map<String, dynamic>))
              .toList() ??
          [];

      // Get ea_pk: prefer the attested one from dynamic config, fall back to chain
      final roundData = roundsMap[roundIdHex] as Map<String, dynamic>?;
      final eaPk = roundData?['ea_pk'] as String? ??
          round['ea_pk'] as String? ??
          '';
      final ncRoot = round['nc_root'] as String? ?? '';
      final nullifierImtRoot = round['nullifier_imt_root'] as String? ?? '';

      _config = VoteConfig(
        voteServers: voteServers,
        pirEndpoints: pirEndpoints,
        voteRoundId: roundIdHex,
        voteRoundIdB64: roundIdB64,
        title: title,
        description: description,
        snapshotHeight: snapshotHeight,
        voteEndTime: voteEndTime,
        proposals: proposals,
        status: status,
        eaPk: eaPk,
        ncRoot: ncRoot,
        nullifierImtRoot: nullifierImtRoot,
      );

      _log.i('[VotingService] Round discovered: "$title" (${_config!.statusLabel}), '
          'snapshot=$snapshotHeight, ${proposals.length} proposals');
      return _config;
    } catch (e) {
      _log.e('[VotingService] Discovery failed: $e');
      return null;
    }
  }

  /// Check if the active wallet is eligible to vote.
  Future<VotingEligibility> checkEligibility(int snapshotHeight) async {
    final result = await rust_engine.engineVoteCheckEligibility(
      snapshotHeight: BigInt.from(snapshotHeight),
    );
    _eligibility = VotingEligibility(
      eligibleWeight: result.eligibleWeight,
      noteCount: result.noteCount,
      bundleCount: result.bundleCount,
    );
    _log.i(
      '[VotingService] Eligibility: ${_eligibility!.eligibleZec} ZEC, '
      '${_eligibility!.noteCount} notes, ${_eligibility!.bundleCount} bundles',
    );
    return _eligibility!;
  }

  /// Full discovery + eligibility check. Returns true if votable.
  Future<bool> discoverActiveRound() async {
    final config = await discover(staging: true);
    if (config == null || !config.isActive || config.isExpired) return false;

    final elig = await checkEligibility(config.snapshotHeight);
    return elig.isEligible;
  }

  /// Fetch tally results for a finalized round.
  Future<List<Map<String, dynamic>>?> fetchTallyResults(String roundIdHex) async {
    if (_config == null || _config!.voteServers.isEmpty) return null;

    final serverUrl = _config!.voteServers.first.url;
    try {
      final response = await http
          .get(Uri.parse(
              '$serverUrl/shielded-vote/v1/tally-results/$roundIdHex'))
          .timeout(const Duration(seconds: 15));

      if (response.statusCode != 200) return null;

      final json = jsonDecode(response.body) as Map<String, dynamic>;
      return (json['results'] as List?)?.cast<Map<String, dynamic>>();
    } catch (e) {
      _log.e('[VotingService] Tally fetch error: $e');
      return null;
    }
  }

  // =========================================================================
  // Full voting flow: delegate -> vote -> shares
  // =========================================================================

  Future<List<rust_engine.EngineDelegationResult>> performDelegation({
    required String seedPhrase,
    required void Function(String phase, double progress) onProgress,
  }) async {
    if (_config == null) {
      throw Exception('Vote config not loaded');
    }

    final pirUrl = _config!.pirEndpoints.first.url;

    onProgress('delegation', 0.0);

    // Re-fetch current round data so nullifier_imt_root is fresh
    // (the IMT changes as other users delegate)
    final freshRound = await _fetchActiveRound();
    final nfImtRoot = freshRound?['nullifier_imt_root'] as String?
        ?? _config!.nullifierImtRoot;
    final ncRoot = freshRound?['nc_root'] as String? ?? _config!.ncRoot;

    _log.i('[VotingService] Starting delegation (fresh IMT root)...');

    final results = await rust_engine.engineVoteDelegate(
      seedPhrase: seedPhrase,
      voteRoundId: _config!.voteRoundId,
      snapshotHeight: BigInt.from(_config!.snapshotHeight),
      eaPk: base64Decode(_config!.eaPk).toList(),
      ncRoot: base64Decode(ncRoot).toList(),
      nfImtRoot: base64Decode(nfImtRoot).toList(),
      pirUrl: pirUrl,
      networkId: 1,
    );

    onProgress('delegation', 1.0);
    _log.i('[VotingService] Delegation complete: ${results.length} bundles');
    return results;
  }

  /// Fetch the latest active round data from the chain.
  Future<Map<String, dynamic>?> _fetchActiveRound() async {
    if (_config == null || _config!.voteServers.isEmpty) return null;
    try {
      final serverUrl = _config!.voteServers.first.url;
      final resp = await http
          .get(Uri.parse('$serverUrl/shielded-vote/v1/rounds/active'))
          .timeout(const Duration(seconds: 15));
      if (resp.statusCode != 200) return null;
      final json = jsonDecode(resp.body) as Map<String, dynamic>;
      return json['round'] as Map<String, dynamic>?;
    } catch (e) {
      _log.w('[VotingService] Fresh round fetch failed: $e');
      return null;
    }
  }

  /// Submit a delegation to the chain. Returns (txHash, vanPosition).
  Future<DelegationSubmissionResult> submitDelegation(
    rust_engine.EngineDelegationResult delegation,
  ) async {
    if (_config == null) throw Exception('Config not loaded');

    final serverUrl = _config!.voteServers.first.url;
    final body = jsonEncode({
      'rk': _bytesToB64(delegation.rk),
      'spend_auth_sig': _bytesToB64(delegation.spendAuthSig),
      'signed_note_nullifier': _bytesToB64(delegation.nfSigned),
      'cmx_new': _bytesToB64(delegation.cmxNew),
      'van_cmx': _bytesToB64(delegation.vanComm),
      'gov_nullifiers':
          delegation.govNullifiers.map((n) => _bytesToB64(n)).toList(),
      'proof': _bytesToB64(delegation.proof),
      'vote_round_id': _config!.voteRoundIdB64,
      'sighash': _bytesToB64(delegation.sighash),
    });

    _log.i('[VotingService] Submitting delegation to $serverUrl');
    final response = await http
        .post(
          Uri.parse('$serverUrl/shielded-vote/v1/delegate-vote'),
          headers: {'Content-Type': 'application/json'},
          body: body,
        )
        .timeout(const Duration(seconds: 120));

    if (response.statusCode != 200 && response.statusCode != 201) {
      throw Exception(
        'Delegation submission failed: ${response.statusCode} ${response.body}',
      );
    }

    final json = jsonDecode(response.body) as Map<String, dynamic>;
    final txHash = json['tx_hash'] as String? ?? json['hash'] as String? ?? '';
    _log.i('[VotingService] Delegation submitted: $txHash');

    final confirmed = await _pollTxConfirmation(serverUrl, txHash);
    final vanPosition = confirmed?['van_position'] as int?
        ?? confirmed?['commitment_index'] as int?
        ?? confirmed?['van_leaf_index'] as int?
        ?? confirmed?['index'] as int?;

    _log.i('[VotingService] Delegation confirmed: hash=$txHash vanPos=$vanPosition');
    return DelegationSubmissionResult(txHash: txHash, vanPosition: vanPosition);
  }

  /// Sync the vote commitment tree and get VAN witnesses for all bundles.
  Future<List<rust_engine.EngineVanWitness>> syncTreeAndWitness(
    List<int> vanPositions,
  ) async {
    if (_config == null) throw Exception('Config not loaded');

    final serverUrl = _config!.voteServers.first.url;
    _log.i('[VotingService] Syncing vote tree, ${vanPositions.length} positions');

    final witnesses = await rust_engine.engineVoteSyncTreeAndWitness(
      nodeUrl: serverUrl,
      voteRoundId: _config!.voteRoundId,
      snapshotHeight: BigInt.from(_config!.snapshotHeight),
      eaPk: base64Decode(_config!.eaPk).toList(),
      ncRoot: base64Decode(_config!.ncRoot).toList(),
      nfImtRoot: base64Decode(_config!.nullifierImtRoot).toList(),
      vanPositions: vanPositions,
    );

    _log.i('[VotingService] Tree sync complete: ${witnesses.length} witnesses');
    return witnesses;
  }

  Future<VoteSubmissionResult> castVote({
    required List<int> votingSeed,
    required int proposalId,
    required int choice,
    required int numOptions,
    required List<int> vanCommRand,
    required int totalValue,
    required List<Uint8List> vanAuthPath,
    required int vanPosition,
    required int anchorHeight,
    required void Function(String phase, double progress) onProgress,
  }) async {
    if (_config == null) {
      throw Exception('Config not loaded');
    }

    onProgress('commitment', 0.0);

    final votingRoundIdBytes = _hexToBytes(_config!.voteRoundId);
    final eaPk = base64Decode(_config!.eaPk).toList();

    _log.i('[VotingService] Building vote commitment for proposal $proposalId');
    final commitment = await rust_engine.engineVoteBuildCommitment(
      votingSeed: votingSeed,
      networkId: 1,
      totalNoteValue: BigInt.from(totalValue),
      govCommRand: vanCommRand,
      votingRoundId: votingRoundIdBytes,
      eaPk: eaPk,
      proposalId: proposalId,
      choice: choice,
      numOptions: numOptions,
      vanAuthPath: vanAuthPath,
      vanPosition: vanPosition,
      anchorHeight: anchorHeight,
      proposalAuthority: BigInt.from(65535),
      singleShare: true,
    );

    onProgress('signing', 0.5);

    final signature = await rust_engine.engineVoteSignCast(
      votingSeed: votingSeed,
      networkId: 1,
      voteRoundIdHex: _config!.voteRoundId,
      rVpkBytes: commitment.rVpkBytes,
      vanNullifier: commitment.vanNullifier,
      voteAuthorityNoteNew: commitment.voteAuthorityNoteNew,
      voteCommitment: commitment.voteCommitment,
      proposalId: proposalId,
      anchorHeight: commitment.anchorHeight,
      alphaV: commitment.alphaV,
    );

    onProgress('submitting', 0.75);

    final serverUrl = _config!.voteServers.first.url;
    final body = jsonEncode({
      'van_nullifier': _bytesToB64(commitment.vanNullifier),
      'vote_authority_note_new': _bytesToB64(commitment.voteAuthorityNoteNew),
      'vote_commitment': _bytesToB64(commitment.voteCommitment),
      'proposal_id': proposalId,
      'proof': _bytesToB64(commitment.proof),
      'vote_comm_tree_anchor_height': commitment.anchorHeight,
      'vote_round_id': _config!.voteRoundIdB64,
      'r_vpk': _bytesToB64(commitment.rVpkBytes),
      'vote_auth_sig': _bytesToB64(signature),
    });

    final response = await http
        .post(
          Uri.parse('$serverUrl/shielded-vote/v1/cast-vote'),
          headers: {'Content-Type': 'application/json'},
          body: body,
        )
        .timeout(const Duration(seconds: 30));

    if (response.statusCode != 200 && response.statusCode != 201) {
      throw Exception(
        'Cast vote failed: ${response.statusCode} ${response.body}',
      );
    }

    final json = jsonDecode(response.body) as Map<String, dynamic>;
    final txHash = json['tx_hash'] as String? ?? json['hash'] as String? ?? '';

    onProgress('confirming', 0.9);
    await _pollTxConfirmation(serverUrl, txHash);

    onProgress('complete', 1.0);
    _log.i('[VotingService] Vote cast: proposal=$proposalId, tx=$txHash');

    return VoteSubmissionResult(
      txHash: txHash,
      commitment: commitment,
    );
  }

  /// Poll until TX is confirmed. Returns the full response body on success.
  Future<Map<String, dynamic>?> _pollTxConfirmation(String serverUrl, String txHash) async {
    if (txHash.isEmpty) return null;

    for (int attempt = 0; attempt < 30; attempt++) {
      await Future.delayed(const Duration(seconds: 3));
      try {
        final response = await http
            .get(Uri.parse('$serverUrl/shielded-vote/v1/tx/$txHash'))
            .timeout(const Duration(seconds: 10));

        if (response.statusCode == 200) {
          final json = jsonDecode(response.body) as Map<String, dynamic>;
          final confirmed = json['confirmed'] as bool? ?? false;
          final height = json['height'] as int? ?? 0;
          if (confirmed && height > 0) {
            _log.i('[VotingService] TX confirmed at height $height');
            return json;
          }
        }
      } catch (e) {
        _log.w('[VotingService] TX poll attempt $attempt failed: $e');
      }
    }
    _log.w('[VotingService] TX confirmation timeout for $txHash');
    return null;
  }

  // =========================================================================
  // Helpers
  // =========================================================================

  List<int> _hexToBytes(String hex) {
    final clean = hex.startsWith('0x') ? hex.substring(2) : hex;
    final result = <int>[];
    for (int i = 0; i < clean.length; i += 2) {
      result.add(int.parse(clean.substring(i, i + 2), radix: 16));
    }
    return result;
  }

  String _bytesToB64(List<int> bytes) {
    return base64Encode(Uint8List.fromList(bytes));
  }

  String _b64ToHex(String b64) {
    final bytes = base64Decode(b64);
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}

class DelegationSubmissionResult {
  final String txHash;
  final int? vanPosition;

  DelegationSubmissionResult({required this.txHash, required this.vanPosition});
}

class VoteSubmissionResult {
  final String txHash;
  final rust_engine.EngineVoteCommitment commitment;

  VoteSubmissionResult({
    required this.txHash,
    required this.commitment,
  });
}
