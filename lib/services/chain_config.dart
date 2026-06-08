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

  /// Identifier used by NEAR Intents (`'bsc'`, `'pol'`, `'arb'`, …).
  final String nearIntentsBlockchain;

  final int maxPriorityFeePerGas;
  final int maxFeePerGas;
  final int defaultGasLimit;

  /// Below this native balance, gas must be funded before any on-chain action.
  final double minGasBalance;

  /// Target native balance when auto-funding gas via ZEC bridge.
  final double gasTarget;

  /// Native balance to leave behind when sweeping native token to ZEC.
  final double nativeSweepReserve;

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
    required this.nativeSweepReserve,
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
    maxPriorityFeePerGas: 1000000000,
    maxFeePerGas: 5000000000,
    defaultGasLimit: 300000,
    minGasBalance: 0.001,
    gasTarget: 0.003,
    nativeSweepReserve: 0.003,
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
    maxPriorityFeePerGas: 30000000000,
    maxFeePerGas: 50000000000,
    defaultGasLimit: 300000,
    minGasBalance: 0.005,
    gasTarget: 0.1,
    nativeSweepReserve: 0.01,
    rpc: EvmRpc.polygon,
    knownTokens: {
      'USDC.e': TokenInfo(address: usdcPolygon, decimals: 6, symbol: 'USDC.e'),
      'USDC': TokenInfo(address: usdcPolygonNative, decimals: 6, symbol: 'USDC'),
    },
  );

  static const ethereum = ChainConfig(
    chainId: 1,
    name: 'Ethereum',
    nativeSymbol: 'ETH',
    nativeDecimals: 18,
    nearIntentsBlockchain: 'eth',
    maxPriorityFeePerGas: 2000000000,
    maxFeePerGas: 30000000000,
    defaultGasLimit: 300000,
    minGasBalance: 0.001,
    gasTarget: 0.005,
    nativeSweepReserve: 0.002,
    rpc: EvmRpc.ethereum,
    knownTokens: {
      'USDC': TokenInfo(
        address: '0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48',
        decimals: 6,
        symbol: 'USDC',
      ),
      'USDT': TokenInfo(
        address: '0xdAC17F958D2ee523a2206206994597C13D831ec7',
        decimals: 6,
        symbol: 'USDT',
      ),
    },
  );

  static const arbitrum = ChainConfig(
    chainId: 42161,
    name: 'Arbitrum',
    nativeSymbol: 'ETH',
    nativeDecimals: 18,
    nearIntentsBlockchain: 'arb',
    maxPriorityFeePerGas: 100000000,
    maxFeePerGas: 500000000,
    defaultGasLimit: 300000,
    minGasBalance: 0.0001,
    gasTarget: 0.001,
    nativeSweepReserve: 0.0003,
    rpc: EvmRpc.arbitrum,
    knownTokens: {
      'USDC': TokenInfo(
        address: '0xaf88d065e77c8cC2239327C5EDb3A432268e5831',
        decimals: 6,
        symbol: 'USDC',
      ),
      'USDT': TokenInfo(
        address: '0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9',
        decimals: 6,
        symbol: 'USDT',
      ),
    },
  );

  static const base = ChainConfig(
    chainId: 8453,
    name: 'Base',
    nativeSymbol: 'ETH',
    nativeDecimals: 18,
    nearIntentsBlockchain: 'base',
    maxPriorityFeePerGas: 100000000,
    maxFeePerGas: 500000000,
    defaultGasLimit: 300000,
    minGasBalance: 0.0001,
    gasTarget: 0.001,
    nativeSweepReserve: 0.0003,
    rpc: EvmRpc.base,
    knownTokens: {
      'USDC': TokenInfo(
        address: '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913',
        decimals: 6,
        symbol: 'USDC',
      ),
    },
  );

  static const optimism = ChainConfig(
    chainId: 10,
    name: 'Optimism',
    nativeSymbol: 'ETH',
    nativeDecimals: 18,
    nearIntentsBlockchain: 'op',
    maxPriorityFeePerGas: 100000000,
    maxFeePerGas: 500000000,
    defaultGasLimit: 300000,
    minGasBalance: 0.0001,
    gasTarget: 0.001,
    nativeSweepReserve: 0.0003,
    rpc: EvmRpc.optimism,
    knownTokens: {
      'USDC': TokenInfo(
        address: '0x0b2C639c533813c4Aa9D7837CA1A1e916A010327',
        decimals: 6,
        symbol: 'USDC',
      ),
    },
  );

  /// Chains where sweep / gas funding can execute on-chain txs.
  static const List<ChainConfig> all = [
    bsc,
    polygon,
    ethereum,
    arbitrum,
    base,
    optimism,
  ];

  /// EVM NEAR Intents blockchains we scan for balances (includes display-only).
  static const Set<String> evmNearBlockchains = {
    'bsc',
    'pol',
    'eth',
    'arb',
    'base',
    'op',
    'avax',
    'gnosis',
  };

  /// Read-only RPC for chains NEAR lists but we cannot sweep from yet.
  static const Map<String, ({String name, EvmRpc rpc})> discoveryOnly = {
    'avax': (name: 'Avalanche', rpc: EvmRpc.avalanche),
    'gnosis': (name: 'Gnosis', rpc: EvmRpc.gnosis),
  };

  static ChainConfig? forNearBlockchain(String id) {
    final n = id.toLowerCase();
    for (final c in all) {
      if (c.nearIntentsBlockchain == n) return c;
    }
    return null;
  }

  /// Resolve user-facing chain names (`polygon`, `arb`, `ethereum`, …).
  static ChainConfig? forLabel(String input) {
    final n = input.toLowerCase();
    switch (n) {
      case 'polygon':
      case 'matic':
      case 'pol':
        return polygon;
      case 'bsc':
      case 'bnb':
        return bsc;
      case 'ethereum':
      case 'eth':
        return ethereum;
      case 'arbitrum':
      case 'arb':
        return arbitrum;
      case 'base':
        return base;
      case 'optimism':
      case 'op':
        return optimism;
      default:
        return forNearBlockchain(n);
    }
  }

  /// Look up config by EVM chain ID. Throws if unknown.
  static ChainConfig fromId(int id) {
    for (final c in all) {
      if (c.chainId == id) return c;
    }
    throw ArgumentError('Unknown chain ID: $id');
  }
}
