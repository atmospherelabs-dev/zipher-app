import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zipher/pages/action/wallet_transfer_progress.dart';
import 'package:zipher/pages/action/widgets/wallet_review_card.dart';
import 'package:zipher/pages/action/widgets/wallet_transfer_status_card.dart';
import 'package:zipher/pages/action/widgets/z_chat_widgets.dart';
import 'package:zipher/zipher_theme.dart';

/// Phone-width layout checks for the cards as they sit in the conversation.
/// With `--dart-define=CHAT_SCREENSHOT=true` each case also writes a PNG to
/// `build/` using synthetic amounts and addresses.
void main() {
  const screenshots = bool.fromEnvironment('CHAT_SCREENSHOT');
  const recipient = 'GbGAFmHmMJmqT6pZ1cQy6dS1wqK5v2ZcEmWGDRoNabcd';
  final swap = ReviewData(
      zatoshis: 150000000,
      fee: 15000,
      recipient: recipient,
      recipientNote: 'Your wallet',
      zecUsd: 790.55,
      swap: const SwapReview(
          symbol: 'USDC',
          chain: 'sol',
          network: 'Solana',
          estimated: '1,185.82',
          minimum: '1,173.96',
          rate: '1 ZEC ≈ 790.5474 USDC',
          usd: 1185.8,
          eta: Duration(minutes: 2),
          depositAddress: 't1SyntheticDepositAddress',
          refundAddress: 't1SyntheticRefundAddress'));
  const send = ReviewData(
      zatoshis: 50000000,
      fee: 10000,
      recipient:
          'u1syntheticaddressaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      memo: 'Thanks for lunch',
      zecUsd: 790.55);

  Widget boxed(Widget child) => Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
          color: ZipherColors.cardBg,
          borderRadius: BorderRadius.circular(ZipherRadius.lg),
          border: Border.all(color: ZipherColors.borderSubtle)),
      child: child);

  Widget review(ReviewData data, String label,
          {ReviewPhase? phase, bool priority = true}) =>
      WalletReviewCard(
          epoch: ValueNotifier(1),
          expectedEpoch: 1,
          data: data,
          confirmLabel: label,
          phase: phase == null ? null : ValueNotifier(phase),
          onConfirm: () async {},
          onCancel: () {},
          onPriorityChanged: priority ? (_) async => data.fee : null);

  Widget status(TransferProgress progress, {bool swap = true}) =>
      WalletTransferStatusCard(
          progress: progress,
          swapChain: swap ? 'sol' : null,
          transactionId: progress.broadcast == TransferBroadcast.notSent
              ? null
              : 'ab' * 32,
          onCopyId: () {},
          onDetails: () {},
          detailsLabel: swap ? 'Swap details' : 'Transaction details',
          onRetry:
              progress.broadcast == TransferBroadcast.notSent ? () {} : null,
          retryLabel: 'Get a new quote');

  TransferProgress swapProgress(TransferBroadcast broadcast,
          {String? status}) =>
      TransferProgress(
          zatoshis: 150000000,
          broadcast: broadcast,
          swapSymbol: 'USDC',
          swapNetwork: 'Solana',
          swapStatus: status);

  Future<void> render(WidgetTester tester, String name, List<Widget> messages,
      {double height = 844}) async {
    tester.view.physicalSize = Size(390, height);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    if (screenshots) {
      await tester.runAsync(() async {
        final root = Platform.environment['FLUTTER_ROOT']!;
        for (final family in ['Roboto', 'Inter', 'JetBrains Mono']) {
          final loader = FontLoader(family)
            ..addFont(File(
                    '$root/bin/cache/artifacts/material_fonts/Roboto-Regular.ttf')
                .readAsBytes()
                .then((b) => ByteData.sublistView(b)));
          await loader.load();
        }
        final icons = FontLoader('MaterialIcons')
          ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
        await icons.load();
      });
    }
    await tester.pumpWidget(MaterialApp(
        theme: ZipherTheme.dark,
        home: RepaintBoundary(
            key: const ValueKey('preview'),
            child: Scaffold(
                backgroundColor: ZipherColors.bg,
                body: SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 12),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: messages))))));
    if (screenshots) {
      await tester.runAsync(() async {
        final context = tester.element(find.byType(Scaffold));
        for (final asset in [
          'assets/tokens/zec.png',
          'assets/tokens/usdc.png',
          'assets/chains/sol.png'
        ]) {
          await precacheImage(AssetImage(asset), context);
        }
      });
    }
    await tester.pump();
    expect(tester.takeException(), isNull, reason: name);
    if (!screenshots) return;
    final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const ValueKey('preview')));
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 2);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await File('build/$name.png').writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  testWidgets('swap review fits a phone without overflow', (tester) async {
    await render(tester, 'chat-swap-review-preview', [
      const ZChatMessage(text: 'swap 1.5 zec to usdc on solana', isUser: true),
      const ZChatMessage(text: recipient, isUser: true),
      ZChatMessage(text: '', card: boxed(review(swap, 'Confirm swap'))),
    ]);
    expect(find.text('Confirm swap').hitTestable(), findsOneWidget);
  });

  testWidgets('send review with a memo fits a phone', (tester) async {
    await render(tester, 'chat-send-review-preview', [
      const ZChatMessage(text: 'send 0.5 zec', isUser: true),
      ZChatMessage(text: '', card: boxed(review(send, 'Send ZEC'))),
    ]);
    expect(find.text('Thanks for lunch'), findsOneWidget);
  });

  testWidgets('a submitted swap shows its approval and live progress',
      (tester) async {
    await render(tester, 'chat-swap-progress-preview', [
      ZChatMessage(
          text: '',
          card: boxed(review(swap, 'Confirm swap', phase: ReviewPhase.sent))),
      ZChatMessage(
          text: '',
          card: boxed(status(swapProgress(TransferBroadcast.accepted,
              status: 'KNOWN_DEPOSIT_TX')))),
      ZChatMessage(
          text: '',
          card: boxed(status(
              swapProgress(TransferBroadcast.accepted, status: 'SUCCESS')))),
      const ZChatMessage(
          text: 'Swap complete. Your USDC was delivered on Solana.'),
    ]);
    expect(find.text('Approved and submitted'), findsOneWidget);
    expect(find.text('Swap complete'), findsOneWidget);
  });

  testWidgets('unconfirmed, refused and unsent outcomes are told apart',
      (tester) async {
    await render(
        tester,
        'chat-swap-problems-preview',
        [
          ZChatMessage(
              text: '',
              card: boxed(status(swapProgress(TransferBroadcast.unreachable)))),
          ZChatMessage(
              text: '',
              card: boxed(status(swapProgress(TransferBroadcast.rejected)))),
          ZChatMessage(
              text: '',
              card: boxed(status(const TransferProgress(
                  zatoshis: 150000000,
                  broadcast: TransferBroadcast.notSent,
                  swapSymbol: 'USDC',
                  swapNetwork: 'Solana',
                  reason: 'The review went out of date before signing.')))),
        ],
        height: 1100);
    expect(find.text('Retrying'), findsOneWidget);
    expect(find.text('Refused'), findsOneWidget);
    expect(find.text('Refused by the Zcash network'), findsOneWidget);
    expect(find.text('Nothing sent'), findsOneWidget);
  });
}
