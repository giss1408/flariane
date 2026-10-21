import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models.dart';
import 'api.dart';

/// flutter run --dart-define=API_BASE_URL=https://api.flariane.ci  (emulator default: host machine)
/// flutter run --dart-define=DEV_BYPASS_AUTH=true  → skips login (dev API only).
const devBypassAuth = bool.fromEnvironment('DEV_BYPASS_AUTH');

const apiBaseUrl = String.fromEnvironment('API_BASE_URL', defaultValue: 'http://10.0.2.2:8000');

final tokenStoreProvider = Provider<TokenStore>((_) => SecureTokenStore());
final apiProvider = Provider<CustomerApi>((ref) => CustomerApi(baseUrl: apiBaseUrl, tokens: ref.watch(tokenStoreProvider)));

enum AuthStatus { loading, loggedOut, loggedIn }

final authProvider = NotifierProvider<AuthController, AuthStatus>(AuthController.new);

class AuthController extends Notifier<AuthStatus> {
  CustomerApi get _api => ref.read(apiProvider);

  @override
  AuthStatus build() {
    ref.read(apiProvider).onSessionExpired = () => state = AuthStatus.loggedOut;
    Future.microtask(_restore);
    return AuthStatus.loading;
  }

  Future<void> _restore() async {
    if (devBypassAuth) {
      try {
        await _api.devLogin();
        state = AuthStatus.loggedIn;
        return;
      } catch (_) {/* fall through to normal login */}
    }
    final outcome = await _api.refresh();
    // Offline at start-up: stay logged in if a session exists; screens show the network error.
    state = outcome == RefreshOutcome.expired ? AuthStatus.loggedOut : AuthStatus.loggedIn;
  }

  Future<void> login(String phone, String password) async {
    await _api.login(phone, password);
    state = AuthStatus.loggedIn;
  }

  Future<void> register(String phone, String password, {String? name}) async {
    await _api.register(phone, password, name: name);
    state = AuthStatus.loggedIn;
  }

  Future<void> logout() async {
    await _api.logout();
    state = AuthStatus.loggedOut;
  }
}

final ordersProvider = FutureProvider.autoDispose<List<OrderSummary>>((ref) => ref.watch(apiProvider).orders());
final orderProvider = FutureProvider.autoDispose.family<Order, String>((ref, r) => ref.watch(apiProvider).order(r));
final pickupPointsProvider = FutureProvider.autoDispose<List<PickupPoint>>((ref) => ref.watch(apiProvider).pickupPoints());
final nextDepartureProvider = FutureProvider.autoDispose<DateTime?>((ref) => ref.watch(apiProvider).nextDeparture());
final meProvider = FutureProvider.autoDispose<Me>((ref) => ref.watch(apiProvider).me());

/// Text shared into the app from SHEIN (Partager → Flariane), waiting to prefill a new order.
final sharedTextProvider = StateProvider<String?>((_) => null);
