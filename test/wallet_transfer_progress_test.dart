import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zipher/pages/action/wallet_amounts.dart';
import 'package:zipher/pages/action/wallet_transfer_progress.dart';
import 'package:zipher/pages/action/widgets/wallet_transfer_status_card.dart';
import 'package:zipher/zipher_theme.dart';

TransferProgress _send(TransferBroadcast broadcast,
        {bool mined = false,
        bool expired = false,
        bool resubmits = true,
        String? reason}) =>
    TransferProgress(
        zatoshis: 50000000,
        broadcast: broadcast,
        mined: mined,
        expired: expired,
        resubmits: resubmits,
        reason: reason);

TransferProgress _swap(TransferBroadcast broadcast,
        {String? status, bool mined = false, bool expired = false}) =>
    TransferProgress(
        zatoshis: 150000000,
        broadcast: broadcast,
        mined: mined,
        expired: expired,
        swapSymbol: 'USDC',
        swapNetwork: 'Solana',
        swapStatus: status);

List<TransferStepState> _states(TransferProgress p) =>
    [for (final step in p.steps) step.state];

void main() {
  const done = TransferStepState.done;
  const active = TransferStepState.active;
  const pending = TransferStepState.pending;
  const failed = TransferStepState.failed;

  test('a failure before signing says nothing was sent and reserves nothing',
      () {
    final p = _send(TransferBroadcast.notSent,
        reason: 'The wallet was busy with another task.');
    expect(p.title, 'Not sent');
    expect(p.badge, 'Nothing sent');
    expect(p.steps, isEmpty);
    expect(p.notice, contains('The wallet was busy'));
    expect(p.notice, contains('no funds are reserved'));
    expect(p.finished, isTrue);
  });

  test('an accepted send waits for a block, then completes', () {
    final waiting = _send(TransferBroadcast.accepted);
    expect(waiting.title, 'Sending 0.5 ZEC');
    expect(_states(waiting), [done, done, active]);
    expect(waiting.notice, isNull);
    expect(waiting.tone, TransferTone.progress);
    final mined = _send(TransferBroadcast.accepted, mined: true);
    expect(mined.title, 'Sent 0.5 ZEC');
    expect(_states(mined), [done, done, done]);
    expect(mined.tone, TransferTone.success);
  });

  test('an unanswered broadcast is never reported as failed or as sent', () {
    final p = _send(TransferBroadcast.unreachable);
    expect(_states(p), [done, active, pending]);
    expect(p.tone, TransferTone.warning);
    expect(p.badge, 'Retrying');
    expect(p.notice, contains('keeps submitting it'));
    expect(p.notice, contains('Don’t send it again.'));
    expect(p.finished, isFalse);
    final unsaved = _send(TransferBroadcast.unreachable, resubmits: false);
    expect(unsaved.notice, contains('Check Activity before sending again'));
    expect(unsaved.badge, 'Unconfirmed');
  });

  test('a refusal says nothing was paid and when the funds come back', () {
    final p = _send(TransferBroadcast.rejected);
    expect(_states(p), [done, failed, pending]);
    expect(p.steps[1].title, 'Refused by the Zcash network');
    expect(p.badge, 'Refused');
    expect(p.notice, contains('nothing was paid'));
    expect(p.notice, contains('until the transaction expires'));
  });

  test('a later block proves an unanswered or refused broadcast arrived', () {
    for (final broadcast in [
      TransferBroadcast.unreachable,
      TransferBroadcast.rejected
    ]) {
      final p = _send(broadcast, mined: true);
      expect(_states(p), [done, done, done]);
      expect(p.notice, isNull);
      expect(p.tone, TransferTone.success);
    }
  });

  test('expiry without a block returns the funds and ends the transfer', () {
    final p = _send(TransferBroadcast.unreachable, expired: true);
    expect(p.title, 'Transaction expired');
    expect(p.steps[1].title, 'Never reached the Zcash network');
    expect(p.notice, contains('back in your balance'));
    expect(p.finished, isTrue);
    expect(_swap(TransferBroadcast.rejected, expired: true).title,
        'Swap not started');
  });

  test('swap steps follow the provider status one stage at a time', () {
    expect(_states(_swap(TransferBroadcast.signing)),
        [active, pending, pending, pending]);
    expect(
        _states(_swap(TransferBroadcast.accepted, status: 'PENDING_DEPOSIT')),
        [done, done, active, pending]);
    expect(
        _states(_swap(TransferBroadcast.accepted, status: 'KNOWN_DEPOSIT_TX')),
        [done, done, done, active]);
    final complete = _swap(TransferBroadcast.accepted, status: 'SUCCESS');
    expect(_states(complete), [done, done, done, done]);
    expect(complete.title, 'Swap complete');
    expect(complete.steps.last.title, 'USDC delivered on Solana');
    expect(complete.finished, isTrue);
  });

  test('provider progress proves the deposit arrived despite a lost reply', () {
    final p = _swap(TransferBroadcast.unreachable, status: 'PROCESSING');
    expect(_states(p), [done, done, done, active]);
    expect(p.notice, isNull);
  });

  test('refunds and failures are stated plainly', () {
    final refunded = _swap(TransferBroadcast.accepted, status: 'REFUNDED');
    expect(refunded.title, 'Swap refunded');
    expect(refunded.badge, 'Refunded');
    expect(refunded.steps.last.title, 'ZEC refunded to your wallet');
    expect(refunded.notice, contains('refunded'));
    final failedSwap = _swap(TransferBroadcast.accepted, status: 'FAILED');
    expect(failedSwap.title, 'Swap needs attention');
    expect(_states(failedSwap).last, failed);
    expect(
        _swap(TransferBroadcast.accepted, status: 'INCOMPLETE_DEPOSIT').notice,
        contains('below the quoted amount'));
  });

  test('an unknown provider status is not presented as progress or failure',
      () {
    final p = _swap(TransferBroadcast.accepted, status: 'SOMETHING_NEW');
    expect(_states(p), [done, done, active, pending]);
    expect(p.notice, isNull);
    expect(p.finished, isFalse);
  });

  testWidgets('status card shows the steps, notice and only offered actions',
      (tester) async {
    var retried = 0;
    await tester.pumpWidget(MaterialApp(
        theme: ZipherTheme.dark,
        home: Scaffold(
            body: SingleChildScrollView(
                child: WalletTransferStatusCard(
                    progress: _send(TransferBroadcast.notSent),
                    onRetry: () => retried++,
                    retryLabel: 'Review again')))));
    expect(find.text('Not sent'), findsOneWidget);
    expect(find.text('Nothing sent'), findsOneWidget);
    expect(find.textContaining('no funds are reserved'), findsOneWidget);
    await tester.tap(find.text('Review again'));
    expect(retried, 1);

    await tester.pumpWidget(MaterialApp(
        theme: ZipherTheme.dark,
        home: Scaffold(
            body: SingleChildScrollView(
                child: WalletTransferStatusCard(
                    progress:
                        _swap(TransferBroadcast.unreachable, status: null),
                    swapChain: 'sol',
                    transactionId: 'ab' * 32,
                    onCopyId: () {},
                    onDetails: () {},
                    detailsLabel: 'Swap details')))));
    expect(find.text('Swapping 1.5 ZEC to USDC'), findsOneWidget);
    expect(find.text('Retrying'), findsOneWidget);
    expect(find.text('Sending to the Zcash network'), findsOneWidget);
    expect(find.text('Swap details'), findsOneWidget);
    expect(find.text('ID ababab…abab'), findsOneWidget);
    expect(find.text('Review again'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  group('display amounts', () {
    test('token amounts truncate, group and never round a minimum up', () {
      expect(WalletAmounts.token(BigInt.from(1185821115), 6), '1,185.82');
      expect(WalletAmounts.token(BigInt.from(1173962903), 6), '1,173.96');
      expect(WalletAmounts.token(BigInt.from(1999999), 6), '1.9999');
      expect(WalletAmounts.token(BigInt.from(12000), 8), '0.00012');
      expect(WalletAmounts.token(BigInt.from(100000000), 8), '1');
      expect(WalletAmounts.token(BigInt.zero, 6), '0');
      expect(WalletAmounts.token(BigInt.one, 18), '<0.00000001');
      expect(WalletAmounts.token(BigInt.from(1234567), 0), '1,234,567');
    });
    test('rate is the quoted output for exactly one ZEC', () {
      expect(
          WalletAmounts.rate(
              zatoshis: 150000000,
              amountOut: BigInt.from(1185821115),
              decimals: 6,
              symbol: 'USDC'),
          '1 ZEC ≈ 790.5474 USDC');
      expect(
          WalletAmounts.rate(
              zatoshis: 0, amountOut: BigInt.one, decimals: 6, symbol: 'USDC'),
          isNull);
    });
    test('addresses and durations stay readable', () {
      expect(WalletAmounts.shortAddress('short'), 'short');
      expect(WalletAmounts.shortAddress('a' * 20 + 'b' * 20),
          '${'a' * 8}…${'b' * 8}');
      expect(
          WalletAmounts.duration(const Duration(seconds: 45)), 'about 45 sec');
      expect(WalletAmounts.duration(const Duration(minutes: 5)), 'about 5 min');
      expect(WalletAmounts.dollars(1185.8), r'$1,185.80');
    });
  });
}
