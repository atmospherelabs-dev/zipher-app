import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zipher/pages/action/widgets/wallet_review_card.dart';
import 'package:zipher/zipher_theme.dart';

const _send = ReviewData(
    zatoshis: 50000000, fee: 10000, recipient: 'Full address', zecUsd: 40);

SwapReview _quote({DateTime? expiry}) => SwapReview(
    symbol: 'USDC',
    chain: 'sol',
    network: 'Solana',
    estimated: '1,185.82',
    minimum: '1,173.96',
    rate: '1 ZEC ≈ 790.5474 USDC',
    usd: 1185.8,
    eta: const Duration(minutes: 2),
    expiry: expiry,
    depositAddress: 't1DepositAddressFromTheProvider',
    refundAddress: 't1RefundAddressOfThisWallet');

ReviewData _swap({DateTime? expiry}) => ReviewData(
    zatoshis: 150000000,
    fee: 15000,
    recipient: 'GbGAFmHmMJmqT6pZ1cQy6dS1wqK5v2ZcEmWGDRoNabcd',
    recipientNote: 'Your wallet',
    zecUsd: 790.55,
    swap: _quote(expiry: expiry));

void main() {
  Widget card(ValueNotifier<int> epoch,
          {required Future<void> Function() confirm,
          required VoidCallback cancel,
          ReviewData data = _send,
          String label = 'Send ZEC',
          Future<int> Function(bool)? priority,
          ValueNotifier<ReviewPhase>? phase,
          VoidCallback? requote,
          DateTime Function()? now}) =>
      MaterialApp(
        theme: ZipherTheme.dark,
        home: Scaffold(
            body: SingleChildScrollView(
                child: WalletReviewCard(
          epoch: epoch,
          expectedEpoch: 1,
          data: data,
          confirmLabel: label,
          onConfirm: confirm,
          onCancel: cancel,
          onPriorityChanged: priority,
          phase: phase,
          onRequote: requote,
          now: now,
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
    expect(find.text('0.5001 ZEC'), findsOneWidget);
    expect(find.text(r'≈ $20.00'), findsOneWidget);
    await tester.tap(find.text('Send ZEC'));
    await tester.pump();
    expect(sends, 1);
    expect(find.text('Send ZEC'), findsNothing);
    expect(find.text('Waiting for your approval…'), findsOneWidget);
    pending.complete();
    await tester.pump();
  });
  testWidgets('cancel consumes the card and says nothing was sent',
      (tester) async {
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
    expect(find.text('Cancelled · nothing was sent'), findsOneWidget);
    // The amount stays visible as a record of what was declined.
    expect(find.text('0.5 ZEC'), findsOneWidget);
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
    expect(find.text('Cancel'), findsNothing);
    expect(find.text('Replaced by a newer request'), findsOneWidget);
  });
  testWidgets('a closed review reports the outcome its owner observed',
      (tester) async {
    final phase = ValueNotifier(ReviewPhase.open);
    await tester.pumpWidget(card(ValueNotifier(1),
        confirm: () async {}, cancel: () {}, phase: phase));
    await tester.tap(find.text('Send ZEC'));
    await tester.pump();
    for (final (value, text) in [
      (ReviewPhase.sending, 'Approved · signing and sending…'),
      (ReviewPhase.sent, 'Approved and submitted'),
      (ReviewPhase.approved, 'Approved · see the status below'),
      (ReviewPhase.failed, 'Not sent'),
      (ReviewPhase.cancelled, 'Cancelled · nothing was sent'),
      (ReviewPhase.expired, 'Quote expired · nothing was sent'),
    ]) {
      phase.value = value;
      await tester.pump();
      expect(find.text(text), findsOneWidget);
    }
  });
  testWidgets('review fits a narrow screen', (tester) async {
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
        card(ValueNotifier(1), confirm: () async {}, cancel: () {}));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(card(ValueNotifier(1),
        confirm: () async {},
        cancel: () {},
        data: _swap(),
        label: 'Confirm swap',
        priority: (_) async => 150000));
    await tester.tap(find.text('Details'));
    await tester.pump();
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
    final pending = Completer<int>();
    var requested = false;
    await tester.pumpWidget(card(ValueNotifier(1),
        confirm: () async {}, cancel: () {}, priority: (value) {
      requested = value;
      return pending.future;
    }));
    await tester.tap(find.text('Details'));
    await tester.pump();
    await tester.tap(find.byType(Switch));
    await tester.pump();
    expect(requested, true);
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull);
    pending.complete(40000);
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
    await tester.tap(find.text('Details'));
    await tester.pump();
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
                                data: ReviewData(
                                    zatoshis: 100000,
                                    fee: 10000,
                                    recipient: 'u1${'a' * 200}'),
                                confirmLabel: 'Send ZEC',
                                onConfirm: () async {},
                                onCancel: () {},
                                onPriorityChanged: (_) async => 10000))))))));
    expect(find.text('0.001 ZEC'), findsOneWidget);
    expect(find.text('0.0001 ZEC'), findsOneWidget);
    expect(find.text('Cancel').hitTestable(), findsOneWidget);
    expect(find.text('Send ZEC').hitTestable(), findsOneWidget);
    expect(tester.getSize(find.byType(WalletReviewCard)).height,
        lessThanOrEqualTo(328));
    expect(tester.takeException(), isNull);
  });

  testWidgets('swap review leads with both sides and keeps the rest secondary',
      (tester) async {
    await tester.pumpWidget(card(ValueNotifier(1),
        confirm: () async {},
        cancel: () {},
        data: _swap(),
        label: 'Confirm swap'));
    // Only what is needed to decide: both sides, destination, rate, fee, time.
    expect(find.text('You pay'), findsOneWidget);
    expect(find.text('1.5 ZEC'), findsOneWidget);
    expect(find.text('You receive'), findsOneWidget);
    expect(find.text('1,185.82 USDC'), findsOneWidget);
    expect(find.text(r'≈ $1,185.80 · on Solana'), findsOneWidget);
    expect(find.text('1 ZEC ≈ 790.5474 USDC'), findsOneWidget);
    expect(find.text('0.00015 ZEC'), findsOneWidget);
    expect(find.text('about 2 min'), findsOneWidget);
    expect(find.textContaining('Your wallet · GbGAFm'), findsOneWidget);
    // The rest is available under Details, not in the way.
    expect(find.text('1,173.96 USDC'), findsNothing);
    expect(find.text('1.50015 ZEC'), findsNothing);
    expect(find.textContaining('NEAR Intents runs this swap'), findsNothing);
    expect(find.text('t1DepositAddressFromTheProvider'), findsNothing);
    expect(find.textContaining('Quote valid until'), findsNothing);
    await tester.tap(find.text('Details'));
    await tester.pump();
    expect(find.text('1,173.96 USDC'), findsOneWidget);
    expect(find.text('1.50015 ZEC'), findsOneWidget);
    expect(find.textContaining('NEAR Intents runs this swap'), findsOneWidget);
    expect(find.text('t1DepositAddressFromTheProvider'), findsOneWidget);
    expect(find.text('t1RefundAddressOfThisWallet'), findsOneWidget);
    expect(find.text('0.5% · included in the rate'), findsOneWidget);
    await tester.tap(find.textContaining('Your wallet · GbGAFm'));
    await tester.pump();
    expect(find.text('GbGAFmHmMJmqT6pZ1cQy6dS1wqK5v2ZcEmWGDRoNabcd'),
        findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a quote that lapses on screen can no longer be confirmed',
      (tester) async {
    var requotes = 0;
    final start = DateTime(2026, 11, 22, 12);
    var clock = start;
    await tester.pumpWidget(card(ValueNotifier(1),
        confirm: () async {
          fail('must not sign an expired quote');
        },
        cancel: () {},
        data: _swap(expiry: start.add(const Duration(minutes: 2, seconds: 20))),
        label: 'Confirm swap',
        requote: () => requotes++,
        now: () => clock));
    expect(find.text('Confirm swap'), findsOneWidget);
    expect(find.text('Quote expires in'), findsOneWidget);
    clock = start.add(const Duration(seconds: 31));
    await tester.pump(const Duration(seconds: 31));
    expect(find.text('Confirm swap'), findsNothing);
    expect(find.text('Quote expired · nothing was sent'), findsOneWidget);
    await tester.tap(find.text('Get a new quote'));
    expect(requotes, 1);
  });

  testWidgets('a quote already past its margin never shows a confirm button',
      (tester) async {
    await tester.pumpWidget(card(ValueNotifier(1), confirm: () async {
      fail('must not sign an expired quote');
    },
        cancel: () {},
        data: _swap(expiry: DateTime.now().add(const Duration(seconds: 30))),
        label: 'Confirm swap'));
    expect(find.text('Confirm swap'), findsNothing);
    expect(find.text('Quote expired · nothing was sent'), findsOneWidget);
  });
}
