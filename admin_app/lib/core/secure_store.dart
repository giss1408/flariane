import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Device credentials and refresh token live only in Keychain (iOS) / Keystore (Android).
abstract class SecureStore {
  Future<String?> read(String key);
  Future<void> write(String key, String? value);
  Future<void> clearSession();
}

class Keys {
  static const deviceId = 'device_id';
  static const deviceSecret = 'device_secret';
  static const refreshToken = 'refresh_token';
  static const email = 'email';
}

class PlatformSecureStore implements SecureStore {
  final _storage = const FlutterSecureStorage();

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String? value) =>
      value == null ? _storage.delete(key: key) : _storage.write(key: key, value: value);

  /// Logout keeps the device registration (id + secret) so the device stays approved.
  @override
  Future<void> clearSession() => _storage.delete(key: Keys.refreshToken);
}

class MemorySecureStore implements SecureStore {
  final Map<String, String> values = {};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String? value) async =>
      value == null ? values.remove(key) : values[key] = value;

  @override
  Future<void> clearSession() async => values.remove(Keys.refreshToken);
}
