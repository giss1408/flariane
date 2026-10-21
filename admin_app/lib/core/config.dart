/// Build-time configuration:
///   flutter run --dart-define=API_BASE_URL=https://api.flariane.ci
/// Android emulators reach the host machine at 10.0.2.2.
class AppConfig {
  static const apiBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://10.0.2.2:8000',
  );

  /// flutter run --dart-define=DEV_BYPASS_AUTH=true → no password/TOTP/biometrics (dev API only).
  static const devBypassAuth = bool.fromEnvironment('DEV_BYPASS_AUTH');

  /// Lock the app (biometrics / device PIN) after this long in the background.
  static const lockAfter = Duration(minutes: 5);
}
