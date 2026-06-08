import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../init.dart' show flutterLocalNotificationsPlugin;
import '../pages/utils.dart' show APP_NAME;
import 'frost_service.dart';

class FrostPushService {
  FrostPushService._();
  static final instance = FrostPushService._();

  static const channelKey = APP_NAME;
  static const approvalType = 'frost_approval_request';

  Future<bool> ensurePermission() async {
    final android = flutterLocalNotificationsPlugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
    if (android != null) {
      final granted = await android.requestNotificationsPermission();
      return granted ?? false;
    }
    return true;
  }

  Future<void> showApprovalRequest(FrostApprovalRequest request) async {
    final allowed = await ensurePermission();
    if (!allowed) return;

    const androidDetails = AndroidNotificationDetails(
      channelKey,
      channelKey,
      channelDescription: 'FROST signing approval requests',
      importance: Importance.max,
      priority: Priority.high,
    );
    const details = NotificationDetails(
      android: androidDetails,
      iOS: DarwinNotificationDetails(),
    );

    final payload = request
        .toPushPayload()
        .map((key, value) => MapEntry(key, value.toString()));

    await flutterLocalNotificationsPlugin.show(
      DateTime.now().millisecondsSinceEpoch.remainder(2147483647),
      request.localNotificationTitle,
      request.localNotificationBody,
      details,
      payload: payload.entries.map((e) => '${e.key}=${e.value}').join('&'),
    );
  }

  bool isFrostApprovalPayload(String? payload) {
    if (payload == null) return false;
    final params = Uri.splitQueryString(payload);
    return params['type'] == approvalType &&
        (params['session_id']?.isNotEmpty ?? false);
  }
}
