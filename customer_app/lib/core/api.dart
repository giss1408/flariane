import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../data/models.dart';
import 'format.dart';

class ApiException implements Exception {
  ApiException(this.status, this.code);

  final int? status;
  final String code;

  String get message =>
      status == null ? 'Pas de connexion. Vérifiez votre réseau.' : (errorMessages[code] ?? 'Une erreur est survenue.');
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

enum RefreshOutcome { ok, expired, offline }

/// Customer API. Access token in memory; refresh token in Keychain/Keystore, rotated on use.
class CustomerApi {
  CustomerApi({required String baseUrl, required this.tokens, Dio? dio, Dio? authDio})
      : dio = dio ?? Dio(BaseOptions(baseUrl: baseUrl, connectTimeout: const Duration(seconds: 15), receiveTimeout: const Duration(seconds: 60))),
        _auth = authDio ?? Dio(BaseOptions(baseUrl: baseUrl, connectTimeout: const Duration(seconds: 15))) {
    this.dio.interceptors.add(QueuedInterceptorsWrapper(
          onRequest: (o, h) {
            if (accessToken != null) o.headers['Authorization'] = 'Bearer $accessToken';
            h.next(o);
          },
          onError: (err, h) async {
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

  final Dio dio;
  final Dio _auth; // no interceptors: refresh must not recurse into the queued error handler
  final TokenStore tokens;
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

  Future<void> register(String phone, String password, {String? name}) =>
      _session('/auth/register', {'phone': phone, 'password': password, 'display_name': name});

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
  }

  // ---- account

  Future<Me> me() => _call(() => dio.get('/me'), (j) => Me.fromJson(j as Map<String, dynamic>));

  Future<Me> updateMe({String? name}) =>
      _call(() => dio.patch('/me', data: {'display_name': name}), (j) => Me.fromJson(j as Map<String, dynamic>));

  Future<Me> setLocation(Location l) =>
      _call(() => dio.put('/me/location', data: l.toJson()), (j) => Me.fromJson(j as Map<String, dynamic>));

  Future<void> changePassword(String current, String next) => _call(
      () => dio.post('/me/password', data: {'current_password': current, 'new_password': next}), (_) {});

  Future<void> deleteMe() => _call(() => dio.delete('/me'), (_) {});

  /// Public info (no auth): next departure, payment mode, Wave number.
  Future<Map<String, dynamic>> publicInfo() => _call(() => dio.get('/public/info'), (j) => j as Map<String, dynamic>);

  Future<DateTime?> nextDeparture() async {
    final v = (await publicInfo())['next_departure_date'] as String?;
    return v == null ? null : DateTime.parse(v);
  }

  String get waveQrUrl => '${dio.options.baseUrl}/public/wave-qr';

  Future<Payment> declarePayment(String ref) =>
      _call(() => dio.post('/orders/$ref/payment/declare'), (j) => Payment.fromJson(j as Map<String, dynamic>));

  // ---- orders

  Future<List<PickupPoint>> pickupPoints() => _call(() => dio.get('/pickup-points'),
      (j) => (j as List).cast<Map<String, dynamic>>().map(PickupPoint.fromJson).toList());

  Future<List<OrderSummary>> orders() => _call(
      () => dio.get('/orders'), (j) => (j as List).cast<Map<String, dynamic>>().map(OrderSummary.fromJson).toList());

  Future<Order> order(String ref) => _call(() => dio.get('/orders/$ref'), (j) => Order.fromJson(j as Map<String, dynamic>));

  Future<Order> createOrder({required String shareText, int? pickupPointId, String? note}) => _call(
      () => dio.post('/orders', data: {'share_text': shareText, 'pickup_point_id': pickupPointId, 'note': note}),
      (j) => Order.fromJson(j as Map<String, dynamic>));

  Future<void> uploadScreenshot(String ref, String path) => _call(
      () async => dio.post('/orders/$ref/attachments', data: FormData.fromMap({'file': await MultipartFile.fromFile(path)})),
      (_) {});

  Future<Payment> acceptQuote(String ref, int version) => _call(
      () => dio.post('/orders/$ref/quotes/$version/accept', data: {'sizes_confirmed': true}),
      (j) => Payment.fromJson(j as Map<String, dynamic>));

  Future<Payment> retryPayment(String ref) =>
      _call(() => dio.post('/orders/$ref/payment'), (j) => Payment.fromJson(j as Map<String, dynamic>));

  Future<void> requestChange(String ref, int version, Map<String, dynamic> body) =>
      _call(() => dio.post('/orders/$ref/quotes/$version/change-request', data: body), (_) {});

  Future<void> requote(String ref) => _call(() => dio.post('/orders/$ref/requote'), (_) {});

  Future<void> cancel(String ref) => _call(() => dio.post('/orders/$ref/cancel'), (_) {});
}
