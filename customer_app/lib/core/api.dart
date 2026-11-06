import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../data/models.dart';
import 'format.dart';
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
  CustomerApi({required String baseUrl, required this.tokens, this.cache = const NoCache(), Dio? dio, Dio? authDio})
      // Free hosting sleeps when idle and can take ~1 min to wake up.
      : dio = dio ?? Dio(BaseOptions(baseUrl: baseUrl, connectTimeout: const Duration(seconds: 60), receiveTimeout: const Duration(seconds: 60))),
        _auth = authDio ?? Dio(BaseOptions(baseUrl: baseUrl, connectTimeout: const Duration(seconds: 60), receiveTimeout: const Duration(seconds: 60))) {
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
                  return h.resolve(await this.dio.fetch(req));
                } on DioException catch (e) {
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
  final Dio _auth; // no interceptors: refresh must not recurse into the queued error handler
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

  Future<void> _session(String path, Map<String, dynamic> body) async {
    try {
      final res = await _auth.post(path, data: {...body, 'client': 'app'});
      accessToken = res.data['access_token'] as String;
      await tokens.write(res.data['refresh_token'] as String);
    } catch (e) {
      throw toApiException(e);
    }
  }

  Future<void> register(String phone, String password, {String? name, String? referralCode}) => _session(
      '/auth/register', {'phone': phone, 'password': password, 'display_name': name, 'consent': true, if (referralCode != null) 'referral_code': referralCode});

  /// Forgotten password: the team is told and sends a temporary password on WhatsApp. Same answer for any number.
  Future<void> requestPasswordReset(String phone) async {
    try {
      await _auth.post('/auth/password-reset-request', data: {'phone': phone});
    } catch (e) {
      throw toApiException(e);
    }
  }

  Future<void> login(String phone, String password) => _session('/auth/login', {'phone': phone, 'password': password});

  Future<RefreshOutcome> refresh() => _inflight ??= _doRefresh().whenComplete(() => _inflight = null);

  Future<RefreshOutcome> _doRefresh() async {
    final token = await tokens.read();
    if (token == null) return RefreshOutcome.expired;
    try {
      final res = await _auth.post('/auth/refresh', data: {'refresh_token': token, 'client': 'app'});
      accessToken = res.data['access_token'] as String;
      await tokens.write(res.data['refresh_token'] as String);
      return RefreshOutcome.ok;
    } catch (e) {
      final ex = toApiException(e);
      if (ex.status == null) return RefreshOutcome.offline;
      accessToken = null;
      await tokens.write(null);
      return RefreshOutcome.expired;
    }
  }

  Future<void> logout() async {
    final token = await tokens.read();
    try {
      if (token != null) await _auth.post('/auth/logout', data: {'refresh_token': token, 'client': 'app'});
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

  Future<Me> changePhone(String phone) =>
      _call(() => dio.put('/me/phone', data: {'phone': phone}), (j) => Me.fromJson(j as Map<String, dynamic>));

  Future<Me> verifyPhone(String code) =>
      _call(() => dio.post('/me/verify-phone', data: {'code': code}), (j) => Me.fromJson(j as Map<String, dynamic>));

  Future<Me> setLocation(Location l) =>
      _call(() => dio.put('/me/location', data: l.toJson()), (j) => Me.fromJson(j as Map<String, dynamic>));

  Future<void> changePassword(String current, String next) => _call(
      () => dio.post('/me/password', data: {'current_password': current, 'new_password': next}), (_) {});

  Future<void> deleteMe() => _call(() => dio.delete('/me'), (_) {});

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
