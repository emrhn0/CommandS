import 'dart:io';

import 'package:commands/l10n/strings.dart';
import 'package:commands/l10n/tr.dart';
import 'package:commands/providers/app_state.dart';
import 'package:commands/screens/settings_screen.dart';
import 'package:commands/widgets/connection_tree.dart';
import 'package:commands/widgets/quick_connect_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Every literal the code sends through the translator, in the forms used:
/// `tr('...')` (adjacent literals joined), `trCount(n, '...', '...')`, and
/// the widgets that translate the label they are given.
Set<String> _translatedLiterals() {
  const lit = r"""(?:'((?:[^'\\]|\\.)*)'|"((?:[^"\\]|\\.)*)")""";
  String unescape(String s) => s.replaceAll(r"\'", "'").replaceAll(r'\n', '\n').replaceAll(r'\$', r'$');
  String joined(String group) =>
      RegExp(lit).allMatches(group).map((m) => unescape(m.group(1) ?? m.group(2)!)).join();
  final patterns = [
    RegExp(r'\btr\(\s*((?:' + lit + r'\s*)+)[,)]'),
    RegExp(r'\btrCount\([^,]+,\s*(' + lit + r')\s*,\s*(' + lit + r')'),
    RegExp(r"\bMenuAction\(\s*'[^']*',\s*(" + lit + r')'),
    RegExp(r'\bLabeledField\(\s*label:\s*(' + lit + r')'),
    RegExp(r'\b_Section\(\s*(' + lit + r')'),
    RegExp(r'\b_Label\(\s*(' + lit + r')'),
    RegExp(r'\b_Toggle\(\s*label:\s*(' + lit + r')'),
    // Named arguments of the widgets and dialogs that translate them.
    RegExp(r'\b(?:title|label|description|action|okLabel|confirmLabel):\s*(' + lit + r')'),
  ];
  final found = <String>{};
  for (final f in Directory('lib').listSync(recursive: true).whereType<File>()) {
    if (!f.path.endsWith('.dart') || f.path.contains('l10n')) continue;
    final src = f.readAsStringSync();
    for (final p in patterns) {
      for (final m in p.allMatches(src)) {
        for (var g = 1; g <= m.groupCount; g++) {
          final text = m.group(g);
          if (text != null && (text.startsWith("'") || text.startsWith('"'))) found.add(joined(text));
        }
        if (p == patterns.first) found.add(joined(m.group(1)!));
      }
    }
  }
  return found;
}

void main() {
  test('every string sent to tr() has a Turkish translation', () {
    final used = _translatedLiterals();
    expect(used.length, greaterThan(150), reason: 'the scan itself must be finding the strings');
    // Names and formats that read the same in Turkish.
    const same = {'SSH', 'RDP', 'JSON', 'XML', 'Port', 'CommandS', 'CSV (Excel/Sheets)'};
    // Interpolated values (a size in pt) carry no wording to translate.
    final missing =
        used.where((s) => !turkish.containsKey(s) && !same.contains(s) && !s.startsWith(r'${')).toList()
          ..sort();
    expect(missing, isEmpty, reason: 'add these to lib/l10n/tr.dart');
  });

  test('placeholders survive translation', () {
    for (final e in turkish.entries) {
      final want = RegExp(r'\{\w+\}').allMatches(e.key).map((m) => m.group(0)).toSet();
      final have = RegExp(r'\{\w+\}').allMatches(e.value).map((m) => m.group(0)).toSet();
      expect(have, want, reason: e.key);
    }
  });

  testWidgets('choosing Türkçe in Settings redraws the app in Turkish, and is remembered', (tester) async {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      (call) async => call.method.startsWith('is') ? false : null,
    );
    tester.view.physicalSize = const Size(1400, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    addTearDown(() => currentLanguage = AppLanguage.en);
    final app = AppState();
    await tester.pump();
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Appearance'), findsOneWidget);
    expect(find.text('English'), findsOneWidget);

    await tester.tap(find.text('Türkçe'));
    await tester.pumpAndSettle();
    // Including the const section headers a plain rebuild would skip.
    expect(find.text('Görünüm'), findsOneWidget);
    expect(find.text('Güncellemeleri denetle'), findsOneWidget);
    expect(find.text('Appearance'), findsNothing);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('commands.language'), 'tr');

    // A new start reads it back.
    final again = AppState();
    currentLanguage = AppLanguage.en;
    await tester.pump(const Duration(milliseconds: 50));
    expect(again.language, AppLanguage.tr);

    await tester.tap(find.text('English'));
    await tester.pumpAndSettle();
    expect(find.text('Appearance'), findsOneWidget);
  });

  testWidgets('sidebar in Turkish', (tester) async {
    SharedPreferences.setMockInitialValues({'commands.language': 'tr'});
    addTearDown(() => currentLanguage = AppLanguage.en);
    final app = AppState();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: const MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 280,
              child: Column(
                children: [
                  Expanded(child: ConnectionTree()),
                  QuickConnectBar(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Sunucu veya IP'), findsOneWidget);
    expect(find.text('0 bağlantı'), findsOneWidget);
  });
}
