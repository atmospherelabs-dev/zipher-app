import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zipher/pages/action/widgets/wallet_review_card.dart';
import 'package:zipher/zipher_theme.dart';

void main() {
  Widget card(ValueNotifier<int> epoch,
          {required Future<void> Function() confirm,
          required VoidCallback cancel,
          Future<Map<String, String>> Function(bool)? priority}) =>
      MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
                child: WalletReviewCard(
          epoch: epoch,
          expectedEpoch: 1,
          details: const {
            'Recipient': 'Full address',
            'Amount': '0.5 ZEC',
            'Network fee': '0.0001 ZEC',
            'Total': '0.5001 ZEC'
          },
          confirmLabel: 'Send ZEC',
          onConfirm: confirm,
          onCancel: cancel,
          onPriorityChanged: priority,
        ))),
      );
  testWidgets('confirmation is single use while signing is pending',
      (tester) async {
    final epoch = ValueNotifier(1);
    var sends = 0;
    final pending = Completer<void>();
    await tester.pumpWidget(card(epoch, confirm: () {
      sends++;
      return pending.future;
    }, cancel: () {}));
    expect(find.text('0.0001 ZEC'), findsOneWidget);
    await tester.tap(find.text('Send ZEC'));
    await tester.pump();
    expect(sends, 1);
    expect(find.text('Send ZEC'), findsNothing);
    pending.complete();
    await tester.pump();
  });
  testWidgets('cancel consumes the card', (tester) async {
    final epoch = ValueNotifier(1);
    var cancelled = 0;
    var sends = 0;
    await tester.pumpWidget(card(epoch, confirm: () async {
      sends++;
    }, cancel: () {
      cancelled++;
    }));
    await tester.tap(find.text('Cancel'));
    await tester.pump();
    expect(cancelled, 1);
    expect(sends, 0);
    expect(find.text('Send ZEC'), findsNothing);
  });
  testWidgets('replaced request cannot be confirmed from old message',
      (tester) async {
    final epoch = ValueNotifier(1);
    await tester.pumpWidget(card(epoch, confirm: () async {
      fail('stale payment executed');
    }, cancel: () {}));
    epoch.value++;
    await tester.pump();
    expect(find.text('Send ZEC'), findsNothing);
    expect(find.text('Review closed'), findsOneWidget);
  });
  testWidgets('review fits a narrow screen', (tester) async {
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
        card(ValueNotifier(1), confirm: () async {}, cancel: () {}));
    expect(tester.takeException(), isNull);
  });
  testWidgets('two taps before a frame still submit only once', (tester) async {
    var calls = 0;
    await tester.pumpWidget(card(ValueNotifier(1), confirm: () async {
      calls++;
    }, cancel: () {}));
    final callback =
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed!;
    callback();
    callback();
    await tester.pump();
    expect(calls, 1);
  });
  testWidgets('priority recalculation blocks signing and updates the exact fee',
      (tester) async {
    final pending = Completer<Map<String, String>>();
    var requested = false;
    await tester.pumpWidget(card(ValueNotifier(1),
        confirm: () async {}, cancel: () {}, priority: (value) {
      requested = value;
      return pending.future;
    }));
    await tester.tap(find.byType(Switch));
    await tester.pump();
    expect(requested, true);
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull);
    pending.complete({
      'Amount': '0.5 ZEC',
      'Network fee': '0.0004 ZEC',
      'Total': '0.5004 ZEC'
    });
    await tester.pumpAndSettle();
    expect(find.text('0.0004 ZEC'), findsOneWidget);
    expect(find.text('0.5004 ZEC'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNotNull);
  });
  testWidgets('failed fee update cannot sign the previous proposal',
      (tester) async {
    await tester.pumpWidget(card(ValueNotifier(1),
        confirm: () async {
          fail('must not sign a stale fee proposal');
        },
        cancel: () {},
        priority: (_) async => throw StateError('insufficient funds')));
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(find.text('Fee update failed. Retry'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull);
  });
  testWidgets(
      'standard review fits a 360-point chat viewport without scrolling',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        theme: ZipherTheme.dark,
        home: Scaffold(
            body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                    width: 358,
                    height: 360,
                    child: SingleChildScrollView(
                        child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: WalletReviewCard(
                                epoch: ValueNotifier(1),
                                expectedEpoch: 1,
                                details: {
                                  'Recipient': 'u1${'a' * 200}',
                                  'Amount': '0.00100000 ZEC',
                                  'Network fee': '0.00010000 ZEC',
                                  'Total': '0.00110000 ZEC'
                                },
                                confirmLabel: 'Send ZEC',
                                onConfirm: () async {},
                                onCancel: () {},
                                onPriorityChanged: (_) async => {}))))))));
    expect(find.text('0.001 ZEC'), findsOneWidget);
    expect(find.text('0.0001 ZEC'), findsOneWidget);
    expect(find.text('Cancel').hitTestable(), findsOneWidget);
    expect(find.text('Send ZEC').hitTestable(), findsOneWidget);
    expect(tester.getSize(find.byType(WalletReviewCard)).height,
        lessThanOrEqualTo(328));
    expect(tester.takeException(), isNull);
  });
}
