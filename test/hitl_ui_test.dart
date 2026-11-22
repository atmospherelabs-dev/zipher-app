import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zipher/pages/hitl/hitl_approve.dart';
import 'package:zipher/pages/hitl/hitl_pair.dart';
import 'package:zipher/pages/hitl/hitl_widgets.dart';
import 'package:zipher/services/hitl_watch_service.dart';
import 'package:zipher/src/rust/api/engine_api.dart';
import 'package:zipher/zipher_theme.dart';

/// Renders the agent-approval screens. With ZIPHER_HITL_UI_CAPTURE=<dir> set,
/// loads macOS system fonts (what iOS shows) and writes PNGs to that directory.
void main() {
  final capture = Platform.environment['ZIPHER_HITL_UI_CAPTURE'];

  Future<void> loadFonts(WidgetTester tester) async {
    if (capture == null) return;
    await tester.runAsync(() async {
      Future<ByteData> f(String path) =>
          File(path).readAsBytes().then((b) => ByteData.sublistView(b));
      for (final family in ['Roboto', 'Inter', '.SF UI Text', '.SF UI Display']) {
        await (FontLoader(family)..addFont(f('/System/Library/Fonts/SFNS.ttf'))).load();
      }
      await (FontLoader('JetBrainsMono')..addFont(f('/System/Library/Fonts/SFNSMono.ttf'))).load();
      await (FontLoader('MaterialIcons')
            ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf')))
          .load();
    });
  }

  Future<void> shoot(WidgetTester tester, String name, Widget page, [void Function()? verify]) async {
    tester.view.physicalSize = const Size(393, 852);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await loadFonts(tester);
    final boundary = GlobalKey();
    await tester.pumpWidget(RepaintBoundary(
      key: boundary,
      child: MaterialApp(debugShowCheckedModeBanner: false, theme: ZipherTheme.dark, home: page),
    ));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 600));
    expect(tester.takeException(), isNull);
    verify?.call();
    if (capture != null) {
      await tester.runAsync(() async {
        final render = boundary.currentContext!.findRenderObject() as RenderRepaintBoundary;
        final image = await render.toImage(pixelRatio: 3);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('$capture/$name.png').writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }
    await tester.pumpWidget(const SizedBox());
  }

  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final request = HitlRequest(
    approvalId: '0123456789abcdef0123456789abcdef',
    network: 'main',
    address: 'u1qx7k3m9wz2vpr5hd8lyn4ecaf6tjgs0ux3wq8m2n7vldk9pz4h6rc5ty8gj2fe3sa0kw7xnl',
    amount: BigInt.from(150000000),
    fee: BigInt.from(10000),
    memo: 'Invoice #1042 — hosting for December',
    contextId: 'order-1042',
    tool: 'propose_send',
    createdAt: BigInt.from(now - 48),
    expiresAt: BigInt.from(now + 252),
    requestJson: '{}',
  );

  testWidgets('approval review', (tester) async {
    HitlWatchService.instance.debugSetPaired('Claude on MacBook Pro');
    await shoot(tester, '1-approve-review', HitlApprovePage(request: request), () {
      expect(find.text('1.5 ZEC'), findsOneWidget);
      expect(find.text('+ 0.0001 ZEC network fee'), findsOneWidget);
      expect(find.text('Approve'), findsOneWidget);
      expect(find.textContaining('u1qx 7k3m'), findsOneWidget);
    });
  });

  testWidgets('pairing confirmation', (tester) async {
    final preview = HitlPairingPreview(
      relayUrl: 'https://relay.atmospherelabs.dev',
      agentName: 'Claude on MacBook Pro',
      checkCode: '482915',
    );
    HitlWatchService.instance.debugSetPaired(null);
    await shoot(tester, '0-pair-confirm',
        HitlPairPage(args: HitlPairingArgs('zipher://pair?v=1', preview)), () {
      expect(find.text('482 915'), findsOneWidget);
      expect(find.textContaining('Replaces'), findsNothing);
    });
  });

  testWidgets('approved confirmation', (tester) async {
    await shoot(
      tester,
      '2-approved',
      const Scaffold(
        backgroundColor: ZipherColors.bg,
        body: HitlDone(
          icon: Icons.check_rounded,
          color: ZipherColors.green,
          title: 'Approved',
          subtitle: 'Your agent will send it now.',
        ),
      ),
    );
  });

  test('zatoshi formatting is exact', () {
    expect(formatZat(BigInt.from(150000000)), '1.5');
    expect(formatZat(BigInt.from(10000)), '0.0001');
    expect(formatZat(BigInt.from(1)), '0.00000001');
    expect(formatZat(BigInt.parse('2100000000000000')), '21000000');
    expect(groupAddress('u1abcdefg'), 'u1ab cdef g');
  });
}
