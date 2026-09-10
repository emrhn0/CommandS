import 'package:flutter/material.dart';

/// CommandS palette — plain monochrome: white accent on near-black in dark
/// mode, black accent on near-white in light mode. No brand color riding on
/// top, so the two themes stay genuinely black/white rather than a tinted
/// version of one.
class AppColors {
  static const accentDark = Color(0xFFF2F2F2); // dark theme's accent (near-white)
  static const accentLight = Color(0xFF141414); // light theme's accent (near-black)

  // Dark mode
  static const darkBg = Color(0xFF0D0D0D);
  static const darkPanel = Color(0xFF161616);
  static const darkPanelAlt = Color(0xFF1F1F1F);
  static const darkBorder = Color(0xFF2C2C2C);
  static const darkText = Color(0xFFF2F2F2);
  static const darkTextDim = Color(0xFF8F8F8F);

  // Light mode
  static const lightBg = Color(0xFFFAFAFA);
  static const lightPanel = Color(0xFFFFFFFF);
  static const lightPanelAlt = Color(0xFFEFEFEF);
  static const lightBorder = Color(0xFFDCDCDC);
  static const lightText = Color(0xFF141414);
  static const lightTextDim = Color(0xFF6B6B6B);
}

class AppTheme {
  static ThemeData dark() {
    final scheme = ColorScheme.fromSeed(
      seedColor: Colors.grey,
      brightness: Brightness.dark,
      surface: AppColors.darkPanel,
      primary: AppColors.accentDark,
    );
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: scheme,
      scaffoldBackgroundColor: AppColors.darkBg,
      canvasColor: AppColors.darkPanel,
      dividerColor: AppColors.darkBorder,
      fontFamily: 'Segoe UI',
      textTheme: const TextTheme(
        bodyMedium: TextStyle(color: AppColors.darkText),
        bodySmall: TextStyle(color: AppColors.darkTextDim),
      ),
      inputDecorationTheme: InputDecorationTheme(
        isDense: true,
        filled: true,
        fillColor: AppColors.darkPanelAlt,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(2),
          borderSide: const BorderSide(color: AppColors.darkBorder),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(2),
          borderSide: const BorderSide(color: AppColors.darkBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(2),
          borderSide: const BorderSide(color: AppColors.accentDark, width: 1.4),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.accentDark,
          foregroundColor: AppColors.darkBg,
          elevation: 0,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(2)),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColors.accentDark,
          side: const BorderSide(color: AppColors.darkBorder),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(2)),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: AppColors.darkPanelAlt,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(2)),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: AppColors.darkPanel,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(2)),
      ),
    );
  }

  static ThemeData light() {
    final scheme = ColorScheme.fromSeed(
      seedColor: Colors.grey,
      brightness: Brightness.light,
      surface: AppColors.lightPanel,
      primary: AppColors.accentLight,
    );
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      colorScheme: scheme,
      scaffoldBackgroundColor: AppColors.lightBg,
      canvasColor: AppColors.lightPanel,
      dividerColor: AppColors.lightBorder,
      fontFamily: 'Segoe UI',
      textTheme: const TextTheme(
        bodyMedium: TextStyle(color: AppColors.lightText),
        bodySmall: TextStyle(color: AppColors.lightTextDim),
      ),
      inputDecorationTheme: InputDecorationTheme(
        isDense: true,
        filled: true,
        fillColor: AppColors.lightPanelAlt,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(2),
          borderSide: const BorderSide(color: AppColors.lightBorder),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(2),
          borderSide: const BorderSide(color: AppColors.lightBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(2),
          borderSide: const BorderSide(color: AppColors.accentLight, width: 1.4),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.accentLight,
          foregroundColor: AppColors.lightBg,
          elevation: 0,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(2)),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColors.accentLight,
          side: const BorderSide(color: AppColors.lightBorder),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(2)),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: AppColors.lightPanel,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(2)),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: AppColors.lightPanel,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(2)),
      ),
    );
  }
}
