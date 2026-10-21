import 'package:flariane_admin/core/api_client.dart';
import 'package:flariane_admin/core/secure_store.dart';
import 'package:flariane_admin/core/session.dart';
import 'package:flariane_admin/data/admin_api.dart';
import 'package:flariane_admin/data/models.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class MockApi extends Mock implements AdminApi {}

class FakeUnlocker implements DeviceUnlocker {
  bool allow = true;

  @override
  Future<bool> unlock() async => allow;
}

final me = AdminMe(id: 1, email: 'a@flariane.ci', name: 'Admin', role: 'OPERATOR', deviceId: 7);

void main() {
  late MockApi api;
  late MemorySecureStore store;
  late FakeUnlocker unlocker;
  late ApiClient client;
  late ProviderContainer container;

  setUp(() {
    api = MockApi();
    store = MemorySecureStore();
    unlocker = FakeUnlocker();
    client = ApiClient(baseUrl: 'http://test');
    container = ProviderContainer(overrides: [
      adminApiProvider.overrideWithValue(api),
      secureStoreProvider.overrideWithValue(store),
      unlockerProvider.overrideWithValue(unlocker),
      apiClientProvider.overrideWithValue(client),
    ]);
    addTearDown(container.dispose);
  });

  Future<SessionState> settle() async {
    container.read(sessionProvider);
    await Future<void>.delayed(Duration.zero);
    return container.read(sessionProvider);
  }

  void stubLogin(LoginResult result) {
    when(() => api.login(
          email: any(named: 'email'),
          password: any(named: 'password'),
          totp: any(named: 'totp'),
          deviceName: any(named: 'deviceName'),
          platform: any(named: 'platform'),
          deviceId: any(named: 'deviceId'),
          deviceSecret: any(named: 'deviceSecret'),
        )).thenAnswer((_) async => result);
  }

  test('starts logged out without a refresh token', () async {
    expect((await settle()).status, SessionStatus.loggedOut);
  });

  test('new device: secret is stored and the session waits for approval', () async {
    await settle();
    stubLogin(LoginResult(status: 'device_pending', deviceId: 7, deviceSecret: 'sekret'));
    await container.read(sessionProvider.notifier).login(email: 'A@Flariane.ci ', password: 'pw', totp: '123456');
    expect(container.read(sessionProvider).status, SessionStatus.devicePending);
    expect(store.values[Keys.deviceId], '7');
    expect(store.values[Keys.deviceSecret], 'sekret');
    expect(store.values[Keys.email], 'a@flariane.ci');
    expect(store.values.containsKey(Keys.refreshToken), isFalse);
  });

  test('approved device: login stores refresh token and loads the admin', () async {
    store.values[Keys.deviceId] = '7';
    store.values[Keys.deviceSecret] = 'sekret';
    await settle();
    stubLogin(LoginResult(status: 'ok', deviceId: 7, accessToken: 'access', refreshToken: 'refresh'));
    when(() => api.me()).thenAnswer((_) async => me);
    await container.read(sessionProvider.notifier).login(email: 'a@flariane.ci', password: 'pw', totp: '123456');
    final captured = verify(() => api.login(
          email: any(named: 'email'),
          password: any(named: 'password'),
          totp: any(named: 'totp'),
          deviceName: any(named: 'deviceName'),
          platform: any(named: 'platform'),
          deviceId: captureAny(named: 'deviceId'),
          deviceSecret: captureAny(named: 'deviceSecret'),
        )).captured;
    expect(captured, [7, 'sekret']);
    expect(container.read(sessionProvider).status, SessionStatus.loggedIn);
    expect(client.accessToken, 'access');
    expect(store.values[Keys.refreshToken], 'refresh');
  });

  test('cold start with a session requires unlock, then refreshes', () async {
    store.values.addAll({Keys.deviceId: '7', Keys.deviceSecret: 'sekret', Keys.refreshToken: 'r1'});
    expect((await settle()).status, SessionStatus.locked);

    when(() => api.refresh(refreshToken: 'r1', deviceId: 7, deviceSecret: 'sekret')).thenAnswer((_) async => Tokens('a2', 'r2'));
    when(() => api.me()).thenAnswer((_) async => me);

    unlocker.allow = false;
    expect(await container.read(sessionProvider.notifier).unlock(), isFalse);
    expect(container.read(sessionProvider).status, SessionStatus.locked);

    unlocker.allow = true;
    expect(await container.read(sessionProvider.notifier).unlock(), isTrue);
    expect(container.read(sessionProvider).status, SessionStatus.loggedIn);
    expect(store.values[Keys.refreshToken], 'r2');
  });

  test('offline refresh keeps the session locked instead of logging out', () async {
    store.values.addAll({Keys.deviceId: '7', Keys.deviceSecret: 'sekret', Keys.refreshToken: 'r1'});
    await settle();
    when(() => api.refresh(refreshToken: any(named: 'refreshToken'), deviceId: any(named: 'deviceId'), deviceSecret: any(named: 'deviceSecret')))
        .thenThrow(ApiException(null, 'network'));
    expect(await container.read(sessionProvider.notifier).unlock(), isFalse);
    expect(container.read(sessionProvider).status, SessionStatus.locked);
    expect(store.values[Keys.refreshToken], 'r1');
  });

  test('revoked device: refresh fails, device credentials are forgotten', () async {
    store.values.addAll({Keys.deviceId: '7', Keys.deviceSecret: 'sekret', Keys.refreshToken: 'r1'});
    await settle();
    when(() => api.refresh(refreshToken: any(named: 'refreshToken'), deviceId: any(named: 'deviceId'), deviceSecret: any(named: 'deviceSecret')))
        .thenThrow(ApiException(401, 'device_invalid'));
    expect(await container.read(sessionProvider.notifier).unlock(), isFalse);
    expect(container.read(sessionProvider).status, SessionStatus.loggedOut);
    expect(store.values.containsKey(Keys.deviceSecret), isFalse);
    expect(store.values.containsKey(Keys.refreshToken), isFalse);
  });

  test('lock only applies to a logged-in session', () async {
    await settle();
    container.read(sessionProvider.notifier).lock();
    expect(container.read(sessionProvider).status, SessionStatus.loggedOut);
  });
}
