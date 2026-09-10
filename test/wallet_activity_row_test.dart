import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zipher/pages/action/widgets/wallet_activity_row.dart';
import 'package:zipher/pages/utils.dart';
import 'package:zipher/zipher_theme.dart';

void main() {
  testWidgets('fee-only activity shows its cost without a negative zero send',
      (tester) async {
    final tx = Tx.from(100, 0, 99, DateTime(2026, 9, 10), 'short', 'full',
        -.0001, null, null, null, [],
        kind: 'sent', fee: .0001);
    await tester.pumpWidget(MaterialApp(
        theme: ZipherTheme.dark,
        home:
            Scaffold(body: WalletActivityRow(transaction: tx, onTap: () {}))));
    expect(find.text('Fee 0.0001 ZEC'), findsOneWidget);
    expect(find.text('Transaction'), findsOneWidget);
    expect(find.text('−0 ZEC'), findsNothing);
  });
  testWidgets('sent amount excludes the fee and pending state is explicit',
      (tester) async {
    final tx = Tx.from(100, 0, 0, DateTime(2026, 9, 10, 9, 30), 'short', 'full',
        -.0101, null, null, null, [],
        kind: 'sent', fee: .0001);
    await tester.pumpWidget(MaterialApp(
        theme: ZipherTheme.dark,
        home:
            Scaffold(body: WalletActivityRow(transaction: tx, onTap: () {}))));
    expect(find.text('−0.01 ZEC'), findsOneWidget);
    expect(find.text('Confirming'), findsOneWidget);
    expect(find.text('Sending'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
