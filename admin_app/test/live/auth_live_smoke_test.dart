// SMOKE against the live local platform (Caddy -> flariane + auth). Skipped unless LIVE_CFG is given:
//   bash platform/tests/smoke_admin_app_auth.sh
// Uses the REAL AdminApi in auth mode; only the transport is pointed at 127.0.0.1 with the right Host header.
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flariane_admin/core/api_client.dart';
import 'package:flariane_admin/data/admin_api.dart';
import 'package:flutter_test/flutter_test.dart';

const _cfgRaw = String.fromEnvironment('LIVE_CFG');

Dio _dio(String host, int port) => Dio(BaseOptions(baseUrl: 'http://127.0.0.1:$port', headers: {'Host': host}, contentType: 'application/json'));

void main() {
  final cfg = _cfgRaw.isEmpty ? <String, dynamic>{} : jsonDecode(_cfgRaw) as Map<String, dynamic>;
  final skipAll = _cfgRaw.isEmpty ? 'needs LIVE_CFG (run platform/tests/smoke_admin_app_auth.sh)' : false;
  Object skipUnless(String scenario) => skipAll != false ? skipAll : (cfg['scenario'] == scenario ? false : 'other scenario');

  AdminApi api() {
    final port = cfg['port'] as int, d = cfg['domain'] as String;
    final flr = _dio('flariane-api.$d', port);
    return AdminApi(ApiClient(baseUrl: 'http://127.0.0.1:$port', dio: flr), authDio: _dio('flariane-api.$d', port), authBaseUrl: 'http://127.0.0.1:$port', authSvcDio: _dio('auth-api.$d', port));
  }

  Future<LoginResult> signIn(AdminApi a, String password, {String? totp, bool withDevice = true}) => a.login(
        email: cfg['email'] as String,
        password: password,
        totp: totp ?? cfg['totp'] as String,
        deviceName: 'Téléphone Android',
        platform: 'android',
        deviceId: withDevice ? cfg['device']['device_id'] as int : null,
        deviceSecret: withDevice ? cfg['device']['device_secret'] as String : null,
      );

  test('ok: approved device signs in through auth and flariane opens the back office', () async {
    final a = api();
    expect(a.authMode, true);
    final wrong = await signIn(a, 'wrong-password-1').then((_) => 'ok', onError: (e) => (e as ApiException).code);
    expect(wrong, 'invalid_credentials');
    final r = await signIn(a, cfg['password'] as String);
    expect(r.status, 'ok');
    expect(r.deviceId, cfg['device']['device_id']);
    expect(r.authRefreshToken, isNotNull);
    a.client.accessToken = r.accessToken;
    final me = await a.me();
    expect(me.email, cfg['email']);
    expect(me.deviceId, r.deviceId);
    // refresh while the auth session is alive, then logout ends both sessions
    final t = await a.refresh(refreshToken: r.refreshToken!, deviceId: r.deviceId, deviceSecret: cfg['device']['device_secret'] as String);
    expect(t.accessToken, isNotEmpty);
    await a.logout(refreshToken: t.refreshToken, deviceId: r.deviceId, deviceSecret: cfg['device']['device_secret'] as String);
    await a.authLogout(r.authRefreshToken!);
    await expectLater(a.refresh(refreshToken: t.refreshToken, deviceId: r.deviceId, deviceSecret: cfg['device']['device_secret'] as String), throwsA(isA<ApiException>()));
  }, skip: skipUnless('ok'));

  test('pending: an unknown device is not approved by signing in at auth', () async {
    final a = api();
    final r = await signIn(a, cfg['password'] as String, withDevice: false);
    expect(r.status, 'device_pending');
    expect(r.accessToken, isNull);
    expect(r.deviceSecret, isNotNull);
    expect(r.authRefreshToken, isNull, reason: 'no auth session is left open for a device that is not approved');
  }, skip: skipUnless('pending'));

  test('forced: a temporary password must be replaced, then the sign-in goes on; the password is restored for the next runs', () async {
    final a = api();
    final r = await signIn(a, cfg['temp'] as String);
    expect(r.status, 'password_change');
    final fresh = await a.changeAuthPassword(authAccessToken: r.authAccessToken!, authRefreshToken: r.authRefreshToken!, current: cfg['temp'] as String, next: 'Live-Forced-Pass-2026');
    final done = await a.completeAuthLogin(
      authAccessToken: fresh.access,
      authRefreshToken: fresh.refresh,
      deviceName: 'Téléphone Android',
      platform: 'android',
      deviceId: cfg['device']['device_id'] as int,
      deviceSecret: cfg['device']['device_secret'] as String,
    );
    expect(done.status, 'ok');
    a.client.accessToken = done.accessToken;
    expect((await a.me()).email, cfg['email']);
    // restore the password the other smoke scripts use
    final back = await a.changeAuthPassword(authAccessToken: fresh.access, authRefreshToken: done.authRefreshToken!, current: 'Live-Forced-Pass-2026', next: cfg['password'] as String);
    await a.authLogout(back.refresh);
  }, skip: skipUnless('forced'));
}
