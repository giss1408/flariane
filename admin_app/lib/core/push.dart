import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/inbox/inbox_screen.dart' show inboxProvider;
import '../features/order/order_screen.dart';
import '../main.dart' show navigatorKey;
import 'attention.dart';
import 'session.dart';

/// Firebase push for admin alerts (new quote request, payment declared…). The server only sends the
/// event and the order reference. Does nothing when Firebase isn't configured (no google-services.json).
class PushService {
  PushService(this.ref);

  final WidgetRef ref;
  final _subs = <StreamSubscription<Object?>>[];

  Future<void> start() async {
    try {
      if (Firebase.apps.isEmpty) await Firebase.initializeApp();
      final messaging = FirebaseMessaging.instance;
      await messaging.requestPermission(); // Android 13+ asks; older versions grant it
      final token = await messaging.getToken();
      debugPrint('push: token ${token == null ? 'null' : 'ok'}');
      _register(token);
      _subs
        ..add(messaging.onTokenRefresh.listen(_register))
        ..add(FirebaseMessaging.onMessage.listen(_foreground))
        ..add(FirebaseMessaging.onMessageOpenedApp.listen(_open));
      final launch = await messaging.getInitialMessage(); // app was closed, opened by tapping the alert
      if (launch != null) _open(launch);
    } catch (e) {
      debugPrint('push: disabled ($e)'); // Firebase not configured (or no Play services): the app works, alerts don't
    }
  }

  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
  }

  Future<void> _register(String? token) async {
    if (token == null) return;
    try {
      await ref.read(adminApiProvider).setPushToken(token);
      debugPrint('push: token registered');
    } catch (e) {
      debugPrint('push: token registration failed ($e)'); // retried at the next launch or token refresh
    }
  }

  /// App in front: the system shows nothing, so make the alert unmissable in the app (sound, vibration, a snackbar
  /// that stays 12 s) and refresh the counters and the order lists behind it.
  void _foreground(RemoteMessage m) {
    ref.invalidate(attentionProvider);
    ref.invalidate(inboxProvider);
    SystemSound.play(SystemSoundType.alert);
    HapticFeedback.heavyImpact();
    final context = navigatorKey.currentContext;
    if (context == null) return;
    final n = m.notification;
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(
      duration: const Duration(seconds: 12),
      behavior: SnackBarBehavior.floating,
      showCloseIcon: true,
      content: Text([n?.title, n?.body].whereType<String>().join(' · '), style: const TextStyle(fontWeight: FontWeight.w700)),
      action: _orderId(m) == null ? null : SnackBarAction(label: 'Ouvrir', onPressed: () => _open(m)),
    ));
  }

  int? _orderId(RemoteMessage m) => int.tryParse(m.data['order_id'] ?? '');

  void _open(RemoteMessage m) {
    final id = _orderId(m);
    if (id == null) return;
    navigatorKey.currentState?.push(MaterialPageRoute(builder: (_) => OrderScreen(orderId: id)));
  }
}
