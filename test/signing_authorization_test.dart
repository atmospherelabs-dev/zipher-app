import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zipher/appsettings.dart';
import 'package:zipher/pages/utils.dart';

void main() {
  testWidgets('legacy auth opt-out cannot bypass device confirmation',
      (tester) async {
    appSettings.defaults();
    appSettings.protectSend = false;
    const channel = MethodChannel('plugins.flutter.io/local_auth');
    var calls = 0;
    var approved = false;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel,
        (call) async {
      expect(call.method, 'authenticate');
      expect(call.arguments['biometricOnly'], false);
      calls++;
      return approved;
    });
    addTearDown(() {
      tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      appSettings.defaults();
    });
    await tester
        .pumpWidget(const MaterialApp(home: Scaffold(body: SizedBox())));
    final context = tester.element(find.byType(SizedBox).first);
    expect(
        await requireSigningAuthorization(context,
            actionSummary: 'Review payment'),
        false);
    expect(calls, 1);
    approved = true;
    expect(
        await requireSigningAuthorization(context,
            actionSummary: 'Review payment'),
        true);
    expect(calls, 2);
  });
}
