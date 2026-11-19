// SMOKE against the live local platform (Caddy -> flariane + auth). Skipped unless LIVE_CFG is given:
//   bash platform/tests/smoke_customer_app_auth.sh      (prepares users, then runs this file)
// Uses the REAL CustomerApi in auth mode; only the transport is pointed at 127.0.0.1 with the right Host header.
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flariane/core/api.dart';
import 'package:flariane/core/response_cache.dart';
import 'package:flutter_test/flutter_test.dart';

const _cfgRaw = String.fromEnvironment('LIVE_CFG');

Dio _dio(String host, int port) => Dio(BaseOptions(baseUrl: 'http://127.0.0.1:$port', headers: {'Host': host}, validateStatus: null))
  ..options.validateStatus = (s) => s != null && s >= 200 && s < 300;

CustomerApi _api(Map cfg) {
  final port = cfg['port'] as int, d = cfg['domain'] as String;
  return CustomerApi(
    baseUrl: 'http://127.0.0.1:$port',
    authBaseUrl: 'http://127.0.0.1:$port',
    tokens: MemoryTokenStore(),
    cache: MemoryCache(),
    dio: _dio('flariane-api.$d', port),
    authDio: _dio('flariane-api.$d', port),
    authSvcDio: _dio('auth-api.$d', port),
  );
}

void main() {
  final cfg = _cfgRaw.isEmpty ? <String, dynamic>{} : jsonDecode(_cfgRaw) as Map<String, dynamic>;
  final skip = _cfgRaw.isEmpty ? 'needs LIVE_CFG (run platform/tests/smoke_customer_app_auth.sh)' : false;

  test('existing customer: login through auth, flariane accepts the token, refresh, logout', () async {
    final api = _api(cfg);
    expect(api.authMode, true);
    expect(await api.login(cfg['a']['phone'], cfg['a']['password']), false);
    final me = await api.me(); // a flariane route, with the auth access token
    expect(me.phoneVerified, true);
    expect(await api.refresh(), RefreshOutcome.ok);
    expect((await api.me()).phoneMasked, me.phoneMasked);
    final loy = await api.loyalty();
    expect(loy.referralCode, isNotNull);
    await api.logout();
    expect(await api.refresh(), RefreshOutcome.expired);
  }, skip: skip);

  test('wrong password and unknown number give the same answer', () async {
    final api = _api(cfg);
    final a = await api.login(cfg['a']['phone'], 'wrong-password-1').then((_) => 'ok', onError: (e) => (e as ApiException).code);
    final b = await api.login('0799999999', 'wrong-password-1').then((_) => 'ok', onError: (e) => (e as ApiException).code);
    expect([a, b], ['invalid_credentials', 'invalid_credentials']);
  }, skip: skip);

  test('temporary password: flariane refuses the flagged session, the new password unlocks everything', () async {
    final api = _api(cfg);
    expect(await api.login(cfg['b']['phone'], cfg['b']['temp']), true);
    await expectLater(api.me(), throwsA(isA<ApiException>().having((e) => e.status, 'status', 401)));
    await api.changePassword(cfg['b']['temp'], 'Brand-New-Pass-2026');
    expect(api.mustChangePassword, false);
    expect((await api.me()).phoneVerified, true); // same session, clean token after the refresh
    await api.logout();
    expect(await api.login(cfg['b']['phone'], 'Brand-New-Pass-2026'), false);
  }, skip: skip);

  test('sign-up with a referral code: register, team relays the code, activate, login, referral applied, then delete the account', () async {
    final port = cfg['port'] as int, d = cfg['domain'] as String;
    // referrer: user A
    final a = _api(cfg);
    await a.login(cfg['a']['phone'], cfg['a']['password']);
    final code = (await a.loyalty()).referralCode!;
    final before = (await a.loyalty()).balance;

    final api = _api(cfg);
    final phone = cfg['new']['phone'] as String, pw = cfg['new']['password'] as String;
    await api.register(phone, pw, name: 'Live Awa', referralCode: code);
    expect(api.accessToken, isNull, reason: 'no session before the number is activated');
    await expectLater(api.login(phone, pw), throwsA(isA<ApiException>().having((e) => e.code, 'code', 'not_activated')));

    // the team (admin app) relays the code through wa.me: done here with the admin token prepared by the script
    final admin = Dio(BaseOptions(baseUrl: 'http://127.0.0.1:$port', headers: {'Host': 'auth-api.$d', 'Authorization': 'Bearer ${cfg['adminToken']}'}));
    final queue = (await admin.get('/v1/admin/relay-queue')).data as List;
    final item = queue.firstWhere((i) => i['purpose'] == 'activation' && (i['phone_masked'] as String).endsWith(phone.substring(phone.length - 2)));
    final url = (await admin.post('/v1/admin/relay/${item['id']}/send')).data['url'] as String;
    final text = Uri.parse(url).queryParameters['text']!;
    final otp = RegExp(r'\*(\d{6})\*').firstMatch(text)!.group(1)!;

    await expectLater(api.activate(phone, otp == '000000' ? '111111' : '000000'), throwsA(isA<ApiException>().having((e) => e.code, 'code', 'wrong_activation_code')));
    await api.activate(phone, otp);
    expect(await api.login(phone, pw), false);
    await api.applyPendingReferral();
    expect((await api.me()).phoneVerified, true); // customer created in flariane on first use

    final after = (await a.loyalty()).balance;
    expect(after, before + 1, reason: 'the referrer earned the signup point');

    // delete: wrong password stops everything first, right password erases flariane then auth
    await expectLater(api.deleteMe(password: 'typo-typo-1'), throwsA(isA<ApiException>()));
    expect((await api.me()).phoneVerified, true, reason: 'nothing was deleted by the wrong password');
    await api.deleteMe(password: pw);
    await expectLater(_api(cfg).login(phone, pw), throwsA(isA<ApiException>().having((e) => e.code, 'code', 'invalid_credentials')));
  }, skip: skip);
}
