// Back-office sign-in through the platform `auth` service (SSO), with fake servers: no network.
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flariane_admin/core/api_client.dart';
import 'package:flariane_admin/core/secure_store.dart';
import 'package:flariane_admin/core/session.dart';
import 'package:flariane_admin/data/admin_api.dart';
import 'package:flariane_admin/data/models.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

typedef Reply = ({int status, Object? body});

class FakeServer implements HttpClientAdapter {
  FakeServer(this.handler);
  final Reply Function(RequestOptions o) handler;
  final calls = <String>[];
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    calls.add('${options.method} ${options.path}');
    requests.add(options);
    final r = handler(options);
    return ResponseBody.fromString(jsonEncode(r.body), r.status, headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType]
    });
  }

  @override
  void close({bool force = false}) {}
}

Dio dioFor(FakeServer s) => Dio(BaseOptions(baseUrl: 'http://fake', contentType: 'application/json'))..httpClientAdapter = s;

const authTokens = {'access_token': 'auth-acc', 'refresh_token': 'auth-ref', 'must_change_password': false};
const flrOk = {
  'status': 'ok',
  'device_id': 7,
  'device_secret': 'dev-secret',
  'tokens': {'access_token': 'flr-acc', 'refresh_token': 'flr-ref', 'expires_in': 900},
};

({AdminApi api, FakeServer flr, FakeServer auth}) build({Reply Function(RequestOptions)? flrH, Reply Function(RequestOptions)? authH, bool authMode = true}) {
  final flr = FakeServer(flrH ?? (o) => (status: 200, body: flrOk));
  final auth = FakeServer(authH ?? (o) => (status: 200, body: authTokens));
  final api = AdminApi(ApiClient(baseUrl: 'http://fake', dio: dioFor(flr)),
      authDio: dioFor(flr), authBaseUrl: authMode ? 'http://auth' : '', authSvcDio: authMode ? dioFor(auth) : null);
  return (api: api, flr: flr, auth: auth);
}

Future<LoginResult> login(AdminApi api, {String totp = '123456', int? deviceId, String? secret}) =>
    api.login(email: 'awa@flariane.ci', password: 'pw-123456', totp: totp, deviceName: 'Téléphone Android', platform: 'android', deviceId: deviceId, deviceSecret: secret);

class MockApi extends Mock implements AdminApi {}

class FakeUnlocker implements DeviceUnlocker {
  @override
  Future<bool> unlock() async => true;
}

final me = AdminMe(id: 1, email: 'awa@flariane.ci', name: 'Awa', role: 'OPERATOR', deviceId: 7);

void main() {
  group('AdminApi with auth', () {
    test('signs in at auth (email, password, code, product, app) then exchanges the token on this device', () async {
      final t = build();
      expect(t.api.authMode, true);
      final r = await login(t.api, deviceId: 7, secret: 'dev-secret');
      expect(t.auth.calls, ['POST /v1/login']);
      expect(t.auth.requests.single.data, {'email': 'awa@flariane.ci', 'password': 'pw-123456', 'product': 'flariane', 'app': 'admin', 'totp': '123456'});
      expect(t.flr.calls, ['POST /admin/auth/sso-login']);
      expect(t.flr.requests.single.headers['Authorization'], 'Bearer auth-acc');
      expect(t.flr.requests.single.data, {'device': {'device_id': 7, 'device_secret': 'dev-secret', 'name': 'Téléphone Android', 'platform': 'android'}});
      expect(r.status, 'ok');
      expect((r.accessToken, r.refreshToken, r.deviceId), ('flr-acc', 'flr-ref', 7));
      expect(r.authRefreshToken, 'auth-ref', reason: 'kept to end the auth session at logout');
      expect(t.flr.calls.any((c) => c.contains('/admin/auth/login')), false, reason: 'flariane password login is not used');
    });

    test('an account without an authenticator code sends none', () async {
      final t = build();
      await login(t.api, totp: '');
      expect(t.auth.requests.single.data.containsKey('totp'), false);
    });

    test('an unknown device is not approved by signing in: pending, and no auth session is left open', () async {
      final t = build(flrH: (o) => (status: 200, body: {'status': 'device_pending', 'device_id': 9, 'device_secret': 'new-secret'}));
      final r = await login(t.api);
      expect(r.status, 'device_pending');
      expect((r.deviceId, r.deviceSecret), (9, 'new-secret'));
      expect(r.accessToken, isNull);
      expect(r.authRefreshToken, isNull);
      expect(t.auth.calls, ['POST /v1/login', 'POST /v1/logout']);
      expect(t.auth.requests.last.data, {'refresh_token': 'auth-ref'});
    });

    test('a temporary password stops before flariane: nothing is sent to flariane', () async {
      final t = build(authH: (o) => (status: 200, body: {...authTokens, 'must_change_password': true}));
      final r = await login(t.api);
      expect(r.status, 'password_change');
      expect((r.authAccessToken, r.authRefreshToken), ('auth-acc', 'auth-ref'));
      expect(t.flr.calls, isEmpty);
    });

    test('errors from auth keep their code (wrong code, locked, blocked) and nothing reaches flariane', () async {
      for (final code in ['invalid_totp', 'invalid_credentials', 'login_locked', 'account_blocked', 'no_access_to_app']) {
        final t = build(authH: (o) => (status: 401, body: {'detail': code}));
        await expectLater(login(t.api), throwsA(isA<ApiException>().having((e) => e.code, 'code', code)));
        expect(t.flr.calls, isEmpty);
      }
    });

    test('flariane refusing the exchange (not a migrated admin) is an error and the auth session is not kept', () async {
      final t = build(flrH: (o) => (status: 401, body: {'detail': 'invalid_credentials'}));
      await expectLater(login(t.api), throwsA(isA<ApiException>().having((e) => e.status, 'status', 401)));
    });

    test('changing the temporary password returns a clean auth session', () async {
      final t = build(authH: (o) => o.path == '/v1/password/change' ? (status: 204, body: null) : (status: 200, body: {...authTokens, 'access_token': 'auth-acc-2', 'refresh_token': 'auth-ref-2'}));
      final fresh = await t.api.changeAuthPassword(authAccessToken: 'auth-acc', authRefreshToken: 'auth-ref', current: 'temp', next: 'new-password-1');
      expect((fresh.access, fresh.refresh), ('auth-acc-2', 'auth-ref-2'));
      expect(t.auth.calls, ['POST /v1/password/change', 'POST /v1/refresh']);
      expect(t.auth.requests.first.headers['Authorization'], 'Bearer auth-acc');
    });

    test('without AUTH_BASE_URL the legacy flariane login is used, unchanged', () async {
      final t = build(authMode: false);
      expect(t.api.authMode, false);
      final r = await login(t.api);
      expect(t.flr.calls, ['POST /admin/auth/login']);
      expect(t.auth.calls, isEmpty);
      expect(r.status, 'ok');
      await t.api.authLogout('x'); // a no-op
      expect(t.auth.calls, isEmpty);
    });
  });

  group('SessionController with auth', () {
    late MockApi api;
    late MemorySecureStore store;
    late ProviderContainer c;

    setUp(() {
      api = MockApi();
      store = MemorySecureStore();
      c = ProviderContainer(overrides: [
        adminApiProvider.overrideWithValue(api),
        secureStoreProvider.overrideWithValue(store),
        unlockerProvider.overrideWithValue(FakeUnlocker()),
        apiClientProvider.overrideWithValue(ApiClient(baseUrl: 'http://test')),
      ]);
      addTearDown(c.dispose);
      when(() => api.me()).thenAnswer((_) async => me);
      when(() => api.authLogout(any())).thenAnswer((_) async {});
      when(() => api.logout(refreshToken: any(named: 'refreshToken'), deviceId: any(named: 'deviceId'), deviceSecret: any(named: 'deviceSecret'))).thenAnswer((_) async {});
    });

    void stubLogin(LoginResult r) => when(() => api.login(
          email: any(named: 'email'),
          password: any(named: 'password'),
          totp: any(named: 'totp'),
          deviceName: any(named: 'deviceName'),
          platform: any(named: 'platform'),
          deviceId: any(named: 'deviceId'),
          deviceSecret: any(named: 'deviceSecret'),
        )).thenAnswer((_) async => r);

    Future<SessionController> start() async {
      final n = c.read(sessionProvider.notifier);
      await Future<void>.delayed(Duration.zero);
      return n;
    }

    test('login keeps the auth refresh token (to end the auth session at logout) next to the flariane one', () async {
      stubLogin(LoginResult(status: 'ok', deviceId: 7, deviceSecret: 'sec', accessToken: 'a', refreshToken: 'r', authRefreshToken: 'auth-r'));
      final n = await start();
      await n.login(email: 'Awa@Flariane.ci ', password: 'pw', totp: '123456');
      expect(c.read(sessionProvider).status, SessionStatus.loggedIn);
      expect(await store.read(Keys.refreshToken), 'r');
      expect(await store.read(Keys.authRefreshToken), 'auth-r');
      expect(await store.read(Keys.deviceId), '7');
      await n.logout();
      verify(() => api.authLogout('auth-r')).called(1);
      expect(await store.read(Keys.authRefreshToken), isNull);
      expect(c.read(sessionProvider).status, SessionStatus.loggedOut);
    });

    test('a temporary password asks for a new one, then signs in on the same device', () async {
      stubLogin(LoginResult(status: 'password_change', deviceId: 0, authAccessToken: 'auth-a', authRefreshToken: 'auth-r'));
      when(() => api.changeAuthPassword(authAccessToken: 'auth-a', authRefreshToken: 'auth-r', current: 'temp', next: 'new-password-1'))
          .thenAnswer((_) async => (access: 'auth-a2', refresh: 'auth-r2'));
      when(() => api.completeAuthLogin(
            authAccessToken: 'auth-a2',
            authRefreshToken: 'auth-r2',
            deviceName: any(named: 'deviceName'),
            platform: any(named: 'platform'),
            deviceId: any(named: 'deviceId'),
            deviceSecret: any(named: 'deviceSecret'),
          )).thenAnswer((_) async => LoginResult(status: 'ok', deviceId: 7, accessToken: 'a', refreshToken: 'r', authRefreshToken: 'auth-r2'));
      final n = await start();
      await n.login(email: 'awa@flariane.ci', password: 'temp', totp: '123456');
      expect(c.read(sessionProvider).status, SessionStatus.passwordChange);
      expect(await store.read(Keys.refreshToken), isNull, reason: 'no flariane session before the new password');
      await n.setNewPassword(current: 'temp', next: 'new-password-1');
      expect(c.read(sessionProvider).status, SessionStatus.loggedIn);
      expect(await store.read(Keys.authRefreshToken), 'auth-r2');
    });

    test('cancelling the forced change ends the auth session', () async {
      stubLogin(LoginResult(status: 'password_change', deviceId: 0, authAccessToken: 'auth-a', authRefreshToken: 'auth-r'));
      final n = await start();
      await n.login(email: 'awa@flariane.ci', password: 'temp', totp: '123456');
      n.cancelPasswordChange();
      verify(() => api.authLogout('auth-r')).called(1);
      expect(c.read(sessionProvider).status, SessionStatus.loggedOut);
    });

    test('a pending device is remembered, nothing else is stored', () async {
      stubLogin(LoginResult(status: 'device_pending', deviceId: 9, deviceSecret: 'new-sec'));
      final n = await start();
      await n.login(email: 'awa@flariane.ci', password: 'pw', totp: '123456');
      expect(c.read(sessionProvider).status, SessionStatus.devicePending);
      expect(await store.read(Keys.deviceSecret), 'new-sec');
      expect(await store.read(Keys.refreshToken), isNull);
      expect(await store.read(Keys.authRefreshToken), isNull);
    });
  });
}
