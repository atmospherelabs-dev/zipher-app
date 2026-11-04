import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:zipher/services/network_privacy.dart';

void main() {
  test('Tor is not reported active before end-to-end verification', () async {
    final verified = Completer<int>();
    final calls = <String>[];
    final privacy = NetworkPrivacy(
      enable: () async => calls.add('enable'),
      disable: () async => calls.add('disable'),
      verify: () => verified.future,
      savePreference: (value) async => calls.add('save:$value'),
    );
    final connecting = privacy.setTor(true);
    await Future<void>.delayed(Duration.zero);
    expect(privacy.state, NetworkPrivacyState.connecting);
    expect(calls, ['save:true', 'enable']);
    await expectLater(privacy.setTor(false), throwsStateError);
    verified.complete(3477900);
    await connecting;
    expect(privacy.state, NetworkPrivacyState.tor);
    expect(privacy.verifiedHeight, 3477900);
    await privacy.setTor(false);
    expect(calls, ['save:true', 'enable', 'disable', 'save:false']);
    expect(privacy.state, NetworkPrivacyState.direct);
    expect(privacy.verifiedHeight, isNull);
    privacy.dispose();
  });

  test('failed verification retains Tor intent and never switches to direct',
      () async {
    final saved = <bool>[];
    var disabled = false;
    final privacy = NetworkPrivacy(
      enable: () async {},
      disable: () async {
        disabled = true;
      },
      verify: () async => throw StateError('network unavailable'),
      savePreference: (value) async => saved.add(value),
    );
    await expectLater(privacy.setTor(true), throwsStateError);
    expect(privacy.state, NetworkPrivacyState.error);
    expect(saved, [true]);
    expect(disabled, isFalse);
    expect(privacy.verifiedHeight, isNull);
    privacy.dispose();
  });

  test(
      'restore re-applies the saved policy instead of retaining stale readiness',
      () async {
    var saved = true;
    final calls = <String>[];
    final privacy = NetworkPrivacy(
      enable: () async => calls.add('enable'),
      disable: () async => calls.add('disable'),
      verify: () async {
        calls.add('verify');
        return 100;
      },
      savePreference: (value) async => saved = value,
      loadPreference: () async => saved,
    );
    await privacy.ensureReady(serverUrl: 'first');
    expect(calls, ['enable', 'verify']);
    saved = false;
    await privacy.restore();
    expect(calls, ['enable', 'verify', 'disable']);
    expect(privacy.state, NetworkPrivacyState.direct);
    expect(privacy.verifiedHeight, isNull);
    privacy.dispose();
  });

  test('unreadable saved intent prevents lifecycle readiness', () async {
    var connected = false;
    final privacy = NetworkPrivacy(
      enable: () async => connected = true,
      disable: () async => connected = true,
      verify: () async => 100,
      savePreference: (_) async {},
      loadPreference: () async => throw StateError('preferences unavailable'),
    );
    await expectLater(privacy.ensureReady(), throwsStateError);
    expect(connected, isFalse);
    expect(privacy.state, NetworkPrivacyState.error);
    privacy.dispose();
  });

  test('wallet invalidation in a readiness listener cancels its caller',
      () async {
    final calls = <String>[];
    final privacy = NetworkPrivacy(
      enable: () async => calls.add('enable'),
      disable: () async => calls.add('disable'),
      verify: () async {
        calls.add('verify');
        return 100;
      },
      savePreference: (_) async {},
      loadPreference: () async => true,
    );
    addTearDown(privacy.dispose);
    var invalidated = false;
    privacy.addListener(() {
      if (!invalidated && privacy.state == NetworkPrivacyState.tor) {
        invalidated = true;
        privacy.invalidateWallet();
      }
    });

    await expectLater(
      privacy.ensureReady(serverUrl: 'first'),
      throwsStateError,
    );
    expect(privacy.verifiedHeight, isNull);

    await privacy.ensureReady(serverUrl: 'first');
    expect(calls, ['enable', 'verify', 'enable', 'verify']);
    expect(privacy.verifiedHeight, 100);
  });
}
