import 'package:commands/providers/app_state.dart';
import 'package:commands/screens/settings_screen.dart';
import 'package:commands/services/terminal_appearance.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('the palette opens on click; the square and the code stay in step; Use applies it', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      (call) async => call.method.startsWith('is') ? false : null,
    );
    tester.view.physicalSize = const Size(1400, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final app = AppState();
    await tester.pump();
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    // Not on screen until asked for.
    expect(find.byKey(const ValueKey('color-code')), findsNothing);
    await tester.tap(find.byIcon(Icons.colorize).first); // Background's palette
    await tester.pumpAndSettle();
    final code = find.byKey(const ValueKey('color-code'));
    expect(code, findsOneWidget);

    // Typing a code moves the picker; the preview follows.
    await tester.enterText(code, '#3366CC');
    await tester.pump();
    // A click in the square's top-right corner: fully saturated and bright.
    final square = tester.getRect(find.byKey(const ValueKey('color-square')));
    await tester.tapAt(square.topRight.translate(-2, 2));
    await tester.pump();
    final picked = tester.widget<TextField>(code).controller!.text;
    expect(picked, isNot('#3366CC'));
    expect(parseColorCode(picked), isNotNull);

    await tester.tap(find.text('Use').last);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('color-code')), findsNothing);
    expect(colorToHex(app.terminalBackground), picked);
  });
}
