import 'package:flutter/material.dart';

class AppTheme {
  static const Color background = Color(0xFF080B14);
  static const Color surface = Color(0xFF111726);
  static const Color surfaceHigh = Color(0xFF182033);
  static const Color accent = Color(0xFF54E6C0);
  static const Color accentAlt = Color(0xFF8C7BFF);
  static const Color muted = Color(0xFF8C95AA);

  static ThemeData dark() {
    final scheme =
        ColorScheme.fromSeed(
          seedColor: accent,
          brightness: Brightness.dark,
        ).copyWith(
          primary: accent,
          onPrimary: const Color(0xFF00382C),
          secondary: accentAlt,
          surface: surface,
          onSurface: Colors.white,
        );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: background,
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
        foregroundColor: Colors.white,
      ),
      snackBarTheme: const SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: surfaceHigh,
        contentTextStyle: TextStyle(color: Colors.white),
      ),
      dividerTheme: DividerThemeData(
        color: Colors.white.withValues(alpha: 0.08),
      ),
      listTileTheme: const ListTileThemeData(
        iconColor: accent,
        textColor: Colors.white,
      ),
    );
  }
}
