import 'dart:convert';

import 'package:http/http.dart' as http;
import '../src/rust/api/engine_api.dart' as engine;
import 'chain_config.dart';
import 'polymarket_client.dart' show polymarketPusd;
import 'secure_key_store.dart';

class EvmTokenBalance {
  final String symbol;
  final String chainLabel;
  final double balance;
  final double balanceUsd;
  final bool priceAvailable;
  final String? thumbnailUrl;
  const EvmTokenBalance(
      {required this.symbol,
      required this.chainLabel,
      required this.balance,
      required this.balanceUsd,
      this.priceAvailable = true,
      this.thumbnailUrl});
}

class EvmBalanceSnapshot {
  final List<EvmTokenBalance> tokens;
  final Set<String> unavailableChains;
  final DateTime fetchedAt;
  const EvmBalanceSnapshot(
      {required this.tokens,
      required this.unavailableChains,
      required this.fetchedAt});
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
  final Duration timeout;
  String? _address;
  EvmBalanceSnapshot? _cached;
  Future<EvmBalanceSnapshot>? _running;

  EvmBalanceReader(
      {required this.readAsset,
      required this.readPrices,
      DateTime Function()? now,
      this.timeout = const Duration(seconds: 12)})
      : now = now ?? DateTime.now;

  Future<EvmBalanceSnapshot> fetch(String address, {bool force = false}) {
    if (!RegExp(r'^0x[0-9a-fA-F]{40}$').hasMatch(address)) {
      return Future.error(ArgumentError('Invalid EVM address'));
    }
    if (_address != address) {
      _address = address;
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
    pending = _fetch(address).then((snapshot) {
      if (_address == address && identical(_running, pending))
        _cached = snapshot;
      return snapshot;
    }).whenComplete(() {
      if (identical(_running, pending)) _running = null;
    });
    return _running = pending;
  }

  Future<EvmBalanceSnapshot> _fetch(String address) async {
    // Prices and all six chains load concurrently, under bounded timeouts.
    final priceFuture = readPrices()
        .timeout(timeout)
        .catchError((Object _) => <String, double>{});
    final failures = <String>{};
    final rows = await Future.wait(ChainConfig.all.map((chain) async {
      try {
        final assets = <TokenInfo?>[
          null,
          ...chain.knownTokens.values,
          if (chain == ChainConfig.polygon)
            const TokenInfo(
                address: polymarketPusd, decimals: 6, symbol: 'pUSD')
        ];
        return await Future.wait(assets.map((token) async {
          final amount = await readAsset(chain, address, token);
          if (!amount.isFinite || amount < 0)
            throw const FormatException('Invalid balance');
          return (
            chain: chain.name,
            symbol: token?.symbol ?? chain.nativeSymbol,
            amount: amount
          );
        })).timeout(timeout);
      } catch (_) {
        failures.add(chain.name);
        return <({String chain, String symbol, double amount})>[];
      }
    }));
    final prices = await priceFuture;
    final tokens = <EvmTokenBalance>[];
    for (final row in rows.expand((r) => r)) {
      if (row.amount == 0) continue;
      final price = prices[row.symbol];
      final priced = price != null && price.isFinite && price > 0;
      tokens.add(EvmTokenBalance(
          symbol: row.symbol,
          chainLabel: row.chain,
          balance: row.amount,
          balanceUsd: priced ? row.amount * price : 0,
          priceAvailable: priced));
    }
    tokens.sort((a, b) => b.balanceUsd.compareTo(a.balanceUsd));
    return EvmBalanceSnapshot(
        tokens: List.unmodifiable(tokens),
        unavailableChains: Set.unmodifiable(failures),
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
        readAsset: (chain, address, token) async {
          final apiKey = await key();
          String raw;
          if (apiKey != null) {
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
                .timeout(timeout);
            if (response.statusCode != 200)
              throw StateError('Balance service unavailable');
            final data = jsonDecode(response.body) as Map;
            if (data['error'] != null || data['result'] is! String)
              throw StateError('Balance unavailable');
            raw = BigInt.parse(
                    (data['result'] as String).replaceFirst('0x', ''),
                    radix: 16)
                .toString();
          } else {
            // Avoid EvmRpc convenience wrappers that turn RPC failures into zero.
            raw = token == null
                ? await engine.engineGetNativeBalance(
                    rpcUrl: chain.rpc.rpcUrl, address: address)
                : await engine.engineGetErc20Balance(
                    rpcUrl: chain.rpc.rpcUrl,
                    tokenContract: token.address,
                    ownerAddress: address);
          }
          return BigInt.parse(raw) /
              BigInt.from(10).pow(token?.decimals ?? chain.nativeDecimals);
        });
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
            '?ids=binancecoin,polygon-ecosystem-token,usd-coin,tether,ethereum&vs_currencies=usd&include_last_updated_at=true'))
        .timeout(timeout);
    if (response.statusCode != 200) return {};
    return parsePrices(jsonDecode(response.body), DateTime.now());
  }

  /// A missing/stale quote is not a fixed $1 stablecoin or guessed ETH price.
  static Map<String, double> parsePrices(dynamic data, DateTime now) {
    if (data is! Map) return {};
    final result = <String, double>{};
    const ids = {
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
