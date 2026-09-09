import 'chain_config.dart';
import '../src/rust/api/engine_api.dart' show EngineMultiChainAddresses;

class WalletReceiveAddress {
  final String id;
  final String label;
  final String address;
  const WalletReceiveAddress(this.id, this.label, this.address);

  static List<WalletReceiveAddress> available(
          {required String zcash,
          required bool testnet,
          EngineMultiChainAddresses? chains}) =>
      [
        if (zcash.isNotEmpty)
          WalletReceiveAddress(
              'zec', testnet ? 'Zcash Testnet' : 'Zcash', zcash),
        // These are the existing mainnet derivations. Never label them as testnet.
        if (!testnet && chains != null) ...[
          if (chains.bitcoin.isNotEmpty)
            WalletReceiveAddress('btc', 'Bitcoin', chains.bitcoin),
          if (chains.solana.isNotEmpty)
            WalletReceiveAddress('sol', 'Solana', chains.solana),
          if (chains.evm.isNotEmpty)
            for (final chain in ChainConfig.all)
              WalletReceiveAddress(
                  chain.nearIntentsBlockchain, chain.name, chains.evm),
        ],
      ];

  static String? requestedChain(String text) {
    final words = text.toLowerCase().split(RegExp(r'[^a-z0-9]+'));
    final matches = <String>{};
    for (final word in words) {
      final id = switch (word) {
        'zcash' || 'zec' => 'zec',
        'bitcoin' || 'btc' => 'btc',
        'solana' || 'sol' => 'sol',
        _ => ChainConfig.forLabel(word)?.nearIntentsBlockchain,
      };
      if (id != null) matches.add(id);
    }
    return matches.length == 1 ? matches.single : null;
  }
}
