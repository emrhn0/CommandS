import 'dart:convert';
import 'dart:io';

import 'package:commands/l10n/strings.dart';
import 'package:commands/providers/app_state.dart';
import 'package:commands/screens/settings_screen.dart';
import 'package:commands/theme/app_theme.dart';
import 'package:commands/theme/theme_presets.dart';
import 'package:commands/widgets/system_brightness_watcher.dart';
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
      expect(names, containsAll(['Tokyo Night', 'Dracula', 'One Dark', 'Monokai', 'Aurora', 'Sakura', 'CommandS Dark', 'CommandS Light']));
      expect(builtInThemes.map((t) => t.id).toSet().length, builtInThemes.length, reason: 'unique ids');
      for (final t in builtInThemes) {
        expect(t.ansi, hasLength(16), reason: t.name);
        expect(t.imported, isFalse);
      }
    });

    test('Aurora round-trips through its JSON form like any other theme', () {
      final aurora = builtInThemes.firstWhere((t) => t.name == 'Aurora');
      final back = ThemePreset.fromJson(jsonDecode(jsonEncode(aurora.toJson())));
      expect(back.name, aurora.name);
      expect(back.dark, isTrue);
      expect(back.background, aurora.background);
      expect(back.accent, aurora.accent);
      expect(back.ansi, aurora.ansi);
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

  group('the default theme', () {
    test('a fresh install, or one that never opened Settings > Theme, starts on CommandS', () async {
      final app = await _loadedState();
      final commandS = builtInThemes.firstWhere((t) => t.id == AppState.defaultThemeId);
      expect(app.themeId, commandS.id);
      expect(app.themeMode, ThemeMode.dark);
      expect(app.terminalBackground, commandS.terminalBackground);
      expect(app.terminalAnsi, commandS.ansi);

      // It is the implicit default, not a saved choice: nothing was written.
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey('commands.themeId'), isFalse);
      expect(prefs.containsKey('commands.themeMode'), isFalse);
    });

    test('someone on the old Light theme moves to CommandS Light, terminal untouched', () async {
      SharedPreferences.setMockInitialValues({
        'commands.themeMode': 'light',
        'commands.terminalBg': 0xFF102030,
      });
      final app = await _loadedState();
      expect(app.themeId, AppState.lightThemeId);
      expect(app.themeMode, ThemeMode.light);
      expect(app.terminalBackground, const Color(0xFF102030), reason: 'the terminal keeps its colours');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('commands.themeId'), AppState.lightThemeId, reason: 'moved once, for good');
      expect((await _loadedState()).themeId, AppState.lightThemeId);
    });

    test('someone on the old Dark theme moves to CommandS Dark', () async {
      SharedPreferences.setMockInitialValues({'commands.themeMode': 'dark'});
      final app = await _loadedState();
      expect(app.themeId, AppState.defaultThemeId);
      expect(app.themeMode, ThemeMode.dark);
    });

    test('someone on the old CommandS theme stays on it, now named CommandS Dark', () async {
      SharedPreferences.setMockInitialValues({'commands.themeMode': 'dark', 'commands.themeId': 'builtin:commands'});
      final app = await _loadedState();
      expect(app.themeId, AppState.defaultThemeId);
      expect(app.activeTheme!.name, 'CommandS Dark');
    });

    test('CommandS Light is the icon colours on white, with its deep fold as the accent', () {
      final light = builtInThemes.firstWhere((t) => t.id == AppState.lightThemeId);
      expect(light.dark, isFalse);
      expect(light.background, const Color(0xFFFFFFFF));
      expect(light.text, const Color(0xFF24130F));
      expect(light.accent, const Color(0xFFC2372A));
      final dark = builtInThemes.firstWhere((t) => t.id == AppState.defaultThemeId);
      expect(dark.background, const Color(0xFF140C0A), reason: 'the icon tile');
      expect(dark.accent, const Color(0xFFFF7B5C), reason: 'the icon bolt');
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
      // An install that already has a classic baseline (not the fresh/
      // never-touched case the CommandS default covers).
      SharedPreferences.setMockInitialValues({'commands.themeMode': 'light'});
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

    test('CommandS Light is chosen like any other theme', () async {
      final app = await _loadedState();
      await app.selectTheme(AppState.lightThemeId);
      expect(app.themeMode, ThemeMode.light);
      expect((await _loadedState()).themeId, AppState.lightThemeId);
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
      // It was a light theme: CommandS Light takes its place.
      expect(again.themeId, AppState.lightThemeId);
      expect((await _loadedState()).themeId, AppState.lightThemeId);
    });

    test('a broken saved theme is skipped rather than stopping the app', () async {
      SharedPreferences.setMockInitialValues({
        'commands.importedThemes': ['{broken', _documentedExample()],
        'commands.themeId': 'custom:gone',
      });
      final app = await _loadedState();
      expect(app.importedThemes.map((t) => t.name), ['Example Ocean']);
      expect(app.themeId, AppState.defaultThemeId, reason: 'an unknown theme falls back to CommandS');
    });
  });

  group('same as system', () {
    test('follows the computer between CommandS Dark and Light, and is remembered', () async {
      final app = await _loadedState();
      await app.setPlatformBrightness(Brightness.dark);
      await app.followSystemTheme();
      expect(app.themeFollowsSystem, isTrue);
      expect(app.themeId, AppState.defaultThemeId);
      expect(app.themeMode, ThemeMode.dark);

      await app.setPlatformBrightness(Brightness.light);
      expect(app.themeId, AppState.lightThemeId);
      expect(app.themeMode, ThemeMode.light);
      final light = builtInThemes.firstWhere((t) => t.id == AppState.lightThemeId);
      expect(app.terminalBackground, light.terminalBackground, reason: 'the terminal follows too');

      final again = await _loadedState();
      expect(again.themeFollowsSystem, isTrue);
    });

    test('any other theme stays as chosen whatever the computer does', () async {
      final app = await _loadedState();
      await app.setPlatformBrightness(Brightness.dark);
      await app.followSystemTheme();
      await app.selectTheme('builtin:tokyo-night');
      expect(app.themeFollowsSystem, isFalse);
      await app.setPlatformBrightness(Brightness.light);
      expect(app.themeId, 'builtin:tokyo-night');

      // Picking CommandS Light by hand does not follow either.
      await app.selectTheme(AppState.lightThemeId);
      await app.setPlatformBrightness(Brightness.dark);
      expect(app.themeId, AppState.lightThemeId);

      final again = await _loadedState();
      expect(again.themeFollowsSystem, isFalse);
      expect(again.themeId, AppState.lightThemeId);
    });

    test('off on a fresh install', () async {
      final app = await _loadedState();
      expect(app.themeFollowsSystem, isFalse);
      expect(app.themeId, AppState.defaultThemeId);
    });
  });

  testWidgets('Same as system is the first card and follows a change of mode', (tester) async {
    tester.view.physicalSize = const Size(1280, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    late AppState app;
    await tester.pumpWidget(ChangeNotifierProvider(
      create: (_) => app = AppState(),
      child: Builder(
        builder: (context) => SystemBrightnessWatcher(
          app: context.read<AppState>(),
          child: const MaterialApp(home: SettingsScreen(initialPage: SettingsPage.theme)),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    final system = find.byKey(const ValueKey('theme-system'));
    expect(system, findsOneWidget);
    expect(find.text('Same as system'), findsOneWidget);
    expect(tester.getTopLeft(system).dx, lessThan(tester.getTopLeft(find.byKey(const ValueKey('theme-builtin:commands'))).dx));

    await tester.tap(system);
    await tester.pumpAndSettle();
    expect(app.themeFollowsSystem, isTrue);
    expect(app.themeId, AppState.defaultThemeId);

    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    await tester.pumpAndSettle();
    expect(app.themeId, AppState.lightThemeId);

    // Only one card is ticked: the CommandS Light in use is not picked by hand.
    Icon radio(String key) => tester.widget<Icon>(
        find.descendant(of: find.byKey(ValueKey(key)), matching: find.byType(Icon)).first);
    expect(radio('theme-system').icon, Icons.radio_button_checked);
    expect(radio('theme-builtin:commands-light').icon, Icons.radio_button_unchecked);

    await tester.tap(find.byKey(const ValueKey('theme-builtin:nord')));
    await tester.pumpAndSettle();
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    await tester.pumpAndSettle();
    expect(app.themeId, 'builtin:nord');
    expect(radio('theme-system').icon, Icons.radio_button_unchecked);
  });

  testWidgets('the catalogue on the Settings page applies a theme', (tester) async {
    tester.view.physicalSize = const Size(1280, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late AppState app;
    await tester.pumpWidget(ChangeNotifierProvider(
      create: (_) => app = AppState(),
      child: const MaterialApp(home: SettingsScreen(initialPage: SettingsPage.theme)),
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

    await tester.tap(find.text('CommandS Light'));
    await tester.pumpAndSettle();
    expect(app.themeId, AppState.lightThemeId);
    expect(app.themeMode, ThemeMode.light);
    expect(find.byKey(const ValueKey('theme-light')), findsNothing, reason: 'the old Light theme is gone');
    expect(find.byKey(const ValueKey('theme-dark')), findsNothing);
  });

  testWidgets('Dark and Light in the CommandS theme names follow the app language', (tester) async {
    tester.view.physicalSize = const Size(1280, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({'commands.language': 'tr'});
    addTearDown(() => currentLanguage = AppLanguage.en);
    await tester.pumpWidget(ChangeNotifierProvider(
      create: (_) => AppState(),
      child: const MaterialApp(home: SettingsScreen(initialPage: SettingsPage.theme)),
    ));
    await tester.pumpAndSettle();
    expect(find.text('CommandS Koyu'), findsOneWidget);
    expect(find.text('CommandS Açık'), findsOneWidget);
    expect(find.text('CommandS Dark'), findsNothing);
  });
}
