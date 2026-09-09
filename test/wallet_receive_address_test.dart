import 'package:flutter_test/flutter_test.dart';
import 'package:zipher/services/wallet_receive_address.dart';
import 'package:zipher/pages/action/wallet_conversation.dart';
import 'package:zipher/src/rust/api/engine_api.dart';

void main() {
  const chains = EngineMultiChainAddresses(
      evm: 'evm fixture', solana: 'sol fixture', bitcoin: 'btc fixture');
  test('picker maps each chain to its own wallet derivation', () {
    final choices = WalletReceiveAddress.available(
        zcash: 'zec fixture', testnet: false, chains: chains);
    expect(choices.length, 9);
    expect(choices.singleWhere((c) => c.id == 'btc').address, chains.bitcoin);
    expect(choices.singleWhere((c) => c.id == 'sol').address, chains.solana);
    expect(choices.singleWhere((c) => c.id == 'base').address, chains.evm);
    expect(choices.singleWhere((c) => c.id == 'zec').address, 'zec fixture');
  });
  test('testnet never offers mainnet BTC SOL or EVM derivations', () {
    final choices = WalletReceiveAddress.available(
        zcash: 'test zec', testnet: true, chains: chains);
    expect(choices.single.label, 'Zcash Testnet');
  });
  test('missing foreign derivations never fall back to Zcash or EVM', () {
    expect(
        WalletReceiveAddress.available(zcash: 'zec', testnet: false).single.id,
        'zec');
  });
  test(
      'address aliases route deterministically and ambiguous chains show picker',
      () {
    expect(WalletReceiveAddress.requestedChain('What is my Bitcoin address?'),
        'btc');
    expect(WalletReceiveAddress.requestedChain('receive on ETH'), 'eth');
    expect(WalletReceiveAddress.requestedChain('my USDC address'), isNull);
    expect(WalletReceiveAddress.requestedChain('Ethereum or Base address'),
        isNull);
    expect(WalletReceiveAddress.requestedChain('my Tron address'), isNull);
    expect(
        WalletConversation.command('show my addresses'), WalletCommand.receive);
    expect(
        WalletConversation.command('show my balances'), WalletCommand.balance);
  });
}
