import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:zipher/pages/scan.dart';

void main() {
  testWidgets('leaving scanner completes the waiting request as cancelled',
      (tester) async {
    String? result;
    final router = GoRouter(routes: [
      GoRoute(
          path: '/',
          builder: (context, _) => Scaffold(
              body: TextButton(
                  onPressed: () async => result = await scanQRCode(context),
                  child: const Text('Open')))),
      GoRoute(
          path: '/scan',
          builder: (context, _) => Scaffold(
              body: TextButton(
                  onPressed: () => context.pop(),
                  child: const Text('Cancel')))),
    ]);
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(result, '');
  });
}
