import 'package:dio/dio.dart';
import 'package:flariane/core/api.dart';
import 'package:flariane/core/response_cache.dart';
import 'package:flutter_test/flutter_test.dart';

/// Answers from a script: a JSON body, a no-network failure, or an HTTP error.
class _Adapter implements HttpClientAdapter {
  _Adapter(this.next);
  Object? Function() next;

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<List<int>>? body, Future<void>? cancel) async {
    final r = next();
    if (r == 'offline') throw DioException.connectionError(requestOptions: options, reason: 'offline');
    if (r is int) return ResponseBody.fromString('{"detail":"boom"}', r, headers: {Headers.contentTypeHeader: ['application/json']});
    return ResponseBody.fromString(r as String, 200, headers: {Headers.contentTypeHeader: ['application/json']});
  }

  @override
  void close({bool force = false}) {}
}

const _list = '[{"public_ref":"FLR-ABCDE","status":"QUOTED","store":"SHEIN","total_xof":1000,"created_at":"2026-10-21T10:00:00Z","status_changed_at":"2026-10-21T10:00:00Z"}]';

void main() {
  CustomerApi build(_Adapter a, ResponseCache cache) {
    final dio = Dio(BaseOptions(baseUrl: 'http://x'))..httpClientAdapter = a;
    return CustomerApi(baseUrl: 'http://x', tokens: MemoryTokenStore(), cache: cache, dio: dio, authDio: Dio());
  }

  test('offline: the last good order list comes back', () async {
    var step = 0;
    final answers = <Object>[_list, 'offline'];
    final api = build(_Adapter(() => answers[step++]), MemoryCache());
    expect((await api.orders()).single.ref, 'FLR-ABCDE');
    expect((await api.orders()).single.ref, 'FLR-ABCDE'); // no connection: cached copy
  });

  test('offline with nothing saved is still an error', () async {
    final api = build(_Adapter(() => 'offline'), MemoryCache());
    await expectLater(api.orders(), throwsA(isA<ApiException>().having((e) => e.status, 'status', null)));
  });

  test('a server error is not hidden by the cache', () async {
    var step = 0;
    final answers = <Object>[_list, 500];
    final api = build(_Adapter(() => answers[step++]), MemoryCache());
    await api.orders();
    await expectLater(api.orders(), throwsA(isA<ApiException>().having((e) => e.status, 'status', 500)));
  });

  test('logout clears the cache', () async {
    final cache = MemoryCache();
    await cache.write('orders', [1]);
    final api = build(_Adapter(() => 200), cache);
    await api.logout();
    expect(await cache.read('orders'), isNull);
  });
}
