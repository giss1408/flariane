import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../core/theme.dart';

/// Strip shown above the whole app while requests get no answer (no internet).
class ConnectionBanner extends StatelessWidget {
  const ConnectionBanner({super.key, required this.online, required this.onRetry, required this.child});

  final ValueListenable<bool> online;
  final Future<void> Function() onRetry;
  final Widget child;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
        valueListenable: online,
        builder: (context, isOnline, _) {
          if (isOnline) return child;
          return Column(children: [
            Material(
              color: context.pal.danger,
              child: SafeArea(
                bottom: false,
                child: InkWell(
                  onTap: onRetry,
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    child: Row(children: [
                      Icon(Icons.wifi_off_rounded, size: 18, color: Colors.white),
                      SizedBox(width: 10),
                      Expanded(
                        child: Text('Pas de connexion internet. Les informations peuvent être anciennes.',
                            style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)),
                      ),
                      Text('Réessayer', style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w800)),
                    ]),
                  ),
                ),
              ),
            ),
            // The banner already covers the status bar: the screen below must not pad for it twice.
            Expanded(child: MediaQuery.removePadding(context: context, removeTop: true, child: child)),
          ]);
        },
      );
}
