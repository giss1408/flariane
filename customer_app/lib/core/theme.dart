import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// "Bissap & wax": hibiscus red, plum ink, mango, lagoon mint on blush.
class AppColors {
  static const primary = Color(0xFFB5164F); // bissap
  static const plum = Color(0xFF2B0F2E); // ink
  static const mango = Color(0xFFFFB020);
  static const mint = Color(0xFF38D6AE); // Ébrié lagoon
  static const blush = Color(0xFFFFF3F7);
  static const lilac = Color(0xFFEADCF8);

  static const text = plum;
  static const muted = Color(0xFF7A5C7E);
  static const warning = Color(0xFFB86E00);
  static const warningBg = Color(0xFFFFF1D6);
  static const danger = Color(0xFFC62828);
  static const success = Color(0xFF0E8F6E);
}

TextStyle display(double size, {Color? color, FontWeight weight = FontWeight.w800}) =>
    GoogleFonts.bricolageGrotesque(fontSize: size, fontWeight: weight, color: color, height: 1.05, letterSpacing: -0.5);

ThemeData buildTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final scheme = ColorScheme.fromSeed(
    seedColor: AppColors.primary,
    brightness: brightness,
    primary: dark ? const Color(0xFFFF6F9C) : AppColors.primary,
    secondary: AppColors.mango,
    tertiary: AppColors.mint,
    surface: dark ? const Color(0xFF1E0D20) : AppColors.blush,
  );
  final base = ThemeData(colorScheme: scheme, useMaterial3: true, brightness: brightness);
  final body = GoogleFonts.dmSansTextTheme(base.textTheme).apply(
    bodyColor: dark ? Colors.white : AppColors.plum,
    displayColor: dark ? Colors.white : AppColors.plum,
  );
  final card = dark ? const Color(0xFF2A1430) : Colors.white;
  return base.copyWith(
    scaffoldBackgroundColor: dark ? const Color(0xFF1E0D20) : AppColors.blush,
    textTheme: body.copyWith(
      headlineMedium: display(30, color: dark ? Colors.white : AppColors.plum),
      titleLarge: display(22, color: dark ? Colors.white : AppColors.plum, weight: FontWeight.w700),
      bodyMedium: body.bodyMedium?.copyWith(fontSize: 15, height: 1.45),
      bodyLarge: body.bodyLarge?.copyWith(fontSize: 16, height: 1.45),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: dark ? const Color(0xFF1E0D20) : AppColors.blush,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(54),
        textStyle: GoogleFonts.dmSans(fontSize: 16, fontWeight: FontWeight.w700),
        shape: const StadiumBorder(),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size.fromHeight(50),
        shape: const StadiumBorder(),
        side: BorderSide(color: scheme.primary, width: 1.5),
        textStyle: GoogleFonts.dmSans(fontSize: 15, fontWeight: FontWeight.w700),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: card,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(18), borderSide: BorderSide.none),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(18),
        borderSide: BorderSide(color: dark ? Colors.white12 : AppColors.lilac, width: 1.5),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(18),
        borderSide: BorderSide(color: scheme.primary, width: 2),
      ),
    ),
    cardTheme: CardTheme(
      elevation: 0,
      color: card,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
    ),
    chipTheme: base.chipTheme.copyWith(shape: const StadiumBorder(), side: BorderSide.none),
  );
}
