import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/inbox/inbox_screen.dart';
import '../features/inbox/verifications_screen.dart';
import 'session.dart';

class Attention {
  Attention(this.counts);

  final Map<String, int> counts;

  int get total => counts.values.fold(0, (a, b) => a + b);
}

/// What waits for the admin. No push service: the app polls every minute while open and on resume.
final attentionProvider = FutureProvider.autoDispose<Attention>((ref) async {
  final me = ref.watch(sessionProvider).me;
  if (me == null || me.isPickupAgent) return Attention({});
  final j = await ref.watch(adminApiProvider).client.call((d) => d.get('/admin/orders/attention'), (j) => j as Map<String, dynamic>);
  final counts = j.map((k, v) => MapEntry(k, (v as num).toInt()));
  if (!me.canOperate) counts.remove('registrations_to_verify');
  return Attention(counts);
});

/// Refreshes counters and the open lists every minute and when the app comes back to the foreground.
class AttentionPoller extends WidgetsBindingObserver {
  AttentionPoller(this.ref) {
    _timer = Timer.periodic(const Duration(seconds: 60), (_) => refresh());
  }

  final WidgetRef ref;
  late final Timer _timer;

  void refresh() {
    ref.invalidate(attentionProvider);
    ref.invalidate(inboxProvider);
    ref.invalidate(unverifiedProvider);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) refresh();
  }

  void dispose() => _timer.cancel();
}
