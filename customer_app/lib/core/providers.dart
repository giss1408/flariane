import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models.dart';
import 'api.dart';
import 'response_cache.dart';

/// flutter run --dart-define=API_BASE_URL=https://api.flariane.ci  (emulator default: host machine)
/// Production server by default (store builds). Local dev: --dart-define=API_BASE_URL=http://10.0.2.2:8000
const apiBaseUrl = String.fromEnvironment('API_BASE_URL', defaultValue: 'https://flariane-api.regisse.com');

/// Platform `auth` service (SSO). Empty = the legacy flariane login. Local dev: --dart-define=AUTH_BASE_URL=http://10.0.2.2:8080
/// (the store build default becomes https://auth-api.regisse.com at the cutover).
const authBaseUrl = String.fromEnvironment('AUTH_BASE_URL');

final tokenStoreProvider = Provider<TokenStore>((_) => SecureTokenStore());
final apiProvider = Provider<CustomerApi>((ref) => CustomerApi(baseUrl: apiBaseUrl, authBaseUrl: authBaseUrl, tokens: ref.watch(tokenStoreProvider), cache: PrefsCache()));

/// activating = the account exists in auth but the number is not proven yet (code from the team on WhatsApp);
/// passwordChange = signed in with a temporary password: a new one must be chosen before anything else.
enum AuthStatus { loading, loggedOut, activating, passwordChange, loggedIn }

/// Phone and password typed at sign-up/login while the number is being activated (memory only, dropped on success).
final pendingLoginProvider = StateProvider<({String phone, String password})?>((_) => null);

final authProvider = NotifierProvider<AuthController, AuthStatus>(AuthController.new);

class AuthController extends Notifier<AuthStatus> {
  CustomerApi get _api => ref.read(apiProvider);

  @override
  AuthStatus build() {
    ref.read(apiProvider).onSessionExpired = () {
      ref.read(apiProvider).cache.clear();
      state = AuthStatus.loggedOut;
    };
    Future.microtask(_restore);
    return AuthStatus.loading;
  }

  Future<void> _restore() async {
    final outcome = await _api.refresh();
    if (outcome == RefreshOutcome.expired) {
      state = AuthStatus.loggedOut;
    } else if (_api.mustChangePassword) {
      state = AuthStatus.passwordChange; // the app was closed before she chose her new password
    } else {
      // Offline at start-up: stay logged in if a session exists; screens show the network error.
      state = AuthStatus.loggedIn;
    }
  }

  Future<void> _afterLogin(bool mustChange) async {
    if (mustChange) {
      state = AuthStatus.passwordChange;
      return;
    }
    await _api.applyPendingReferral();
    state = AuthStatus.loggedIn;
  }

  Future<void> login(String phone, String password) async {
    try {
      await _afterLogin(await _api.login(phone, password));
    } on ApiException catch (e) {
      if (_api.authMode && e.code == 'not_activated') {
        ref.read(pendingLoginProvider.notifier).state = (phone: phone, password: password);
        state = AuthStatus.activating;
        return;
      }
      rethrow;
    }
  }

  Future<void> register(String phone, String password, {String? name, String? referralCode}) async {
    await _api.register(phone, password, name: name, referralCode: referralCode);
    if (_api.authMode) {
      ref.read(pendingLoginProvider.notifier).state = (phone: phone, password: password);
      state = AuthStatus.activating;
    } else {
      state = AuthStatus.loggedIn;
    }
  }

  /// Enters the code the team sent on WhatsApp, then signs in with what she typed at sign-up.
  Future<void> activate(String code) async {
    final p = ref.read(pendingLoginProvider);
    if (p == null) return;
    await _api.activate(p.phone, code);
    ref.read(pendingLoginProvider.notifier).state = null;
    await _afterLogin(await _api.login(p.phone, p.password));
  }

  void cancelActivation() {
    ref.read(pendingLoginProvider.notifier).state = null;
    state = AuthStatus.loggedOut;
  }

  /// Called after the forced password change (auth): the session is clean now.
  Future<void> passwordChanged() async {
    await _api.applyPendingReferral();
    ref.invalidate(meProvider);
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
final nextDepartureProvider = FutureProvider.autoDispose<({DateTime departure, DateTime? deadline})?>((ref) => ref.watch(apiProvider).nextDeparture());
final publicInfoProvider = FutureProvider.autoDispose<Map<String, dynamic>>((ref) => ref.watch(apiProvider).publicInfo());

/// Offers the team switched on. A failure just means no banner: never block the home screen on it.
final offersProvider = FutureProvider.autoDispose<List<Offer>>((ref) async {
  try {
    final info = await ref.watch(publicInfoProvider.future);
    return [for (final o in (info['offers'] as List?) ?? const []) Offer.fromJson(o as Map<String, dynamic>)];
  } catch (_) {
    return const [];
  }
});
final legalDocsProvider = FutureProvider.autoDispose<List<LegalDoc>>((ref) => ref.watch(apiProvider).legalDocuments());
final legalDocProvider = FutureProvider.autoDispose.family<LegalDoc, String>((ref, slug) => ref.watch(apiProvider).legalDocument(slug));
final myDataProvider = FutureProvider.autoDispose<Map<String, dynamic>>((ref) => ref.watch(apiProvider).myData());
final loyaltyProvider = FutureProvider.autoDispose<Loyalty>((ref) => ref.watch(apiProvider).loyalty());
final meProvider = FutureProvider.autoDispose<Me>((ref) => ref.watch(apiProvider).me());

/// Text shared into the app from SHEIN (Partager → Flariane), waiting to prefill a new order.
final sharedTextProvider = StateProvider<String?>((_) => null);
