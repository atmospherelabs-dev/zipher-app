import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zipher/accounts.dart';
import 'package:zipher/appsettings.dart';
import 'package:zipher/coin/coins.dart';
import 'package:zipher/pages/cipherpay/invoice_pay.dart';
import 'package:zipher/services/cipherpay_client.dart';
import 'package:zipher/services/hitl_watch_service.dart';
import 'package:zipher/services/network_mode.dart';
import 'package:zipher/services/wallet_birthdays.dart';
import 'package:zipher/services/wallet_registry.dart';
import 'package:zipher/services/wallet_service.dart';
import 'package:zipher/settings.pb.dart';
import 'package:zipher/store2.dart';

String _stored(CoinSettings s) => base64Encode(s.writeToBuffer());

CoinSettings _customServer(String url) => CoinSettings()
  ..lwd = (ServerURL()
    ..index = -1
    ..customURL = url);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    isTestnet = false;
    testnetNotifier.value = false;
    marketPrice.price = null;
    coinSettings = CoinSettings();
    WalletRegistry.instance.invalidateCache();
  });

  group('switching network', () {
    test('loads the target network settings, never the previous ones',
        () async {
      SharedPreferences.setMockInitialValues({
        'coin_settings_0': _stored(_customServer('https://main.example:443')),
        'coin_settings_1': _stored(_customServer('https://test.example:443')),
      });
      coinSettings = _customServer('https://main.example:443');
      marketPrice.price = 42.0;
      var reinits = 0;

      await applyNetworkMode(true, reinitCoins: () async => reinits++);

      expect(isTestnet, isTrue);
      expect(testnetNotifier.value, isTrue);
      expect(reinits, 1);
      expect(resolveURL(coins[1], coinSettings), 'https://test.example:443');
      expect(marketPrice.price, isNull,
          reason: 'mainnet ZEC price must not be shown next to TAZ');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('testnet'), isTrue);

      await applyNetworkMode(false, reinitCoins: () async {});
      expect(resolveURL(coins[0], coinSettings), 'https://main.example:443');
    });

    test('a network with no saved settings uses its own default server',
        () async {
      SharedPreferences.setMockInitialValues({
        'coin_settings_0': _stored(_customServer('https://main.example:443')),
      });
      coinSettings = _customServer('https://main.example:443');
      await applyNetworkMode(true, reinitCoins: () async {});
      expect(resolveURL(coins[1], coinSettings), zcashtest.lwd.first.url);
    });

    test('selecting the account keeps the saved server choice', () async {
      SharedPreferences.setMockInitialValues({
        'coin_settings_1': _stored(_customServer('https://test.example:443')),
      });
      await setActiveAccount(1, 1);
      expect(resolveURL(coins[1], coinSettings), 'https://test.example:443');
      expect(coinSettings.account, 1);
    });

    test('testnet has no market price', () async {
      SharedPreferences.setMockInitialValues({});
      isTestnet = true;
      marketPrice.price = 42.0;
      await marketPrice.update();
      expect(marketPrice.price, isNull);
    });

    test('a watch-only wallet is not given a seed on the other network',
        () async {
      SharedPreferences.setMockInitialValues({});
      final profile =
          await WalletRegistry.instance.create('Shared', watchOnly: true);
      await expectLater(
          WalletService.instance.createNetworkWalletForProfile(profile.id),
          throwsStateError);
    });
  });

  group('wallet birthdays', () {
    test('rebuild starts at the remembered birthday of that network',
        () async {
      SharedPreferences.setMockInitialValues({});
      await WalletBirthdays.remember('w1_testnet', 3900000);
      expect(await WalletBirthdays.forRestore('w1_testnet'), 3900000);
      expect(await WalletBirthdays.forRestore('w1'), 0,
          reason: 'the mainnet wallet keeps its own birthday');
    });

    test('without a birthday the rebuild scans full history, not from tip',
        () async {
      SharedPreferences.setMockInitialValues({});
      await WalletBirthdays.remember('w2', 0);
      expect(await WalletBirthdays.forRestore('w2'), 0);
      await WalletBirthdays.remember('w2', 3000000);
      await WalletBirthdays.forget('w2');
      expect(await WalletBirthdays.forRestore('w2'), 0);
    });
  });

  group('agent approvals', () {
    test('a request for the other network waits instead of being dropped', () {
      final shown = <String>{};
      expect(
          claimHitlRequestForDisplay(
              approvalId: 'a1',
              requestNetwork: 'main',
              testnet: true,
              shownIds: shown),
          isFalse);
      expect(shown, isEmpty);
      // After switching back to mainnet the same request appears, once.
      expect(
          claimHitlRequestForDisplay(
              approvalId: 'a1',
              requestNetwork: 'main',
              testnet: false,
              shownIds: shown),
          isTrue);
      expect(
          claimHitlRequestForDisplay(
              approvalId: 'a1',
              requestNetwork: 'main',
              testnet: false,
              shownIds: shown),
          isFalse);
    });
  });

  group('CipherPay on testnet', () {
    const uuid = '123e4567-e89b-42d3-a456-426614174000';
    final memo = base64Url.encode(utf8.encode('CP-ABC12345')).replaceAll('=', '');

    test('mainnet still recognises every invoice shape', () {
      expect(CipherPayClient.extractInvoiceRef('https://cipherpay.app/pay/$uuid'),
          uuid);
      expect(CipherPayClient.extractInvoiceRef('CP-ABC12345'), 'CP-ABC12345');
      expect(
          CipherPayClient.extractInvoiceRef('zcash:u1abc?amount=1&memo=$memo'),
          'CP-ABC12345');
    });

    test('testnet payment requests are plain sends, not mainnet invoices', () {
      expect(
          CipherPayClient.extractInvoiceRef('zcash-test:utest1abc?memo=$memo',
              testnet: true),
          isNull);
      expect(CipherPayClient.extractInvoiceRef('CP-ABC12345', testnet: true),
          isNull);
      expect(CipherPayClient.extractInvoiceRef(uuid, testnet: true), isNull);
      // A checkout link still opens the page, which explains why it can't pay.
      expect(
          CipherPayClient.extractInvoiceRef('https://cipherpay.app/pay/$uuid',
              testnet: true),
          uuid);
    });

    testWidgets('invoice page explains instead of loading or paying',
        (tester) async {
      isTestnet = true;
      await tester.pumpWidget(
          const MaterialApp(home: InvoicePayPage(invoiceRef: uuid)));
      await tester.pump();
      expect(find.text(cipherPayTestnetMessage), findsOneWidget);
      expect(find.text('Retry'), findsNothing);
    });
  });
}
