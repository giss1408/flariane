import 'dart:async';

import 'package:flutter/widgets.dart';

/// Calls [onRefresh] every [every] while this screen is the one in front, and once when the app
/// comes back to the foreground, so status changes made by Flariane show up without pulling down.
class AutoRefresh extends StatefulWidget {
  const AutoRefresh(
      {super.key,
      required this.onRefresh,
      required this.child,
      this.every = const Duration(seconds: 20)});

  final VoidCallback onRefresh;
  final Widget child;
  final Duration every;

  @override
  State<AutoRefresh> createState() => _AutoRefreshState();
}

class _AutoRefreshState extends State<AutoRefresh> with WidgetsBindingObserver {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _timer = Timer.periodic(widget.every, (_) {
      if (mounted && (ModalRoute.of(context)?.isCurrent ?? true)) {
        widget.onRefresh();
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) {
      widget.onRefresh();
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
