import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';

import 'core/providers.dart';
import 'core/theme.dart';
import 'features/auth/login_screen.dart';
import 'features/auth/verify_phone_screen.dart';
import 'features/orders/home_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Fonts ship with the app (assets/google_fonts): never download them over mobile data.
  GoogleFonts.config.allowRuntimeFetching = false;
  LicenseRegistry.addLicense(() async* {
    for (final f in ['OFL-BricolageGrotesque.txt', 'OFL-DMSans.txt']) {
      yield LicenseEntryWithLineBreaks([f.split('-').last.replaceAll('.txt', '')], await rootBundle.loadString('assets/google_fonts/$f'));
    }
  });
  await initializeDateFormatting('fr');
  runApp(const ProviderScope(child: FlarianeApp()));
}

class FlarianeApp extends ConsumerStatefulWidget {
  const FlarianeApp({super.key});

  @override
  ConsumerState<FlarianeApp> createState() => _FlarianeAppState();
}

class _FlarianeAppState extends ConsumerState<FlarianeApp> {
  StreamSubscription<List<SharedMediaFile>>? _shares;

  @override
  void initState() {
    super.initState();
    // "Partager → Flariane" from the SHEIN app: the shared text carries the cart link.
    void take(List<SharedMediaFile> files) {
      final text = files.where((f) => f.type == SharedMediaType.text || f.type == SharedMediaType.url).map((f) => f.path).join(' ');
      if (text.isNotEmpty) ref.read(sharedTextProvider.notifier).state = text;
    }

    try {
      _shares = ReceiveSharingIntent.instance.getMediaStream().listen(take);
      ReceiveSharingIntent.instance.getInitialMedia().then((files) {
        take(files);
        ReceiveSharingIntent.instance.reset();
      });
    } catch (_) {
      // Platform without share support (tests, desktop).
    }
  }

  @override
  void dispose() {
    _shares?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);
    return MaterialApp(
      title: 'Flariane',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      themeMode: ThemeMode.light, // the bissap & blush palette is designed for light backgrounds
      locale: const Locale('fr'),
      supportedLocales: const [Locale('fr'), Locale('en')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: switch (auth) {
        AuthStatus.loading => const Scaffold(body: Center(child: CircularProgressIndicator())),
        AuthStatus.loggedOut => const LoginScreen(),
        AuthStatus.loggedIn => const _PasswordGate(),
      },
    );
  }
}

/// Gates before the home screen: forced password change (after an admin reset), then phone verification.
class _PasswordGate extends ConsumerWidget {
  const _PasswordGate();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(meProvider).valueOrNull;
    if (me?.mustChangePassword == true) return const ChangePasswordScreen(forced: true);
    if (me != null && !me.phoneVerified) return VerifyPhoneScreen(phoneMasked: me.phoneMasked, rejected: me.phoneRejected);
    return const HomeScreen();
  }
}
