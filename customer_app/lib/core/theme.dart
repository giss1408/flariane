import 'package:flutter/material.dart';

/// Calm, trustworthy palette: deep teal primary, distinct from Wave's light blue.
class AppColors {
  static const primary = Color(0xFF0F5F5C);
  static const primaryDark = Color(0xFF4FB3AD);
  static const text = Color(0xFF1F2933);
  static const muted = Color(0xFF5F6B76);
  static const surface = Color(0xFFF6F8F8);
  static const warning = Color(0xFFB45309);
  static const warningBg = Color(0xFFFFF4E5);
  static const danger = Color(0xFFB42318);
  static const success = Color(0xFF067647);
}

ThemeData buildTheme(Brightness brightness) {
  final isDark = brightness == Brightness.dark;
  final scheme = ColorScheme.fromSeed(
    seedColor: AppColors.primary,
    brightness: brightness,
    primary: isDark ? AppColors.primaryDark : AppColors.primary,
  );
  final base = ThemeData(colorScheme: scheme, useMaterial3: true, brightness: brightness);
  return base.copyWith(
    scaffoldBackgroundColor: isDark ? const Color(0xFF111615) : AppColors.surface,
    textTheme: base.textTheme.apply(
      bodyColor: isDark ? Colors.white : AppColors.text,
      displayColor: isDark ? Colors.white : AppColors.text,
    ).copyWith(
      bodyMedium: base.textTheme.bodyMedium?.copyWith(fontSize: 15, height: 1.45),
      bodyLarge: base.textTheme.bodyLarge?.copyWith(fontSize: 16, height: 1.45),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(52),
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size.fromHeight(48),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
      filled: true,
      fillColor: isDark ? const Color(0xFF1B2221) : Colors.white,
    ),
    cardTheme: CardTheme(
      elevation: 0,
      color: isDark ? const Color(0xFF1B2221) : Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: isDark ? Colors.white12 : const Color(0xFFE3E8E8)),
      ),
      margin: EdgeInsets.zero,
    ),
  );
}
