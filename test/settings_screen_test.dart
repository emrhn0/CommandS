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

        // Every page, reached from the sidebar. An overflow on any fails.
        final expected = {
          SettingsPage.general: 'Applies to CommandS itself; sessions are not affected.',
          SettingsPage.theme: 'Font',
          SettingsPage.connections: 'Export connections',
          SettingsPage.sessionLogs: 'Choose log folder',
          SettingsPage.privacy: 'Passwords',
          SettingsPage.updates: 'Check for updates',
          SettingsPage.support: 'Support & feedback',
        };
        for (final page in SettingsPage.values) {
          await tester.tap(find.byKey(ValueKey('settings-nav-${page.name}')));
          await tester.pumpAndSettle();
          expect(find.byKey(ValueKey('settings-page-${page.name}')), findsOneWidget);
          expect(find.text(expected[page]!), findsWidgets, reason: page.name);
        }
      });
    }
  }

  testWidgets('connection cards and terminal size control align at desktop width', (tester) async {
    tester.view.physicalSize = const Size(900, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_app(const SettingsScreen(initialPage: SettingsPage.connections), dark: false));
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

    await tester.tap(find.byKey(const ValueKey('settings-nav-theme')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Size'));
    await tester.pumpAndSettle();
    expect((tester.getCenter(find.text('Size')).dy - tester.getCenter(find.text('13 pt')).dy).abs(), lessThan(2));
    expect((tester.getCenter(find.text('Size')).dy - tester.getCenter(find.byType(Slider)).dy).abs(), lessThan(2));
  });

  testWidgets('the app theme and the SSH terminal look share one page', (tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_app(const SettingsScreen(initialPage: SettingsPage.theme), dark: true));
    await tester.pumpAndSettle();

    expect(find.text('Theme & colors'), findsWidgets);
    expect(find.text('App theme'), findsOneWidget);
    expect(find.text('SSH terminal'), findsOneWidget);
    expect(find.text('Light'), findsWidgets);
    expect(find.text('Font'), findsWidgets);
    expect(find.byKey(const ValueKey('settings-nav-terminal')), findsNothing);
  });

  for (final width in [1100.0, 1374.0, 1920.0]) {
    testWidgets('terminal background and text are two separate groups at $width px', (tester) async {
      tester.view.physicalSize = Size(width, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(_app(const SettingsScreen(initialPage: SettingsPage.theme), dark: true));
      await tester.pumpAndSettle();

      final bgGroup = find.byKey(const ValueKey('terminal-group-background'));
      final textGroup = find.byKey(const ValueKey('terminal-group-text'));
      await tester.ensureVisible(textGroup);
      await tester.pumpAndSettle();

      // Side by side, the same width, tops level.
      final bg = tester.getRect(bgGroup);
      final text = tester.getRect(textGroup);
      expect(bg.top, text.top);
      expect(bg.right, lessThan(text.left));
      expect((bg.width - text.width).abs(), lessThan(1));

      // The font, its size and the text colour all sit inside the text group.
      for (final control in [find.text('Font'), find.byType(Slider), find.text('Color')]) {
        expect(text.contains(tester.getCenter(control.first)), isTrue);
        expect(bg.contains(tester.getCenter(control.first)), isFalse);
      }
      // The size is right under the font, not off to the side.
      final font = tester.getRect(find.ancestor(of: find.text('Font'), matching: find.byType(InputDecorator)).first);
      final slider = tester.getRect(find.byType(Slider));
      expect(slider.top, greaterThan(font.bottom));
      expect(slider.top - font.bottom, lessThan(40));

      // Each group's swatches and palette button stay on a single line.
      final rows = find.byKey(const ValueKey('swatch-row'));
      expect(rows, findsNWidgets(2));
      for (final row in rows.evaluate()) {
        final swatches = find.descendant(of: find.byWidget(row.widget), matching: find.byType(Container));
        final tops = {for (final e in swatches.evaluate()) (e.renderObject as RenderBox).localToGlobal(Offset.zero).dy.round()};
        final first = tops.reduce((a, b) => a < b ? a : b);
        expect(tops.every((t) => t - first < 34), isTrue, reason: 'a swatch wrapped to a second line');
      }
      // The two colour code fields line up across the groups.
      final codes = find.widgetWithText(TextField, 'Color code');
      expect(codes, findsNWidgets(2));
      expect((tester.getSize(codes.at(0)).width - tester.getSize(codes.at(1)).width).abs(), lessThan(1));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('connection cards stack in a narrow settings window', (tester) async {
    tester.view.physicalSize = const Size(640, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_app(const SettingsScreen(initialPage: SettingsPage.connections), dark: false));
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
      child: const MaterialApp(home: SettingsScreen(initialPage: SettingsPage.theme)),
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
      child: const MaterialApp(home: SettingsScreen(initialPage: SettingsPage.updates)),
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
