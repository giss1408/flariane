import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'core/app_lock.dart';
import 'core/push.dart';
import 'core/session.dart';
import 'core/theme.dart';
import 'features/account/account_screen.dart';
import 'features/auth/auth_screens.dart';
import 'features/inbox/inbox_screen.dart';
import 'features/order/order_screen.dart';
import 'features/pickup/pickup_desk_screen.dart';
import 'features/shipments/shipments_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('fr');
  await PushService.init();
  runApp(const ProviderScope(child: FlarianeAdminApp()));
}

final navigatorKey = GlobalKey<NavigatorState>();

class FlarianeAdminApp extends ConsumerStatefulWidget {
  const FlarianeAdminApp({super.key});

  @override
  ConsumerState<FlarianeAdminApp> createState() => _FlarianeAdminAppState();
}

class _FlarianeAdminAppState extends ConsumerState<FlarianeAdminApp> {
  late final AppLockObserver _lock = AppLockObserver(ref);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(_lock);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(_lock);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(sessionProvider, (prev, next) {
      if (next.status == SessionStatus.loggedIn && prev?.status != SessionStatus.loggedIn) {
        PushService.register(ref.read(adminApiProvider), (orderId) {
          navigatorKey.currentState?.push(MaterialPageRoute(builder: (_) => OrderScreen(orderId: orderId)));
        });
      }
    });
    return MaterialApp(
      title: 'Flariane Admin',
      navigatorKey: navigatorKey,
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      locale: const Locale('fr'),
      supportedLocales: const [Locale('fr'), Locale('en')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: const AuthGate(),
    );
  }
}

class AuthGate extends ConsumerWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(sessionProvider.select((s) => s.status));
    return switch (status) {
      SessionStatus.loading => const Scaffold(body: Center(child: CircularProgressIndicator())),
      SessionStatus.loggedOut => const LoginScreen(),
      SessionStatus.devicePending => const DevicePendingScreen(),
      SessionStatus.locked => const LockScreen(),
      SessionStatus.loggedIn => const HomeShell(),
    };
  }
}

class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    // Pickup agents only get the pickup desk and their account.
    if (ref.watch(sessionProvider).me?.isPickupAgent ?? false) {
      return Scaffold(
        body: IndexedStack(index: _index, children: const [PickupDeskScreen(), AccountScreen()]),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _index,
          onDestinationSelected: (i) => setState(() => _index = i),
          destinations: const [
            NavigationDestination(icon: Icon(Icons.storefront_outlined), selectedIcon: Icon(Icons.storefront), label: 'Retraits'),
            NavigationDestination(icon: Icon(Icons.person_outline), selectedIcon: Icon(Icons.person), label: 'Compte'),
          ],
        ),
      );
    }
    return _fullShell();
  }

  Widget _fullShell() => Scaffold(
        body: IndexedStack(index: _index, children: const [InboxScreen(), ShipmentsScreen(), AccountScreen()]),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _index,
          onDestinationSelected: (i) => setState(() => _index = i),
          destinations: const [
            NavigationDestination(icon: Icon(Icons.receipt_long_outlined), selectedIcon: Icon(Icons.receipt_long), label: 'Commandes'),
            NavigationDestination(icon: Icon(Icons.local_shipping_outlined), selectedIcon: Icon(Icons.local_shipping), label: 'Expéditions'),
            NavigationDestination(icon: Icon(Icons.person_outline), selectedIcon: Icon(Icons.person), label: 'Compte'),
          ],
        ),
      );
}
