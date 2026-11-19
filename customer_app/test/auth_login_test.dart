// Customer app login through the platform `auth` service (SSO), with fake servers: no network.
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flariane/core/api.dart';
import 'package:flariane/core/providers.dart';
import 'package:flariane/core/response_cache.dart';
import 'package:flariane/features/auth/activation_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

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

Dio dioFor(FakeServer s) => Dio(BaseOptions(baseUrl: 'http://fake'))..httpClientAdapter = s;

const tokensOk = {'access_token': 'acc-1', 'refresh_token': 'ref-1', 'must_change_password': false};

({CustomerApi api, FakeServer flr, FakeServer auth, MemoryTokenStore store, MemoryCache cache}) build({
  Reply Function(RequestOptions)? flrH,
  Reply Function(RequestOptions)? authH,
  bool authMode = true,
}) {
  final flr = FakeServer(flrH ?? (o) => (status: 200, body: {'id': 1}));
  final auth = FakeServer(authH ?? (o) => (status: 200, body: tokensOk));
  final store = MemoryTokenStore();
  final cache = MemoryCache();
  final api = CustomerApi(
    baseUrl: 'http://flr',
    authBaseUrl: authMode ? 'http://auth' : '',
    tokens: store,
    cache: cache,
    dio: dioFor(flr),
    authDio: dioFor(flr),
    authSvcDio: authMode ? dioFor(auth) : null,
  );
  return (api: api, flr: flr, auth: auth, store: store, cache: cache);
}

ProviderContainer containerFor(CustomerApi api) => ProviderContainer(overrides: [apiProvider.overrideWithValue(api)]);

Future<AuthController> settle(ProviderContainer c) async {
  final n = c.read(authProvider.notifier);
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
  return n;
}

void main() {
  group('CustomerApi with auth', () {
    test('login goes to auth with product and app, keeps the tokens, and flariane calls use the same access token', () async {
      final t = build();
      expect(t.api.authMode, true);
      final must = await t.api.login('0701020304', 'secret-123');
      expect(must, false);
      expect(t.auth.calls, ['POST /v1/login']);
      expect(t.auth.requests.single.data, {'phone': '0701020304', 'password': 'secret-123', 'product': 'flariane', 'app': 'customer'});
      expect(await t.store.read(), 'ref-1');
      await t.api.me().catchError((_) => throw 'unused'); // flariane /me with the access token
      expect(t.flr.requests.last.headers['Authorization'], 'Bearer acc-1');
      expect(t.flr.calls.every((c) => !c.contains('/auth/')), true, reason: 'flariane auth endpoints are not used');
    });

    test('without AUTH_BASE_URL nothing changes: the legacy flariane login is used', () async {
      final t = build(authMode: false, flrH: (o) => (status: 200, body: tokensOk));
      expect(t.api.authMode, false);
      await t.api.login('0701020304', 'secret-123');
      expect(t.flr.calls, ['POST /auth/login']);
      expect(t.auth.calls, isEmpty);
    });

    test('login with a temporary password reports that a new one must be chosen', () async {
      final t = build(authH: (o) => (status: 200, body: {...tokensOk, 'must_change_password': true}));
      expect(await t.api.login('0701020304', 'tmp-pass'), true);
      expect(t.api.mustChangePassword, true);
    });

    test('register creates no session; activate then login does', () async {
      final t = build(authH: (o) => o.path == '/v1/register' ? (status: 201, body: {'status': 'pending_activation'}) : (status: 200, body: tokensOk));
      await t.api.register('0701020304', 'secret-123', name: 'Awa', referralCode: 'ABC-1234');
      expect(t.api.accessToken, isNull);
      expect(await t.store.read(), isNull);
      expect(t.auth.requests.single.data['product'], 'flariane');
      expect(t.auth.requests.single.data['consent'], true);
      expect(t.auth.requests.single.data.containsKey('referral_code'), false, reason: 'referral is applied on flariane, after login');
      await t.api.activate('0701020304', '123456');
      expect(t.auth.calls, ['POST /v1/register', 'POST /v1/activate']);
    });

    test('the referral typed at sign-up is applied once after the first login, then forgotten', () async {
      final t = build(authH: (o) => o.path == '/v1/register' ? (status: 201, body: {}) : (status: 200, body: tokensOk));
      await t.api.register('0701020304', 'secret-123', referralCode: 'ABC-1234');
      await t.api.login('0701020304', 'secret-123');
      await t.api.applyPendingReferral();
      await t.api.applyPendingReferral();
      expect(t.flr.calls, ['POST /me/referral']);
      expect(t.flr.requests.single.data, {'code': 'ABC-1234'});
    });

    test('a refused referral (late, unknown) never blocks the session and is dropped', () async {
      final t = build(flrH: (o) => (status: 409, body: {'detail': 'referral_too_late'}));
      await t.cache.write('pending_referral', 'ABC-1234');
      await t.api.applyPendingReferral();
      expect(await t.cache.read('pending_referral'), isNull);
    });

    test('refresh, logout, reset request and password change all go to auth', () async {
      final t = build(authH: (o) => o.path == '/v1/password/change' ? (status: 204, body: null) : (status: 200, body: tokensOk));
      await t.api.login('0701020304', 'secret-123');
      expect(await t.api.refresh(), RefreshOutcome.ok);
      await t.api.requestPasswordReset('0701020304');
      await t.api.changePassword('old', 'new-password-1');
      await t.api.logout();
      expect(t.auth.calls, ['POST /v1/login', 'POST /v1/refresh', 'POST /v1/password/reset-request', 'POST /v1/password/change', 'POST /v1/refresh', 'POST /v1/logout']);
      expect(t.auth.requests[2].data, {'phone': '0701020304', 'product': 'flariane'});
      expect(t.auth.requests[3].headers['Authorization'], 'Bearer acc-1');
      expect(t.flr.calls, isEmpty);
      expect(await t.store.read(), isNull);
    });

    test('an expired session at refresh is reported as expired', () async {
      final t = build(authH: (o) => (status: 401, body: {'detail': 'session_expired'}));
      await t.store.write('ref-old');
      expect(await t.api.refresh(), RefreshOutcome.expired);
      expect(await t.store.read(), isNull);
    });

    test('wrong current password is reported as such, without silently refreshing', () async {
      final t = build(authH: (o) => o.path == '/v1/login' ? (status: 200, body: tokensOk) : (status: 401, body: {'detail': 'invalid_credentials'}));
      await t.api.login('0701020304', 'secret-123');
      await expectLater(t.api.changePassword('wrong', 'new-password-1'), throwsA(isA<ApiException>().having((e) => e.code, 'code', 'invalid_credentials')));
      expect(t.auth.calls.where((c) => c.contains('refresh')), isEmpty);
    });

    test('an expired access token is refreshed once and the call retried', () async {
      var first = true;
      final t = build(authH: (o) {
        if (o.path == '/v1/password/change') {
          if (first) {
            first = false;
            return (status: 401, body: {'detail': 'invalid_token'});
          }
          return (status: 204, body: null);
        }
        return (status: 200, body: {...tokensOk, 'access_token': 'acc-2'});
      });
      await t.store.write('ref-1');
      t.api.accessToken = 'stale';
      await t.api.changePassword('old', 'new-password-1');
      expect(t.auth.calls.take(3), ['POST /v1/password/change', 'POST /v1/refresh', 'POST /v1/password/change']);
      expect(t.auth.requests[2].headers['Authorization'], 'Bearer acc-2');
    });

    test('delete account: password checked in auth FIRST, then flariane, then auth erases; a wrong password deletes nothing', () async {
      final ok = build(flrH: (o) => (status: 204, body: null), authH: (o) => o.path == '/v1/login' ? (status: 200, body: tokensOk) : (status: 204, body: null));
      await ok.api.login('0701020304', 'secret-123');
      await ok.api.deleteMe(password: 'secret-123');
      expect(ok.auth.calls, ['POST /v1/login', 'POST /v1/me/delete', 'POST /v1/me/delete']);
      expect(ok.auth.requests[1].data, {'current_password': 'secret-123', 'check_only': true});
      expect(ok.auth.requests[2].data, {'current_password': 'secret-123'});
      expect(ok.flr.calls, ['DELETE /me']);

      final bad = build(flrH: (o) => (status: 204, body: null), authH: (o) => o.path == '/v1/login' ? (status: 200, body: tokensOk) : (status: 401, body: {'detail': 'invalid_credentials'}));
      await bad.api.login('0701020304', 'secret-123');
      await expectLater(bad.api.deleteMe(password: 'typo'), throwsA(isA<ApiException>()));
      expect(bad.flr.calls, isEmpty, reason: 'flariane data untouched when the password is wrong');
    });

    test('flariane refusing the deletion (orders in progress) leaves the auth identity untouched', () async {
      final t = build(flrH: (o) => (status: 409, body: {'detail': 'orders_in_progress'}), authH: (o) => o.path == '/v1/login' ? (status: 200, body: tokensOk) : (status: 204, body: null));
      await t.api.login('0701020304', 'secret-123');
      await expectLater(t.api.deleteMe(password: 'secret-123'), throwsA(isA<ApiException>().having((e) => e.code, 'code', 'orders_in_progress')));
      expect(t.auth.calls, ['POST /v1/login', 'POST /v1/me/delete']); // only the check_only call
    });

    test('a fresh token that flariane still refuses ends the session instead of hanging (blocked customer)', () async {
      final t = build(flrH: (o) => (status: 401, body: {'detail': 'not_authenticated'}));
      var expired = 0;
      t.api.onSessionExpired = () => expired++;
      await t.api.login('0701020304', 'secret-123');
      await expectLater(t.api.me().timeout(const Duration(seconds: 5)), throwsA(isA<ApiException>().having((e) => e.status, 'status', 401)));
      expect(expired, 1);
      expect(t.auth.calls, ['POST /v1/login', 'POST /v1/refresh']); // one refresh, one retry, then stop
      expect(t.flr.calls, ['GET /me', 'GET /me']);
    });

    test('changing the phone number is not available with auth yet', () {
      expect(() => build().api.changePhone('0709090909'), throwsA(isA<ApiException>().having((e) => e.code, 'code', 'phone_change_unavailable')));
    });
  });

  group('AuthController with auth', () {
    test('register -> activating -> activate -> logged in (and the pending login is dropped)', () async {
      final t = build(authH: (o) => o.path == '/v1/register' ? (status: 201, body: {}) : (status: 200, body: tokensOk));
      final c = containerFor(t.api);
      final n = await settle(c);
      await n.register('0701020304', 'secret-123', name: 'Awa');
      expect(c.read(authProvider), AuthStatus.activating);
      expect(c.read(pendingLoginProvider)?.phone, '0701020304');
      await n.activate('123456');
      expect(c.read(authProvider), AuthStatus.loggedIn);
      expect(c.read(pendingLoginProvider), isNull);
      expect(t.auth.calls, ['POST /v1/register', 'POST /v1/activate', 'POST /v1/login']);
    });

    test('a wrong code keeps her on the activation screen with the error', () async {
      final t = build(authH: (o) => o.path == '/v1/register' ? (status: 201, body: {}) : (status: 400, body: {'detail': 'wrong_activation_code'}));
      final c = containerFor(t.api);
      final n = await settle(c);
      await n.register('0701020304', 'secret-123');
      await expectLater(n.activate('000000'), throwsA(isA<ApiException>().having((e) => e.code, 'code', 'wrong_activation_code')));
      expect(c.read(authProvider), AuthStatus.activating);
      expect(c.read(pendingLoginProvider), isNotNull);
    });

    test('logging in with a number that is not activated yet sends her to the code screen', () async {
      final t = build(authH: (o) => (status: 403, body: {'detail': 'not_activated'}));
      final c = containerFor(t.api);
      final n = await settle(c);
      await n.login('0701020304', 'secret-123');
      expect(c.read(authProvider), AuthStatus.activating);
      expect(c.read(pendingLoginProvider)?.password, 'secret-123');
    });

    test('other login errors stay errors', () async {
      final t = build(authH: (o) => (status: 401, body: {'detail': 'invalid_credentials'}));
      final c = containerFor(t.api);
      final n = await settle(c);
      await expectLater(n.login('0701020304', 'nope'), throwsA(isA<ApiException>().having((e) => e.code, 'code', 'invalid_credentials')));
      expect(c.read(authProvider), AuthStatus.loggedOut);
    });

    test('a temporary password leads to the forced password change, then to the app, with no flariane call before it', () async {
      final t = build(authH: (o) => o.path == '/v1/password/change' ? (status: 204, body: null) : (status: 200, body: {...tokensOk, 'must_change_password': true}));
      final c = containerFor(t.api);
      final n = await settle(c);
      await n.login('0701020304', 'tmp-pass');
      expect(c.read(authProvider), AuthStatus.passwordChange);
      expect(t.flr.calls, isEmpty, reason: 'flariane refuses tokens flagged "must change password"');
      await t.api.changePassword('tmp-pass', 'new-password-1');
      await n.passwordChanged();
      expect(c.read(authProvider), AuthStatus.loggedIn);
    });

    test('app restarted before she chose her new password: back to the forced change', () async {
      final t = build(authH: (o) => (status: 200, body: {...tokensOk, 'must_change_password': true}));
      await t.store.write('ref-1');
      final c = containerFor(t.api);
      await settle(c);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(c.read(authProvider), AuthStatus.passwordChange);
    });

    test('app restarted with a good session: logged in; with an expired one: logged out', () async {
      final ok = build();
      await ok.store.write('ref-1');
      final c1 = containerFor(ok.api);
      await settle(c1);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(c1.read(authProvider), AuthStatus.loggedIn);

      final expired = build(authH: (o) => (status: 401, body: {'detail': 'session_expired'}));
      await expired.store.write('ref-old');
      final c2 = containerFor(expired.api);
      await settle(c2);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(c2.read(authProvider), AuthStatus.loggedOut);
    });
  });

  testWidgets('activation screen: shows the masked number, validates the code, shows server errors', (tester) async {
    final t = build(authH: (o) => o.path == '/v1/register' ? (status: 201, body: {}) : (status: 400, body: {'detail': 'wrong_activation_code'}));
    final c = containerFor(t.api);
    // real async (Dio, timers) must run outside the fake-async zone of testWidgets
    await tester.runAsync(() async {
      final n = await settle(c);
      await n.register('0701020304', 'secret-123');
    });
    await tester.pumpWidget(UncontrolledProviderScope(container: c, child: const MaterialApp(home: ActivationScreen())));
    expect(find.textContaining('07 •• •• 04'), findsOneWidget);
    expect(find.textContaining('0701020304'), findsNothing, reason: 'the full number is not shown');
    await tester.enterText(find.byType(TextField), '123');
    await tester.tap(find.text('Valider'));
    await tester.pump();
    expect(find.text('Code à 6 chiffres.'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '123456');
    await tester.tap(find.text('Valider'));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 200)); // lets Dio's fake-async timers and microtasks run
    }
    expect(find.text('Code incorrect ou expiré.'), findsOneWidget);
    await tester.tap(find.text('Retour'));
    await tester.pump();
    expect(c.read(authProvider), AuthStatus.loggedOut);
  });
}
