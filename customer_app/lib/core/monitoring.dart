import 'package:flutter/widgets.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

/// Build with --dart-define=SENTRY_DSN=... to report crashes; without it nothing is sent.
const _sentryDsn = String.fromEnvironment('SENTRY_DSN');

/// Runs the app, reporting uncaught errors to Sentry when a DSN is set.
/// Privacy: no personal data (no IP/user, no screenshots, no view hierarchy).
Future<void> runWithMonitoring(Widget app) async {
  if (_sentryDsn.isEmpty) return runApp(app);
  await SentryFlutter.init(
    (o) {
      o.dsn = _sentryDsn;
      o.sendDefaultPii = false;
      o.attachScreenshot = false;
      o.attachViewHierarchy = false;
      o.tracesSampleRate = 0;
      o.environment = const bool.fromEnvironment('dart.vm.product') ? 'release' : 'debug';
    },
    appRunner: () => runApp(app),
  );
}
