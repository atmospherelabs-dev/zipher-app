import 'package:awesome_notifications/awesome_notifications.dart';

import 'frost_service.dart';

class FrostPushService {
  FrostPushService._();
  static final instance = FrostPushService._();

  static const channelKey = 'Zipher';
  static const approvalType = 'frost_approval_request';

  Future<bool> ensurePermission() async {
    final allowed = await AwesomeNotifications().isNotificationAllowed();
    if (allowed) return true;
    return AwesomeNotifications().requestPermissionToSendNotifications();
  }

  Future<void> showApprovalRequest(FrostApprovalRequest request) async {
    final allowed = await ensurePermission();
    if (!allowed) return;
    await AwesomeNotifications().createNotification(
      content: NotificationContent(
        id: DateTime.now().millisecondsSinceEpoch.remainder(2147483647),
        channelKey: channelKey,
        title: request.localNotificationTitle,
        body: request.localNotificationBody,
        payload: request.toPushPayload().map(
              (key, value) => MapEntry(key, value.toString()),
            ),
      ),
    );
  }

  bool isFrostApprovalPayload(Map<String, String?>? payload) {
    return payload?['type'] == approvalType &&
        payload?['session_id']?.isNotEmpty == true;
  }
}
