import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

const _baseUrl = 'https://1click.chaindefuser.com/v0';
const _quoteWaitingTimeMs = 3000;
const _affiliateAddress = 'cipherscan.near';
const _affiliateFeeBps = 50; // 0.5%
const _referral = 'zipher';
const _apiKey = 'eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCIsImtpZCI6IjIwMjUtMDEtMTItdjEifQ.eyJ2IjoxLCJrZXlfdHlwZSI6ImRpc3RyaWJ1dGlvbl9jaGFubmVsIiwicGFydG5lcl9pZCI6ImNpcGhlcnNjYW4iLCJpYXQiOjE3NzEzMTg2NjEsImV4cCI6MTgwMjg1NDY2MX0.Lcyle1wo7WnNT8eXrL7oOk3cpZakyjkGqBYjCpoFCkxtQC_Et1FE_3mK0nRODoYwutOuDPkw-JIRl47hmGhSmdCl-5r8R3Tw4LrQk-UY0g5a6WWfyjlrqTPeyexnRyKN-ry6Mm3kDwJm4g9uDxUFhea11lOnbNyD4SyuWRi_6Tp3Ch_ucTV2O6il5m8ZRhWi3yKV9yl4SUf324chPtLefwiTxJB-psA05vU0jurKpjO18t37Vuty6On1rgAQqMfm_h2KOwtjxhFk5ey5vk6dvfMfTsvsH08_bYeK45nLihtDtsPyKQKV1snhSwyjdzWZB5R5fZHSn7x4gw_bEf91FA'; // TODO: paste your JWT token from NEAR Intents here

class NearIntentsService {
  static final NearIntentsService _instance = NearIntentsService._();
  factory NearIntentsService() => _instance;
  NearIntentsService._();

  List<NearToken>? _cachedTokens;

  Map<String, String> _headers({bool auth = false}) {
    final h = <String, String>{'Content-Type': 'application/json'};
    if (auth && _apiKey.isNotEmpty) {
      h['Authorization'] = 'Bearer $_apiKey';
    }
    return h;
  }

  Future<List<NearToken>> getTokens({bool forceRefresh = false}) async {
    if (_cachedTokens != null && !forceRefresh) return _cachedTokens!;

    final resp = await http.get(
      Uri.parse('$_baseUrl/tokens'),
      headers: _headers(),
    );
    if (resp.statusCode ~/ 100 != 2) {
      throw NearIntentsException('Failed to fetch tokens: ${resp.statusCode}', resp.body);
    }
    final List<dynamic> data = jsonDecode(resp.body);
    _cachedTokens = data.map((j) => NearToken.fromJson(j)).toList();
    return _cachedTokens!;
  }

  NearToken? findZecToken(List<NearToken> tokens) {
    return tokens.cast<NearToken?>().firstWhere(
      (t) => t!.symbol.toUpperCase() == 'ZEC',
      orElse: () => null,
    );
  }

  List<NearToken> getSwappableTokens(List<NearToken> tokens) {
    final list = tokens.where((t) {
      if (t.symbol.toUpperCase() == 'ZEC') return false;
      if (t.price == null || t.price == 0) return false;
      return true;
    }).toList();
    list.sort(_tokenSortComparator);
    return list;
  }

  static int _tokenSortComparator(NearToken a, NearToken b) {
    final pa = _sortPriority(a);
    final pb = _sortPriority(b);
    if (pa != pb) return pa.compareTo(pb);
    return a.symbol.compareTo(b.symbol);
  }

  static int _sortPriority(NearToken t) {
    final sym = t.symbol.toUpperCase();
    final chain = t.blockchain.toLowerCase();
    final key = '$sym:$chain';

    const top = {
      'BTC:btc': 0, 'ETH:eth': 1, 'SOL:sol': 2, 'BNB:bsc': 3,
      'XRP:xrp': 4, 'DOGE:doge': 5, 'ADA:cardano': 6, 'TRX:tron': 7,
      'AVAX:avax': 8, 'LTC:ltc': 9, 'BCH:bch': 10, 'LINK:eth': 11,
      'SUI:sui': 12, 'APT:aptos': 13, 'TON:ton': 14, 'XLM:stellar': 15,
      'NEAR:near': 16, 'ARB:arb': 17, 'OP:op': 18, 'POL:pol': 19,
    };
    if (top.containsKey(key)) return top[key]!;

    const stables = {'USDC', 'USDT', 'DAI', 'FRAX', 'USAD'};
    if (stables.contains(sym)) return 100;

    return 200;
  }

  Future<NearQuoteResponse> getQuote({
    required bool dry,
    required String originAsset,
    required String destinationAsset,
    required BigInt amount,
    required String refundTo,
    required String recipient,
    int slippageBps = 100,
    Duration deadline = const Duration(hours: 2),
  }) async {
    final deadlineTs = DateTime.now().toUtc().add(deadline).toIso8601String();
    final body = {
      'dry': dry,
      'swapType': 'EXACT_INPUT',
      'slippageTolerance': slippageBps,
      'originAsset': originAsset,
      'depositType': 'ORIGIN_CHAIN',
      'destinationAsset': destinationAsset,
      'amount': amount.toString(),
      'refundTo': refundTo,
      'refundType': 'ORIGIN_CHAIN',
      'recipient': recipient,
      'recipientType': 'DESTINATION_CHAIN',
      'deadline': deadlineTs,
      'quoteWaitingTimeMs': _quoteWaitingTimeMs,
      'appFees': [
        {'recipient': _affiliateAddress, 'fee': _affiliateFeeBps},
      ],
      'referral': _referral,
    };

    final resp = await http.post(
      Uri.parse('$_baseUrl/quote'),
      headers: _headers(auth: true),
      body: jsonEncode(body),
    );
    if (resp.statusCode ~/ 100 != 2) {
      final errBody = _tryParseError(resp.body);
      throw NearIntentsException(
        errBody ?? 'Quote request failed: ${resp.statusCode}',
        resp.body,
      );
    }
    return NearQuoteResponse.fromJson(jsonDecode(resp.body));
  }

  Future<void> submitDeposit({
    required String txHash,
    required String depositAddress,
  }) async {
    final resp = await http.post(
      Uri.parse('$_baseUrl/deposit/submit'),
      headers: _headers(auth: true),
      body: jsonEncode({
        'txHash': txHash,
        'depositAddress': depositAddress,
      }),
    );
    if (resp.statusCode ~/ 100 != 2) {
      throw NearIntentsException(
        'Deposit submit failed: ${resp.statusCode}',
        resp.body,
      );
    }
  }

  Future<NearSwapStatus> getStatus(String depositAddress) async {
    final uri = Uri.parse('$_baseUrl/status').replace(
      queryParameters: {'depositAddress': depositAddress},
    );
    final resp = await http.get(uri, headers: _headers(auth: true));
    if (resp.statusCode ~/ 100 != 2) {
      throw NearIntentsException(
        'Status check failed: ${resp.statusCode}',
        resp.body,
      );
    }
    return NearSwapStatus.fromJson(jsonDecode(resp.body));
  }

  String? _tryParseError(String body) {
    try {
      final json = jsonDecode(body);
      if (json is Map && json.containsKey('message')) return json['message'];
      if (json is Map && json.containsKey('error')) return json['error'].toString();
    } catch (_) {}
    return null;
  }
}

// ---------------------------------------------------------------------------
// Data models
// ---------------------------------------------------------------------------

class NearToken {
  final String assetId;
  final String symbol;
  final String blockchain;
  final int decimals;
  final double? price;
  final String? icon;

  NearToken({
    required this.assetId,
    required this.symbol,
    required this.blockchain,
    required this.decimals,
    this.price,
    this.icon,
  });

  factory NearToken.fromJson(Map<String, dynamic> json) {
    return NearToken(
      assetId: json['defuseAssetId'] ?? json['assetId'] ?? '',
      symbol: json['symbol'] ?? '',
      blockchain: json['blockchain'] ?? '',
      decimals: json['decimals'] ?? 0,
      price: (json['price'] as num?)?.toDouble(),
      icon: json['icon'],
    );
  }

  String get displayName => '$symbol (${blockchain.toUpperCase()})';
}

class NearQuoteResponse {
  final String depositAddress;
  final BigInt amountIn;
  final BigInt amountOut;
  final BigInt? minAmountOut;
  final String deadline;
  final Map<String, dynamic> raw;

  NearQuoteResponse({
    required this.depositAddress,
    required this.amountIn,
    required this.amountOut,
    this.minAmountOut,
    required this.deadline,
    required this.raw,
  });

  factory NearQuoteResponse.fromJson(Map<String, dynamic> json) {
    final quote = json['quote'] ?? json;
    final request = json['quoteRequest'] ?? {};
    return NearQuoteResponse(
      depositAddress: quote['depositAddress'] ?? '',
      amountIn: BigInt.tryParse('${request['amount'] ?? quote['amountIn'] ?? '0'}') ?? BigInt.zero,
      amountOut: BigInt.tryParse('${quote['amountOut'] ?? '0'}') ?? BigInt.zero,
      minAmountOut: BigInt.tryParse('${quote['minAmountOut'] ?? ''}'),
      deadline: request['deadline'] ?? quote['deadline'] ?? '',
      raw: json,
    );
  }
}

class NearSwapStatus {
  final String status;
  final String? txHashIn;
  final String? txHashOut;
  final NearQuoteResponse? quoteResponse;
  final Map<String, dynamic> raw;

  NearSwapStatus({
    required this.status,
    this.txHashIn,
    this.txHashOut,
    this.quoteResponse,
    required this.raw,
  });

  factory NearSwapStatus.fromJson(Map<String, dynamic> json) {
    NearQuoteResponse? qr;
    if (json.containsKey('quoteResponse')) {
      qr = NearQuoteResponse.fromJson(json['quoteResponse']);
    }
    return NearSwapStatus(
      status: json['status'] ?? 'UNKNOWN',
      txHashIn: json['txHashIn'],
      txHashOut: json['txHashOut'],
      quoteResponse: qr,
      raw: json,
    );
  }

  bool get isPending => status == 'PENDING' || status == 'PENDING_DEPOSIT';
  bool get isProcessing => status == 'PROCESSING' || status == 'CONFIRMING';
  bool get isSuccess => status == 'SUCCESS' || status == 'COMPLETED';
  bool get isFailed => status == 'FAILED' || status == 'EXPIRED';
  bool get isRefunded => status == 'REFUNDED';
  bool get isTerminal => isSuccess || isFailed || isRefunded;
}

class NearIntentsException implements Exception {
  final String message;
  final String? responseBody;
  NearIntentsException(this.message, [this.responseBody]);

  @override
  String toString() => 'NearIntentsException: $message';
}

// ---------------------------------------------------------------------------
// Token icon widget (local bundled assets, like Zodl)
// ---------------------------------------------------------------------------

class TokenIcon extends StatelessWidget {
  final NearToken token;
  final double size;
  final bool showChainBadge;

  const TokenIcon({
    super.key,
    required this.token,
    this.size = 36,
    this.showChainBadge = true,
  });

  static const _symbolToAsset = {
    'BTC': 'btc', 'ETH': 'eth', 'SOL': 'sol', 'BNB': 'bnb',
    'USDT': 'usdt', 'USDC': 'usdc', 'XRP': 'xrp', 'DOGE': 'doge',
    'ADA': 'ada', 'TRX': 'trx', 'AVAX': 'avax', 'LTC': 'ltc',
    'BCH': 'bch', 'LINK': 'link', 'SUI': 'sui', 'TON': 'ton',
    'XLM': 'xlm', 'APT': 'apt', 'NEAR': 'near', 'ARB': 'arb',
    'OP': 'op', 'POL': 'pol', 'DAI': 'dai', 'UNI': 'uni',
    'AAVE': 'aave', 'SHIB': 'shib', 'PEPE': 'pepe', 'TRUMP': 'trump',
    'WBTC': 'wbtc', 'CBBTC': 'cbbtc', 'BERA': 'bera', 'STRK': 'strk',
    'GNO': 'gno', 'FRAX': 'frax', 'WIF': 'wif', 'WNEAR': 'wnear',
    'ZEC': 'zec', 'XMR': 'xmr',
    '\$WIF': 'wif', 'XBTC': 'xbtc', 'MATIC': 'matic',
  };

  static const _chainToAsset = {
    'btc': 'btc', 'eth': 'eth', 'sol': 'sol', 'arb': 'arb',
    'base': 'base', 'bsc': 'bsc', 'tron': 'tron', 'near': 'near',
    'pol': 'pol', 'op': 'op', 'avax': 'avax', 'gnosis': 'gnosis',
    'sui': 'sui', 'ton': 'ton', 'stellar': 'stellar', 'doge': 'doge',
    'xrp': 'xrp', 'ltc': 'ltc', 'bch': 'bch', 'cardano': 'cardano',
    'aptos': 'aptos', 'starknet': 'starknet', 'bera': 'bera',
  };

  @override
  Widget build(BuildContext context) {
    final sym = token.symbol.toUpperCase();
    final assetKey = _symbolToAsset[sym];
    final badgeSize = size * 0.4;

    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // Main token logo
          ClipOval(
            child: assetKey != null
                ? Image.asset(
                    'assets/tokens/$assetKey.png',
                    width: size,
                    height: size,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => _fallbackCircle(size),
                  )
                : _fallbackCircle(size),
          ),
          // Chain badge (bottom-right)
          if (showChainBadge && !_isNativeChain)
            Positioned(
              right: -2,
              bottom: -2,
              child: Container(
                width: badgeSize,
                height: badgeSize,
                decoration: BoxDecoration(
                  color: const Color(0xFF0A0E27),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: const Color(0xFF0A0E27),
                    width: 1.5,
                  ),
                ),
                child: ClipOval(
                  child: _chainBadgeImage(badgeSize - 3),
                ),
              ),
            ),
        ],
      ),
    );
  }

  bool get _isNativeChain {
    final sym = token.symbol.toUpperCase();
    final chain = token.blockchain.toLowerCase();
    const nativePairs = {
      'BTC': 'btc', 'ETH': 'eth', 'SOL': 'sol', 'BNB': 'bsc',
      'DOGE': 'doge', 'XRP': 'xrp', 'ADA': 'cardano', 'TRX': 'tron',
      'AVAX': 'avax', 'LTC': 'ltc', 'BCH': 'bch', 'SUI': 'sui',
      'APT': 'aptos', 'TON': 'ton', 'XLM': 'stellar', 'NEAR': 'near',
      'ARB': 'arb', 'OP': 'op', 'POL': 'pol', 'BERA': 'bera',
      'STRK': 'starknet', 'GNO': 'gnosis',
    };
    return nativePairs[sym] == chain;
  }

  Widget _chainBadgeImage(double s) {
    final chain = token.blockchain.toLowerCase();
    final chainAsset = _chainToAsset[chain];
    if (chainAsset != null) {
      return Image.asset(
        'assets/chains/$chainAsset.png',
        width: s,
        height: s,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => _chainFallback(s),
      );
    }
    return _chainFallback(s);
  }

  Widget _chainFallback(double s) {
    return Container(
      width: s, height: s,
      color: Colors.white.withValues(alpha: 0.1),
      child: Center(
        child: Text(
          token.blockchain.isNotEmpty
              ? token.blockchain[0].toUpperCase()
              : '?',
          style: TextStyle(
            fontSize: s * 0.6,
            fontWeight: FontWeight.w700,
            color: Colors.white.withValues(alpha: 0.5),
          ),
        ),
      ),
    );
  }

  Widget _fallbackCircle(double s) {
    final sym = token.symbol.toUpperCase();
    final hash = sym.hashCode;
    final hue = (hash % 360).abs().toDouble();
    final color = HSLColor.fromAHSL(1, hue, 0.5, 0.3).toColor();
    return Container(
      width: s, height: s,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      child: Center(
        child: Text(
          sym.substring(0, math.min(sym.length, 2)),
          style: TextStyle(
            fontSize: s * 0.35,
            fontWeight: FontWeight.w700,
            color: Colors.white.withValues(alpha: 0.8),
          ),
        ),
      ),
    );
  }
}
