import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    as frb;
import 'package:flutter_test/flutter_test.dart';
import 'package:zipher/appsettings.dart';
import 'package:zipher/pages/more/ironwood.dart';
import 'package:zipher/src/rust/api/engine_api.dart';
import 'package:zipher/src/rust/frb_generated.dart';
import 'package:zipher/zipher_theme.dart';

class MigrationUpgradeApi implements RustLibApi {
  String status = 'upgrade_review_required';
  int signingCalls = 0;

  @override
  Future<IronwoodSdkProgress>
      crateApiEngineApiEngineIronwoodSdkStatus() async => IronwoodSdkProgress(
          status: status,
          crossingValues: frb.Uint64List.fromList([]),
          totalPlannedZat: BigInt.from(500000),
          totalConfirmedZat: BigInt.from(200000),
          broadcastCount: 2,
          confirmedCount: 2,
          totalTxCount: 5,
          nextDueHeight: 0,
          feesPaidZat: BigInt.zero);

  @override
  Future<IronwoodSdkProgress> crateApiEngineApiEngineIronwoodSdkTick(
      {required String seedPhrase}) async {
    signingCalls++;
    throw StateError('Rendering a paused migration must not sign');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  final api = MigrationUpgradeApi();
  setUpAll(() => RustLib.initMock(api: api));
  tearDownAll(RustLib.dispose);

  for (final status in [
    'paused_by_upgrade',
    'upgrade_review_required',
    'stopped_by_upgrade'
  ]) {
    testWidgets(
        '$status explains remaining funds instead of reporting completion',
        (tester) async {
      appSettings.defaults();
      api.status = status;
      api.signingCalls = 0;
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      if (Platform.environment['ZIPHER_UPGRADE_UI_CAPTURE'] != null) {
        await tester.runAsync(() async {
          final root = Platform.environment['FLUTTER_ROOT']!;
          for (final family in ['Roboto', 'Inter', 'JetBrains Mono']) {
            final loader = FontLoader(family)
              ..addFont(File(
                      '$root/bin/cache/artifacts/material_fonts/Roboto-Regular.ttf')
                  .readAsBytes()
                  .then((bytes) => ByteData.sublistView(bytes)));
            await loader.load();
          }
          await (FontLoader('MaterialIcons')
                ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf')))
              .load();
        });
      }
      final boundary = GlobalKey();
      await tester.pumpWidget(RepaintBoundary(
          key: boundary,
          child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: ZipherTheme.dark,
              home: const IronwoodPage())));
      await tester.pumpAndSettle();
      expect(find.text('Migration Complete'), findsNothing);
      expect(find.text('All funds are in the Ironwood pool.'), findsNothing);
      expect(api.signingCalls, 0);
      if (status == 'stopped_by_upgrade') {
        expect(find.text('Review remaining funds'), findsOneWidget);
        expect(find.text('Review remaining balance'), findsOneWidget);
      } else if (status == 'upgrade_review_required') {
        expect(find.text('Verifying earlier transfers'), findsOneWidget);
        expect(find.text('Check recovery'), findsOneWidget);
        expect(find.text('Review remaining balance'), findsNothing);
      } else {
        expect(find.text('Migration paused'), findsOneWidget);
        expect(find.text('Check again'), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
      final capture = Platform.environment['ZIPHER_UPGRADE_UI_CAPTURE'];
      if (capture != null && status == 'stopped_by_upgrade') {
        await tester.runAsync(() async {
          final render = boundary.currentContext!.findRenderObject()
              as RenderRepaintBoundary;
          final image = await render.toImage(pixelRatio: 2);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(capture).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
      await tester.pumpWidget(const SizedBox());
    });
  }
}
