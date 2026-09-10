import 'dart:convert';

import 'package:http/http.dart' as http;
import '../src/rust/api/engine_api.dart' as engine;
import 'chain_config.dart';
import 'polymarket_client.dart' show polymarketPusd;
import 'secure_key_store.dart';
import 'app_log.dart';

class EvmTokenBalance {
  final String symbol;
  final String chainLabel;
  final double balance;
  final double balanceUsd;
  final bool priceAvailable;
  final String? thumbnailUrl;
  final bool stale;
  const EvmTokenBalance(
      {required this.symbol,
      required this.chainLabel,
      required this.balance,
      required this.balanceUsd,
      this.priceAvailable = true,
      this.stale = false,
      this.thumbnailUrl});
}

class EvmBalanceSnapshot {
  final List<EvmTokenBalance> tokens;
  final Set<String> unavailableChains;
  final DateTime fetchedAt;
  final double? zecPriceUsd;
  const EvmBalanceSnapshot(
      {required this.tokens,
      required this.unavailableChains,
      required this.fetchedAt,
      this.zecPriceUsd});
  bool get complete => unavailableChains.isEmpty;
  bool get fullyPriced => tokens.every((t) => t.priceAvailable);
  double get evmTotalUsd => tokens.fold(0.0, (sum, t) => sum + t.balanceUsd);
}

/// Strict reads: an unavailable chain is never represented as a zero balance.
/// One reader belongs to one screen; cached addresses never go to disk or logs.
class EvmBalanceReader {
  final Future<double> Function(ChainConfig, String, TokenInfo?) readAsset;
  final Future<Map<String, double>> Function() readPrices;
  final DateTime Function() now;
  final Future<double> Function(String chain, String address)? readNative;
  final Duration timeout;
  String? _address;
  EvmBalanceSnapshot? _cached;
  Future<EvmBalanceSnapshot>? _running;

  EvmBalanceReader(
      {required this.readAsset,
      required this.readPrices,
      this.readNative,
      DateTime Function()? now,
      this.timeout = const Duration(seconds: 12)})
      : now = now ?? DateTime.now;

  Future<EvmBalanceSnapshot> fetch(String address,
      {bool force = false, String? bitcoin, String? solana}) {
    if (!RegExp(r'^0x[0-9a-fA-F]{40}$').hasMatch(address)) {
      return Future.error(ArgumentError('Invalid EVM address'));
    }
    final owner = '$address:$bitcoin:$solana';
    if (_address != owner) {
      _address = owner;
      _cached = null;
      _running = null;
    }
    if (_running != null) return _running!;
    if (!force &&
        _cached != null &&
        now().difference(_cached!.fetchedAt) < const Duration(seconds: 60)) {
      return Future.value(_cached!);
    }
    late Future<EvmBalanceSnapshot> pending;
    pending =
        _fetch(address, bitcoin: bitcoin, solana: solana, previous: _cached)
            .then((snapshot) {
      if (_address == owner && identical(_running, pending)) _cached = snapshot;
      return snapshot;
    }).whenComplete(() {
      if (identical(_running, pending)) _running = null;
    });
    return _running = pending;
  }

  Future<EvmBalanceSnapshot> _fetch(String address,
      {String? bitcoin, String? solana, EvmBalanceSnapshot? previous}) async {
    final priceFuture = Future.sync(readPrices)
        .timeout(timeout)
        .catchError((Object _) => <String, double>{});
    final failures = <String>{};
    final rows = <({String chain, String symbol, double amount})>[];
    final tasks = <Future<void>>[];
    Future<void> read(
        String chain, String symbol, Future<double> Function() request) async {
      try {
        final amount = await Future.sync(request).timeout(timeout);
        if (!amount.isFinite || amount < 0)
          throw const FormatException('Invalid balance');
        rows.add((chain: chain, symbol: symbol, amount: amount));
      } catch (e) {
        failures.add(chain);
        AppLog.instance.event('balance', 'asset_unavailable',
            detail: 'chain=$chain asset=$symbol', error: e);
        // Keep successful sibling assets. Retain a last known amount only with
        // an explicit stale marker; it never contributes to the current subtotal.
      }
    }

    for (final chain in ChainConfig.all) {
      for (final token in <TokenInfo?>[
        null,
        ...chain.knownTokens.values,
        if (chain == ChainConfig.polygon)
          const TokenInfo(address: polymarketPusd, decimals: 6, symbol: 'pUSD')
      ]) {
        tasks.add(read(chain.name, token?.symbol ?? chain.nativeSymbol,
            () => readAsset(chain, address, token)));
      }
    }
    if (readNative != null) {
      for (final entry in [
        ('Bitcoin', 'BTC', bitcoin),
        ('Solana', 'SOL', solana)
      ]) {
        if (entry.$3?.isNotEmpty == true)
          tasks.add(
              read(entry.$1, entry.$2, () => readNative!(entry.$1, entry.$3!)));
      }
    }
    await Future.wait(tasks);
    final prices = await priceFuture;
    final tokens = <EvmTokenBalance>[];
    for (final row in rows) {
      // Show native assets even at zero so every supported chain is visible.
      if (row.amount == 0 &&
          !['BTC', 'SOL', 'ETH', 'BNB', 'POL'].contains(row.symbol)) continue;
      final price = prices[row.symbol];
      final priced = price != null && price.isFinite && price > 0;
      tokens.add(EvmTokenBalance(
          symbol: row.symbol,
          chainLabel: row.chain,
          balance: row.amount,
          balanceUsd: priced ? row.amount * price : 0,
          priceAvailable: priced || row.amount == 0));
    }
    for (final old in previous?.tokens ?? <EvmTokenBalance>[]) {
      if (failures.contains(old.chainLabel) &&
          !rows.any(
              (r) => r.chain == old.chainLabel && r.symbol == old.symbol)) {
        tokens.add(EvmTokenBalance(
            symbol: old.symbol,
            chainLabel: old.chainLabel,
            balance: old.balance,
            balanceUsd: 0,
            priceAvailable: false,
            stale: true));
      }
    }
    tokens.sort((a, b) => b.balanceUsd.compareTo(a.balanceUsd));
    return EvmBalanceSnapshot(
        tokens: List.unmodifiable(tokens),
        unavailableChains: Set.unmodifiable(failures),
        zecPriceUsd: prices['ZEC'],
        fetchedAt: now());
  }
}

class EvmPortfolioBalance {
  EvmPortfolioBalance._();
  static EvmBalanceReader createReader(
      {Duration timeout = const Duration(seconds: 12)}) {
    Future<String?>? keyFuture;
    Future<String?> key() =>
        keyFuture ??= SecureKeyStore.getApiKey('alchemy').then((value) {
          const configured = String.fromEnvironment('ALCHEMY_API_KEY');
          return value?.isNotEmpty == true
              ? value
              : configured.isEmpty
                  ? null
                  : configured;
        }).catchError((Object _) => null);
    return EvmBalanceReader(
        timeout: timeout,
        readPrices: () => _prices(timeout),
        readNative: (chain, address) => _nativeBalance(chain, address, timeout),
        readAsset: (chain, address, token) async {
          final apiKey = await key();
          String raw;
          Future<String> publicRead() async {
            final urls = <String>[
              chain.rpc.rpcUrl,
              if (chain.name == 'Ethereum') 'https://eth.drpc.org'
            ];
            for (var i = 0; i < urls.length; i++) {
              try {
                return await (token == null
                        ? engine.engineGetNativeBalance(
                            rpcUrl: urls[i], address: address)
                        : engine.engineGetErc20Balance(
                            rpcUrl: urls[i],
                            tokenContract: token.address,
                            ownerAddress: address))
                    .timeout(const Duration(seconds: 4));
              } catch (_) {
                if (i == urls.length - 1) rethrow;
                AppLog.instance.event('balance', 'rpc_fallback',
                    detail:
                        'chain=${chain.name} asset=${token?.symbol ?? chain.nativeSymbol}');
              }
            }
            throw StateError('Balance unavailable');
          }

          if (apiKey != null) {
            try {
              final network = switch (chain.name) {
                'BSC' => 'bnb-mainnet',
                'Polygon' => 'polygon-mainnet',
                'Ethereum' => 'eth-mainnet',
                'Arbitrum' => 'arb-mainnet',
                'Base' => 'base-mainnet',
                _ => 'opt-mainnet',
              };
              final method = token == null ? 'eth_getBalance' : 'eth_call';
              final params = token == null
                  ? <Object>[address, 'latest']
                  : <Object>[
                      {
                        'to': token.address,
                        'data':
                            '0x70a08231${address.substring(2).padLeft(64, '0')}'
                      },
                      'latest'
                    ];
              final response = await http
                  .post(Uri.parse('https://$network.g.alchemy.com/v2/$apiKey'),
                      headers: {'Content-Type': 'application/json'},
                      body: jsonEncode({
                        'jsonrpc': '2.0',
                        'id': 1,
                        'method': method,
                        'params': params
                      }))
                  .timeout(const Duration(seconds: 3));
              if (response.statusCode != 200)
                throw StateError('Balance service unavailable');
              final data = jsonDecode(response.body) as Map;
              if (data['error'] != null || data['result'] is! String)
                throw StateError('Balance unavailable');
              raw = BigInt.parse(
                      (data['result'] as String).replaceFirst('0x', ''),
                      radix: 16)
                  .toString();
            } catch (_) {
              AppLog.instance.event('balance', 'configured_rpc_fallback',
                  detail: 'chain=${chain.name}');
              raw = await publicRead();
            }
          } else {
            raw = await publicRead();
          }

          return BigInt.parse(raw) /
              BigInt.from(10).pow(token?.decimals ?? chain.nativeDecimals);
        });
  }

  static Future<double> _nativeBalance(
      String chain, String address, Duration timeout) async {
    if (chain == 'Bitcoin') {
      if (!RegExp(r'^(bc1|[13])[a-zA-Z0-9]{20,90}$').hasMatch(address))
        throw const FormatException('Invalid Bitcoin address');
      final response = await http
          .get(Uri.https('blockstream.info', '/api/address/$address'))
          .timeout(timeout);
      if (response.statusCode != 200)
        throw StateError('Bitcoin balance service unavailable');
      return parseBitcoinBalance(jsonDecode(response.body));
    }
    if (!RegExp(r'^[1-9A-HJ-NP-Za-km-z]{32,44}$').hasMatch(address))
      throw const FormatException('Invalid Solana address');
    final response = await http
        .post(Uri.parse('https://api.mainnet-beta.solana.com'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'jsonrpc': '2.0',
              'id': 1,
              'method': 'getBalance',
              'params': [
                address,
                {'commitment': 'confirmed'}
              ]
            }))
        .timeout(timeout);
    if (response.statusCode != 200)
      throw StateError('Solana balance service unavailable');
    return parseSolanaBalance(jsonDecode(response.body));
  }

  static double parseBitcoinBalance(dynamic data) {
    if (data is! Map) throw const FormatException('Invalid Bitcoin response');
    int sum = 0;
    for (final key in ['chain_stats', 'mempool_stats']) {
      final row = data[key];
      if (row is! Map ||
          row['funded_txo_sum'] is! int ||
          row['spent_txo_sum'] is! int)
        throw const FormatException('Missing Bitcoin balance');
      sum += (row['funded_txo_sum'] as int) - (row['spent_txo_sum'] as int);
    }
    if (sum < 0) throw const FormatException('Invalid Bitcoin balance');
    return sum / 1e8;
  }

  static double parseSolanaBalance(dynamic data) {
    if (data is! Map ||
        data['error'] != null ||
        data['result'] is! Map ||
        data['result']['value'] is! int ||
        data['result']['value'] < 0)
      throw const FormatException('Missing Solana balance');
    return (data['result']['value'] as int) / 1e9;
  }

  static Future<({List<EvmTokenBalance> tokens, double evmTotalUsd})> fetch(
      String address,
      {Duration timeout = const Duration(seconds: 12)}) async {
    final snapshot = await createReader(timeout: timeout).fetch(address);
    return (tokens: snapshot.tokens, evmTotalUsd: snapshot.evmTotalUsd);
  }

  static Future<Map<String, double>> _prices(Duration timeout) async {
    final response = await http
        .get(Uri.parse('https://api.coingecko.com/api/v3/simple/price'
            '?ids=zcash,binancecoin,polygon-ecosystem-token,usd-coin,tether,ethereum,bitcoin,solana&vs_currencies=usd&include_last_updated_at=true'))
        .timeout(timeout);
    if (response.statusCode != 200) return {};
    return parsePrices(jsonDecode(response.body), DateTime.now());
  }

  /// A missing/stale quote is not a fixed $1 stablecoin or guessed ETH price.
  static Map<String, double> parsePrices(dynamic data, DateTime now) {
    if (data is! Map) return {};
    final result = <String, double>{};
    const ids = {
      'ZEC': 'zcash',
      'BTC': 'bitcoin',
      'SOL': 'solana',
      'BNB': 'binancecoin',
      'POL': 'polygon-ecosystem-token',
      'ETH': 'ethereum',
      'USDC': 'usd-coin',
      'USDC.e': 'usd-coin',
      'USDT': 'tether'
    };
    for (final entry in ids.entries) {
      final row = data[entry.value];
      if (row is! Map || row['usd'] is! num || row['last_updated_at'] is! num)
        continue;
      final price = (row['usd'] as num).toDouble();
      final age =
          now.millisecondsSinceEpoch / 1000 - (row['last_updated_at'] as num);
      if (price.isFinite && price > 0 && age >= -60 && age <= 300)
        result[entry.key] = price;
    }
    return result;
  }
}
