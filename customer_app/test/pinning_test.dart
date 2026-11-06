import 'package:dio/io.dart';
import 'package:flariane/core/pinned_roots.dart';
import 'package:flariane/core/pinning.dart';
import 'package:flutter_test/flutter_test.dart';

IOHttpClientAdapter _io(dynamic dio) => dio.httpClientAdapter as IOHttpClientAdapter;

void main() {
  test('every bundled root parses as a certificate', () {
    expect(pinnedRootsPem, isNotEmpty);
    // The client is built lazily; building it fails if any PEM is invalid.
    expect(_io(newApiDio('https://flariane-api.regisse.com')).createHttpClient!(), isNotNull);
  });

  test('https gets the pinned client, local http keeps the default one', () {
    expect(_io(newApiDio('https://flariane-api.regisse.com')).createHttpClient, isNotNull);
    expect(_io(newApiDio('http://10.0.2.2:8000')).createHttpClient, isNull);
  });
}
