import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zipher/generated/intl/messages.dart';
import 'package:zipher/pages/more/about.dart';
import 'package:zipher/pages/splash.dart';
import 'package:zipher/src/version.dart';

Widget _app(Widget home, {bool reduceMotion = false}) => MaterialApp(
      localizationsDelegates: const [S.delegate],
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: reduceMotion),
          child: home,
        ),
      ),
    );

void main() {
  testWidgets('About shows the build, the links and the disclaimer',
      (tester) async {
    tester.view.physicalSize = const Size(1179, 2556);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_app(const AboutPage()));
    await tester.pumpAndSettle();

    final version = packageVersion.split('+').first;
    expect(find.textContaining('Version $version'), findsOneWidget);
    expect(find.textContaining(commitId.substring(0, 7)), findsOneWidget);
    for (final link in [
      'Website',
      'Source code',
      'ZecBlock',
      'Privacy policy',
      'Terms of use',
    ]) {
      await tester.scrollUntilVisible(find.text(link), 120);
      expect(find.text(link), findsOneWidget, reason: link);
    }
    await tester.scrollUntilVisible(find.textContaining('without warranty'), 120);
    expect(find.textContaining('without warranty'), findsOneWidget);

    await tester.tap(find.text('Terms of use'));
    await tester.pumpAndSettle();
    expect(find.text('Terms'), findsOneWidget);
  });

  testWidgets('Splash shows each loading stage and holds still under Reduce Motion',
      (tester) async {
    final key = GlobalKey();
    await tester.pumpWidget(
        _app(LoadProgress(key: key), reduceMotion: true));
    // Nothing repeats under Reduce Motion, so the frame settles.
    await tester.pumpAndSettle();

    (key.currentState as dynamic).setValue(0.7, 'Loading wallet data…');
    await tester.pump();
    expect(find.text('Loading wallet data…'), findsOneWidget);
    expect(tester.hasRunningAnimations, isFalse);
  });
}
