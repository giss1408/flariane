import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:local_auth/local_auth.dart';

import '../data/admin_api.dart';
import '../data/models.dart';
import 'api_client.dart';
import 'config.dart';
import 'secure_store.dart';

enum SessionStatus { loading, loggedOut, devicePending, locked, loggedIn }

@immutable
class SessionState {
  const SessionState(this.status, {this.me, this.deviceId, this.message, this.email});

  final SessionStatus status;
  final AdminMe? me;
  final int? deviceId;
  final String? message; // shown on the login screen (e.g. "session expired")
  final String? email;
}

/// Biometric / device-PIN check. Abstracted for tests.
abstract class DeviceUnlocker {
  Future<bool> unlock();
}

class LocalAuthUnlocker implements DeviceUnlocker {
  final _auth = LocalAuthentication();

  @override
  Future<bool> unlock() async {
    try {
      if (!await _auth.isDeviceSupported()) return true; // no lock screen configured: nothing to check against
      return await _auth.authenticate(
        localizedReason: 'Déverrouiller Flariane Admin',
        options: const AuthenticationOptions(stickyAuth: true),
      );
    } catch (_) {
      return false;
    }
  }
}

final secureStoreProvider = Provider<SecureStore>((_) => PlatformSecureStore());
final unlockerProvider = Provider<DeviceUnlocker>((_) => LocalAuthUnlocker());
final apiClientProvider = Provider<ApiClient>((_) => ApiClient(baseUrl: AppConfig.apiBaseUrl));
final adminApiProvider = Provider<AdminApi>((ref) => AdminApi(ref.watch(apiClientProvider)));

final sessionProvider = NotifierProvider<SessionController, SessionState>(SessionController.new);

class SessionController extends Notifier<SessionState> {
  SecureStore get _store => ref.read(secureStoreProvider);
  AdminApi get _api => ref.read(adminApiProvider);
  ApiClient get _client => ref.read(apiClientProvider);

  @override
  SessionState build() {
    final client = ref.read(apiClientProvider);
    client.refresher = _refresh;
    client.onSessionExpired = () => _expire('Session expirée. Reconnectez-vous.');
    Future.microtask(init);
    return const SessionState(SessionStatus.loading);
  }

  Future<void> init() async {
    final email = await _store.read(Keys.email);
    final refreshToken = await _store.read(Keys.refreshToken);
    if (refreshToken == null) {
      state = SessionState(SessionStatus.loggedOut, email: email);
      return;
    }
    // A stored session still requires biometrics on cold start.
    state = SessionState(SessionStatus.locked, email: email);
  }

  static String get _platform {
    if (kIsWeb) return 'web';
    return Platform.isIOS ? 'ios' : 'android';
  }

  Future<void> login({required String email, required String password, required String totp}) async {
    final deviceIdRaw = await _store.read(Keys.deviceId);
    final deviceSecret = await _store.read(Keys.deviceSecret);
    final result = await _api.login(
      email: email.trim().toLowerCase(),
      password: password,
      totp: totp,
      deviceName: _platform == 'ios' ? 'iPhone' : 'Téléphone Android',
      platform: _platform,
      deviceId: deviceSecret == null ? null : int.tryParse(deviceIdRaw ?? ''),
      deviceSecret: deviceSecret,
    );
    await _store.write(Keys.email, email.trim().toLowerCase());
    if (result.deviceSecret != null) {
      await _store.write(Keys.deviceId, '${result.deviceId}');
      await _store.write(Keys.deviceSecret, result.deviceSecret);
    }
    if (result.status == 'device_pending') {
      state = SessionState(SessionStatus.devicePending, deviceId: result.deviceId, email: email);
      return;
    }
    _client.accessToken = result.accessToken;
    await _store.write(Keys.refreshToken, result.refreshToken);
    await _loadMe();
  }

  /// Called on cold start and after the background timeout.
  Future<bool> unlock() async {
    if (!await ref.read(unlockerProvider).unlock()) return false;
    if (_client.accessToken == null) {
      final outcome = await _refresh();
      if (outcome == RefreshOutcome.expired) {
        await _expire('Session expirée. Reconnectez-vous.');
        return false;
      }
      if (outcome == RefreshOutcome.offline) {
        state = SessionState(SessionStatus.locked, me: state.me, email: state.email, message: 'Pas de connexion. Réessayez.');
        return false;
      }
    }
    try {
      await _loadMe();
      return true;
    } on ApiException catch (e) {
      if (e.status == null && state.me != null) {
        state = SessionState(SessionStatus.loggedIn, me: state.me); // offline: keep working with cached data
        return true;
      }
      await _expire('Session expirée. Reconnectez-vous.');
      return false;
    }
  }

  void lock() {
    if (state.status == SessionStatus.loggedIn) {
      state = SessionState(SessionStatus.locked, me: state.me, email: state.email);
    }
  }

  Future<void> logout() async {
    final refreshToken = await _store.read(Keys.refreshToken);
    final deviceId = int.tryParse(await _store.read(Keys.deviceId) ?? '');
    final secret = await _store.read(Keys.deviceSecret);
    if (refreshToken != null && deviceId != null && secret != null) {
      await _api.logout(refreshToken: refreshToken, deviceId: deviceId, deviceSecret: secret);
    }
    await _expire(null);
  }

  Future<void> _loadMe() async {
    final me = await _api.me();
    state = SessionState(SessionStatus.loggedIn, me: me, email: me.email);
  }

  Future<RefreshOutcome> _refresh() async {
    final refreshToken = await _store.read(Keys.refreshToken);
    final deviceId = int.tryParse(await _store.read(Keys.deviceId) ?? '');
    final secret = await _store.read(Keys.deviceSecret);
    if (refreshToken == null || deviceId == null || secret == null) return RefreshOutcome.expired;
    try {
      final tokens = await _api.refresh(refreshToken: refreshToken, deviceId: deviceId, deviceSecret: secret);
      _client.accessToken = tokens.accessToken;
      await _store.write(Keys.refreshToken, tokens.refreshToken);
      return RefreshOutcome.ok;
    } on ApiException catch (e) {
      if (e.status == null) return RefreshOutcome.offline;
      if (e.code == 'device_invalid') {
        // Revoked or unknown device: forget it so the next login registers a new one.
        await _store.write(Keys.deviceId, null);
        await _store.write(Keys.deviceSecret, null);
      }
      return RefreshOutcome.expired;
    }
  }

  Future<void> _expire(String? message) async {
    _client.accessToken = null;
    await _store.clearSession();
    state = SessionState(SessionStatus.loggedOut, message: message, email: await _store.read(Keys.email));
  }
}
