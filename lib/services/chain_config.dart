import 'evm_rpc.dart';

/// Metadata for a known ERC-20 token on a specific chain.
class TokenInfo {
  final String address;
  final int decimals;
  final String symbol;

  const TokenInfo({
    required this.address,
    required this.decimals,
    required this.symbol,
  });
}

/// Per-chain configuration used by [FundingResolver] and action executors.
///
/// Holds RPC, gas params, and a registry of known tokens so that funding
/// logic never needs to hard-code chain IDs or fee constants inline.
class ChainConfig {
  final int chainId;
  final String name;
  final String nativeSymbol;
  final int nativeDecimals;

  /// Identifier used by NEAR Intents (`'bsc'`, `'pol'`, …).
  final String nearIntentsBlockchain;

  final int maxPriorityFeePerGas;
  final int maxFeePerGas;
  final int defaultGasLimit;

  /// Below this native balance, gas must be funded before any on-chain action.
  final double minGasBalance;

  /// Target native balance when auto-funding gas via ZEC bridge.
  final double gasTarget;

  final EvmRpc rpc;

  /// Well-known ERC-20 tokens on this chain, keyed by uppercase symbol.
  final Map<String, TokenInfo> knownTokens;

  const ChainConfig({
    required this.chainId,
    required this.name,
    required this.nativeSymbol,
    required this.nativeDecimals,
    required this.nearIntentsBlockchain,
    required this.maxPriorityFeePerGas,
    required this.maxFeePerGas,
    required this.defaultGasLimit,
    required this.minGasBalance,
    required this.gasTarget,
    required this.rpc,
    required this.knownTokens,
  });

  // ── Static registry ────────────────────────────────────────────────────

  static const bsc = ChainConfig(
    chainId: 56,
    name: 'BSC',
    nativeSymbol: 'BNB',
    nativeDecimals: 18,
    nearIntentsBlockchain: 'bsc',
    maxPriorityFeePerGas: 1000000000,   // 1 gwei
    maxFeePerGas: 5000000000,            // 5 gwei
    defaultGasLimit: 300000,
    minGasBalance: 0.001,
    gasTarget: 0.003,
    rpc: EvmRpc.bsc,
    knownTokens: {
      'USDT': TokenInfo(address: usdtBsc, decimals: 18, symbol: 'USDT'),
    },
  );

  static const polygon = ChainConfig(
    chainId: 137,
    name: 'Polygon',
    nativeSymbol: 'POL',
    nativeDecimals: 18,
    nearIntentsBlockchain: 'pol',
    maxPriorityFeePerGas: 30000000000,  // 30 gwei
    maxFeePerGas: 50000000000,           // 50 gwei
    defaultGasLimit: 300000,
    minGasBalance: 0.005,
    gasTarget: 0.1,
    rpc: EvmRpc.polygon,
    knownTokens: {
      'USDC.e': TokenInfo(address: usdcPolygon, decimals: 6, symbol: 'USDC.e'),
      'USDC': TokenInfo(address: usdcPolygonNative, decimals: 6, symbol: 'USDC'),
    },
  );

  static const List<ChainConfig> all = [bsc, polygon];

  /// Look up config by EVM chain ID. Throws if unknown.
  static ChainConfig fromId(int id) {
    for (final c in all) {
      if (c.chainId == id) return c;
    }
    throw ArgumentError('Unknown chain ID: $id');
  }
}
