import 'package:commands/app_version.dart';
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
        expect(find.text('SSH terminal'), findsOneWidget);
        expect(find.text('Import connections'), findsOneWidget);
        expect(find.text('Export connections'), findsOneWidget);
        expect(find.text('Check for updates'), findsOneWidget);
      });
    }
  }

  testWidgets('connection cards and terminal size control align at desktop width', (tester) async {
    tester.view.physicalSize = const Size(900, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_app(const SettingsScreen(), dark: false));
    await tester.pumpAndSettle();

    final importCard = find.byKey(const Key('settings-import-card'));
    final exportCard = find.byKey(const Key('settings-export-card'));
    await tester.ensureVisible(exportCard);
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(importCard).dy, tester.getTopLeft(exportCard).dy);
    expect(tester.getSize(importCard).height, tester.getSize(exportCard).height);
    expect(
      tester.getBottomLeft(find.widgetWithText(OutlinedButton, 'Import…')).dy,
      tester.getBottomLeft(find.widgetWithText(OutlinedButton, 'Export…')).dy,
    );

    await tester.ensureVisible(find.text('Size'));
    await tester.pumpAndSettle();
    expect((tester.getCenter(find.text('Size')).dy - tester.getCenter(find.text('13 pt')).dy).abs(), lessThan(2));
    expect((tester.getCenter(find.text('Size')).dy - tester.getCenter(find.byType(Slider)).dy).abs(), lessThan(2));
    expect(tester.getTopLeft(find.text('Size')).dx, closeTo(tester.getTopLeft(find.text('Text')).dx, 1));
    expect(
      tester.widget<Text>(find.text('Size')).style?.fontWeight,
      tester.widget<Text>(find.text('Text')).style?.fontWeight,
    );
  });

  testWidgets('connection cards stack in a narrow settings window', (tester) async {
    tester.view.physicalSize = const Size(640, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_app(const SettingsScreen(), dark: false));
    await tester.pumpAndSettle();

    final importCard = find.byKey(const Key('settings-import-card'));
    final exportCard = find.byKey(const Key('settings-export-card'));
    await tester.ensureVisible(exportCard);
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(importCard).dx, tester.getTopLeft(exportCard).dx);
    expect(tester.getTopLeft(exportCard).dy, greaterThan(tester.getBottomLeft(importCard).dy));
    expect(tester.takeException(), isNull);
  });

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

  testWidgets('turning on beta updates is saved', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    late AppState app;
    await tester.pumpWidget(ChangeNotifierProvider(
      create: (_) => app = AppState(),
      child: const MaterialApp(home: SettingsScreen()),
    ));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('beta-updates')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('beta-updates')));
    await tester.pumpAndSettle();

    expect(app.updateChannel, ReleaseChannel.beta);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('commands.update.channel'), 'beta');
  });

  testWidgets('quick connect defaults to Serial with a fixed COM; SSH and RDP drop it', (tester) async {
    tester.view.physicalSize = const Size(260, 240);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_app(const Scaffold(body: Align(
      alignment: Alignment.bottomCenter,
      child: QuickConnectBar(),
    )), dark: true));
    await tester.pumpAndSettle();

    expect(find.text('Serial'), findsOneWidget);
    expect(find.text('COM'), findsOneWidget, reason: 'shown before anything is typed');
    // Only digits (and a :speed) go into the box; COM is not part of the text.
    await tester.enterText(find.byType(TextField), 'COM3x');
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, '3');

    // All three are offered, the current one ticked.
    await tester.tap(find.text('Serial'));
    await tester.pumpAndSettle();
    expect(find.text('Quick connect with'), findsOneWidget);
    expect(find.text('SSH'), findsOneWidget);
    expect(find.text('RDP'), findsOneWidget);
    expect(find.text('Serial'), findsNWidgets(2));
    expect(find.byIcon(Icons.check), findsOneWidget);
    await tester.tap(find.text('SSH'));
    await tester.pumpAndSettle();
    expect(find.text('SSH'), findsOneWidget);
    expect(find.text('COM'), findsNothing);
    expect(find.text('Host or IP'), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, '', reason: 'a port is not a host');
    await tester.enterText(find.byType(TextField), '192.0.2.1');
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, '192.0.2.1');

    await tester.tap(find.text('SSH'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('RDP'));
    await tester.pumpAndSettle();
    expect(find.text('RDP'), findsOneWidget);
    expect(find.text('COM'), findsNothing);

    await tester.tap(find.text('RDP'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Serial'));
    await tester.pumpAndSettle();
    expect(find.text('COM'), findsOneWidget);
  });
}
