import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:logger/logger.dart';

final _log = Logger();

const myriadApi = 'https://api-v2.myriadprotocol.com';
const myriadContract = '0x39E66eE6b2ddaf4DEfDEd3038E0162180dbeF340';

/// Thin client for the Myriad prediction market API.
class MyriadClient {
  MyriadClient._();
  static final instance = MyriadClient._();

  /// Get a buy/sell quote for a Myriad market.
  Future<Map<String, dynamic>?> getQuote(
    int marketId,
    int outcome,
    double amount,
    double slippage,
  ) async {
    try {
      final resp = await http.post(
        Uri.parse('$myriadApi/markets/quote'),
        headers: const {'Content-Type': 'application/json'},
        body: jsonEncode({
          'market_id': marketId,
          'outcome_id': outcome,
          'network_id': 56,
          'action': 'buy',
          'value': amount,
          'slippage': slippage,
        }),
      );
      if (resp.statusCode >= 300) {
        _log.w('[Myriad] quote failed (${resp.statusCode}): '
            '${resp.body.substring(0, resp.body.length.clamp(0, 200))}');
        return null;
      }
      return jsonDecode(resp.body) as Map<String, dynamic>;
    } catch (e) {
      _log.w('[Myriad] quote failed: $e');
      return null;
    }
  }
}
