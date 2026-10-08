import 'package:commands/providers/app_state.dart';
import 'package:commands/screens/settings_screen.dart';
import 'package:commands/services/terminal_appearance.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('parseColorCode', () {
    test('hex, short hex and rgb forms', () {
      expect(parseColorCode('#1E1E1E'), const Color(0xFF1E1E1E));
      expect(parseColorCode('1e1e1e'), const Color(0xFF1E1E1E));
      expect(parseColorCode('#FFF'), const Color(0xFFFFFFFF));
      expect(parseColorCode('rgb(30, 30, 30)'), const Color(0xFF1E1E1E));
      expect(parseColorCode('30,30,30'), const Color(0xFF1E1E1E));
      expect(parseColorCode(' RGB(255,0,0) '), const Color(0xFFFF0000));
    });

    test('rejects what is not a colour', () {
      for (final bad in ['', '#12', '#GGGGGG', 'rgb(256,0,0)', 'red', '1,2']) {
        expect(parseColorCode(bad), isNull, reason: bad);
      }
    });

    test('colorToHex round-trips', () {
      expect(colorToHex(const Color(0xFF00AAFF)), '#00AAFF');
      expect(parseColorCode(colorToHex(const Color(0xFF123456))), const Color(0xFF123456));
    });
  });

  test('terminal style falls back to the platform fonts', () {
    final s = terminalStyle(family: 'JetBrains Mono', size: 16);
    expect(s.fontFamily, 'JetBrains Mono');
    expect(s.fontSize, 16);
    expect(s.fontFamilyFallback, isNot(contains('JetBrains Mono')));
    expect(terminalStyle(family: null, size: 13).fontFamily, defaultTerminalFont);
  });

  group('settings', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('window_manager'),
        (call) async => call.method == 'isMaximized' ? false : null,
      );
    });

    test('font choice is remembered and can be reset', () async {
      final app = AppState();
      await app.setTerminalFont(family: 'Fira Code', size: 17);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('commands.terminalFont'), 'Fira Code');
      expect(prefs.getDouble('commands.terminalFontSize'), 17);
      await app.setTerminalFont(resetFamily: true);
      expect(app.terminalFontFamily, isNull);
      expect(prefs.getString('commands.terminalFont'), isNull);
      await app.setTerminalFont(size: 99);
      expect(app.terminalFontSize, 32, reason: 'clamped');
    });

    testWidgets('typing a colour code applies it; a bad one says what it expects', (tester) async {
      tester.view.physicalSize = const Size(1280, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      late AppState app;
      await tester.pumpWidget(ChangeNotifierProvider(
        create: (_) => app = AppState(),
        child: const MaterialApp(home: SettingsScreen()),
      ));
      await tester.pumpAndSettle();

      final codeFields = find.widgetWithText(TextField, 'Color code');
      expect(codeFields, findsNWidgets(2));

      await tester.enterText(codeFields.first, '#102030');
      await tester.pump();
      expect(app.terminalBackground, const Color(0xFF102030));

      await tester.enterText(codeFields.last, 'rgb(200, 100, 50)');
      await tester.pump();
      expect(app.terminalForeground, const Color.fromARGB(255, 200, 100, 50));

      await tester.enterText(codeFields.first, 'not a colour');
      await tester.pump();
      expect(find.text('Use #RRGGBB, #RGB or rgb(r, g, b)'), findsOneWidget);
      expect(app.terminalBackground, const Color(0xFF102030), reason: 'unchanged by a bad code');
    });
  });
}
