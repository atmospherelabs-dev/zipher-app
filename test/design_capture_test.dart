import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zipher/pages/accounts/restore.dart';
import 'package:zipher/pages/action/widgets/wallet_activity_panel.dart';
import 'package:zipher/pages/more/about.dart';
import 'package:zipher/pages/welcome.dart';
import 'package:zipher/pages/action/widgets/wallet_review_card.dart';
import 'package:zipher/pages/action/widgets/z_chat_widgets.dart';
import 'package:zipher/pages/hitl/hitl_agent.dart';
import 'package:zipher/pages/utils.dart';
import 'package:zipher/services/hitl_watch_service.dart';
import 'package:zipher/services/near_intents.dart';
import 'package:zipher/services/wallet_swap_tracker.dart';
import 'package:zipher/zipher_theme.dart';

/// Phone-size renders of the redesigned surfaces with synthetic data. They
/// always check for layout errors; with ZIPHER_DESIGN_CAPTURE=<dir> they also
/// load the macOS system fonts (what iOS shows) and write PNGs there.
void main() {
  final capture = Platform.environment['ZIPHER_DESIGN_CAPTURE'];

  setUp(() {
    // Onboarding screens touch plugins that have no native side in tests.
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('screen_protector'), (_) async => null);
  });

  Future<void> loadFonts(WidgetTester tester) async {
    if (capture == null) return;
    await tester.runAsync(() async {
      Future<ByteData> f(String path) =>
          File(path).readAsBytes().then((b) => ByteData.sublistView(b));
      for (final family in [
        'Roboto',
        'Inter',
        '.SF UI Text',
        '.SF UI Display'
      ]) {
        await (FontLoader(family)..addFont(f('/System/Library/Fonts/SFNS.ttf')))
            .load();
      }
      for (final family in ['JetBrainsMono', 'JetBrains Mono']) {
        await (FontLoader(family)
              ..addFont(f('/System/Library/Fonts/SFNSMono.ttf')))
            .load();
      }
      await (FontLoader('MaterialIcons')
            ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf')))
          .load();
    });
  }

  Future<void> shoot(WidgetTester tester, String name, Widget page,
      {List<String> images = const [],
      Future<void> Function()? act}) async {
    tester.view.physicalSize = const Size(393, 852);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await loadFonts(tester);
    final boundary = GlobalKey();
    await tester.pumpWidget(RepaintBoundary(
      key: boundary,
      child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ZipherTheme.dark,
          home: MediaQuery(
              data: const MediaQueryData(
                  size: Size(393, 852),
                  padding: EdgeInsets.only(top: 59, bottom: 34)),
              child: page)),
    ));
    if (capture != null) {
      await tester.runAsync(() async {
        final context = tester.element(find.byType(MaterialApp));
        for (final asset in images) {
          await precacheImage(AssetImage(asset), context);
        }
      });
    }
    await tester.pump(const Duration(milliseconds: 600));
    // Pinned review actions arrive one frame after the review builds.
    await tester.pump(const Duration(milliseconds: 300));
    if (act != null) {
      await act();
      await tester.pump(const Duration(milliseconds: 400));
    }
    // Plugins without a native side in tests (screen protection, secure
    // storage) report MissingPluginException; anything else is a real failure.
    Object? error;
    while ((error = tester.takeException()) != null) {
      expect(error, isA<MissingPluginException>(), reason: name);
    }
    if (capture != null) {
      await tester.runAsync(() async {
        final render = boundary.currentContext!.findRenderObject()
            as RenderRepaintBoundary;
        final image = await render.toImage(pixelRatio: 3);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('$capture/$name.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }
  }

  final today = DateTime.now();
  Tx tx(String id, int height, double value, DateTime at,
          {String? kind, double? fee, String? memo}) =>
      Tx.from(100, 0, height, at, id, id, value, null, null, memo, [],
          kind: kind ?? (value > 0 ? 'received' : 'sent'), fee: fee);

  WalletSwapActivity swap(String deposit, String status, DateTime at,
          {String to = 'USDC', String chain = 'sol', String? txId}) =>
      WalletSwapActivity(StoredSwap(
          provider: 'near_intents',
          depositAddress: deposit,
          timestamp: at.millisecondsSinceEpoch ~/ 1000,
          fromCurrency: 'ZEC',
          fromAmount: '1.5',
          toCurrency: to,
          toAmount: '1185.82',
          toAddress: 'recipient',
          toBlockchain: chain,
          txId: txId))
        ..status = NearSwapStatus(status: status, raw: const {});

  testWidgets('activity with items', (tester) async {
    final transactions = [
      tx('a', 0, .25, today.subtract(const Duration(minutes: 3))),
      tx('b', 99, -.0101, today.subtract(const Duration(hours: 2)),
          fee: .0001, memo: 'Thanks for lunch'),
      tx('c', 99, 1.2, today.subtract(const Duration(hours: 5))),
      tx('d', 99, -.0001, today.subtract(const Duration(days: 1, hours: 1)),
          kind: 'shield', fee: .0001),
      tx('e', 99, 3.5, today.subtract(const Duration(days: 1, hours: 4))),
      tx('f', 99, -.5001, today.subtract(const Duration(days: 9)), fee: .0001),
      tx('g', 99, .042, today.subtract(const Duration(days: 12))),
    ];
    await shoot(
        tester,
        'activity',
        Scaffold(
            backgroundColor: ZipherColors.bg,
            body: Padding(
                padding: const EdgeInsets.only(top: 59),
                child: WalletActivityPanel(
                    chat: const SizedBox(),
                    selectedTab: WalletHomeTab.activity,
                    onTabChanged: (_) {},
                    transactions: transactions,
                    swaps: [
                      swap('live', 'PROCESSING',
                          today.subtract(const Duration(minutes: 1)),
                          txId: 'x'),
                      swap('done', 'SUCCESS',
                          today.subtract(const Duration(days: 1, hours: 2)),
                          to: 'ETH', chain: 'base'),
                    ],
                    onTransaction: (_) {},
                    onSwap: (_) {}))),
        images: [
          'assets/tokens/usdc.png',
          'assets/chains/sol.png',
          'assets/chains/base.png',
        ]);
  });

  testWidgets('swap recap', (tester) async {
    const review = ReviewData(
        zatoshis: 150000000,
        fee: 15000,
        recipient: 'GbGAFmHmMJmqT6pZ1cQy6dS1wqK5v2ZcEmWGDRoNabcd',
        recipientNote: 'Your wallet',
        zecUsd: 790.55,
        swap: SwapReview(
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
    final actions = ReviewActionHost();
    await shoot(
        tester,
        'swap-recap',
        Scaffold(
            backgroundColor: ZipherColors.bg,
            body: Column(children: [
              Expanded(
                  child: ListView(
                      padding: const EdgeInsets.fromLTRB(16, 67, 16, 8),
                      children: [
                    const ZChatMessage(
                        text: 'swap 1.5 zec to usdc on solana', isUser: true),
                    const ZChatMessage(
                        text: 'GbGAFmHmMJmqT6pZ1cQy6dS1wqK5v2ZcEmWGDRoNabcd',
                        isUser: true),
                    ZChatMessage(
                        text: '',
                        card: ZChatCard(
                            child: WalletReviewCard(
                                epoch: ValueNotifier(1),
                                expectedEpoch: 1,
                                data: review,
                                confirmLabel: 'Confirm swap',
                                actions: actions,
                                onConfirm: () async {},
                                onCancel: () {},
                                onPriorityChanged: (_) async => 15000))),
                  ])),
              ReviewActionBar(host: actions),
              ZChatComposer(
                  controller: TextEditingController(),
                  busy: false,
                  onSubmit: (_) {},
                  onScan: () {},
                  hint: 'Change the amount, token or address'),
              const SizedBox(height: 34),
            ])),
        images: [
          'assets/tokens/zec.png',
          'assets/tokens/usdc.png',
          'assets/chains/sol.png',
        ]);
    expect(find.text('Confirm swap').hitTestable(), findsOneWidget);
  });

  testWidgets('agent screen', (tester) async {
    HitlWatchService.instance.debugSetPaired('Claude on MacBook Pro');
    await shoot(tester, 'agent', const HitlAgentPage());
  });

  testWidgets('onboarding: welcome', (tester) async {
    await shoot(tester, 'onboarding-welcome', WelcomePage(),
        images: ['assets/zipher_logo.png']);
  });

  testWidgets('onboarding: one-tap understanding', (tester) async {
    await shoot(tester, 'onboarding-understand',
        DisclaimerPage(mode: 'create'));
    expect(find.text('I understand'), findsOneWidget);
  });

  testWidgets('onboarding: restore phrase', (tester) async {
    await shoot(tester, 'onboarding-restore', RestoreAccountPage());
    // The date question is its own step, not hidden below the words.
    expect(find.text('Continue'), findsOneWidget);
    expect(find.text('Not sure'), findsNothing);
  });

  testWidgets('onboarding: restore start date', (tester) async {
    await shoot(tester, 'onboarding-restore-date',
        RestoreAccountPage(initialStep: 1), act: () async {
      Future<void> settle() => tester.pump(const Duration(milliseconds: 400));
      await settle();
      await tester.ensureVisible(find.text('2025'));
      await settle();
      await tester.tap(find.text('2025'));
      await settle();
      await tester.ensureVisible(find.text('Mar'));
      await settle();
      await tester.tap(find.text('Mar'));
      await settle();
    });
    expect(find.text('When did you start using it?'), findsOneWidget);
    expect(find.textContaining('Starts from February 2025'), findsOneWidget);
    expect(find.text('Restore'), findsOneWidget);
  });
}
