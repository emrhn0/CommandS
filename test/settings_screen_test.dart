import 'package:commands/providers/app_state.dart';
import 'package:commands/screens/settings_screen.dart';
import 'package:commands/theme/app_theme.dart';
import 'package:commands/widgets/quick_connect_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The title bar talks to window_manager over a platform channel that does not
/// exist under `flutter test`; answer it so the page can build.
void _fakeWindowManager() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('window_manager'),
    (call) async => call.method == 'isMaximized' ? false : null,
  );
}

Widget _app(Widget home, {required bool dark}) => ChangeNotifierProvider(
      create: (_) => AppState(),
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light(),
        darkTheme: AppTheme.dark(),
        themeMode: dark ? ThemeMode.dark : ThemeMode.light,
        home: home,
      ),
    );

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    _fakeWindowManager();
  });

  // The app's minimum window size, a typical one, and a large one. A
  // RenderFlex overflow at any of them fails the test on its own.
  const sizes = [Size(900, 600), Size(1280, 800), Size(1920, 1040)];

  for (final dark in [false, true]) {
    for (final size in sizes) {
      testWidgets(
          'Settings lays out at ${size.width.toInt()}x${size.height.toInt()} '
          '(${dark ? 'dark' : 'light'})', (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(_app(const SettingsScreen(), dark: dark));
        await tester.pumpAndSettle();

        expect(find.text('Settings'), findsOneWidget);
        expect(find.text('Appearance'), findsOneWidget);
        expect(find.text('Light'), findsOneWidget);
        expect(find.text('Dark'), findsOneWidget);
        expect(find.text('Terminal colors'), findsOneWidget);
        expect(find.text('Import connections'), findsOneWidget);
        expect(find.text('Export connections'), findsOneWidget);
        expect(find.text('Check for updates'), findsOneWidget);
      });
    }
  }

  testWidgets('choosing a theme on the Settings page applies and is remembered', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    late AppState app;
    await tester.pumpWidget(ChangeNotifierProvider(
      create: (_) => app = AppState(),
      child: const MaterialApp(home: SettingsScreen()),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Light'));
    await tester.pumpAndSettle();
    expect(app.themeMode, ThemeMode.light);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('commands.themeMode'), 'light');

    await tester.tap(find.text('Dark'));
    await tester.pumpAndSettle();
    expect(app.themeMode, ThemeMode.dark);
    expect(prefs.getString('commands.themeMode'), 'dark');
  });

  testWidgets('quick connect defaults to SSH and offers RDP, then SSH back', (tester) async {
    tester.view.physicalSize = const Size(260, 120);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_app(const Scaffold(body: Align(
      alignment: Alignment.bottomCenter,
      child: QuickConnectBar(),
    )), dark: true));
    await tester.pumpAndSettle();

    expect(find.text('SSH'), findsOneWidget);
    expect(find.text('RDP'), findsNothing);

    await tester.tap(find.text('SSH'));
    await tester.pumpAndSettle();
    // The menu offers only the other protocol.
    expect(find.text('RDP'), findsOneWidget);
    await tester.tap(find.text('RDP'));
    await tester.pumpAndSettle();
    expect(find.text('RDP'), findsOneWidget);
    expect(find.text('SSH'), findsNothing);

    await tester.tap(find.text('RDP'));
    await tester.pumpAndSettle();
    expect(find.text('SSH'), findsOneWidget);
    await tester.tap(find.text('SSH').last);
    await tester.pumpAndSettle();
    expect(find.text('SSH'), findsOneWidget);
    expect(find.text('RDP'), findsNothing);
  });
}
