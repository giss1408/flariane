import 'package:flutter/services.dart' show appFlavor;

/// Build-time configuration:
///   flutter run --dart-define=API_BASE_URL=https://api.flariane.ci
/// Android emulators reach the host machine at 10.0.2.2.
class AppConfig {
  static const apiBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://10.0.2.2:8000',
  );

  /// Platform `auth` service (SSO). Empty = the legacy flariane login (email + password + code straight to flariane).
  /// With it, the back office signs in at auth (password + authenticator code) and flariane exchanges that for its own
  /// session on this device, so device approval stays in flariane. Local dev: --dart-define=AUTH_BASE_URL=http://10.0.2.2:8080
  static const authBaseUrl = String.fromEnvironment('AUTH_BASE_URL');

  /// Shown in the recents screen and on the login screen; the integration flavor says TEST
  /// so it can't be mistaken for prod.
  static const isTest = appFlavor == 'integration';
  static const appTitle = isTest ? 'Flariane Admin TEST' : 'Flariane Admin';

  /// Lock the app (biometrics / device PIN) after this long in the background.
  static const lockAfter = Duration(minutes: 5);
}
