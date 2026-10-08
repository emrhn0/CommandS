import 'dart:io';

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

/// Corner radius shared by menus, dialogs, fields and buttons, so every
/// surface in the app has the same desktop shape as the context menu.
const double kControlRadius = 6;

class AppTheme {
  static ThemeData dark() => _build(
    brightness: Brightness.dark,
    accent: AppColors.accentDark,
    onAccent: AppColors.darkBg,
    bg: AppColors.darkBg,
    panel: AppColors.darkPanel,
    panelAlt: AppColors.darkPanelAlt,
    border: AppColors.darkBorder,
    text: AppColors.darkText,
    textDim: AppColors.darkTextDim,
    // Fields sit a step darker than the dialog in dark mode, a step
    // lighter in light mode: either way, recessed into it.
    field: const Color(0xFF111111),
    overlay: Colors.white,
  );

  static ThemeData light() => _build(
    brightness: Brightness.light,
    accent: AppColors.accentLight,
    onAccent: AppColors.lightBg,
    bg: AppColors.lightBg,
    panel: AppColors.lightPanel,
    panelAlt: AppColors.lightPanelAlt,
    border: AppColors.lightBorder,
    text: AppColors.lightText,
    textDim: AppColors.lightTextDim,
    field: AppColors.lightBg,
    overlay: Colors.black,
  );

  static ThemeData _build({
    required Brightness brightness,
    required Color accent,
    required Color onAccent,
    required Color bg,
    required Color panel,
    required Color panelAlt,
    required Color border,
    required Color text,
    required Color textDim,
    required Color field,
    required Color overlay,
  }) {
    final dark = brightness == Brightness.dark;
    final scheme = ColorScheme.fromSeed(
      seedColor: Colors.grey,
      brightness: brightness,
      surface: panel,
      primary: accent,
    );
    final radius = BorderRadius.circular(kControlRadius);
    final shape = RoundedRectangleBorder(borderRadius: radius);
    // The neutral highlight the connection tree uses for hover and selection.
    final hover = overlay.withValues(alpha: dark ? 0.06 : 0.04);
    final selected = overlay.withValues(alpha: dark ? 0.11 : 0.075);
    // The family is spelled out: a button's textStyle replaces the theme's
    // text style outright, so leaving it off drops the button onto Roboto.
    final buttonText = TextStyle(fontFamily: _uiFontFamily, fontSize: 13, fontWeight: FontWeight.w500);
    const buttonPadding = EdgeInsets.symmetric(horizontal: 16, vertical: 10);
    const buttonSize = Size(0, 34);

    OutlineInputBorder outline(Color c, [double w = 1]) => OutlineInputBorder(
      borderRadius: radius,
      borderSide: BorderSide(color: c, width: w),
    );

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: bg,
      canvasColor: panel,
      dividerColor: border,
      hoverColor: hover,
      fontFamily: _uiFontFamily,
      textTheme: TextTheme(
        // What text fields type in: desktop size, not Material's 16.
        bodyLarge: TextStyle(fontSize: 14, color: text),
        bodyMedium: TextStyle(color: text),
        bodySmall: TextStyle(color: textDim),
      ),
      dividerTheme: DividerThemeData(color: border, thickness: 1, space: 1),
      inputDecorationTheme: InputDecorationTheme(
        isDense: true,
        filled: true,
        fillColor: field,
        hoverColor: hover,
        border: outline(border),
        enabledBorder: outline(border),
        disabledBorder: outline(border.withValues(alpha: 0.5)),
        focusedBorder: outline(accent, 1.4),
        hintStyle: TextStyle(fontSize: 13, color: textDim.withValues(alpha: 0.8)),
        labelStyle: TextStyle(fontSize: 13, color: textDim),
        floatingLabelStyle: TextStyle(color: textDim),
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        // Material reserves 48x48 for a suffix icon, which made fields with
        // one (password, folder) taller than the rest.
        suffixIconConstraints: const BoxConstraints(minWidth: 34, minHeight: 30),
      ),
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: accent,
        selectionColor: overlay.withValues(alpha: 0.18),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: accent,
          foregroundColor: onAccent,
          elevation: 0,
          shape: shape,
          padding: buttonPadding,
          minimumSize: buttonSize,
          textStyle: buttonText,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: accent,
          foregroundColor: onAccent,
          shape: shape,
          padding: buttonPadding,
          minimumSize: buttonSize,
          textStyle: buttonText,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: accent,
          backgroundColor: panel,
          side: BorderSide(color: border),
          shape: shape,
          padding: buttonPadding,
          minimumSize: buttonSize,
          textStyle: buttonText,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: text,
          shape: shape,
          padding: buttonPadding,
          minimumSize: buttonSize,
          textStyle: buttonText,
        ),
      ),
      iconButtonTheme: IconButtonThemeData(style: IconButton.styleFrom(shape: shape)),
      // The protocol switch in the connection dialog: a neutral grey for the
      // chosen side, like a selected tree row, not Material's tinted fill.
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          shape: WidgetStatePropertyAll(shape),
          side: WidgetStatePropertyAll(BorderSide(color: border)),
          textStyle: WidgetStatePropertyAll(buttonText),
          minimumSize: const WidgetStatePropertyAll(buttonSize),
          visualDensity: VisualDensity.compact,
          foregroundColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.selected) ? text : textDim,
          ),
          backgroundColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.selected) ? selected : panel,
          ),
          overlayColor: WidgetStatePropertyAll(hover),
        ),
      ),
      switchTheme: SwitchThemeData(
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        thumbColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? onAccent : textDim,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? accent : panelAlt,
        ),
        trackOutlineColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? accent : border,
        ),
      ),
      checkboxTheme: CheckboxThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(3)),
        side: BorderSide(color: textDim, width: 1.4),
        fillColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? accent : Colors.transparent,
        ),
        checkColor: WidgetStatePropertyAll(onAccent),
      ),
      radioTheme: RadioThemeData(
        fillColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? accent : textDim,
        ),
      ),
      listTileTheme: ListTileThemeData(
        shape: shape,
        selectedColor: text,
        selectedTileColor: selected,
        iconColor: text,
      ),
      tooltipTheme: TooltipThemeData(
        textStyle: TextStyle(fontSize: 12, color: text),
        decoration: BoxDecoration(
          color: panel,
          borderRadius: radius,
          border: Border.all(color: border),
          boxShadow: [
            BoxShadow(color: Colors.black.withValues(alpha: 0.15), blurRadius: 8, offset: const Offset(0, 2)),
          ],
        ),
        waitDuration: const Duration(milliseconds: 500),
      ),
      // Desktop-style menus everywhere: compact text, a hairline border and a
      // real shadow, rather than Material's flat touch-sized sheet.
      popupMenuTheme: PopupMenuThemeData(
        color: dark ? AppColors.darkPanelAlt : panel,
        elevation: 8,
        surfaceTintColor: Colors.transparent,
        textStyle: TextStyle(fontSize: 13, color: text),
        shape: RoundedRectangleBorder(
          borderRadius: radius,
          side: BorderSide(color: border),
        ),
      ),
      // Dialogs match the menus: same corners, same hairline edge and soft
      // shadow, over a light scrim instead of Material's heavy grey.
      dialogTheme: DialogThemeData(
        backgroundColor: panel,
        surfaceTintColor: Colors.transparent,
        elevation: 16,
        shadowColor: Colors.black.withValues(alpha: dark ? 0.6 : 0.3),
        barrierColor: Colors.black.withValues(alpha: dark ? 0.45 : 0.22),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(color: border),
        ),
        titleTextStyle: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: text),
        contentTextStyle: TextStyle(fontSize: 13, color: text),
      ),
      snackBarTheme: SnackBarThemeData(behavior: SnackBarBehavior.floating, shape: shape, width: 420),
    );
  }
}

/// Segoe UI does not exist on a Mac, and asking for a missing family drops
/// the whole app onto Flutter's bundled fallback rather than the system
/// face. Leaving it null on macOS is what picks up SF Pro.
final String? _uiFontFamily = Platform.isMacOS ? null : 'Segoe UI';
