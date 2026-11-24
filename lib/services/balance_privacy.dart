import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// What a motion sample means for balance privacy.
enum PrivacyGesture { shake, faceDown }

/// Turns raw motion into gestures. Pure, so it can be tested with samples.
///
/// * Shake: three strong jolts (user acceleration, gravity removed) within
///   0.8 s. One bump or a step while walking is not enough.
/// * Face down: gravity points out of the screen for half a second, as when
///   the phone is laid on a table screen-down.
class MotionPrivacyDetector {
  static const shakeThreshold = 15.0; // m/s², about 1.5 g without gravity
  static const shakePeaks = 3;
  static const shakeWindow = Duration(milliseconds: 800);
  static const peakGap = Duration(milliseconds: 90);
  static const faceDownZ = -8.0; // m/s²; flat screen-down is about -9.8
  static const faceDownHold = Duration(milliseconds: 500);
  static const cooldown = Duration(milliseconds: 1500);

  final _peaks = <Duration>[];
  Duration? _faceDownSince;
  bool _faceDownFired = false;
  Duration? _lastGesture;

  bool _cooling(Duration t) =>
      _lastGesture != null && t - _lastGesture! < cooldown;

  PrivacyGesture? _fire(PrivacyGesture g, Duration t) {
    _lastGesture = t;
    _peaks.clear();
    return g;
  }

  /// Acceleration without gravity.
  PrivacyGesture? onUserAcceleration(double x, double y, double z, Duration t) {
    if (_cooling(t)) return null;
    final magnitude = sqrt(x * x + y * y + z * z);
    if (magnitude < shakeThreshold) return null;
    if (_peaks.isNotEmpty && t - _peaks.last < peakGap) return null;
    _peaks
      ..add(t)
      ..removeWhere((p) => t - p > shakeWindow);
    return _peaks.length >= shakePeaks ? _fire(PrivacyGesture.shake, t) : null;
  }

  /// Acceleration including gravity; z is out of the screen (positive when
  /// the phone lies face up).
  PrivacyGesture? onGravity(double x, double y, double z, Duration t) {
    if (z > faceDownZ) {
      _faceDownSince = null;
      _faceDownFired = false;
      return null;
    }
    _faceDownSince ??= t;
    if (_faceDownFired || t - _faceDownSince! < faceDownHold) return null;
    _faceDownFired = true;
    return _fire(PrivacyGesture.faceDown, t);
  }
}

/// Whether amounts on the home screen are masked, and the motion gestures
/// that change it. Shake toggles; turning the phone face down hides. The
/// choice persists across launches.
class BalancePrivacy {
  BalancePrivacy._();
  static final instance = BalancePrivacy._();

  static const mask = '••••';
  static const _hiddenKey = 'balance_hidden';
  static const _gesturesKey = 'balance_hide_gestures';

  final hidden = ValueNotifier<bool>(false);
  final gestures = ValueNotifier<bool>(true);

  final _detector = MotionPrivacyDetector();
  final _clock = Stopwatch()..start();
  final _subs = <StreamSubscription<Object?>>[];
  bool _loaded = false;

  /// Masked text when hidden.
  String show(String text) => hidden.value ? mask : text;

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      hidden.value = prefs.getBool(_hiddenKey) ?? false;
      gestures.value = prefs.getBool(_gesturesKey) ?? true;
    } catch (_) {}
  }

  Future<void> setHidden(bool value) async {
    if (hidden.value == value) return;
    hidden.value = value;
    HapticFeedback.mediumImpact();
    try {
      (await SharedPreferences.getInstance()).setBool(_hiddenKey, value);
    } catch (_) {}
  }

  Future<void> setGestures(bool value) async {
    gestures.value = value;
    if (!value) stopListening();
    try {
      (await SharedPreferences.getInstance()).setBool(_gesturesKey, value);
    } catch (_) {}
  }

  /// Listen only while the home screen is visible and the app is in front.
  void startListening() {
    if (!gestures.value || _subs.isNotEmpty) return;
    try {
      _subs
        ..add(userAccelerometerEventStream(
                samplingPeriod: SensorInterval.gameInterval)
            .listen(
                (e) => _handle(_detector.onUserAcceleration(
                    e.x, e.y, e.z, _clock.elapsed)),
                onError: (_) {}))
        ..add(accelerometerEventStream(
                samplingPeriod: SensorInterval.uiInterval)
            .listen(
                (e) =>
                    _handle(_detector.onGravity(e.x, e.y, e.z, _clock.elapsed)),
                onError: (_) {}));
    } catch (_) {
      stopListening();
    }
  }

  void stopListening() {
    for (final s in _subs) {
      s.cancel();
    }
    _subs.clear();
  }

  void _handle(PrivacyGesture? g) {
    switch (g) {
      case PrivacyGesture.shake:
        setHidden(!hidden.value);
      case PrivacyGesture.faceDown:
        setHidden(true);
      case null:
        break;
    }
  }
}
