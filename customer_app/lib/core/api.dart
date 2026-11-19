import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../data/models.dart';
import 'format.dart';
import 'pinning.dart';
import 'response_cache.dart';

class ApiException implements Exception {
  ApiException(this.status, this.code);

  final int? status;
  final String code;

  String get message =>
      status == null ? 'Pas de connexion. Vérifie ton réseau.' : (errorMessages[code] ?? 'Une erreur est survenue.');
}

ApiException toApiException(Object e) {
  if (e is ApiException) return e;
  if (e is DioException) {
    final res = e.response;
    if (res == null) return ApiException(null, 'network');
    final data = res.data;
    return ApiException(res.statusCode, data is Map && data['detail'] is String ? data['detail'] as String : 'http_${res.statusCode}');
  }
  return ApiException(null, 'unknown');
}

abstract class TokenStore {
  Future<String?> read();
  Future<void> write(String? token);
}

class SecureTokenStore implements TokenStore {
  static const _key = 'refresh_token';
  final _s = const FlutterSecureStorage();

  @override
  Future<String?> read() => _s.read(key: _key);

  @override
  Future<void> write(String? token) => token == null ? _s.delete(key: _key) : _s.write(key: _key, value: token);
}

class MemoryTokenStore implements TokenStore {
  String? token;

  @override
  Future<String?> read() async => token;

  @override
  Future<void> write(String? t) async => token = t;
}

/// One per user action (not per HTTP attempt): a retry after a timeout sends the same key, so the server
/// answers with the first result instead of creating a second order or payment declaration.
String newIdempotencyKey() {
  final r = Random.secure();
  return List.generate(16, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
}

enum RefreshOutcome { ok, expired, offline }

/// Customer API. Access token in memory; refresh token in Keychain/Keystore, rotated on use.
class CustomerApi {
  CustomerApi({required String baseUrl, this.authBaseUrl = '', required this.tokens, this.cache = const NoCache(), Dio? dio, Dio? authDio, Dio? authSvcDio})
      // Free hosting sleeps when idle and can take ~1 min to wake up (timeouts are set in newApiDio).
      : dio = dio ?? newApiDio(baseUrl),
        _auth = authDio ?? newApiDio(baseUrl),
        _authSvc = authSvcDio ?? (authBaseUrl.isEmpty ? null : newApiDio(authBaseUrl)) {
    this.dio.interceptors.add(QueuedInterceptorsWrapper(
          onRequest: (o, h) {
            if (accessToken != null) o.headers['Authorization'] = 'Bearer $accessToken';
            h.next(o);
          },
          onResponse: (res, h) {
            online.value = true;
            h.next(res);
          },
          onError: (err, h) async {
            // No answer at all (no network, DNS, timeout) = offline; any HTTP answer, even an error, = online.
            online.value = err.response != null;
            final req = err.requestOptions;
            if (err.response?.statusCode == 401 && req.extra['retried'] != true) {
              final outcome = await refresh();
              if (outcome == RefreshOutcome.ok) {
                req.extra['retried'] = true;
                req.headers['Authorization'] = 'Bearer $accessToken';
                try {
                  // A client WITHOUT the queued interceptors: retrying through `this.dio` from inside this queued error
                  // handler deadlocks when the retry fails with 401 again (the second error waits for the first to finish).
                  return h.resolve(await _retryClient.fetch(req));
                } on DioException catch (e) {
                  // A fresh token that flariane still refuses (customer blocked, account gone): stuck otherwise, so sign out.
                  if (authMode && e.response?.statusCode == 401) onSessionExpired?.call();
                  return h.next(e);
                }
              }
              if (outcome == RefreshOutcome.expired) onSessionExpired?.call();
            }
            h.next(err);
          },
        ));
  }

  /// False after a request got no answer, true again after the next one that does. Drives the offline banner.
  final ValueNotifier<bool> online = ValueNotifier(true);
  final Dio dio;
  late final Dio _retryClient = Dio(dio.options)..httpClientAdapter = dio.httpClientAdapter;
  final Dio _auth; // no interceptors: refresh must not recurse into the queued error handler
  /// Platform `auth` service (SSO). When set, sign-up, activation, login, refresh, logout, password reset and password
  /// change go to auth instead of flariane's own endpoints; everything else (orders, /me...) still goes to flariane with the
  /// same access token. Empty = the legacy flariane login (store builds until the cutover).
  final String authBaseUrl;
  final Dio? _authSvc;
  bool get authMode => _authSvc != null;
  static const authProduct = 'flariane';
  static const _pendingReferralKey = 'pending_referral';

  /// True when the last login/refresh said the account must set a new password before anything else (temporary password).
  bool mustChangePassword = false;
  final TokenStore tokens;
  final ResponseCache cache;
  String? accessToken;
  void Function()? onSessionExpired;
  Future<RefreshOutcome>? _inflight;

  Future<T> _call<T>(Future<Response<dynamic>> Function() req, T Function(dynamic) parse) async {
    try {
      return parse((await req()).data);
    } catch (e) {
      throw toApiException(e);
    }
  }

  // ---- auth

  /// POST a login-like call and keep the tokens. Returns true when the account must set a new password first.
  Future<bool> _session(Dio client, String path, Map<String, dynamic> body) async {
    try {
      final res = await client.post(path, data: body);
      accessToken = res.data['access_token'] as String;
      await tokens.write(res.data['refresh_token'] as String);
      mustChangePassword = res.data['must_change_password'] == true;
      return mustChangePassword;
    } catch (e) {
      throw toApiException(e);
    }
  }

  /// Creates the account. With auth: no session yet, the number must be activated with the code the team sends on WhatsApp
  /// (then [login]). The referral code is kept and applied after the first login ([applyPendingReferral]).
  Future<void> register(String phone, String password, {String? name, String? referralCode}) async {
    if (authMode) {
      try {
        await _authSvc!.post('/v1/register', data: {'phone': phone, 'password': password, 'display_name': name, 'product': authProduct, 'consent': true});
      } catch (e) {
        throw toApiException(e);
      }
      if (referralCode != null) await cache.write(_pendingReferralKey, referralCode);
      return;
    }
    await _session(_auth, '/auth/register', {
      'phone': phone, 'password': password, 'display_name': name, 'consent': true, 'client': 'app',
      if (referralCode != null) 'referral_code': referralCode,
    });
  }

  /// auth only: proves the number with the 6-digit code the team sent on WhatsApp.
  Future<void> activate(String phone, String code) async {
    try {
      await _authSvc!.post('/v1/activate', data: {'phone': phone, 'code': code});
    } catch (e) {
      throw toApiException(e);
    }
  }

  /// Applies the referral code typed at sign-up, once, after the first login (flariane cannot receive it at registration
  /// any more). Never blocks login: an unknown, late or already-set code is dropped silently.
  Future<void> applyPendingReferral() async {
    if (!authMode) return;
    final code = await cache.read(_pendingReferralKey);
    if (code is! String) return;
    try {
      await dio.post('/me/referral', data: {'code': code});
    } on DioException catch (_) {
      // dropped on purpose
    }
    await cache.write(_pendingReferralKey, null);
  }

  /// Forgotten password: the team is told and sends a temporary password on WhatsApp. Same answer for any number.
  Future<void> requestPasswordReset(String phone) async {
    try {
      if (authMode) {
        await _authSvc!.post('/v1/password/reset-request', data: {'phone': phone, 'product': authProduct});
      } else {
        await _auth.post('/auth/password-reset-request', data: {'phone': phone});
      }
    } catch (e) {
      throw toApiException(e);
    }
  }

  /// Returns true when she must choose a new password first (she signed in with a temporary one).
  Future<bool> login(String phone, String password) => authMode
      ? _session(_authSvc!, '/v1/login', {'phone': phone, 'password': password, 'product': authProduct, 'app': 'customer'})
      : _session(_auth, '/auth/login', {'phone': phone, 'password': password, 'client': 'app'});

  Future<RefreshOutcome> refresh() => _inflight ??= _doRefresh().whenComplete(() => _inflight = null);

  Future<RefreshOutcome> _doRefresh() async {
    final token = await tokens.read();
    if (token == null) return RefreshOutcome.expired;
    try {
      final res = authMode
          ? await _authSvc!.post('/v1/refresh', data: {'refresh_token': token})
          : await _auth.post('/auth/refresh', data: {'refresh_token': token, 'client': 'app'});
      accessToken = res.data['access_token'] as String;
      await tokens.write(res.data['refresh_token'] as String);
      mustChangePassword = res.data['must_change_password'] == true;
      return RefreshOutcome.ok;
    } catch (e) {
      final ex = toApiException(e);
      if (ex.status == null) return RefreshOutcome.offline;
      accessToken = null;
      await tokens.write(null);
      return RefreshOutcome.expired;
    }
  }

  /// A call to the auth service with the access token; one silent refresh when the token has just expired.
  Future<T> _authed<T>(Future<Response<dynamic>> Function(Options) req, T Function(dynamic) parse) async {
    Options opts() => Options(headers: {'Authorization': 'Bearer $accessToken'});
    try {
      return await _call(() => req(opts()), parse);
    } on ApiException catch (e) {
      if (e.status == 401 && (e.code == 'invalid_token' || e.code == 'missing_token') && await refresh() == RefreshOutcome.ok) {
        return _call(() => req(opts()), parse);
      }
      rethrow;
    }
  }

  Future<void> logout() async {
    final token = await tokens.read();
    try {
      if (token != null) {
        if (authMode) {
          await _authSvc!.post('/v1/logout', data: {'refresh_token': token});
        } else {
          await _auth.post('/auth/logout', data: {'refresh_token': token, 'client': 'app'});
        }
      }
    } catch (_) {}
    accessToken = null;
    await tokens.write(null);
    await cache.clear();
  }

  // ---- account

  Future<Me> me() => _call(() => dio.get('/me'), (j) => Me.fromJson(j as Map<String, dynamic>));

  Future<Me> updateMe({String? name}) =>
      _call(() => dio.patch('/me', data: {'display_name': name}), (j) => Me.fromJson(j as Map<String, dynamic>));

  Future<Me> giveConsent() => _call(() => dio.post('/me/consent'), (j) => Me.fromJson(j as Map<String, dynamic>));

  /// Not available with auth yet (a number change must also move her login in auth): she writes to the team.
  Future<Me> changePhone(String phone) {
    if (authMode) throw ApiException(null, 'phone_change_unavailable');
    return _call(() => dio.put('/me/phone', data: {'phone': phone}), (j) => Me.fromJson(j as Map<String, dynamic>));
  }

  Future<Me> verifyPhone(String code) =>
      _call(() => dio.post('/me/verify-phone', data: {'code': code}), (j) => Me.fromJson(j as Map<String, dynamic>));

  Future<Me> setLocation(Location l) =>
      _call(() => dio.put('/me/location', data: l.toJson()), (j) => Me.fromJson(j as Map<String, dynamic>));

  Future<void> changePassword(String current, String next) async {
    if (!authMode) {
      return _call(() => dio.post('/me/password', data: {'current_password': current, 'new_password': next}), (_) {});
    }
    await _authed((o) => _authSvc!.post('/v1/password/change', data: {'current_password': current, 'new_password': next}, options: o), (_) {});
    await refresh(); // a fresh token without the "must change password" mark
  }

  /// With auth the password is asked first and checked BEFORE anything is deleted, so a typo cannot leave a half-deleted account:
  /// check password (auth) -> anonymise (flariane, refused while orders are in progress) -> erase identity (auth).
  Future<void> deleteMe({String? password}) async {
    if (authMode) {
      await _authed((o) => _authSvc!.post('/v1/me/delete', data: {'current_password': password ?? '', 'check_only': true}, options: o), (_) {});
    }
    await _call(() => dio.delete('/me'), (_) {});
    if (authMode) {
      await _authed((o) => _authSvc!.post('/v1/me/delete', data: {'current_password': password ?? ''}, options: o), (_) {});
    }
  }

  /// Everything we hold about her (law 2013-450): name, phone, orders.
  Future<Map<String, dynamic>> myData() => _call(() => dio.get('/me/export'), (j) => j as Map<String, dynamic>);

  /// Legal texts: public, kept for offline reading.
  Future<List<LegalDoc>> legalDocuments() =>
      _cached('legal.list', '/legal/documents', (j) => (j as List).cast<Map<String, dynamic>>().map(LegalDoc.fromJson).toList());

  Future<LegalDoc> legalDocument(String slug) =>
      _cached('legal.$slug', '/legal/documents/$slug', (j) => LegalDoc.fromJson(j as Map<String, dynamic>));

  /// Public info (no auth): next departure, payment mode, Wave number.
  Future<Map<String, dynamic>> publicInfo() => _call(() => dio.get('/public/info'), (j) => j as Map<String, dynamic>);

  /// Next departure and the last day to order for it (deadline may be unset).
  Future<({DateTime departure, DateTime? deadline})?> nextDeparture() async {
    final info = await publicInfo();
    final v = info['next_departure_date'] as String?;
    if (v == null) return null;
    final d = info['next_order_deadline'] as String?;
    return (departure: DateTime.parse(v), deadline: d == null ? null : DateTime.parse(d));
  }

  String get waveQrUrl => '${dio.options.baseUrl}/public/wave-qr';

  Future<Payment> declarePayment(String ref, {required String method, required String proofPath, String? idempotencyKey}) => _call(
        () async => dio.post('/orders/$ref/payment/declare',
            data: FormData.fromMap({'method': method, 'file': await MultipartFile.fromFile(proofPath)}),
            options: _idem(idempotencyKey)),
        (j) => Payment.fromJson(j as Map<String, dynamic>),
      );

  // ---- orders

  Future<List<PickupPoint>> pickupPoints() => _call(() => dio.get('/pickup-points'),
      (j) => (j as List).cast<Map<String, dynamic>>().map(PickupPoint.fromJson).toList());

  /// GET that remembers the last good answer and returns it when there is no connection at all
  /// (an HTTP error, including 4xx/5xx, is still an error). The offline banner tells her it may be old.
  Future<T> _cached<T>(String key, String path, T Function(dynamic) parse) async {
    try {
      final data = (await dio.get(path)).data;
      await cache.write(key, data);
      return parse(data);
    } catch (e) {
      final err = toApiException(e);
      if (err.status == null) {
        final saved = await cache.read(key);
        if (saved != null) return parse(saved);
      }
      throw err;
    }
  }

  Future<List<OrderSummary>> orders() =>
      _cached('orders', '/orders', (j) => (j as List).cast<Map<String, dynamic>>().map(OrderSummary.fromJson).toList());

  Future<Order> order(String ref) => _cached('order.$ref', '/orders/$ref', (j) => Order.fromJson(j as Map<String, dynamic>));

  Options? _idem(String? key) => key == null ? null : Options(headers: {'Idempotency-Key': key});

  Future<Order> createOrder({required String shareText, int? pickupPointId, String? note, String? idempotencyKey}) => _call(
      () => dio.post('/orders', data: {'share_text': shareText, 'pickup_point_id': pickupPointId, 'note': note}, options: _idem(idempotencyKey)),
      (j) => Order.fromJson(j as Map<String, dynamic>));

  Future<void> uploadScreenshot(String ref, String path) => _call(
      () async => dio.post('/orders/$ref/attachments', data: FormData.fromMap({'file': await MultipartFile.fromFile(path)})),
      (_) {});

  Future<Loyalty> loyalty() => _cached('loyalty', '/me/loyalty', (j) => Loyalty.fromJson(j as Map<String, dynamic>));

  Future<Payment> acceptQuote(String ref, int version, {bool usePoints = false}) => _call(
      () => dio.post('/orders/$ref/quotes/$version/accept', data: {'sizes_confirmed': true, 'use_points': usePoints}),
      (j) => Payment.fromJson(j as Map<String, dynamic>));

  Future<void> requestChange(String ref, int version, Map<String, dynamic> body) =>
      _call(() => dio.post('/orders/$ref/quotes/$version/change-request', data: body), (_) {});

  Future<void> requote(String ref) => _call(() => dio.post('/orders/$ref/requote'), (_) {});

  Future<void> cancel(String ref) => _call(() => dio.post('/orders/$ref/cancel'), (_) {});

  /// Clears a finished order from her own list (the business keeps the order).
  Future<void> hideOrder(String ref) => _call(() => dio.post('/orders/$ref/hide'), (_) {});
}
