import 'package:flutter_test/flutter_test.dart';
import 'package:zipher/pages/action/wallet_conversation.dart';
import 'package:zipher/pages/action/wallet_swap_flow.dart';
import 'package:zipher/services/near_intents.dart';

NearToken _token(String symbol, String chain,
        {double? price = 1, String? id, int decimals = 6}) =>
    NearToken(
        assetId: id ?? 'asset:$symbol:$chain',
        symbol: symbol,
        blockchain: chain,
        decimals: decimals,
        price: price);

/// Shaped like the live 1Click list: same symbol on many networks, deprecated
/// twins, an unpriced token, two assets sharing a symbol on one network.
SwapCatalog _catalog() => SwapCatalog([
      _token('ZEC', 'zec'),
      _token('ZEC', 'sol'),
      for (final chain in [
        'near',
        'eth',
        'arb',
        'base',
        'sol',
        'gnosis',
        'pol'
      ])
        _token('USDC', chain),
      _token('USDC', 'hypercore', id: 'hip1'),
      _token('USDC', 'hypercore', id: 'erc20'),
      _token('USDC(DEPRECATED)', 'eth'),
      for (final chain in ['eth', 'tron', 'sol']) _token('USDT', chain),
      _token('BTC', 'near'),
      _token('BTC', 'btc', decimals: 8),
      _token('ETH', 'arb', decimals: 18),
      _token('ETH', 'eth', decimals: 18),
      _token('SOL', 'sol', decimals: 9),
      _token('USAD', 'near'),
      _token('USDe', 'hood'),
      _token('wNEAR', 'near', decimals: 24),
      _token('NEAR', 'bsc', decimals: 24),
      _token('DAI', 'eth', decimals: 18),
      _token('GHOST', 'eth', price: null),
      _token(r'$WIF', 'sol'),
    ]);

const _sol = 'GbGAFmHmMJmqT6pZ1cQy6dS1wqK5v2ZcEmWGDRoNabcd';
const _evm = '0x1111111111111111111111111111111111111111';

void main() {
  group('catalog', () {
    test('never offers ZEC, deprecated, unpriced or ambiguous assets', () {
      final catalog = _catalog();
      expect(catalog.networksFor('ZEC'), isEmpty);
      expect(catalog.networksFor('USDC(DEPRECATED)'), isEmpty);
      expect(catalog.networksFor('GHOST'), isEmpty);
      expect(catalog.networksFor('usdc').map((t) => t.blockchain),
          isNot(contains('hypercore')),
          reason: 'two USDC assets on one network cannot be told apart');
    });

    test('orders networks by where ZEC actually goes, native network first',
        () {
      final catalog = _catalog();
      expect(catalog.networksFor('usdc').map((t) => t.blockchain).toList(),
          ['sol', 'eth', 'base', 'arb', 'near', 'pol', 'gnosis']);
      expect(catalog.networksFor('BTC').first.blockchain, 'btc');
      expect(catalog.networksFor('eth').first.blockchain, 'eth');
    });

    test('resolves names and wrapped forms without guessing', () {
      final catalog = _catalog();
      expect(catalog.networksFor('bitcoin').first.symbol, 'BTC');
      expect(catalog.networksFor('Tether').first.symbol, 'USDT');
      expect(catalog.networksFor('wif').single.symbol, r'$WIF');
      expect(catalog.networksFor('near').map((t) => t.displayName),
          ['wNEAR (NEAR)', 'NEAR (BSC)']);
      expect(catalog.networksFor('USED'), isEmpty);
    });

    test('a mistyped token suggests the popular token before obscure ones', () {
      final catalog = _catalog();
      final suggestions = catalog.suggest('USED');
      expect(suggestions.take(2), ['USDC', 'USDT']);
      expect(suggestions, containsAll(['USAD', 'USDe']));
      expect(catalog.suggest('bitc'), ['BTC']);
      expect(catalog.suggest('us').first, 'USDC');
      expect(catalog.suggest('zzzzzz'), isEmpty);
    });
  });

  group('one-line requests', () {
    test('amount, token and network are read from natural phrasing', () {
      for (final (text, zatoshis, token, network) in [
        ('swap', null, null, null),
        ('swap 1.5 zec to usdc', 150000000, 'USDC', null),
        ('swap 1.5 ZEC to USDC on solana', 150000000, 'USDC', 'solana'),
        ('swap 1.5 zec for usdc (sol)', 150000000, 'USDC', 'sol'),
        ('swap 1 zec to usdc sol', 100000000, 'USDC', 'sol'),
        ('I want to convert .5 into btc', 50000000, 'BTC', null),
        ('swap to eth', null, 'ETH', null),
        ('swap usdc', null, 'USDC', null),
        ('swap zec to usdt on tron', null, 'USDT', 'tron'),
        ('1.5 zec to usdc on solana', 150000000, 'USDC', 'solana'),
      ]) {
        expect(WalletConversation.command(text), WalletCommand.swap,
            reason: text);
        final request = WalletConversation.parseSwap(text);
        expect(request.zatoshis, zatoshis, reason: text);
        expect(request.token, token, reason: text);
        expect(request.network, network, reason: text);
        expect(request.unreadAmount, isFalse, reason: text);
      }
    });

    test('dollar and inexact amounts are flagged, never converted', () {
      for (final text in [
        r'swap $10 to usdc',
        'swap 10 usd to usdc',
        'swap all to usdc',
        'swap 1,5 zec to usdc',
        'swap 0.000000001 zec to usdc',
      ]) {
        final request = WalletConversation.parseSwap(text);
        expect(request.zatoshis, isNull, reason: text);
        expect(request.unreadAmount, isTrue, reason: text);
        expect(request.token, 'USDC', reason: text);
      }
    });
  });

  group('draft', () {
    test('a mistyped token keeps the amount and only asks for the token', () {
      final draft = SwapDraft(_catalog());
      draft.seed(zatoshis: 150000000);
      final reply = draft.accept('USED');
      expect(reply.problem, contains('USED'));
      expect(reply.suggestions.first, 'USDC');
      expect(draft.zatoshis, 150000000);
      expect(draft.step, SwapStep.token);
      final first = draft.accept('usdc');
      expect(first.change, SwapChange.token);
      expect(first.replaced, isFalse,
          reason: 'a first answer is not a correction');
      expect(draft.step, SwapStep.network);
      expect(draft.accept('Solana').change, SwapChange.network);
      expect(draft.accept(_sol).change, SwapChange.recipient);
      expect(draft.step, SwapStep.ready);
      expect(draft.summary, '1.5 ZEC to USDC · Solana');
    });

    test('a one-line request with a typo still keeps everything else', () {
      final draft = SwapDraft(_catalog());
      final reply =
          draft.seed(zatoshis: 150000000, token: 'USED', network: 'solana');
      expect(reply.suggestions, contains('USDC'));
      expect(draft.zatoshis, 150000000);
      expect(draft.step, SwapStep.token);
    });

    test('a complete one-line request only needs the recipient', () {
      final draft = SwapDraft(_catalog());
      final reply =
          draft.seed(zatoshis: 150000000, token: 'USDC', network: 'solana');
      expect(reply.problem, isNull);
      expect(draft.token!.blockchain, 'sol');
      expect(draft.step, SwapStep.recipient);
    });

    test('every field can be retyped at any step, including during review', () {
      final draft = SwapDraft(_catalog())
        ..seed(zatoshis: 100000000, token: 'USDC', network: 'eth');
      expect(draft.accept(_evm).change, SwapChange.recipient);
      expect(draft.step, SwapStep.ready);

      // Another token on the same network keeps the network and address.
      expect(draft.accept('usdt').change, SwapChange.token);
      expect(draft.token!.symbol, 'USDT');
      expect(draft.token!.blockchain, 'eth');
      expect(draft.recipient, _evm);
      expect(draft.step, SwapStep.ready);

      // Another EVM network keeps the same address.
      draft.accept('usdc');
      expect(draft.accept('base').change, SwapChange.network);
      expect(draft.recipient, _evm);

      // A network with another address format asks for the address again.
      expect(draft.accept('solana').change, SwapChange.network);
      expect(draft.recipient, isNull);
      expect(draft.step, SwapStep.recipient);

      final amount = draft.accept('2.25');
      expect(amount.change, SwapChange.amount);
      expect(amount.replaced, isTrue, reason: 'corrections are acknowledged');
      expect(draft.zatoshis, 225000000);
      expect(draft.accept(_sol).change, SwapChange.recipient);
      expect(draft.step, SwapStep.ready);
      expect(draft.accept(_sol.replaceFirst('G', 'H')).change,
          SwapChange.recipient,
          reason: 'a new address replaces the reviewed one');
    });

    test('a single-network token skips the network question', () {
      final draft = SwapDraft(_catalog())..seed(zatoshis: 1);
      draft.accept('dai');
      expect(draft.token!.blockchain, 'eth');
      expect(draft.step, SwapStep.recipient);
    });

    test('a token that is not on the chosen network asks for a network', () {
      final draft = SwapDraft(_catalog())
        ..seed(zatoshis: 1, token: 'USDC', network: 'base');
      draft.accept(_evm);
      draft.accept('usdt');
      expect(draft.token, isNull);
      expect(draft.recipient, isNull);
      expect(draft.step, SwapStep.network);
      expect(draft.accept('polygon').problem, contains('Polygon'));
    });

    test('wrong-network and malformed addresses are refused with the reason',
        () {
      final draft = SwapDraft(_catalog())
        ..seed(zatoshis: 1, token: 'USDC', network: 'sol');
      expect(draft.accept(_evm).problem, contains('Solana address'));
      expect(draft.accept('two words').problem, contains('Solana'));
      expect(draft.accept('nope').problem, contains('Solana address'));
      expect(draft.recipient, isNull);
      expect(draft.accept(_sol).problem, isNull);
    });

    test('non-ZEC and inexact amounts never become the amount', () {
      final draft = SwapDraft(_catalog());
      for (final input in [r'$10', '-1', '0', '1e3', '1,5']) {
        expect(draft.accept(input).problem, contains('ZEC'), reason: input);
        expect(draft.zatoshis, isNull, reason: input);
      }
      // The token may be given before the amount.
      expect(draft.accept('usdc').change, SwapChange.token);
      expect(draft.step, SwapStep.amount);
      expect(draft.accept('0.5').change, SwapChange.amount);
      expect(draft.step, SwapStep.network);
    });

    test('an unlisted network is named back instead of silently ignored', () {
      final draft = SwapDraft(_catalog())..seed(zatoshis: 1, token: 'USDT');
      expect(draft.accept('base').problem, contains('Base'));
      expect(draft.token, isNull);
      expect(draft.seed(zatoshis: 1, token: 'USDT', network: 'base').problem,
          contains('Base'));
    });
  });
}
