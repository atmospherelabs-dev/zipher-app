import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zipher/appsettings.dart';
import 'package:zipher/services/network_privacy.dart';
import 'package:zipher/services/wallet_registry.dart';
import 'package:zipher/services/wallet_service.dart';
import 'package:zipher/src/rust/api/wallet.dart';
import 'package:zipher/src/rust/frb_generated.dart';

class PrivacyLifecycleApi implements RustLibApi {
  final calls = <String>[];
  bool tor = false;
  bool failBootstrap = false;
  bool failVerification = false;
  bool requireTor = true;
  Completer<int>? heightGate;
  Completer<void> heightRequested = Completer<void>();

  void network(String operation) {
    calls.add('$operation:${tor ? 'tor' : 'direct'}');
    if (requireTor && !tor) throw StateError('Unexpected direct connection');
  }

  @override
  Future<void> crateApiEngineApiEngineEnableTor(
      {required String dataDir}) async {
    calls.add('enable');
    if (failBootstrap) throw StateError('Tor bootstrap failed');
    tor = true;
  }

  @override
  Future<void> crateApiEngineApiEngineDisableTor() async {
    calls.add('disable');
    tor = false;
  }

  @override
  Future<int> crateApiEngineApiEngineGetLatestBlockHeight(
      {required String serverUrl}) async {
    network('height');
    if (!heightRequested.isCompleted) heightRequested.complete();
    if (failVerification) throw StateError('Tor verification failed');
    if (heightGate != null) return heightGate!.future;
    return 100;
  }

  @override
  Future<String> crateApiEngineApiEngineCreateWallet(
      {required String dataDir,
      required String serverUrl,
      required ChainType chainType,
      required int chainHeight,
      String? dbCipherKey}) async {
    network('create');
    return 'synthetic fixture, never a real seed';
  }

  @override
  Future<void> crateApiEngineApiEngineRestoreFromSeed(
          {required String dataDir,
          required String serverUrl,
          required ChainType chainType,
          required String seedPhrase,
          required int birthday,
          String? dbCipherKey}) async =>
      network('restore');

  @override
  Future<void> crateApiEngineApiEngineRestoreFromUfvk(
          {required String dataDir,
          required String serverUrl,
          required ChainType chainType,
          required String ufvk,
          required int birthday,
          String? dbCipherKey}) async =>
      network('ufvk');

  @override
  Future<void> crateApiEngineApiEngineOpenWallet(
          {required String dataDir,
          required String serverUrl,
          required ChainType chainType,
          String? dbCipherKey}) async =>
      calls.add('open');

  @override
  Future<void> crateApiEngineApiEngineCloseWallet() async => calls.add('close');

  @override
  Future<void> crateApiEngineApiEngineStartSync() async => network('sync');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final api = PrivacyLifecycleApi();
  final service = WalletService.instance;
  final storage = <String, String>{};
  late Directory directory;
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  const keys = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUpAll(() => RustLib.initMock(api: api));
  tearDownAll(RustLib.dispose);
  setUp(() async {
    directory =
        await Directory.systemTemp.createTemp('zipher-privacy-fixture-');
    messenger.setMockMethodCallHandler(paths, (_) async => directory.path);
    messenger.setMockMethodCallHandler(keys, (call) async {
      final args = call.arguments as Map;
      final key = args['key'] as String?;
      if (call.method == 'read') return storage[key];
      if (call.method == 'write') storage[key!] = args['value'] as String;
      return null;
    });
    await service.closeWallet();
    appSettings.defaults();
    WalletRegistry.instance.invalidateCache();
    SharedPreferences.setMockInitialValues(
        {NetworkPrivacy.preferenceKey: true});
    storage.clear();
    api.calls.clear();
    api.tor = false;
    api.failBootstrap = false;
    api.failVerification = false;
    api.requireTor = true;
    api.heightGate = null;
    api.heightRequested = Completer<void>();
  });
  tearDown(() async {
    await service.closeWallet();
    messenger.setMockMethodCallHandler(paths, null);
    messenger.setMockMethodCallHandler(keys, null);
    await directory.delete(recursive: true);
  });

  test('saved Tor is verified before creation and autosync', () async {
    await service.createWallet(chainHeight: 100);
    await service.startSync();
    expect(api.calls, ['enable', 'height:tor', 'create:tor', 'sync:tor']);
  });

  test('registry create and restore fail before profiles or native calls',
      () async {
    api.failBootstrap = true;
    for (final operation in <Future<dynamic> Function()>[
      () => service.createNewWallet('fixture'),
      () => service.restoreWallet('fixture', 'synthetic fixture', 90),
      () => service.restoreWalletFromUfvk('fixture', 'synthetic fixture', 90),
      () => service.createFrostWallet('fixture', 90),
    ]) {
      await expectLater(operation(), throwsStateError);
    }
    expect(api.calls, ['enable', 'enable', 'enable', 'enable']);
    expect((await SharedPreferences.getInstance()).getString('wallet_profiles'),
        isNull);
  });

  test('saved direct choice is explicitly applied before creation', () async {
    SharedPreferences.setMockInitialValues(
        {NetworkPrivacy.preferenceKey: false});
    api.tor = true; // A previous wallet must not override the saved choice.
    api.requireTor = false;
    await service.createWallet(chainHeight: 100);
    await service.startSync();
    expect(api.calls, ['disable', 'create:direct', 'sync:direct']);
  });

  test('creation waits for target-server Tor verification to complete',
      () async {
    api.heightGate = Completer<int>();
    final creating = service.createWallet(chainHeight: 100);
    await api.heightRequested.future;
    expect(api.calls, ['enable', 'height:tor']);
    expect(service.isWalletOpen, isFalse);
    api.heightGate!.complete(100);
    await creating;
    expect(api.calls.last, 'create:tor');
  });

  test('closing during Tor verification cancels the pending creation',
      () async {
    api.heightGate = Completer<int>();
    final creating = service.createWallet(chainHeight: 100);
    final canceled = expectLater(creating, throwsStateError);
    await api.heightRequested.future;
    expect(api.calls, ['enable', 'height:tor']);
    await service.closeWallet();
    api.heightGate!.complete(100);
    await canceled;
    expect(api.calls, ['enable', 'height:tor', 'close']);
    expect(service.isWalletOpen, isFalse);
  });

  for (final bootstrap in [true, false]) {
    test(
        '${bootstrap ? 'bootstrap' : 'verification'} failure prevents creation and sync',
        () async {
      api.failBootstrap = bootstrap;
      api.failVerification = !bootstrap;
      await expectLater(
          service.createWallet(chainHeight: 100), throwsStateError);
      await expectLater(service.startSync(), throwsStateError);
      expect(
          api.calls.any((s) =>
              s.startsWith('create:') ||
              s.startsWith('sync:') ||
              s.endsWith(':direct')),
          isFalse);
      expect(api.calls, isNot(contains('disable')));
      expect(
          (await SharedPreferences.getInstance())
              .getBool(NetworkPrivacy.preferenceKey),
          isTrue);
    });
  }

  test('seed and viewing-key restore prepare Tor before birthday requests',
      () async {
    await service.restoreFromSeed('synthetic fixture', 90);
    expect(api.calls, ['enable', 'height:tor', 'restore:tor']);
    await service.closeWallet();
    api.calls.clear();
    await service.restoreFromUfvk('synthetic viewing-key fixture', 90);
    expect(api.calls, ['enable', 'height:tor', 'ufvk:tor']);
  });

  test('reopen re-verifies the route before opening and resuming sync',
      () async {
    await service.createWallet(chainHeight: 100);
    await service.closeWallet();
    api.calls.clear();
    await service.openWallet();
    await service.startSync();
    expect(api.calls, ['enable', 'height:tor', 'open', 'sync:tor']);
  });
}
