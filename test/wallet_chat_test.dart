import 'dart:io';
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
import 'package:zipher/src/rust/api/engine_api.dart';
import 'package:zipher/router.dart' as app_router;

void main() {
  setUp(() {
    appSettings.defaults();
    marketPrice.price = null;
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
    expect(find.text('0.75000000 ZEC'), findsOneWidget);
    expect(find.text('0.50000000 ZEC spendable'), findsNothing);
    expect(find.byType(ZChatComposer), findsOneWidget);
    await tester.tap(find.bySemanticsLabel(RegExp('Expand balance details')));
    await tester.pumpAndSettle();
    expect(find.text('0.50000000 ZEC spendable'), findsOneWidget);
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
  testWidgets('Z balance keeps its fiat headline and expandable asset details',
      (tester) async {
    await open(tester);
    marketPrice.price = 40;
    await tester.pumpAndSettle();
    expect(find.text(r'$30.00'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel(RegExp('Expand balance details')));
    await tester.pumpAndSettle();
    expect(find.text('0.75000000 ZEC'), findsOneWidget);
    expect(find.text('0.25000000 ZEC confirming'), findsOneWidget);
    marketPrice.price = null;
    await tester.pumpAndSettle();
    expect(find.text(r'$30.00'), findsNothing);
    expect(find.text('0.75000000 ZEC'), findsNWidgets(2));
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
    await tester.tap(find.text('Recent Actions'));
    await tester.tap(find.bySemanticsLabel(RegExp('Expand balance details')));
    await tester.pumpAndSettle();
    expect(find.text('Confirmed'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'send .5');
    tester.view.viewInsets = const FakeViewPadding(bottom: 280);
    await tester.pumpAndSettle();
    expect(find.text('Recent Actions'), findsNothing);
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

  testWidgets('EVM balances contribute to USD subtotal and retain chain labels',
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
    expect(find.text(r'$2030.00'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel(RegExp('Expand balance details')));
    await tester.pumpAndSettle();
    expect(find.text('1.00000000 ETH · Ethereum'), findsOneWidget);
    await preview(tester, 'chat-balances-preview');
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

  testWidgets('legacy submission routes cannot report a fake payment', (tester) async {
    app_router.router.go('/account/submit_tx', extra: 'obsolete-plan');
    await tester.pumpWidget(MaterialApp.router(
      theme: ZipherTheme.dark,
      localizationsDelegates: const [S.delegate],
      routerConfig: app_router.router,
    ));
    await tester.pumpAndSettle();
    expect(find.textContaining('No wallet action was performed'), findsOneWidget);
    expect(find.text('Transaction Sent'), findsNothing);
    app_router.router.go('/account/broadcast_tx', extra: 'obsolete-binary');
    await tester.pumpAndSettle();
    expect(find.textContaining('No wallet action was performed'), findsOneWidget);
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
    expect(find.text('Syncing 25%'), findsOneWidget);
    syncStatus2.blocksScanned = 75;
    await tester.pump();
    expect(find.text('Syncing 75%'), findsOneWidget);
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
}
