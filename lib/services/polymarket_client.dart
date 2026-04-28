import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:logger/logger.dart';

import '../src/rust/api/engine_api.dart' as rust_engine;

final _log = Logger();

const polymarketClobApi = 'https://clob.polymarket.com';
const polymarketCtfExchange = '0x4bFb41d5B3570DeFd03C39a9A4D8dE6Bd8B8982E';
const polymarketNegRiskExchange = '0xC5d563A36AE78145C45a50134d48A1215220f80a';

/// ERC-1155 Conditional Tokens — outcome balances live here.
const polymarketCtfContract = '0x4D97DCd97eC945f40cF65F87097ACe5EA0476045';

/// Neg-risk adapter (ERC-1155) — approve for neg-risk markets before SELL on CLOB.
const polymarketNegRiskAdapter = '0xd91E80cF2E7be2e162c6513ceD06f1dD0dA35296';

/// 1.5% Atmosphere fee on Polymarket bets.
const atmosphereFeeRate = 0.015;

/// Polymarket CLOB API client — handles L1 auth, L2 HMAC, order posting.
class PolymarketClient {
  PolymarketClient._();
  static final instance = PolymarketClient._();

  /// Create or derive CLOB API credentials via L1 EIP-712 auth.
  ///
  /// Mirrors the official `createOrDeriveApiKey()` flow:
  /// 1. Try GET /auth/derive-api-key (retrieve existing key for nonce 0).
  /// 2. If 400/404 (no key exists yet), POST /auth/api-key to create one.
  Future<Map<String, String>> deriveCredentials(String seed) async {
    final timestamp = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    const nonce = 0;

    final authResult = await rust_engine.enginePolymarketSignAuth(
      seedPhrase: seed,
      timestamp: BigInt.from(timestamp),
      nonce: BigInt.from(nonce),
    );

    _log.d('[Polymarket] L1 auth: address=${authResult.address}, sig=${authResult.signature.substring(0, 20)}…');

    final l1Headers = {
      'POLY_ADDRESS': authResult.address,
      'POLY_SIGNATURE': authResult.signature,
      'POLY_TIMESTAMP': timestamp.toString(),
      'POLY_NONCE': nonce.toString(),
    };

    // Step 1: try to derive existing key
    var resp = await http.get(
      Uri.parse('$polymarketClobApi/auth/derive-api-key'),
      headers: l1Headers,
    );

    // Step 2: if no key exists, create one
    if (resp.statusCode >= 300) {
      _log.i('[Polymarket] derive-api-key returned ${resp.statusCode}, attempting create…');
      resp = await http.post(
        Uri.parse('$polymarketClobApi/auth/api-key'),
        headers: l1Headers,
      );
    }

    if (resp.statusCode >= 300) {
      _log.e('[Polymarket] CLOB auth failed (${resp.statusCode}): ${resp.body}');
      throw Exception('CLOB auth failed (${resp.statusCode}): ${resp.body}');
    }

    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    _log.i('[Polymarket] CLOB auth success — got API key');
    return {
      'apiKey': (body['apiKey'] ?? body['key'] ?? '') as String,
      'secret': body['secret'] as String? ?? '',
      'passphrase': body['passphrase'] as String? ?? '',
      'address': authResult.address,
    };
  }

  /// Get fee rate (bps) for a Polymarket token.
  Future<int> getFeeRate(String tokenId) async {
    try {
      final resp = await http.get(
        Uri.parse('$polymarketClobApi/fee-rate?token_id=$tokenId'),
      );
      if (resp.statusCode == 200) {
        final body = jsonDecode(resp.body);
        return (body['fee_rate_bps'] as num?)?.toInt() ?? 0;
      }
    } catch (_) {}
    return 0;
  }

  /// Build HMAC-SHA256 headers for L2 CLOB auth.
  Map<String, String> buildHeaders(
    Map<String, String> creds,
    String method,
    String path,
    String body,
  ) {
    final timestamp = (DateTime.now().millisecondsSinceEpoch / 1000).toString();
    final message = '$timestamp$method$path$body';

    final secretBytes = base64.decode(creds['secret'] ?? '');
    final hmacSha256 = Hmac(sha256, secretBytes);
    final digest = hmacSha256.convert(utf8.encode(message));
    final sig = base64.encode(digest.bytes);

    return {
      'Content-Type': 'application/json',
      'POLY_ADDRESS': creds['address'] ?? '',
      'POLY_API_KEY': creds['apiKey'] ?? '',
      'POLY_SIGNATURE': sig,
      'POLY_TIMESTAMP': timestamp,
      'POLY_PASSPHRASE': creds['passphrase'] ?? '',
    };
  }

  /// Authenticated POST to the Polymarket CLOB API.
  Future<Map<String, dynamic>?> post(
    String path,
    Map<String, dynamic> body,
    Map<String, String> creds,
  ) async {
    final bodyStr = jsonEncode(body);
    final headers = buildHeaders(creds, 'POST', path, bodyStr);

    final resp = await http.post(
      Uri.parse('$polymarketClobApi$path'),
      headers: headers,
      body: bodyStr,
    );

    if (resp.statusCode >= 300) {
      _log.e('[Polymarket] CLOB POST $path failed (${resp.statusCode}): ${resp.body}');
      return {'success': false, 'error': resp.body};
    }

    return jsonDecode(resp.body) as Map<String, dynamic>;
  }
}
