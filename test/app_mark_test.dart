import 'dart:io';

import 'package:commands/providers/app_state.dart';
import 'package:commands/theme/app_mark.dart';
import 'package:commands/theme/app_theme.dart';
import 'package:commands/theme/theme_presets.dart';
import 'package:commands/widgets/custom_title_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      (call) async => call.method == 'isMaximized' ? false : null,
    );
  });

  Future<void> pumpBar(WidgetTester tester, ThemeData theme) async {
    await tester.pumpWidget(MaterialApp(
      theme: theme,
      home: const Scaffold(body: Column(children: [CustomTitleBar()])),
    ));
    await tester.pump();
  }

  ThemePreset preset(String id) => builtInThemes.firstWhere((t) => t.id == id);
  AppPalette paletteOf(ThemePreset p) => AppTheme.fromPreset(p).extension<AppPalette>()!;

  void near(Color actual, int expected, String what) {
    final e = Color(0xFF000000 | expected);
    for (final (a, b) in [(actual.r, e.r), (actual.g, e.g), (actual.b, e.b)]) {
      expect((a - b).abs(), lessThan(10 / 255), reason: '$what: ${actual.toARGB32().toRadixString(16)}');
    }
  }

  test("on CommandS Dark the mark keeps the icon's own colours", () {
    final dark = preset(AppState.defaultThemeId);
    final c = AppMark.colorsFor(dark.accent, paletteOf(dark), Brightness.dark);
    expect(c.upper, const Color(0xFFFF7B5C));
    near(c.lower, 0xC2372A, 'lower fold');
    near(c.fold, 0x8C2219, 'fold shadow');
    near(c.tileTop, 0x2A1712, 'tile top');
    near(c.tileBottom, 0x120907, 'tile bottom');
  });

  test('the bolt takes the accent of any theme, like the S of CommandS', () {
    for (final p in builtInThemes) {
      final c = AppMark.colorsFor(p.accent, paletteOf(p), p.dark ? Brightness.dark : Brightness.light);
      expect(c.upper, p.accent, reason: p.name);
      final upper = HSLColor.fromColor(c.upper).lightness;
      expect(HSLColor.fromColor(c.lower).lightness, lessThan(upper), reason: '${p.name}: the lower fold is deeper');
      expect(HSLColor.fromColor(c.fold).lightness, lessThan(HSLColor.fromColor(c.lower).lightness), reason: p.name);
    }
  });

  test('the tile follows the theme: dark on a dark theme, light on a light one', () {
    final light = preset(AppState.lightThemeId);
    final c = AppMark.colorsFor(light.accent, paletteOf(light), Brightness.light);
    expect(c.tileTop.computeLuminance(), greaterThan(0.6));
    final dark = preset(AppState.defaultThemeId);
    expect(AppMark.colorsFor(dark.accent, paletteOf(dark), Brightness.dark).tileTop.computeLuminance(), lessThan(0.1));
  });

  test('the drawing in the app has the same shape as the icon file', () {
    final file = File(AppMark.asset).readAsStringSync();
    for (final points in [AppMark.upperFold, AppMark.lowerFold, AppMark.foldShadow]) {
      expect(file, contains('points="$points"'));
    }
    expect(file, contains('rx="${AppMark.tileRadius}"'));
    final dark = preset(AppState.defaultThemeId);
    final svg = AppMark.svgFor(AppMark.colorsFor(dark.accent, paletteOf(dark), Brightness.dark));
    expect(svg, startsWith('<svg'));
    expect(svg, contains('fill="#FF7B5C"'));
  });

  testWidgets('the title bar draws the mark from the theme, not a fixed file', (tester) async {
    await pumpBar(tester, AppTheme.fromPreset(preset(AppState.lightThemeId)));
    final picture = tester.widget<SvgPicture>(
      find.descendant(of: find.byType(AppMark), matching: find.byType(SvgPicture)),
    );
    expect(picture.bytesLoader, isA<SvgStringLoader>());
  });
}
