import '../pages/action/models.dart';
import 'chain_config.dart';
import 'evm_rpc.dart';
import 'near_intents.dart';
import 'polymarket_client.dart';

/// Discovers sweepable balances across EVM chains using the NEAR Intents token
/// catalog + on-chain balance checks. Execution requires a matching [ChainConfig].
class PortfolioScanner {
  PortfolioScanner._();

  static const minUsd = 0.10;

  /// Scan [evmAddress] on every NEAR-listed EVM chain (and known tokens).
  static Future<List<SweepableToken>> scanSweepable(String evmAddress) async {
    final addr = evmAddress.trim();
    if (!addr.startsWith('0x') || addr.length < 42) return [];

    final nearTokens = await NearIntents.instance.getTokens();
    final out = <SweepableToken>[];
    final seen = <String>{};

    // Start with our known EVM chains, then add any new EVM chains from the
    // NEAR token catalog that we haven't hardcoded yet.
    final chainsToScan = <String>{...ChainConfig.evmNearBlockchains};
    for (final t in nearTokens) {
      final chain = (t['blockchain'] as String? ?? '').toLowerCase();
      if (chain.isNotEmpty && !chainsToScan.contains(chain)) {
        // Only add EVM-looking chains (skip 'near', 'btc', 'sol', etc.)
        if (_isLikelyEvmChain(chain)) {
          chainsToScan.add(chain);
        }
      }
    }

    for (final chainId in chainsToScan) {
      final exec = ChainConfig.forNearBlockchain(chainId);
      if (exec != null) {
        await _scanExecutionChain(
          chain: exec,
          address: addr,
          nearTokens: nearTokens,
          out: out,
          seen: seen,
        );
      } else {
        final discovery = ChainConfig.discoveryOnly[chainId];
        if (discovery != null) {
          await _scanDiscoveryOnlyChain(
            nearBlockchain: chainId,
            label: discovery.name,
            rpc: discovery.rpc,
            address: addr,
            nearTokens: nearTokens,
            out: out,
            seen: seen,
          );
        }
      }
    }

    await _scanPolymarketPusd(addr, out, seen);

    out.sort((a, b) => b.usdValue.compareTo(a.usdValue));
    return out.where((t) => t.sweepAmount > 0 && t.usdValue >= minUsd).toList();
  }

  static Future<void> _scanExecutionChain({
    required ChainConfig chain,
    required String address,
    required List<Map<String, dynamic>> nearTokens,
    required List<SweepableToken> out,
    required Set<String> seen,
  }) async {
    await _scanNative(chain, address, nearTokens, out, seen);

    final contracts = <String, _NearTokenRef>{};

    for (final entry in chain.knownTokens.entries) {
      contracts[entry.value.address.toLowerCase()] = _NearTokenRef(
        symbol: entry.value.symbol,
        decimals: entry.value.decimals,
        defuseId: _defuseIdForContract(
          nearTokens,
          chain.nearIntentsBlockchain,
          entry.value.address,
          entry.value.symbol,
        ),
      );
    }

    for (final token in nearTokens) {
      final chainName = (token['blockchain'] as String? ?? '').toLowerCase();
      if (chainName != chain.nearIntentsBlockchain) continue;

      final contract = (token['contractAddress'] as String? ??
              token['address'] as String? ??
              '')
          .trim();
      if (contract.isEmpty || !contract.startsWith('0x')) continue;

      final symbol = (token['symbol'] as String? ?? 'TOKEN').toUpperCase();
      if (symbol == chain.nativeSymbol.toUpperCase()) continue;

      contracts[contract.toLowerCase()] = _NearTokenRef(
        symbol: symbol,
        decimals: (token['decimals'] as num?)?.toInt() ?? 18,
        defuseId: token['defuseAssetId'] ??
            token['assetId'] ??
            token['asset_id'] ??
            token['defuse_asset_id'] as String?,
        price: (token['price'] as num?)?.toDouble(),
      );
    }

    for (final entry in contracts.entries) {
      await _scanErc20(
        chain: chain,
        address: address,
        contract: entry.key,
        ref: entry.value,
        out: out,
        seen: seen,
        supported: true,
      );
    }
  }

  static Future<void> _scanDiscoveryOnlyChain({
    required String nearBlockchain,
    required String label,
    required EvmRpc rpc,
    required String address,
    required List<Map<String, dynamic>> nearTokens,
    required List<SweepableToken> out,
    required Set<String> seen,
  }) async {
    // Native balance (e.g. AVAX on Avalanche)
    final nativeBal = await rpc.getNativeBalance(address);
    if (nativeBal > 0.000001) {
      final nativeSymbol = _nativeSymbolForDiscoveryChain(nearBlockchain);
      final price = _discoveryNativePrice(nearBlockchain, nearTokens);
      final usd = price > 0 ? nativeBal * price : nativeBal;
      if (usd >= minUsd) {
        _add(
          out,
          seen,
          SweepableToken(
            id: '$label:$nativeSymbol',
            chainLabel: label,
            chainId: 0,
            symbol: nativeSymbol,
            balance: nativeBal,
            sweepAmount: nativeBal,
            usdValue: usd,
            decimals: 18,
            supported: false,
            unsupportedReason: 'Sweep from $label coming soon',
          ),
        );
      }
    }

    final contracts = <String, _NearTokenRef>{};
    for (final token in nearTokens) {
      final chainName = (token['blockchain'] as String? ?? '').toLowerCase();
      if (chainName != nearBlockchain) continue;
      final contract = (token['contractAddress'] as String? ??
              token['address'] as String? ??
              '')
          .trim();
      if (contract.isEmpty || !contract.startsWith('0x')) continue;
      contracts[contract.toLowerCase()] = _NearTokenRef(
        symbol: (token['symbol'] as String? ?? 'TOKEN').toUpperCase(),
        decimals: (token['decimals'] as num?)?.toInt() ?? 18,
        defuseId: null,
        price: (token['price'] as num?)?.toDouble(),
      );
    }

    for (final entry in contracts.entries) {
      await _scanErc20Discovery(
        chainLabel: label,
        chainId: 0,
        rpc: rpc,
        address: address,
        contract: entry.key,
        ref: entry.value,
        out: out,
        seen: seen,
      );
    }
  }

  static String _nativeSymbolForDiscoveryChain(String nearBlockchain) {
    switch (nearBlockchain) {
      case 'avax':
        return 'AVAX';
      case 'gnosis':
        return 'xDAI';
      default:
        return nearBlockchain.toUpperCase();
    }
  }

  static double _discoveryNativePrice(
    String nearBlockchain,
    List<Map<String, dynamic>> nearTokens,
  ) {
    final symbol = _nativeSymbolForDiscoveryChain(nearBlockchain);
    final near = NearIntents.instance;
    final token = near.findToken(nearTokens, symbol, nearBlockchain) ??
        near.findToken(nearTokens, symbol);
    return (token?['price'] as num?)?.toDouble() ?? 0;
  }

  static Future<void> _scanNative(
    ChainConfig chain,
    String address,
    List<Map<String, dynamic>> nearTokens,
    List<SweepableToken> out,
    Set<String> seen,
  ) async {
    final bal = await chain.rpc.getNativeBalance(address);
    if (bal <= 0) return;

    final sweepAmount = bal - chain.nativeSweepReserve;
    if (sweepAmount <= 0.000001) return;

    final defuseId = _defuseIdForNative(chain, nearTokens);
    final usd = _usdForNative(chain, sweepAmount, nearTokens);

    _add(
      out,
      seen,
      SweepableToken(
        id: '${chain.name}:${chain.nativeSymbol}',
        chainLabel: chain.name,
        chainId: chain.chainId,
        symbol: chain.nativeSymbol,
        balance: bal,
        sweepAmount: sweepAmount,
        usdValue: usd,
        decimals: chain.nativeDecimals,
        defuseAssetId: defuseId,
        supported: defuseId != null,
        unsupportedReason:
            defuseId == null ? 'Not bridgeable via NEAR Intents yet' : null,
      ),
    );
  }

  static Future<void> _scanErc20({
    required ChainConfig chain,
    required String address,
    required String contract,
    required _NearTokenRef ref,
    required List<SweepableToken> out,
    required Set<String> seen,
    required bool supported,
  }) async {
    final bal = await chain.rpc.getErc20Balance(
      address,
      contract,
      decimals: ref.decimals,
    );
    if (bal <= 0) return;

    final defuseId = ref.defuseId;
    final canSweep = supported && defuseId != null;
    final usd = _usdForToken(ref.symbol, bal, ref.price);

    _add(
      out,
      seen,
      SweepableToken(
        id: '${chain.name}:${ref.symbol}:${contract.toLowerCase()}',
        chainLabel: chain.name,
        chainId: chain.chainId,
        symbol: ref.symbol,
        balance: bal,
        sweepAmount: bal,
        usdValue: usd,
        contractAddress: contract,
        defuseAssetId: defuseId,
        decimals: ref.decimals,
        supported: canSweep,
        unsupportedReason: canSweep
            ? null
            : 'Not bridgeable via NEAR Intents yet',
      ),
    );
  }

  static Future<void> _scanErc20Discovery({
    required String chainLabel,
    required int chainId,
    required EvmRpc rpc,
    required String address,
    required String contract,
    required _NearTokenRef ref,
    required List<SweepableToken> out,
    required Set<String> seen,
  }) async {
    final bal = await rpc.getErc20Balance(
      address,
      contract,
      decimals: ref.decimals,
    );
    if (bal <= 0) return;

    final usd = _usdForToken(ref.symbol, bal, ref.price);
    if (usd < minUsd) return;

    _add(
      out,
      seen,
      SweepableToken(
        id: '$chainLabel:${ref.symbol}:${contract.toLowerCase()}',
        chainLabel: chainLabel,
        chainId: chainId,
        symbol: ref.symbol,
        balance: bal,
        sweepAmount: bal,
        usdValue: usd,
        contractAddress: contract,
        decimals: ref.decimals,
        supported: false,
        unsupportedReason: 'Sweep from $chainLabel coming soon',
      ),
    );
  }

  static Future<void> _scanPolymarketPusd(
    String address,
    List<SweepableToken> out,
    Set<String> seen,
  ) async {
    final bal = await EvmRpc.polygon.getErc20Balance(
      address,
      polymarketPusd,
      decimals: 6,
    );
    if (bal <= 0 || bal < minUsd) return;

    _add(
      out,
      seen,
      SweepableToken(
        id: 'Polygon:pUSD',
        chainLabel: 'Polygon',
        chainId: 137,
        symbol: 'pUSD',
        balance: bal,
        sweepAmount: bal,
        usdValue: bal,
        contractAddress: polymarketPusd,
        decimals: 6,
        supported: false,
        unsupportedReason:
            'Polymarket collateral — sell positions on Polymarket first',
      ),
    );
  }

  static void _add(
    List<SweepableToken> out,
    Set<String> seen,
    SweepableToken token,
  ) {
    if (seen.contains(token.id)) return;
    seen.add(token.id);
    out.add(token);
  }

  static String? _defuseIdForNative(
    ChainConfig chain,
    List<Map<String, dynamic>> nearTokens,
  ) {
    final near = NearIntents.instance;
    final primary = near.findToken(
      nearTokens,
      chain.nativeSymbol,
      chain.nearIntentsBlockchain,
    );
    if (primary != null) {
      return primary['defuseAssetId'] ??
          primary['assetId'] ??
          primary['asset_id'] as String?;
    }
    if (chain.nativeSymbol == 'POL') {
      final matic =
          near.findToken(nearTokens, 'MATIC', chain.nearIntentsBlockchain);
      return matic?['defuseAssetId'] ?? matic?['assetId'] as String?;
    }
    if (chain.nativeSymbol == 'ETH') {
      return near
              .findToken(nearTokens, 'ETH', chain.nearIntentsBlockchain)?[
          'defuseAssetId'] as String?;
    }
    return null;
  }

  static String? _defuseIdForContract(
    List<Map<String, dynamic>> nearTokens,
    String blockchain,
    String contract,
    String symbol,
  ) {
    final lower = contract.toLowerCase();
    for (final t in nearTokens) {
      final c = (t['contractAddress'] as String? ?? t['address'] as String? ?? '')
          .toLowerCase();
      if (c == lower) {
        return t['defuseAssetId'] ??
            t['assetId'] ??
            t['asset_id'] as String?;
      }
    }
    final near = NearIntents.instance;
    final bySymbol = near.findToken(nearTokens, symbol, blockchain);
    return bySymbol?['defuseAssetId'] ?? bySymbol?['assetId'] as String?;
  }

  static double _usdForNative(
    ChainConfig chain,
    double amount,
    List<Map<String, dynamic>> nearTokens,
  ) {
    final near = NearIntents.instance;
    final token = near.findToken(
          nearTokens,
          chain.nativeSymbol,
          chain.nearIntentsBlockchain,
        ) ??
        (chain.nativeSymbol == 'POL'
            ? near.findToken(nearTokens, 'MATIC', chain.nearIntentsBlockchain)
            : null) ??
        (chain.nativeSymbol == 'ETH'
            ? near.findToken(nearTokens, 'ETH', chain.nearIntentsBlockchain)
            : null);
    final price = (token?['price'] as num?)?.toDouble();
    if (price != null && price > 0) return amount * price;
    if (chain.chainId == 56) return amount * 600;
    if (chain.chainId == 137) return amount * 0.085;
    if (chain.nativeSymbol == 'ETH') return amount * 2500;
    return amount;
  }

  static double _usdForToken(String symbol, double balance, double? price) {
    final upper = symbol.toUpperCase();
    if (upper == 'USDT' ||
        upper == 'USDC' ||
        upper == 'USDC.E' ||
        upper == 'DAI' ||
        upper == 'BUSD') {
      return balance;
    }
    if (price != null && price > 0) return balance * price;
    return balance;
  }

  /// Heuristic: non-EVM chains we know about from NEAR Intents.
  static const _nonEvmChains = {'near', 'btc', 'bitcoin', 'sol', 'solana', 'ton', 'sui', 'aptos'};

  static bool _isLikelyEvmChain(String chain) {
    return !_nonEvmChains.contains(chain);
  }
}

class _NearTokenRef {
  final String symbol;
  final int decimals;
  final String? defuseId;
  final double? price;

  const _NearTokenRef({
    required this.symbol,
    required this.decimals,
    this.defuseId,
    this.price,
  });
}
