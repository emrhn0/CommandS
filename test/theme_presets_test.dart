import 'dart:convert';
import 'dart:io';

import 'package:commands/providers/app_state.dart';
import 'package:commands/screens/settings_screen.dart';
import 'package:commands/theme/app_theme.dart';
import 'package:commands/theme/theme_presets.dart';
import 'package:commands/widgets/terminal_tabs.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The example theme in docs/theme-format.md, so the documentation and the
/// parser cannot drift apart.
String _documentedExample() {
  final doc = File('docs/theme-format.md').readAsStringSync().replaceAll('\r\n', '\n');
  final match = RegExp(r'```json\n(.*?)\n```', dotAll: true).firstMatch(doc);
  return match!.group(1)!;
}

Map<String, Object?> _example() => jsonDecode(_documentedExample()) as Map<String, Object?>;

Future<AppState> _loadedState() async {
  final app = AppState();
  await pumpEventQueue(times: 50);
  return app;
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      (call) async => call.method == 'isMaximized' ? false : null,
    );
  });

  group('catalogue', () {
    test('has the requested themes, each complete', () {
      final names = builtInThemes.map((t) => t.name).toSet();
      expect(names, containsAll(['Tokyo Night', 'Dracula', 'One Dark', 'Monokai']));
      expect(builtInThemes.map((t) => t.id).toSet().length, builtInThemes.length, reason: 'unique ids');
      for (final t in builtInThemes) {
        expect(t.ansi, hasLength(16), reason: t.name);
        expect(t.imported, isFalse);
      }
    });

    test('every built-in theme survives its own file format', () {
      for (final t in builtInThemes) {
        final back = ThemePreset.parse(jsonEncode(t.toJson()));
        expect(back.name, t.name);
        expect(back.dark, t.dark);
        expect(back.background, t.background);
        expect(back.accent, t.accent);
        expect(back.terminalForeground, t.terminalForeground);
        expect(back.ansi, t.ansi);
      }
    });

    test('a theme builds an app theme that carries its palette', () {
      final dracula = builtInThemes.firstWhere((t) => t.name == 'Dracula');
      final theme = AppTheme.fromPreset(dracula);
      expect(theme.brightness, Brightness.dark);
      expect(theme.scaffoldBackgroundColor, dracula.background);
      expect(theme.extension<AppPalette>()!.text, dracula.text);
      expect(AppTheme.light().extension<AppPalette>()!.bg, AppColors.lightBg);
    });

    test('the terminal takes a theme\'s 16 colours, or the defaults without one', () {
      final monokai = builtInThemes.firstWhere((t) => t.name == 'Monokai');
      final themed = TerminalThemes.withColors(
        background: monokai.terminalBackground,
        foreground: monokai.terminalForeground,
        ansi: monokai.ansi,
      );
      expect(themed.red, monokai.ansi[1]);
      expect(themed.brightWhite, monokai.ansi[15]);
      final plain = TerminalThemes.withColors(background: Colors.black, foreground: Colors.white);
      expect(plain.red, TerminalThemes.dark.red);
    });
  });

  group('theme file', () {
    test('the documented example is a valid theme', () {
      final t = ThemePreset.parse(_documentedExample());
      expect(t.name, 'Example Ocean');
      expect(t.id, 'custom:example-ocean');
      expect(t.imported, isTrue);
      expect(t.ansi, hasLength(16));
    });

    test('refuses what is not a theme, saying why', () {
      void refuses(Object? json, String why) {
        expect(
          () => ThemePreset.parse(jsonEncode(json)),
          throwsA(isA<FormatException>().having((e) => e.message, 'message', contains(why))),
          reason: why,
        );
      }

      refuses([1, 2], 'JSON object');
      refuses({..._example(), 'format': 'other'}, '"format"');
      refuses({..._example(), 'version': 2}, 'version');
      refuses({..._example(), 'name': '  '}, '"name"');
      refuses({..._example(), 'name': 'x' * 41}, '1 to 40');
      refuses({..._example(), 'dark': 'yes'}, '"dark"');
      final badColour = _example();
      (badColour['ui'] as Map)['accent'] = 'blue';
      refuses(badColour, 'ui.accent');
      final shortAnsi = _example();
      ((shortAnsi['terminal'] as Map)['ansi'] as List).removeLast();
      refuses(shortAnsi, 'exactly 16');
      expect(() => ThemePreset.parse('{not json'), throwsFormatException);
      expect(() => ThemePreset.parse(' ' * (ThemePreset.maxFileBytes + 1)), throwsFormatException);
    });
  });

  group('choosing a theme', () {
    test('applies its terminal colours and is remembered after a restart', () async {
      final app = await _loadedState();
      final dracula = builtInThemes.firstWhere((t) => t.name == 'Dracula');
      await app.selectTheme(dracula.id);
      expect(app.activeTheme, same(dracula));
      expect(app.themeMode, ThemeMode.dark);
      expect(app.terminalBackground, dracula.terminalBackground);
      expect(app.terminalAnsi, dracula.ansi);

      final again = await _loadedState();
      expect(again.themeId, dracula.id);
      expect(again.terminalBackground, dracula.terminalBackground);
      expect(again.terminalAnsi, dracula.ansi);
    });

    test('keep my terminal colours leaves the terminal alone', () async {
      final app = await _loadedState();
      await app.setTerminalColors(background: const Color(0xFF102030));
      await app.setKeepTerminalColors(true);
      await app.selectTheme('builtin:tokyo-night');
      expect(app.themeId, 'builtin:tokyo-night');
      expect(app.terminalBackground, const Color(0xFF102030));
      expect(app.terminalAnsi, isNull);
      expect((await _loadedState()).keepTerminalColors, isTrue);
    });

    test('terminal colours can still be changed by hand after a theme', () async {
      final app = await _loadedState();
      await app.selectTheme('builtin:nord');
      await app.setTerminalColors(foreground: const Color(0xFFABCDEF));
      expect(app.terminalForeground, const Color(0xFFABCDEF));
      expect(app.themeId, 'builtin:nord', reason: 'the app theme stays');
    });

    test('Light and Dark still work; they undo only colours a theme brought', () async {
      final app = await _loadedState();
      await app.selectTheme('builtin:monokai');
      await app.setThemeMode(ThemeMode.light);
      expect(app.themeId, isNull);
      expect(app.themeMode, ThemeMode.light);
      expect(app.terminalBackground, AppState.defaultTerminalBackground);
      expect(app.terminalAnsi, isNull);

      await app.selectTheme('builtin:monokai');
      await app.setTerminalColors(background: const Color(0xFF223344));
      await app.setThemeMode(ThemeMode.dark);
      expect(app.terminalBackground, const Color(0xFF223344), reason: 'picked by the user');
      expect((await _loadedState()).themeId, isNull);
    });

    test('an imported theme is kept, replaced by name, and can be removed', () async {
      final app = await _loadedState();
      final theme = await app.importTheme(_documentedExample());
      await app.selectTheme(theme.id);
      final changed = _example()..['dark'] = false;
      await app.importTheme(jsonEncode(changed));
      expect(app.importedThemes, hasLength(1));
      expect(app.importedThemes.single.dark, isFalse);

      final again = await _loadedState();
      expect(again.importedThemes.single.name, 'Example Ocean');
      expect(again.themeId, theme.id);

      await again.removeImportedTheme(theme.id);
      expect(again.importedThemes, isEmpty);
      expect(again.themeId, isNull);
      expect(again.activeTheme, isNull);
    });

    test('a broken saved theme is skipped rather than stopping the app', () async {
      SharedPreferences.setMockInitialValues({
        'commands.importedThemes': ['{broken', _documentedExample()],
        'commands.themeId': 'custom:gone',
      });
      final app = await _loadedState();
      expect(app.importedThemes.map((t) => t.name), ['Example Ocean']);
      expect(app.themeId, isNull, reason: 'an unknown theme falls back to classic');
    });
  });

  testWidgets('the catalogue on the Settings page applies a theme', (tester) async {
    tester.view.physicalSize = const Size(1280, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late AppState app;
    await tester.pumpWidget(ChangeNotifierProvider(
      create: (_) => app = AppState(),
      child: const MaterialApp(home: SettingsScreen()),
    ));
    await tester.pumpAndSettle();

    for (final t in builtInThemes) {
      expect(find.byKey(ValueKey('theme-${t.id}')), findsOneWidget, reason: t.name);
    }
    expect(find.byKey(const ValueKey('import-theme')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('theme-builtin:one-dark')));
    await tester.pumpAndSettle();
    expect(app.themeId, 'builtin:one-dark');

    await tester.tap(find.byKey(const ValueKey('keep-terminal-colors')));
    await tester.pumpAndSettle();
    expect(app.keepTerminalColors, isTrue);

    await tester.tap(find.text('Light'));
    await tester.pumpAndSettle();
    expect(app.themeId, isNull);
    expect(app.themeMode, ThemeMode.light);
  });
}
