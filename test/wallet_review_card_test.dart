import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zipher/pages/action/widgets/wallet_review_card.dart';

void main() {
  Widget card(ValueNotifier<int> epoch,
          {required Future<void> Function() confirm,
          required VoidCallback cancel}) =>
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
}
