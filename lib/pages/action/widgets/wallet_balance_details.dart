import 'package:flutter/material.dart';
import '../../../accounts.dart';
import '../../../zipher_theme.dart';
import '../wallet_conversation.dart';

class WalletChainLogo extends StatelessWidget {
  final String chain;
  final double size;
  const WalletChainLogo(this.chain, {super.key, this.size = 20});

  @override
  Widget build(BuildContext context) {
    final id = switch (chain.toLowerCase()) {
      'zec' || 'zcash' => 'zec',
      'bitcoin' => 'btc',
      'solana' => 'sol',
      'ethereum' => 'eth',
      'polygon' => 'pol',
      'arbitrum' => 'arb',
      'optimism' => 'op',
      _ => chain.toLowerCase(),
    };
    return ClipOval(
        child: Image.asset(
      id == 'zec' ? 'assets/tokens/zec.png' : 'assets/chains/$id.png',
      width: size,
      height: size,
      errorBuilder: (_, __, ___) => Icon(Icons.currency_exchange, size: size),
    ));
  }
}

class WalletPoolDetails extends StatelessWidget {
  final PoolBalance balance;
  const WalletPoolDetails(this.balance, {super.key});

  @override
  Widget build(BuildContext context) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Where your ZEC is',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Text(
              'Shielded pools keep your balance private. Transparent funds are public.',
              style: TextStyle(color: ZipherColors.text60, fontSize: 13)),
          const SizedBox(height: 16),
          for (final row in [
            (
              'Ironwood',
              balance.totalIronwood,
              balance.ironwood,
              ZipherColors.ironwood
            ),
            (
              'Orchard',
              balance.totalOrchard,
              balance.orchard,
              ZipherColors.orchard
            ),
            (
              'Sapling',
              balance.totalSapling,
              balance.sapling,
              ZipherColors.sapling
            ),
            (
              'Transparent',
              balance.totalTransparent,
              balance.transparent,
              ZipherColors.transparent
            ),
          ])
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 9),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Icon(
                          row.$1 == 'Transparent'
                              ? Icons.shield_outlined
                              : Icons.shield_rounded,
                          size: 15,
                          color: row.$4),
                      const SizedBox(width: 8),
                      Expanded(child: Text(row.$1)),
                      Text('${WalletConversation.formatZec(row.$2)} ZEC',
                          style: TextStyle(fontSize: 12)),
                    ]),
                    const SizedBox(height: 6),
                    LinearProgressIndicator(
                        value: balance.total > 0 ? row.$2 / balance.total : 0,
                        minHeight: 3,
                        color: row.$4,
                        backgroundColor: ZipherColors.borderSubtle),
                    if (row.$2 > row.$3)
                      Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                              '${WalletConversation.formatZec(row.$2 - row.$3)} ZEC not yet spendable',
                              style: TextStyle(
                                  fontSize: 11, color: ZipherColors.text40))),
                  ]),
            ),
          const SizedBox(height: 8),
          Text(
              '${WalletConversation.formatZec(balance.shielded)} ZEC spendable shielded',
              style: TextStyle(color: ZipherColors.text60, fontSize: 13)),
        ],
      );
}
