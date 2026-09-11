import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zipher/pages/sensitive_qr.dart';
import 'package:zipher/services/frost_service.dart';
import 'package:zipher/services/secure_key_store.dart';
import 'package:zipher/services/wallet_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  final storage = <String, String>{};
  var writes = 0;
  var reads = 0;
  bool failRead = false;
  bool failDelete = false;
  Completer<void>? readGate;

  setUp(() {
    storage.clear();
    writes = 0;
    reads = 0;
    failRead = false;
    failDelete = false;
    readGate = null;
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      final args = call.arguments as Map;
      final key = args['key'] as String?;
      switch (call.method) {
        case 'read':
          reads++;
          if (failRead) throw PlatformException(code: 'keychain_unavailable');
          if (readGate != null) await readGate!.future;
          return storage[key];
        case 'write':
          writes++;
          storage[key!] = args['value'] as String;
          return null;
        case 'delete':
          if (failDelete) throw PlatformException(code: 'keychain_unavailable');
          storage.remove(key);
          return null;
        case 'readAll':
          return Map<String, String>.from(storage);
        default:
          throw StateError('Unexpected storage operation ${call.method}');
      }
    });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('keychain read failure never replaces an existing database key',
      () async {
    storage['db_cipher_key_0'] = 'original-key';
    failRead = true;
    await expectLater(
        SecureKeyStore.getOrCreateDbKey(0), throwsA(isA<PlatformException>()));
    expect(writes, 0);
    expect(storage['db_cipher_key_0'], 'original-key');
    failRead = false;
    expect(await SecureKeyStore.getOrCreateDbKey(0), 'original-key');
  });

  test('concurrent database initialization creates exactly one key', () async {
    readGate = Completer<void>();
    final a = SecureKeyStore.getOrCreateDbKey(1);
    final b = SecureKeyStore.getOrCreateDbKey(1);
    readGate!.complete();
    final keys = await Future.wait([a, b]);
    expect(keys[0], keys[1]);
    expect(keys[0].length, 64);
    expect(reads, 1);
    expect(writes, 1);
  });

  test('shared-wallet deletion removes share and relay key on both networks',
      () async {
    for (final id in ['deleted', 'deleted_testnet', 'keep']) {
      storage['frost_key_package_$id'] = 'share';
      storage['frost_relay_private_key_$id'] = 'relay';
    }
    await FrostService.instance.deleteWalletMaterial('deleted');
    await FrostService.instance.deleteWalletMaterial('deleted_testnet');
    expect(storage.keys.toSet(),
        {'frost_key_package_keep', 'frost_relay_private_key_keep'});
  });

  test('missing registry never authorizes erasing retained shared-wallet keys',
      () async {
    storage.addAll({
      'frost_key_package_keep': 'share',
      'frost_relay_private_key_unknown': 'relay',
      'seed_wallet_keep': 'test-placeholder'
    });
    await FrostService.instance.resumeExplicitDeletions();
    expect(storage.length, 3);
    await FrostService.instance.queueWalletDeletion('unknown');
    await FrostService.instance.resumeExplicitDeletions();
    expect(
        storage.keys.toSet(), {'frost_key_package_keep', 'seed_wallet_keep'});
    await FrostService.instance.resumeExplicitDeletions();
    expect(storage.length, 2);
  });

  test('failed key deletion retains explicit intent and safely retries',
      () async {
    storage['frost_key_package_deleted'] = 'share';
    await FrostService.instance.queueWalletDeletion('deleted');
    failDelete = true;
    await expectLater(FrostService.instance.resumeExplicitDeletions(),
        throwsA(isA<PlatformException>()));
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList('frost_pending_deletions_v1'), ['deleted']);
    expect(storage['frost_key_package_deleted'], 'share');
    failDelete = false;
    await FrostService.instance.resumeExplicitDeletions();
    expect(storage, isEmpty);
    expect(prefs.getStringList('frost_pending_deletions_v1'), isEmpty);
  });

  test('unbound sends and remote FROST approval fail before key access',
      () async {
    await expectLater(WalletService.instance.confirmSend(), throwsStateError);
    await expectLater(
        FrostService.instance.approveSigningRequest(walletId: 'unused'),
        throwsStateError);
    await expectLater(
        FrostService.instance.cosignerFinishSigning(walletId: 'unused'),
        throwsStateError);
    expect(reads, 0);
  });

  testWidgets('recovery QR stays hidden after resume until fresh authorization',
      (tester) async {
    var allow = false;
    var authCalls = 0;
    await tester.pumpWidget(MaterialApp(
        home: SensitiveQrPage(
            title: 'Recovery',
            value: 'dummy-test-value',
            authorize: () async {
              authCalls++;
              return allow;
            })));
    expect(find.byType(QrImage), findsOneWidget);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(find.byType(QrImage), findsNothing);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(find.byType(QrImage), findsNothing);
    await tester.tap(find.byType(TextButton));
    await tester.pumpAndSettle();
    expect(find.byType(QrImage), findsNothing);
    allow = true;
    await tester.tap(find.byType(TextButton));
    await tester.pumpAndSettle();
    expect(authCalls, 2);
    expect(find.byType(QrImage), findsOneWidget);
    expect(find.byIcon(Icons.copy), findsNothing);
    expect(find.byIcon(Icons.save), findsNothing);
  });
}
