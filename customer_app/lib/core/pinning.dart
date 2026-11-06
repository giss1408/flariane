import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';

import 'pinned_roots.dart';

/// Certificate pinning for the API connection.
///
/// The app trusts ONLY the root certificates in [pinnedRootsPem], not the phone's CA store. A CA installed
/// by the user or by malware (proxy, corporate or rogue root) therefore cannot intercept API traffic.
/// Roots are pinned rather than the server certificate because Render renews that one every ~60-90 days.
/// Hostname and expiry are still checked by the normal TLS verification.
///
/// If the host ever moves to a CA outside this list, installed apps stop connecting until updated:
/// add the new root to `pinned_roots.dart` and ship a release BEFORE switching the server.
HttpClientAdapter pinnedAdapter([List<String> rootsPem = pinnedRootsPem]) {
  return IOHttpClientAdapter(createHttpClient: () {
    final ctx = SecurityContext(withTrustedRoots: false);
    for (final pem in rootsPem) {
      ctx.setTrustedCertificatesBytes(utf8.encode(pem));
    }
    return HttpClient(context: ctx);
  });
}

/// Dio for [baseUrl]; pinned when it is https (local http development servers stay unpinned).
Dio newApiDio(String baseUrl) {
  final dio = Dio(BaseOptions(
      baseUrl: baseUrl,
      connectTimeout: const Duration(seconds: 60),
      receiveTimeout: const Duration(seconds: 60)));
  if (baseUrl.startsWith('https://')) dio.httpClientAdapter = pinnedAdapter();
  return dio;
}
