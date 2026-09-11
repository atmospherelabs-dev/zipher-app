import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zipher/accounts.dart';
import 'package:zipher/appsettings.dart';
import 'package:zipher/generated/intl/messages.dart';
import 'package:zipher/pages/accounts/send.dart';
import 'package:zipher/pages/accounts/split.dart';
import 'package:zipher/pages/utils.dart';
import 'package:zipher/services/wallet_registry.dart';
import 'package:zipher/services/wallet_service.dart';
import 'package:zipher/store2.dart';

void main() {
  setUp(() {
    appSettings.defaults();
    WalletRegistry.instance.invalidateCache();
    SharedPreferences.setMockInitialValues({});
    marketPrice.price = 40;
    aa =
        ActiveAccount2(coin: 0, id: 1, name: 'Test', address: '', canPay: true);
    aa.poolBalances = PoolBalance(sapling: 100000000);
  });
  tearDown(() {
    WalletRegistry.instance.invalidateCache();
    aa = nullAccount;
  });

  test('corrupt registry cannot be replaced by a new account', () async {
    for (final raw in ['broken-json', '{}', '[{"id":"partial"}]']) {
      WalletRegistry.instance.invalidateCache();
      SharedPreferences.setMockInitialValues({'wallet_profiles': raw});
      await expectLater(WalletRegistry.instance.getAll(), throwsStateError);
      await expectLater(
          WalletRegistry.instance.create('New account'), throwsStateError);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('wallet_profiles'), raw);
    }
  });

  test('registry read can recover without restarting after data is repaired',
      () async {
    SharedPreferences.setMockInitialValues({'wallet_profiles': 'broken'});
    await expectLater(WalletRegistry.instance.getAll(), throwsStateError);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('wallet_profiles', '[]');
    final profile = await WalletRegistry.instance.create('Recovered');
    expect((await WalletRegistry.instance.getAll()).single.id, profile.id);
  });

  test('shield approval for another wallet is rejected before native access',
      () async {
    await expectLater(
        () => WalletService.instance.shieldFunds(
            expectedWalletId: 'previous-wallet',
            expectedTestnet: false,
            expectedGeneration: -1),
        throwsStateError);
  });

  for (final count in [1, 2]) {
    testWidgets('split with $count recipients cannot directly sign',
        (tester) async {
      SendContext? received;
      final router = GoRouter(routes: [
        GoRoute(
            path: '/',
            builder: (_, __) => SplitBillPage(
                prefilled: List.generate(
                    count,
                    (i) => Zip321Payment(
                        address: 'recipient-$i',
                        amountZat: 100000,
                        memo: 'invoice memo')))),
        GoRoute(
            path: '/account/quick_send',
            builder: (_, state) {
              received = state.extra as SendContext;
              return const Scaffold(body: Text('Review destination'));
            }),
      ]);
      await tester.pumpWidget(MaterialApp.router(
          routerConfig: router, localizationsDelegates: const [S.delegate]));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Review & Send'));
      await tester.pumpAndSettle();
      if (count == 1) {
        expect(received?.address, 'recipient-0');
        expect(received?.amount.value, 100000);
        expect(received?.memo?.memo, 'invoice memo');
        expect(find.text('Review destination'), findsOneWidget);
      } else {
        expect(received, isNull);
        expect(
            find.textContaining('Multiple-recipient payments'), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      router.dispose();
    });
  }

  testWidgets('received payment memo overrides default memo', (tester) async {
    appSettings.memo = 'default memo';
    await tester.pumpWidget(MaterialApp(
        localizationsDelegates: const [S.delegate],
        home: QuickSendPage(
            sendContext: SendContext('recipient', 7, Amount(100000, false),
                MemoData(false, '', 'invoice memo')))));
    await tester.pumpAndSettle();
    expect(find.text('invoice memo'), findsOneWidget);
    expect(find.text('default memo'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
