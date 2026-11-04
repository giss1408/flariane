import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Last good answer of a few read-only endpoints, shown when the phone has no connection.
/// Holds order data (items, prices, pickup point): cleared at logout and when the session ends.
abstract class ResponseCache {
  Future<dynamic> read(String key);
  Future<void> write(String key, dynamic json);
  Future<void> clear();
}

class NoCache implements ResponseCache {
  const NoCache();
  @override
  Future<dynamic> read(String key) async => null;
  @override
  Future<void> write(String key, dynamic json) async {}
  @override
  Future<void> clear() async {}
}

class MemoryCache implements ResponseCache {
  final _data = <String, dynamic>{};
  @override
  Future<dynamic> read(String key) async => _data[key];
  @override
  Future<void> write(String key, dynamic json) async => _data[key] = json;
  @override
  Future<void> clear() async => _data.clear();
}

class PrefsCache implements ResponseCache {
  static const _prefix = 'cache.';

  @override
  Future<dynamic> read(String key) async {
    try {
      final raw = (await SharedPreferences.getInstance()).getString('$_prefix$key');
      return raw == null ? null : jsonDecode(raw);
    } catch (_) {
      return null; // a damaged cache is just a miss
    }
  }

  @override
  Future<void> write(String key, dynamic json) async {
    try {
      await (await SharedPreferences.getInstance()).setString('$_prefix$key', jsonEncode(json));
    } catch (_) {}
  }

  @override
  Future<void> clear() async {
    try {
      final p = await SharedPreferences.getInstance();
      for (final k in p.getKeys().where((k) => k.startsWith(_prefix)).toList()) {
        await p.remove(k);
      }
    } catch (_) {}
  }
}
