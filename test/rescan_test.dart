import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:zipher/generated/intl/messages.dart';
import 'package:zipher/pages/accounts/rescan.dart';

void main() {
  testWidgets('recovery failure stays visible and allows a deliberate retry',
      (tester) async {
    var calls = 0;
    final pending = Completer<void>();
    final router = GoRouter(routes: [
      GoRoute(
          path: '/',
          builder: (_, __) => RescanPage(rescan: () {
                calls++;
                return pending.future;
              })),
    ]);
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(
      routerConfig: router,
      localizationsDelegates: const [S.delegate],
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Recover transactions'));
    await tester.pumpAndSettle();
    expect(calls, 0); // Confirmation is required before starting recovery.
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull);
    pending.completeError(StateError('disposable test failure'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Recovery could not start'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNotNull);
    expect(calls, 1);
  });
}
