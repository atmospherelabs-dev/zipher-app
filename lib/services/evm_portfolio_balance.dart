import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:logger/logger.dart';

import 'evm_rpc.dart';
import 'secure_key_store.dart';

final _log = Logger();

/// Build-time default (CI / local); never commit real keys. User may override via [SecureKeyStore].
const String _alchemyApiKeyDefine = String.fromEnvironment(
  'ALCHEMY_API_KEY',
  defaultValue: '',
);

String _alchemyBscUrl(String apiKey) => 'https://bnb-mainnet.g.alchemy.com/v2/$apiKey';

String _alchemyPolygonUrl(String apiKey) => 'https://polygon-mainnet.g.alchemy.com/v2/$apiKey';

/// One line on the Action balance header (EVM only; ZEC is separate).
class EvmTokenBalance {
  final String symbol;
  /// Short chain label for UI, e.g. "BSC", "Polygon".
  final String chainLabel;
  final double balance;
  final double balanceUsd;
  final String? thumbnailUrl;

  const EvmTokenBalance({
    required this.symbol,
    required this.chainLabel,
    required this.balance,
    required this.balanceUsd,
    this.thumbnailUrl,
  });
}

class _WatchEntry {
  final EvmRpc rpc;
  final String chainLabel;
  final String symbol;
  final String? contract;
  final int decimals;
  final double Function(double balance) toUsd;

  const _WatchEntry({
    required this.rpc,
    required this.chainLabel,
    required this.symbol,
    this.contract,
    required this.decimals,
    required this.toUsd,
  });
}

double _usdStable(double b) => b;
double _usdBnb(double b) => b * 600;
double _usdPol(double b) => b * 0.085;

final _publicWatchlist = <_WatchEntry>[
  _WatchEntry(rpc: EvmRpc.bsc, chainLabel: 'BSC', symbol: 'BNB', contract: null, decimals: 18, toUsd: _usdBnb),
  _WatchEntry(
    rpc: EvmRpc.bsc,
    chainLabel: 'BSC',
    symbol: 'USDT',
    contract: usdtBsc,
    decimals: 18,
    toUsd: _usdStable,
  ),
  _WatchEntry(
    rpc: EvmRpc.polygon,
    chainLabel: 'Polygon',
    symbol: 'POL',
    contract: null,
    decimals: 18,
    toUsd: _usdPol,
  ),
];

double _toHumanFromHex(String hex, int decimals) {
  final h = hex.trim();
  if (h.isEmpty || h == '0x' || h == '0x0') return 0;
  final raw = BigInt.tryParse(h.replaceFirst(RegExp(r'^0x', caseSensitive: false), ''), radix: 16);
  if (raw == null || raw == BigInt.zero) return 0;
  return raw / BigInt.from(10).pow(decimals);
}

/// Fetches EVM balances for the Action page: Alchemy when configured, else public RPC + watchlist.
class EvmPortfolioBalance {
  EvmPortfolioBalance._();

  static Future<String?> _resolveAlchemyKey() async {
    final fromStore = await SecureKeyStore.getApiKey('alchemy');
    if (fromStore != null && fromStore.isNotEmpty) return fromStore;
    if (_alchemyApiKeyDefine.isNotEmpty) return _alchemyApiKeyDefine;
    return null;
  }

  static Future<Map<String, dynamic>> _alchemyJsonRpc(
    String httpUrl,
    String method,
    List<dynamic> params, {
    required Duration timeout,
  }) async {
    final resp = await http
        .post(
          Uri.parse(httpUrl),
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode({'jsonrpc': '2.0', 'id': 1, 'method': method, 'params': params}),
        )
        .timeout(timeout);
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw Exception('Alchemy HTTP ${resp.statusCode}');
    }
    final raw = resp.body.trim();
    if (raw.isEmpty || (!raw.startsWith('{'))) {
      throw const FormatException('Alchemy: non-JSON response');
    }
    final decoded = jsonDecode(resp.body);
    if (decoded is! Map) throw const FormatException('Alchemy: expected JSON object');
    final err = decoded['error'];
    if (err != null) throw Exception('Alchemy RPC error: $err');
    return Map<String, dynamic>.from(decoded);
  }

  static Future<List<EvmTokenBalance>> _fetchAlchemyBsc(
    String wallet,
    String apiKey,
    Map<String, double> prices, {
    required Duration timeout,
  }) async {
    final url = _alchemyBscUrl(apiKey);
    final out = <EvmTokenBalance>[];

    final balResp = await _alchemyJsonRpc(url, 'eth_getBalance', [wallet, 'latest'], timeout: timeout);
    final balHex = balResp['result'] as String? ?? '0x0';
    final bnb = _toHumanFromHex(balHex, 18);
    if (bnb > 0) {
      final px = prices['binancecoin'] ?? 0;
      final usd = px > 0 ? bnb * px : _usdBnb(bnb);
      out.add(EvmTokenBalance(symbol: 'BNB', chainLabel: 'BSC', balance: bnb, balanceUsd: usd));
    }

    final tokResp = await _alchemyJsonRpc(
      url,
      'alchemy_getTokenBalances',
      [wallet, [usdtBsc]],
      timeout: timeout,
    );
    final result = tokResp['result'];
    if (result is Map) {
      final list = result['tokenBalances'];
      if (list is List) {
        for (final item in list) {
          if (item is! Map) continue;
          final m = Map<String, dynamic>.from(item);
          if (m['error'] != null) continue;
          final hex = m['tokenBalance'] as String? ?? '0x0';
          final human = _toHumanFromHex(hex, 18);
          if (human <= 0) continue;
          final px = prices['tether'] ?? 0;
          final usd = px > 0 ? human * px : _usdStable(human);
          out.add(EvmTokenBalance(symbol: 'USDT', chainLabel: 'BSC', balance: human, balanceUsd: usd));
        }
      }
    }
    return out;
  }

  static Future<List<EvmTokenBalance>> _fetchAlchemyPolygon(
    String wallet,
    String apiKey,
    Map<String, double> prices, {
    required Duration timeout,
  }) async {
    final url = _alchemyPolygonUrl(apiKey);
    final out = <EvmTokenBalance>[];

    final balResp = await _alchemyJsonRpc(url, 'eth_getBalance', [wallet, 'latest'], timeout: timeout);
    final balHex = balResp['result'] as String? ?? '0x0';
    final pol = _toHumanFromHex(balHex, 18);
    if (pol > 0) {
      final px = prices['polygon-ecosystem-token'] ?? 0;
      final usd = px > 0 ? pol * px : _usdPol(pol);
      out.add(EvmTokenBalance(symbol: 'POL', chainLabel: 'Polygon', balance: pol, balanceUsd: usd));
    }

    final tokResp = await _alchemyJsonRpc(
      url,
      'alchemy_getTokenBalances',
      [wallet, [usdcPolygon, usdcPolygonNative]],
      timeout: timeout,
    );
    final result = tokResp['result'];
    if (result is Map) {
      final list = result['tokenBalances'];
      if (list is List) {
        for (final item in list) {
          if (item is! Map) continue;
          final m = Map<String, dynamic>.from(item);
          if (m['error'] != null) continue;
          final contract = (m['contractAddress'] as String?)?.toLowerCase() ?? '';
          final hex = m['tokenBalance'] as String? ?? '0x0';
          final human = _toHumanFromHex(hex, 6);
          if (human <= 0) continue;
          final px = prices['usd-coin'] ?? 0;
          final usd = px > 0 ? human * px : _usdStable(human);
          if (contract == usdcPolygon.toLowerCase() || contract == usdcPolygonNative.toLowerCase()) {
            out.add(EvmTokenBalance(symbol: 'USDC', chainLabel: 'Polygon', balance: human, balanceUsd: usd));
          }
        }
      }
    }
    return out;
  }

  static Future<({List<EvmTokenBalance> tokens, double evmTotalUsd})> fetch(
    String evmAddress, {
    Duration timeout = const Duration(seconds: 12),
  }) async {
    final addr = evmAddress.trim();
    if (!addr.startsWith('0x') || addr.length < 42) {
      _log.w('[EvmPortfolio] Invalid EVM address');
      return (tokens: <EvmTokenBalance>[], evmTotalUsd: 0.0);
    }

    try {
      final prices = await _fetchUsdPrices(timeout: timeout);
      final key = await _resolveAlchemyKey();

      final List<EvmTokenBalance> rows;
      if (key != null && key.isNotEmpty) {
        final parts = await Future.wait([
          _fetchAlchemyBsc(addr, key, prices, timeout: timeout),
          _fetchAlchemyPolygon(addr, key, prices, timeout: timeout),
        ]);
        rows = [...parts[0], ...parts[1]];
      } else {
        _log.d('[EvmPortfolio] No Alchemy key; using public RPC watchlist (set ALCHEMY_API_KEY or storeApiKey("alchemy", …))');
        rows = await _fetchPublicRpcWatchlist(addr, timeout: timeout);
      }

      final merged = _mergePolygonUsdc(rows);
      merged.sort((a, b) => b.balanceUsd.compareTo(a.balanceUsd));
      final total = merged.fold<double>(0, (s, t) => s + t.balanceUsd);
      return (tokens: merged, evmTotalUsd: total);
    } catch (e, st) {
      _log.w('[EvmPortfolio] fetch failed: $e\n$st');
      return (tokens: <EvmTokenBalance>[], evmTotalUsd: 0.0);
    }
  }

  static Future<List<EvmTokenBalance>> _fetchPublicRpcWatchlist(
    String evmAddress, {
    required Duration timeout,
  }) async {
    try {
      final results = await Future.wait(
        [
          ..._publicWatchlist.map((e) async {
            final bal = e.contract == null
                ? await e.rpc.getNativeBalance(evmAddress)
                : await e.rpc.getErc20Balance(evmAddress, e.contract!, decimals: e.decimals);
            final usd = e.toUsd(bal);
            return EvmTokenBalance(
              symbol: e.symbol,
              chainLabel: e.chainLabel,
              balance: bal,
              balanceUsd: usd,
            );
          }),
          _polygonUsdcCombined(evmAddress),
        ],
      ).timeout(timeout);

      return results.where((t) => t.balance > 0).toList();
    } catch (e, st) {
      _log.w('[EvmPortfolio] public RPC watchlist failed: $e\n$st');
      return [];
    }
  }

  static Future<EvmTokenBalance> _polygonUsdcCombined(String evmAddress) async {
    final poly = EvmRpc.polygon;
    final bridged = await poly.getErc20Balance(evmAddress, usdcPolygon, decimals: 6);
    final native = await poly.getErc20Balance(evmAddress, usdcPolygonNative, decimals: 6);
    final sum = bridged + native;
    return EvmTokenBalance(
      symbol: 'USDC',
      chainLabel: 'Polygon',
      balance: sum,
      balanceUsd: sum,
    );
  }

  /// CoinGecko simple price (no key; low rate — OK for a few symbols per refresh).
  static Future<Map<String, double>> _fetchUsdPrices({required Duration timeout}) async {
    final uri = Uri.parse(
      'https://api.coingecko.com/api/v3/simple/price'
      '?ids=binancecoin,polygon-ecosystem-token,usd-coin,tether&vs_currencies=usd',
    );
    try {
      final resp = await http.get(
        uri,
        headers: const {'User-Agent': 'ZipherWallet/1.0 (balance display)'},
      ).timeout(timeout);
      if (resp.statusCode < 200 || resp.statusCode >= 300) return {};
      final map = jsonDecode(resp.body);
      if (map is! Map) return {};
      double pick(String id) {
        final block = map[id];
        if (block is! Map) return 0;
        final u = block['usd'];
        if (u is num) return u.toDouble();
        return double.tryParse(u?.toString() ?? '') ?? 0;
      }

      return {
        'binancecoin': pick('binancecoin'),
        'polygon-ecosystem-token': pick('polygon-ecosystem-token'),
        'usd-coin': pick('usd-coin'),
        'tether': pick('tether'),
      };
    } catch (e) {
      _log.d('[EvmPortfolio] CoinGecko price fetch failed: $e');
      return {};
    }
  }

  /// Sum Polygon USDC.e + native USDC into one row.
  static List<EvmTokenBalance> _mergePolygonUsdc(List<EvmTokenBalance> rows) {
    var polyBal = 0.0;
    var polyUsd = 0.0;
    final rest = <EvmTokenBalance>[];
    for (final t in rows) {
      final onPoly = t.chainLabel == 'Polygon' && t.symbol == 'USDC';
      if (onPoly) {
        polyBal += t.balance;
        polyUsd += t.balanceUsd;
      } else {
        rest.add(t);
      }
    }
    if (polyBal > 0) {
      rest.add(EvmTokenBalance(
        symbol: 'USDC',
        chainLabel: 'Polygon',
        balance: polyBal,
        balanceUsd: polyUsd > 0 ? polyUsd : polyBal,
      ));
    }
    return rest;
  }
}
