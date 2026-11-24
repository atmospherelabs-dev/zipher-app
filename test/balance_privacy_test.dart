import 'package:flutter_test/flutter_test.dart';
import 'package:zipher/services/balance_privacy.dart';

Duration ms(int v) => Duration(milliseconds: v);

void main() {
  test('three strong jolts in quick succession are a shake', () {
    final d = MotionPrivacyDetector();
    expect(d.onUserAcceleration(20, 0, 0, ms(0)), null);
    expect(d.onUserAcceleration(-20, 0, 0, ms(150)), null);
    expect(d.onUserAcceleration(20, 0, 0, ms(300)), PrivacyGesture.shake);
  });

  test('a single bump, slow bumps or gentle motion are not a shake', () {
    final d = MotionPrivacyDetector();
    expect(d.onUserAcceleration(25, 0, 0, ms(0)), null);
    expect(d.onUserAcceleration(25, 0, 0, ms(1000)), null);
    expect(d.onUserAcceleration(25, 0, 0, ms(2000)), null);
    for (var t = 2100; t < 3000; t += 50) {
      expect(d.onUserAcceleration(8, 4, 3, ms(t)), null);
    }
  });

  test('samples within one jolt count once', () {
    final d = MotionPrivacyDetector();
    expect(d.onUserAcceleration(20, 0, 0, ms(0)), null);
    expect(d.onUserAcceleration(20, 0, 0, ms(20)), null);
    expect(d.onUserAcceleration(20, 0, 0, ms(40)), null);
    expect(d.onUserAcceleration(20, 0, 0, ms(200)), null);
  });

  test('a shake is not repeated during the cooldown', () {
    final d = MotionPrivacyDetector();
    for (final t in [0, 150, 300]) {
      d.onUserAcceleration(20, 0, 0, ms(t));
    }
    for (final t in [450, 600, 750]) {
      expect(d.onUserAcceleration(20, 0, 0, ms(t)), null);
    }
    for (final t in [2000, 2150]) {
      expect(d.onUserAcceleration(20, 0, 0, ms(t)), null);
    }
    expect(d.onUserAcceleration(20, 0, 0, ms(2300)), PrivacyGesture.shake);
  });

  test('face down for half a second hides once until turned back', () {
    final d = MotionPrivacyDetector();
    expect(d.onGravity(0, 0, 9.8, ms(0)), null); // face up
    expect(d.onGravity(0, 0, -9.7, ms(100)), null);
    expect(d.onGravity(0, 0, -9.7, ms(400)), null);
    expect(d.onGravity(0, 0, -9.7, ms(650)), PrivacyGesture.faceDown);
    expect(d.onGravity(0, 0, -9.7, ms(3000)), null);
    expect(d.onGravity(0, 0, 9.8, ms(3100)), null);
    expect(d.onGravity(0, 0, -9.7, ms(3200)), null);
    expect(d.onGravity(0, 0, -9.7, ms(3800)), PrivacyGesture.faceDown);
  });

  test('held upright or tilted is not face down', () {
    final d = MotionPrivacyDetector();
    for (var t = 0; t < 2000; t += 100) {
      expect(d.onGravity(0, 9.8, 0, ms(t)), null);
      expect(d.onGravity(0, 6, -6, ms(t + 50)), null);
    }
  });

  test('hidden state masks text', () {
    final p = BalancePrivacy.instance;
    p.hidden.value = true;
    expect(p.show(r'$30.00'), BalancePrivacy.mask);
    p.hidden.value = false;
    expect(p.show(r'$30.00'), r'$30.00');
  });
}
