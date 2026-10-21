import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'config.dart';
import 'session.dart';

/// Locks the session when the app comes back after [AppConfig.lockAfter] in the background.
class AppLockObserver extends WidgetsBindingObserver {
  AppLockObserver(this.ref, {DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  final WidgetRef ref;
  final DateTime Function() _clock;
  DateTime? _backgroundedAt;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      _backgroundedAt ??= _clock();
    } else if (state == AppLifecycleState.resumed) {
      final since = _backgroundedAt;
      _backgroundedAt = null;
      if (since != null && _clock().difference(since) >= AppConfig.lockAfter) {
        ref.read(sessionProvider.notifier).lock();
      }
    }
  }
}
