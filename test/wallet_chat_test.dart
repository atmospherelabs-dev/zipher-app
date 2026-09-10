import 'dart:io';
import 'package:go_router/go_router.dart';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:zipher/zipher_theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zipher/accounts.dart';
import 'package:zipher/coin/coins.dart';
import 'package:zipher/appsettings.dart';
import 'package:zipher/generated/intl/messages.dart';
import 'package:zipher/pages/action/wallet_chat.dart';
import 'package:zipher/pages/action/widgets/z_chat_widgets.dart';
import 'package:zipher/pages/utils.dart';
import 'package:zipher/store2.dart';
import 'package:zipher/services/evm_portfolio_balance.dart';
import 'package:zipher/services/chain_config.dart';
import 'package:zipher/services/network_privacy.dart';
import 'package:zipher/src/rust/api/engine_api.dart';
import 'package:zipher/router.dart' as app_router;

void main() {
  testWidgets('privacy icon opens an opaque sheet with scoped Tor controls',
      (tester) async {
    final privacy = NetworkPrivacy(
        enable: () async {},
        disable: () async {},
        verify: () async => 3477900,
        savePreference: (_) async {});
    await tester.pumpWidget(MaterialApp(
        theme: ZipherTheme.dark,
        localizationsDelegates: const [S.delegate],
        home: WalletChatPage(privacy: privacy)));
    await tester.pump();
    await tester.tap(find.byTooltip('Direct connection'));
    await tester.pumpAndSettle();
    expect(find.text('Enable Tor'), findsOneWidget);
    expect(find.text('External VPN / Nym: not verified by Zipher.'),
        findsOneWidget);
    expect(tester.widget<BottomSheet>(find.byType(BottomSheet)).backgroundColor,
        ZipherColors.surface);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    privacy.dispose();
  });

  setUp(() {
    appSettings.defaults();
    marketPrice.price = 40;
    aa = ActiveAccount2(
        coin: 0, id: 1, name: 'Test wallet', address: '', canPay: false);
    aa.poolBalances = PoolBalance(
        sapling: 50000000,
        totalSapling: 75000000,
        unconfirmedSapling: 25000000);
    aa.diversifiedAddress = 'u1${'a' * 100}';
    syncStatus2.connected = true;
  });
  tearDown(() {
    syncTimer?.cancel();
    syncTimer = null;
    aa = nullAccount;
  });
  Future<void> open(WidgetTester tester, {EvmBalanceReader? reader}) async {
    if (const bool.fromEnvironment('CHAT_SCREENSHOT')) {
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
      localizationsDelegates: const [S.delegate],
      home: RepaintBoundary(
          key: const ValueKey('chat-preview'),
          child: WalletChatPage(balanceReader: reader)),
    ));
    if (const bool.fromEnvironment('CHAT_SCREENSHOT')) {
      await tester.runAsync(() async {
        final context = tester.element(find.byType(WalletChatPage));
        for (final asset in [
          'assets/tokens/zec.png',
          ...['btc', 'sol', 'bsc', 'pol', 'eth', 'arb', 'base', 'op']
              .map((id) => 'assets/chains/$id.png')
        ]) {
          await precacheImage(AssetImage(asset), context);
        }
      });
    }
    await tester.pumpAndSettle();
  }

  Future<void> preview(WidgetTester tester, String name) async {
    if (!const bool.fromEnvironment('CHAT_SCREENSHOT')) return;
    final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const ValueKey('chat-preview')));
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 2);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await File('build/$name.png').writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  testWidgets('home shows balance and keeps send prompts inside chat',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await open(tester);
    if (const bool.fromEnvironment('CHAT_SCREENSHOT')) {
      final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(const ValueKey('chat-preview')));
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 2);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('build/chat-preview.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }
    expect(find.text('0.75 ZEC'), findsNothing);
    expect(find.byIcon(Icons.expand_more), findsOneWidget);
    expect(find.byType(ZChatComposer), findsOneWidget);
    await tester.tap(find.bySemanticsLabel(RegExp('Expand balance details')));
    await tester.pumpAndSettle();
    expect(find.text('0.75 ZEC'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel(RegExp('Collapse balance details')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ZChatShortcut, 'Send'));
    await tester.pumpAndSettle();
    expect(
        find.textContaining('Who would you like to send to?'), findsOneWidget);
    await tester.enterText(find.byType(TextField), aa.diversifiedAddress);
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pumpAndSettle();
    expect(find.text('How much ZEC would you like to send?'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '-1');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pumpAndSettle();
    expect(find.textContaining('You can also type cancel.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
      'account control and long-press pool breakdown are available on Home',
      (tester) async {
    await open(tester);
    expect(find.text('Test wallet'), findsOneWidget);
    expect(find.byTooltip('ZEC fully shielded'), findsOneWidget);
    await tester
        .longPress(find.bySemanticsLabel(RegExp('Expand balance details')));
    await tester.pumpAndSettle();
    expect(find.text('Where your ZEC is'), findsOneWidget);
    final sheet = tester.widget<BottomSheet>(find.byType(BottomSheet));
    expect(sheet.backgroundColor, ZipherColors.surface);
    expect(sheet.backgroundColor!.a, 1);
    for (final pool in ['Ironwood', 'Orchard', 'Sapling', 'Transparent']) {
      expect(find.text(pool), findsOneWidget);
    }
    expect(find.text('0.5 ZEC spendable shielded'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('receive shows QR address without preparing a transaction',
      (tester) async {
    await open(tester);
    await tester.tap(find.widgetWithText(ZChatShortcut, 'Receive'));
    await tester.pumpAndSettle();
    expect(
        find.text('Which chain would you like to receive on?'), findsOneWidget);
    await tester.tap(find.widgetWithText(ZChatShortcut, 'Zcash'));
    await tester.pumpAndSettle();
    expect(find.text('Copy address'), findsOneWidget);
    expect(find.text(aa.diversifiedAddress), findsOneWidget);
    expect(tester.takeException(), isNull);
    syncTimer?.cancel();
  });
  testWidgets('home adapts to phone width and open keyboard', (tester) async {
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1;
    tester.view.viewInsets = const FakeViewPadding(bottom: 280);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    await open(tester);
    expect(tester.takeException(), isNull);
    expect(find.byType(TextField), findsOneWidget);
  });
  testWidgets('dollar balance reveals assets without a balance chevron',
      (tester) async {
    await open(tester);
    marketPrice.price = 40;
    await tester.pumpAndSettle();
    expect(find.text(r'$30.00'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel(RegExp('Expand balance details')));
    await tester.pumpAndSettle();
    expect(find.text('0.75 ZEC'), findsOneWidget);
    expect(find.text('View pool breakdown'), findsNothing);
    expect(find.byIcon(Icons.expand_less), findsNothing);
    marketPrice.price = null;
    await tester.pumpAndSettle();
    expect(find.text(r'$30.00'), findsNothing);
    expect(find.text('0.75 ZEC'), findsOneWidget);
  });

  testWidgets('recent actions and expanded balance leave room for the keyboard',
      (tester) async {
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    aa.txs.items = [
      Tx.from(
          100, 1, 99, DateTime.now(), 'test', 'test', .25, null, null, null, [])
    ];
    await open(tester);
    await tester.tap(find.text('Activity'));
    await tester.tap(find.bySemanticsLabel(RegExp('Expand balance details')));
    await tester.pumpAndSettle();
    expect(find.text('Confirmed'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    await tester.tap(find.text('Chat'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'send .5');
    tester.view.viewInsets = const FakeViewPadding(bottom: 280);
    await tester.pumpAndSettle();
    expect(find.text('Activity'), findsNothing);
    expect(find.text('0.50000000 ZEC spendable'), findsNothing);
    expect(find.text('send .5'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'address question offers chains and copies the selected Bitcoin address',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    aa.chainAddresses = EngineMultiChainAddresses(
        evm: '0x${'1' * 40}', solana: 'solana fixture', bitcoin: 'bc1qfixture');
    await open(tester,
        reader: EvmBalanceReader(
            readPrices: () async => {}, readAsset: (_, __, ___) async => 0));
    String? copied;
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData')
        copied = (call.arguments as Map)['text'] as String;
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
    await tester.enterText(find.byType(TextField), 'what is my address?');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pumpAndSettle();
    await preview(tester, 'chat-addresses-preview');
    await tester.tap(find.widgetWithText(ZChatShortcut, 'Bitcoin'));
    await tester.pumpAndSettle();
    expect(find.text('bc1qfixture'), findsOneWidget);
    expect(find.textContaining('Bitcoin mainnet'), findsWidgets);
    await tester.tap(find.text('Copy address'));
    await tester.pumpAndSettle();
    await preview(tester, 'chat-copy-preview');
    expect(copied, 'bc1qfixture');
    expect(find.text('Bitcoin address copied.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('dollar total includes Zcash and valued assets across chains',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    aa.chainAddresses = EngineMultiChainAddresses(
        evm: '0x${'1' * 40}', solana: '', bitcoin: '');
    await open(tester,
        reader: EvmBalanceReader(
            readPrices: () async => {'ETH': 2000},
            readAsset: (chain, _, token) async =>
                chain == ChainConfig.ethereum && token == null ? 1 : 0));
    marketPrice.price = 40;
    await tester.pumpAndSettle();
    expect(find.text(r'$2,030.00'), findsOneWidget);
    expect(find.text('0.75 ZEC'), findsNothing);
    await tester.tap(find.bySemanticsLabel(RegExp('Expand balance details')));
    await tester.pumpAndSettle();
    expect(find.text('1 ETH'), findsOneWidget);
    await preview(tester, 'chat-balances-preview');
    expect(tester.takeException(), isNull);
  });

  testWidgets('balance response updates in place after refresh',
      (tester) async {
    aa.chainAddresses = EngineMultiChainAddresses(
        evm: '0x${'1' * 40}', solana: '', bitcoin: '');
    var amount = 1.0;
    await open(tester,
        reader: EvmBalanceReader(
            readPrices: () async => {'ETH': 2000},
            readAsset: (chain, _, token) async =>
                chain == ChainConfig.ethereum && token == null ? amount : 0));
    await tester.tap(find.widgetWithText(ZChatShortcut, 'Balance'));
    await tester.pumpAndSettle();
    expect(find.text('1 ETH'), findsOneWidget);
    amount = 2;
    await tester.ensureVisible(find.text('Refresh balances'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Refresh balances'));
    await tester.pumpAndSettle();
    expect(find.text('2 ETH'), findsOneWidget);
    expect(find.text('1 ETH'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'portfolio dollars never mix a non-USD Zcash quote with USD assets',
      (tester) async {
    appSettings.currency = 'EUR';
    aa.chainAddresses = EngineMultiChainAddresses(
        evm: '0x${'1' * 40}', solana: '', bitcoin: '');
    await open(tester,
        reader: EvmBalanceReader(
            readPrices: () async => {'ETH': 2000, 'ZEC': 40},
            readAsset: (chain, _, token) async =>
                chain == ChainConfig.ethereum && token == null ? 1 : 0));
    marketPrice.price = 100;
    await tester.pumpAndSettle();
    expect(find.text(r'$2,030.00'), findsOneWidget);
    expect(find.text(r'$2,075.00'), findsNothing);
  });

  testWidgets('recent transaction opens the correct detail after sorting',
      (tester) async {
    aa.txs.items = [
      Tx.from(100, 1, 90, DateTime(2026, 1, 1), 'old', 'old', .1, null, null,
          null, []),
      Tx.from(100, 2, 99, DateTime(2026, 9, 1), 'new', 'new', .2, null, null,
          null, []),
    ];
    final router = GoRouter(routes: [
      GoRoute(path: '/', builder: (_, __) => const WalletChatPage()),
      GoRoute(
          path: '/more/history/details',
          builder: (_, state) => Scaffold(
              body: Text('Detail ${state.uri.queryParameters['index']}'))),
    ]);
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(
        routerConfig: router,
        theme: ZipherTheme.dark,
        localizationsDelegates: const [S.delegate]));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Activity'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('+0.2 ZEC'));
    await tester.pumpAndSettle();
    expect(find.text('Detail 1'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('swap tab is removed and its old route starts the chat flow',
      (tester) async {
    app_router.router.go('/account');
    await tester.pumpWidget(MaterialApp.router(
        theme: ZipherTheme.dark,
        localizationsDelegates: const [S.delegate],
        routerConfig: app_router.router));
    await tester.pumpAndSettle();
    expect(find.text('Home'), findsOneWidget);
    expect(find.text('More'), findsOneWidget);
    expect(find.text('Swap'), findsOneWidget); // chat shortcut only
    app_router.router.go('/swap');
    await tester.pumpAndSettle();
    expect(app_router.router.routerDelegate.currentConfiguration.uri.path,
        '/account');
    expect(find.text('How much ZEC would you like to swap?'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Z route opens the same home conversation', (tester) async {
    app_router.router.go('/ask');
    await tester.pumpWidget(MaterialApp.router(
      theme: ZipherTheme.dark,
      localizationsDelegates: const [S.delegate],
      routerConfig: app_router.router,
    ));
    await tester.pumpAndSettle();
    expect(find.byType(WalletChatPage), findsOneWidget);
    expect(app_router.router.routerDelegate.currentConfiguration.uri.path,
        '/account');
    expect(find.text('What would you like to do?'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('legacy submission routes cannot report a fake payment',
      (tester) async {
    app_router.router.go('/account/submit_tx', extra: 'obsolete-plan');
    await tester.pumpWidget(MaterialApp.router(
      theme: ZipherTheme.dark,
      localizationsDelegates: const [S.delegate],
      routerConfig: app_router.router,
    ));
    await tester.pumpAndSettle();
    expect(
        find.textContaining('No wallet action was performed'), findsOneWidget);
    expect(find.text('Transaction Sent'), findsNothing);
    app_router.router.go('/account/broadcast_tx', extra: 'obsolete-binary');
    await tester.pumpAndSettle();
    expect(
        find.textContaining('No wallet action was performed'), findsOneWidget);
    expect(find.text('Transaction Sent'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('sync progress updates without rebuilding the page',
      (tester) async {
    await open(tester);
    syncStatus2.syncing = true;
    syncStatus2.latestHeight = 100;
    syncStatus2.blocksTotal = 100;
    syncStatus2.blocksScanned = 25;
    await tester.pump();
    expect(find.byTooltip('Syncing 25.0%'), findsOneWidget);
    expect(find.text('25.0%'), findsOneWidget);
    syncStatus2.blocksScanned = 75;
    await tester.pump();
    expect(find.byTooltip('Syncing 75.0%'), findsOneWidget);
    expect(find.text('75.0%'), findsOneWidget);
    syncStatus2.syncing = false;
    await tester.pumpAndSettle();
  });
  testWidgets(
      'live sync event updates the target and avoids a premature empty balance',
      (tester) async {
    aa.poolBalances = PoolBalance();
    syncStatus2.syncedHeight = 0;
    syncStatus2.latestHeight = 100;
    await open(tester);
    syncStatus2.connected = false;
    syncStatus2.connectionError = 'download timeout';
    syncStatus2.applyEngineEvent(EngineSyncEvent(
      eventType: 'phase_changed',
      phase: 'scanning',
      scanningUpTo: 81,
      syncedHeight: 75,
      latestHeight: 100,
      maintenanceQueueLen: 0,
      scanProgressNum: BigInt.zero,
      scanProgressDen: BigInt.zero,
      recoveryProgressNum: BigInt.zero,
      recoveryProgressDen: BigInt.zero,
      blocksScanned: BigInt.from(75),
      blocksTotal: BigInt.from(100),
    ));
    await tester.pump();
    expect(syncStatus2.scanningUpTo, 81);
    expect(syncStatus2.connectionError, isNull);
    expect(syncStatus2.connected, isTrue);
    expect(find.byTooltip('Syncing 75.0%'), findsOneWidget);
    expect(find.text('Updating balance…'), findsOneWidget);
    expect(find.text('No funds'), findsNothing);
    syncStatus2.syncing = false;
    await tester.pumpAndSettle();
  });
  testWidgets('network switch clears the old draft and messages',
      (tester) async {
    await open(tester);
    await tester.tap(find.widgetWithText(ZChatShortcut, 'Send'));
    await tester.pumpAndSettle();
    expect(
        find.textContaining('Who would you like to send to?'), findsOneWidget);
    isTestnet = true;
    testnetNotifier.value = true;
    await tester.pumpAndSettle();
    expect(find.text('Testnet'), findsOneWidget);
    expect(find.textContaining('Who would you like to send to?'), findsNothing);
    isTestnet = false;
    testnetNotifier.value = false;
    await tester.pumpAndSettle();
  });
  testWidgets('clear chat returns to the greeting and shortcuts',
      (tester) async {
    await open(tester);
    await tester.enterText(find.byType(TextField), 'receive');
    await tester.tap(find.byTooltip('Send message'));
    await tester.pumpAndSettle();
    expect(
        find.text('Which chain would you like to receive on?'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'clear chat');
    await tester.tap(find.byTooltip('Send message'));
    await tester.pumpAndSettle();
    expect(
        find.text('Which chain would you like to receive on?'), findsNothing);
    expect(find.widgetWithText(ZChatShortcut, 'Send'), findsOneWidget);
    expect(find.widgetWithText(ZChatShortcut, 'Help'), findsOneWidget);
  });

  testWidgets('contact flow treats names as data and cancel invalidates save', (tester) async {
    await open(tester);
    Future<void> say(String text) async {
      await tester.enterText(find.byType(TextField), text);
      await tester.tap(find.byTooltip('Send message'));
      await tester.pumpAndSettle();
    }
    expect(find.byTooltip('Scan QR code'), findsOneWidget);
    expect(find.widgetWithText(ZChatShortcut, 'History'), findsNothing);
    await say('add contact');
    await say('Ethereum');
    await say('Send');
    expect(find.textContaining('Paste their Ethereum address'), findsOneWidget);
    await say('not an address');
    expect(find.text('Invalid Ethereum address'), findsOneWidget);
    await say('0x1111111111111111111111111111111111111111');
    expect(find.widgetWithText(TextButton, 'Save contact'), findsOneWidget);
    await say('cancel');
    expect(tester.widget<TextButton>(find.widgetWithText(TextButton, 'Save contact')).onPressed, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('history command opens Activity rather than duplicating chat history', (tester) async {
    await open(tester);
    await tester.enterText(find.byType(TextField), 'history');
    await tester.tap(find.byTooltip('Send message'));
    await tester.pumpAndSettle();
    expect(find.byType(ZChatComposer), findsNothing);
    await tester.tap(find.text('Chat'));
    await tester.pumpAndSettle();
    expect(find.byType(ZChatComposer), findsOneWidget);
  });

  testWidgets('memos show local message previews and a transaction link',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    aa.txs.items = [
      Tx.from(100, 0, 99, DateTime(2026, 9, 10), 'short', 'full', .01, null,
          null, 'Thank you for lunch', [])
    ];
    await open(tester);
    await tester.enterText(find.byType(TextField), 'latest memos');
    await tester.tap(find.byTooltip('Send message'));
    await tester.pumpAndSettle();
    await preview(tester, 'chat-memos-preview');
    expect(find.text('Thank you for lunch'), findsOneWidget);
    expect(find.text('Received'), findsOneWidget);
    expect(find.text('+0.01 ZEC'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('long memo replies open at the newest entry', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    aa.txs.items = List.generate(
        10,
        (i) => Tx.from(
            100,
            i,
            99,
            DateTime(2026, 9, 10).subtract(Duration(days: i)),
            'short$i',
            'full$i',
            .01,
            null,
            null,
            'Message $i', []));
    await open(tester);
    await tester.enterText(find.byType(TextField), 'latest memos');
    await tester.tap(find.byTooltip('Send message'));
    await tester.pumpAndSettle();
    expect(find.text('Message 0').hitTestable(), findsOneWidget);
    expect(find.text('Message 9').hitTestable(), findsNothing);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
      'Activity replaces chat and preserves its draft without taking focus on incoming activity',
      (tester) async {
    await open(tester);
    await tester.enterText(find.byType(TextField), 'send .02');
    aa.txs.items = [
      Tx.from(100, 0, 0, DateTime.now(), 'incoming', 'incoming', .01, null,
          null, null, [])
    ];
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('Incoming'), findsNothing);
    await tester.tap(find.text('Activity'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
    expect(find.widgetWithText(ZChatShortcut, 'Send'), findsNothing);
    expect(find.text('In progress'), findsOneWidget);
    expect(find.text('Incoming'), findsOneWidget);
    await tester.tap(find.text('Chat'));
    await tester.pumpAndSettle();
    expect(find.text('send .02'), findsOneWidget);
    expect(find.text('Incoming'), findsNothing);
    expect(find.widgetWithText(ZChatShortcut, 'Send'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
      'send prompts include spendable ZEC instead of the portfolio total',
      (tester) async {
    await open(tester);
    expect(find.text('0.5 ZEC available'), findsOneWidget);
    await tester.tap(find.widgetWithText(ZChatShortcut, 'Send'));
    await tester.pumpAndSettle();
    expect(find.text('0.5 ZEC available · fee applies'), findsOneWidget);
  });
}
