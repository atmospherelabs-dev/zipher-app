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
  test('guided swaps retain amount while collecting token', () {
    final chat = WalletConversation();
    expect(chat.accept('swap').prompt, contains('How much'));
    expect(chat.accept('0.5 zec').prompt, contains('Which token'));
    final request = chat.accept('btc').request!;
    expect(request.token, 'BTC');
    expect(request.zatoshis, 50000000);
    expect(chat.accept('swap 1 ZEC to USDC').request!.token, 'USDC');
    expect(chat.accept('1 ZEC to ETH').request!.token, 'ETH');
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
}
