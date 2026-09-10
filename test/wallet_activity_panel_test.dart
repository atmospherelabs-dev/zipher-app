import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zipher/pages/action/widgets/wallet_activity_panel.dart';
import 'package:zipher/pages/utils.dart';
import 'package:zipher/services/near_intents.dart';
import 'package:zipher/services/wallet_swap_tracker.dart';
import 'package:zipher/zipher_theme.dart';

Tx transaction(String id, int height, double value) => Tx.from(
    100, 0, height, DateTime(2026, 9, 10), id, id, value, null, null, null, [],
    kind: value > 0 ? 'received' : 'sent');

void main() {
  testWidgets('activity updates a pending incoming transfer after confirmation',
      (tester) async {
    String? opened;
    Widget panel(int height) => MaterialApp(
        theme: ZipherTheme.dark,
        home: Scaffold(
            body: WalletActivityPanel(
                chat: const Text('Conversation'),
                selectedTab: WalletHomeTab.activity,
                onTabChanged: (_) {},
                transactions: [transaction('incoming', height, .001)],
                swaps: [],
                onTransaction: (id) => opened = id,
                onSwap: (_) {})));
    await tester.pumpWidget(panel(0));
    expect(find.text('Incoming'), findsOneWidget);
    expect(find.text('Confirming'), findsOneWidget);
    await tester.tap(find.text('+0.001 ZEC'));
    expect(opened, 'incoming');
    await tester.pumpWidget(panel(99));
    expect(find.text('Received'), findsOneWidget);
    expect(find.text('Confirmed'), findsOneWidget);
    expect(find.text('Incoming'), findsNothing);
    expect(find.text('Conversation'), findsNothing);
  });
  testWidgets('live swap replaces its funding row and opens provider details',
      (tester) async {
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    String? opened;
    final entry = WalletSwapActivity(StoredSwap(
        provider: 'near_intents',
        depositAddress: 'deposit',
        timestamp: 1,
        fromCurrency: 'ZEC',
        fromAmount: '0.1',
        toCurrency: 'ETH',
        toAmount: '0.2',
        toAddress: 'recipient',
        txId: 'funding'))
      ..status = NearSwapStatus(status: 'PROCESSING', raw: {});
    await tester.pumpWidget(MaterialApp(
        theme: ZipherTheme.dark,
        home: Scaffold(
            body: WalletActivityPanel(
                chat: const Text('Conversation'),
                selectedTab: WalletHomeTab.activity,
                onTabChanged: (_) {},
                transactions: [transaction('funding', 0, -.1)],
                swaps: [entry],
                onTransaction: (_) {},
                onSwap: (id) => opened = id))));
    expect(find.text('Sending'), findsNothing);
    expect(find.text('NEAR Intents · Swapping'), findsOneWidget);
    await tester.tap(find.text('ZEC → ETH'));
    expect(opened, 'deposit');
    expect(tester.takeException(), isNull);
  });
}
