import 'dart:async';

import 'package:dio/dio.dart';

import 'format.dart';

class ApiException implements Exception {
  ApiException(this.status, this.code, [this.detail]);

  final int? status;
  final String code;
  final String? detail;

  String get message {
    if (code == 'unknown') return 'Erreur inattendue : ${detail ?? ''}';
    if (status == null) return 'Connexion impossible (serveur injoignable ou en train de démarrer). Réessayez dans une minute.';
    return errorMessages[code] ?? 'Erreur ($code).';
  }

  @override
  String toString() => 'ApiException($status, $code, $detail)';
}

ApiException toApiException(Object e) {
  if (e is ApiException) return e;
  if (e is DioException) {
    final res = e.response;
    if (res == null) return ApiException(null, 'network');
    final data = res.data;
    var code = 'http_${res.statusCode}';
    String? detail;
    if (data is Map && data['detail'] is String) code = data['detail'] as String;
    if (data is Map && data['message'] is String) detail = data['message'] as String;
    if (data is Map && data['detail'] is List) code = 'validation_error';
    return ApiException(res.statusCode, code, detail);
  }
  return ApiException(null, 'unknown', e.toString());
}

enum RefreshOutcome { ok, expired, offline }

/// Dio wrapper: attaches the short-lived access token and refreshes it once on 401.
class ApiClient {
  ApiClient({required String baseUrl, Dio? dio})
      : dio = dio ??
            Dio(BaseOptions(
              baseUrl: baseUrl,
              // Free hosting sleeps when idle and can take ~1 min to wake up.
              connectTimeout: const Duration(seconds: 60),
              receiveTimeout: const Duration(seconds: 60),
              contentType: 'application/json',
            )) {
    this.dio.interceptors.add(QueuedInterceptorsWrapper(
          onRequest: (options, handler) {
            final token = accessToken;
            if (token != null && !_isAuthCall(options.path)) {
              options.headers['Authorization'] = 'Bearer $token';
            }
            handler.next(options);
          },
          onError: (error, handler) async {
            final req = error.requestOptions;
            if (error.response?.statusCode == 401 && !_isAuthCall(req.path) && req.extra['retried'] != true) {
              final outcome = await _refreshOnce();
              if (outcome == RefreshOutcome.ok) {
                req.extra['retried'] = true;
                req.headers['Authorization'] = 'Bearer $accessToken';
                try {
                  return handler.resolve(await this.dio.fetch(req));
                } on DioException catch (e) {
                  return handler.next(e);
                }
              }
              // Offline: keep the session, surface the network error to the screen.
              if (outcome == RefreshOutcome.expired) onSessionExpired?.call();
            }
            handler.next(error);
          },
        ));
  }

  final Dio dio;
  String? accessToken;

  /// Set by the session: performs the refresh-token exchange.
  Future<RefreshOutcome> Function()? refresher;
  void Function()? onSessionExpired;
  Future<RefreshOutcome>? _inflight;

  static bool _isAuthCall(String path) =>
      path.startsWith('/admin/auth/login') || path.startsWith('/admin/auth/refresh');

  Future<RefreshOutcome> _refreshOnce() {
    final r = refresher;
    if (r == null) return Future.value(RefreshOutcome.expired);
    return _inflight ??= r().catchError((_) => RefreshOutcome.offline).whenComplete(() => _inflight = null);
  }

  Future<T> call<T>(Future<Response<dynamic>> Function(Dio d) request, T Function(dynamic data) parse) async {
    try {
      final res = await request(dio);
      return parse(res.data);
    } catch (e) {
      throw toApiException(e);
    }
  }
}
