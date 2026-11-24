import 'package:flutter_test/flutter_test.dart';
import 'package:zipher/pages/action/wallet_conversation.dart';

void main() {
  test('privacy routing is local and cannot override a payment memo', () {
    for (final text in [
      'activate tor',
      'enable Tor',
      'turn on tor',
      '/tor on'
    ]) {
      expect(WalletConversation.command(text), WalletCommand.torOn);
    }
    expect(WalletConversation.command('disable tor'), WalletCommand.torOff);
    expect(WalletConversation.command('privacy'), WalletCommand.privacy);
    expect(WalletConversation.command('activate nym'), WalletCommand.nym);
    expect(WalletConversation.command('enable vpn'), WalletCommand.vpn);
    expect(WalletConversation.command('send 1 ZEC memo: enable Tor'),
        WalletCommand.send);
    final conversation = WalletConversation();
    conversation.accept('send');
    conversation.accept('enable Tor');
    expect(conversation.pending, isNull);
  });

  test('pool questions route locally without preparing a payment', () {
    for (final prompt in [
      'pools',
      'pool breakdown',
      'where is my ZEC',
      'repartition'
    ]) {
      expect(WalletConversation().accept(prompt).request?.command,
          WalletCommand.pools);
    }
  });

  final address = 'u1${'a' * 100}';
  test('guided send collects recipient then exact ZEC amount', () {
    final chat = WalletConversation();
    expect(chat.accept('send').prompt, contains('Who'));
    expect(chat.accept(address).prompt, contains('How much'));
    final request = chat.accept('0.12345678 ZEC').request!;
    expect(request.recipient, address);
    expect(request.zatoshis, 12345678);
    expect(chat.pending, isNull);
  });
  test('amount first and one-line natural request produce the same payment',
      () {
    final chat = WalletConversation();
    expect(chat.accept('send 0.5 ZEC').prompt, contains('Who'));
    expect(chat.accept(address).request!.zatoshis, 50000000);
    final parsed = chat.accept('I want to send .5 ZEC to $address').request!;
    expect(parsed.recipient, address);
    expect(parsed.zatoshis, 50000000);
  });
  test('invalid input preserves recipient and draft', () {
    final chat = WalletConversation();
    chat.accept('send to $address');
    for (final input in [
      '-1',
      '0',
      r'$10',
      '0.000000001',
      '1e8',
      '1,5',
      'NaN'
    ]) {
      expect(chat.accept(input).request, isNull, reason: input);
      expect(chat.pending!.recipient, address);
    }
    expect(chat.accept('1 ZEC').request!.zatoshis, 100000000);
  });
  test('USD and negative one-liners never become ZEC payments', () {
    for (final amount in [
      r'$10',
      '10 USD',
      '-5 ZEC',
      '1e2 ZEC',
      '1,000 ZEC',
      '0.000000001 ZEC'
    ]) {
      final chat = WalletConversation();
      expect(chat.accept('send $amount to $address').request, isNull);
      expect(chat.pending!.zatoshis, isNull);
    }
  });
  test('addresses and memo numbers are never treated as amounts', () {
    final chat = WalletConversation();
    final reply = chat.accept('send to $address memo: invoice 123');
    expect(reply.request, isNull);
    expect(chat.pending!.memo, 'invoice 123');
    expect(chat.pending!.zatoshis, isNull);
  });
  test('cancel clears draft and starting another command replaces it', () {
    final chat = WalletConversation();
    chat.accept('send 1');
    chat.accept('cancel');
    expect(chat.pending, isNull);
    expect(chat.accept('1').request, isNull);
    chat.accept('send 1');
    expect(chat.accept('receive').request!.command, WalletCommand.receive);
    expect(chat.pending, isNull);
  });
  test('swap requests are parsed in one line and never held as a send draft',
      () {
    final chat = WalletConversation();
    final bare = chat.accept('swap');
    expect(bare.prompt, isNull);
    expect(bare.request!.command, WalletCommand.swap);
    expect(bare.request!.zatoshis, isNull);
    expect(chat.pending, isNull);
    expect(chat.accept('swap 1 ZEC to USDC').request!.token, 'USDC');
    expect(chat.accept('1 ZEC to ETH').request!.token, 'ETH');
    final full = chat.accept('swap 0.5 zec to usdc on solana').request!;
    expect((full.zatoshis, full.token, full.network),
        (50000000, 'USDC', 'solana'));
    // Starting a swap replaces a send draft rather than mixing with it.
    chat.accept('send 1');
    expect(chat.accept('swap').request!.command, WalletCommand.swap);
    expect(chat.pending, isNull);
  });
  test('looking something up keeps a send draft', () {
    final chat = WalletConversation();
    chat.accept('send 1');
    for (final lookup in ['balance', 'pools', 'help', 'memos', 'privacy']) {
      expect(chat.accept(lookup).request, isNotNull, reason: lookup);
      expect(chat.pending!.zatoshis, 100000000, reason: lookup);
    }
    expect(chat.accept(address).request!.recipient, address);
  });
  test('a pasted address or amount corrects the send draft', () {
    final chat = WalletConversation();
    final other = 'u1${'b' * 100}';
    chat.accept('send to $address');
    expect(chat.accept(other).prompt, contains('How much'));
    expect(chat.pending!.recipient, other);
    expect(chat.accept('0.25').request!.recipient, other);
  });
  test('all address families are collected without mutating case', () {
    for (final prefix in [
      'u1',
      'utest1',
      'zs1',
      'ztestsapling1',
      'tex1',
      'textest1',
      't1',
      't3',
      'tm',
      't2'
    ]) {
      final chat = WalletConversation();
      final addr = '$prefix${'Abc' * 30}';
      chat.accept('send 1 ZEC');
      expect(chat.accept(addr).request!.recipient, addr);
    }
  });
  test('known typo and slash commands stay local', () {
    expect(WalletConversation.command('reveice'), WalletCommand.receive);
    expect(WalletConversation.command('/send'), WalletCommand.send);
    expect(WalletConversation.command('sender'), WalletCommand.unknown);
    expect(WalletConversation.command('exchange 1 ZEC to BTC'),
        WalletCommand.swap);
  });
  test('zatoshi conversion is exact and bounded', () {
    expect(WalletConversation.parseZatoshis('0.00000001'), 1);
    expect(WalletConversation.parseZatoshis('21000000'), 2100000000000000);
    expect(WalletConversation.parseZatoshis('21000000.00000001'), isNull);
    expect(WalletConversation.formatZec(0), '0');
    expect(WalletConversation.formatZec(100000000), '1');
    expect(WalletConversation.formatZec(100000), '0.001');
    expect(WalletConversation.formatZec(-100000), '-0.001');
    expect(WalletConversation.formatZec(-1), '-0.00000001');
    expect(WalletConversation.formatZec(1), '0.00000001');
    expect(WalletConversation.formatZec(123456789), '1.23456789');
  });

  group('contact names as recipients', () {
    final alice = 'u1alice${'a' * 80}';
    final bob = 'u1bob${'b' * 80}';
    final bobToo = 'u1bobtoo${'c' * 80}';
    WalletConversation chat() => WalletConversation(
        zcashContacts: () => [
              (name: 'Alice Smith', address: alice),
              (name: 'Bob', address: bob),
              (name: 'bob', address: bobToo),
            ]);

    test('a one-line send to a contact resolves to its saved address', () {
      final request = chat().accept('send 0.5 ZEC to alice smith').request!;
      expect(request.recipient, alice);
      expect(request.zatoshis, 50000000);
    });

    test('typing a contact name at the recipient step fills the address', () {
      final c = chat();
      c.accept('send');
      c.accept('  ALICE SMITH ');
      expect(c.pending!.recipient, alice);
      expect(c.accept('0.1').request!.recipient, alice);
    });

    test('an ambiguous name never picks a contact', () {
      final c = chat();
      final reply = c.accept('send 1 ZEC to bob');
      expect(reply.request, isNull);
      expect(reply.prompt, contains('More than one contact'));
      expect(c.pending!.recipient, isNull);
      expect(c.accept('Bob').prompt, contains('More than one contact'));
      expect(c.pending!.recipient, isNull);
    });

    test('an unknown name asks for an address and keeps the amount', () {
      final c = chat();
      final reply = c.accept('send 1 ZEC to carol');
      expect(reply.prompt, contains('No contact named “carol”'));
      expect(c.pending!.zatoshis, 100000000);
      expect(c.pending!.recipient, isNull);
    });

    test('partial names do not match', () {
      final c = chat();
      c.accept('send 1 ZEC');
      expect(c.accept('Alice').request, isNull);
      expect(c.pending!.recipient, isNull);
    });
  });
}
