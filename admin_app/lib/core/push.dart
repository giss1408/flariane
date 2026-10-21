import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import '../data/admin_api.dart';

/// Push notifications are optional: without Firebase config (`flutterfire configure` adds
/// google-services.json / GoogleService-Info.plist) the app runs without them.
class PushService {
  static bool _ready = false;

  static Future<void> init() async {
    try {
      await Firebase.initializeApp();
      _ready = true;
    } catch (e) {
      debugPrint('Push disabled: $e');
    }
  }

  /// Registers this device's FCM token with the API and calls [onOpenOrder] when a
  /// notification is tapped. Payloads carry only the order id/ref, never customer data.
  static Future<void> register(AdminApi api, void Function(int orderId) onOpenOrder) async {
    if (!_ready) return;
    try {
      final messaging = FirebaseMessaging.instance;
      await messaging.requestPermission();
      final token = await messaging.getToken();
      if (token != null) await api.setPushToken(token);
      messaging.onTokenRefresh.listen((t) => api.setPushToken(t));

      void open(RemoteMessage m) {
        final id = int.tryParse(m.data['order_id'] ?? '');
        if (id != null) onOpenOrder(id);
      }

      FirebaseMessaging.onMessageOpenedApp.listen(open);
      final initial = await messaging.getInitialMessage();
      if (initial != null) open(initial);
    } catch (e) {
      debugPrint('Push registration failed: $e');
    }
  }
}
