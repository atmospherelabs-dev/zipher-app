import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:zipher/pages/action/wallet_chat_input.dart';

void main() {
  final address = 'u1${'a' * 100}';
  test('management commands do not capture payment memos', () {
    expect(chatTool(' add contact '), ChatTool.addContact);
    expect(chatTool('/rename wallet'), ChatTool.renameAccount);
    expect(chatTool('delete account'), ChatTool.deleteAccount);
    expect(chatTool('send 1 ZEC to $address memo: delete account'), isNull);
    expect(chatTool('my account is named scan'), isNull);
  });
  test('QR requests preserve exact amount and private text memo', () {
    final memo = base64Url.encode(utf8.encode('Coffee ☕')).replaceAll('=', '');
    final request = scannedPayment('zcash:$address?amount=0.001&memo=$memo',
        testnet: false);
    expect(request.zatoshis, 100000);
    expect(request.recipient, address);
    expect(request.memo, 'Coffee ☕');
    expect(scannedPayment(address, testnet: false).zatoshis, isNull);
  });
  test('QR rejects ambiguous, unsupported and wrong-network payments', () {
    for (final payload in [
      'zcash:$address?amount=1&amount=2',
      'zcash:$address?amount=0.000000001',
      'zcash:$address?amount=0',
      'zcash:$address?req-unknown=1',
      'zcash:$address?address.1=$address',
      'zcash:$address?memo=invalid!',
      'zcash:$address#fragment',
      'zcash-test:$address?amount=1',
      'https://example.com',
      'send 1 ZEC',
    ]) {
      expect(
          () => scannedPayment(payload, testnet: false), throwsFormatException,
          reason: payload);
    }
  });
}
