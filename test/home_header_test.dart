import 'package:commands/app_version.dart';
import 'package:commands/providers/app_state.dart';
import 'package:commands/screens/home_screen.dart';
import 'package:commands/screens/settings_screen.dart';
import 'package:commands/services/update_service.dart';
import 'package:commands/theme/app_mark.dart';
import 'package:commands/theme/app_theme.dart';
import 'package:commands/widgets/terminal_tabs.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('New Connection leads the panel; hiding it and Settings sit at its foot', (tester) async {
    SharedPreferences.setMockInitialValues({});
    UpdateService.available.value = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      (call) async => call.method == 'isMaximized' ? false : null,
    );
    tester.view.physicalSize = const Size(900, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    addTearDown(() => UpdateService.available.value = null);

    late AppState app;
    await tester.pumpWidget(ChangeNotifierProvider(
      create: (_) => app = AppState(),
      child: MaterialApp(theme: AppTheme.light(), home: const HomeScreen()),
    ));
    await tester.pumpAndSettle();

    final button = find.byKey(const Key('sidebar-new-connection'));
    final caption = find.byKey(const Key('sidebar-caption'));
    expect(button, findsOneWidget);
    // The list's name on the left, a small New button on the right.
    expect(tester.widget<Text>(caption).data, 'CONNECTIONS');
    expect(tester.getTopLeft(caption).dx, lessThan(24));
    expect(tester.getTopRight(button).dx, greaterThan(app.sidebarWidth - 24));
    expect(tester.getSize(button).height, 24);
    expect(tester.getSize(button).width, lessThan(100));
    // The panel's foot: the hide button on the left, Settings on the right,
    // under everything else in the panel.
    final footer = tester.getRect(find.byKey(const Key('sidebar-footer')));
    final toggle = tester.getRect(find.byKey(const Key('sidebar-toggle')));
    final settings = tester.getRect(find.byKey(const Key('sidebar-settings')));
    expect(footer.bottom, 600);
    expect(footer.top, greaterThan(tester.getRect(button).bottom + 200));
    expect(footer.contains(toggle.center), isTrue);
    expect(footer.contains(settings.center), isTrue);
    expect(toggle.left, lessThan(24));
    expect(settings.right, greaterThan(footer.right - 24));
    expect(find.byKey(const Key('quick-search-button')), findsOneWidget, reason: 'the title bar search box');

    UpdateService.available.value = const UpdateInfo(
      version: 'v9.9.9',
      releaseUrl: 'https://example.invalid',
      notes: '',
      assetName: null,
      assetUrl: null,
      assetSize: 0,
      checksumsUrl: null,
      method: null,
    );
    final note = find.byKey(const ValueKey('update-button'));
    for (final width in [AppState.defaultSidebarWidth, AppState.minSidebarWidth]) {
      app.setSidebarWidth(width);
      await tester.pump();
      expect(caption, findsNothing);
      expect(note, findsOneWidget);
      final noteBounds = tester.getRect(note);
      final buttonBounds = tester.getRect(button);
      expect(noteBounds.top, buttonBounds.top);
      expect(noteBounds.height, buttonBounds.height);
      expect(buttonBounds.left - noteBounds.right, greaterThanOrEqualTo(8));
      expect(noteBounds.left, lessThan(24));
      expect(buttonBounds.right, greaterThan(width - 24));
    }
    // The version may give way there, the word Update never does.
    final action = find.byKey(const ValueKey('update-note-action'));
    expect(tester.widget<Text>(action).data, contains('Update'));
    expect(tester.getRect(action).right, lessThanOrEqualTo(tester.getRect(note).right));
    expect(tester.takeException(), isNull);

    final boundsWithUpdate = tester.getRect(button);
    UpdateService.available.value = null;
    await tester.pump();
    expect(caption, findsOneWidget);
    expect(note, findsNothing);
    expect(tester.getRect(button), boundsWithUpdate);

    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(find.text('CONNECTION'), findsOneWidget);
  });

  testWidgets('collapsing keeps Settings, compacts the title, and remembers the width', (tester) async {
    SharedPreferences.setMockInitialValues({});
    UpdateService.available.value = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      (call) async => call.method == 'isMaximized' ? false : null,
    );
    tester.view.physicalSize = const Size(900, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final theme = ValueNotifier(AppTheme.light());
    addTearDown(theme.dispose);
    late AppState app;
    await tester.pumpWidget(ChangeNotifierProvider(
      create: (_) => app = AppState(),
      child: ValueListenableBuilder<ThemeData>(
        valueListenable: theme,
        builder: (_, value, home) => MaterialApp(theme: value, home: home),
        child: const HomeScreen(),
      ),
    ));
    await tester.pumpAndSettle();
    app.setSidebarWidth(300);
    await tester.pump();

    final toggle = find.byKey(const Key('sidebar-toggle'));
    final settings = find.byKey(const Key('sidebar-settings'));
    final wordmark = find.byKey(const Key('title-bar-name'));
    final compactBranding = find.byKey(const Key('sidebar-compact-branding'));
    final rail = find.byKey(const Key('sidebar-rail'));
    final terminal = find.byType(TerminalTabsArea);
    final initialWidth = tester.getSize(terminal).width;
    final hideAt = tester.getCenter(toggle);
    expect(find.byKey(const Key('sidebar-new-connection')), findsOneWidget);
    expect(wordmark, findsOneWidget);

    await tester.tap(toggle);
    await tester.pump();
    expect(find.byKey(const Key('sidebar-new-connection')), findsNothing);
    // Nothing saved yet: the welcome screen lists the first steps.
    expect(find.byKey(const Key('welcome-first-steps')), findsOneWidget);
    expect(tester.getSize(terminal).width, greaterThan(initialWidth + 250));
    expect(app.sidebarWidth, 300);
    // The button that brings it back is where the hide button was, at the
    // bottom left, not up in the title bar.
    expect(tester.getRect(rail), const Rect.fromLTWH(0, 0, 30, 600));
    final border = (tester.widget<Container>(rail).decoration as BoxDecoration).border as Border;
    expect(border.right, BorderSide(color: theme.value.dividerColor));
    expect(tester.getCenter(toggle), hideAt);
    expect(hideAt.dy, greaterThan(560));
    expect(tester.getCenter(settings).dx, hideAt.dx);
    expect(tester.getRect(settings).bottom, lessThan(tester.getRect(toggle).top));
    expect(wordmark, findsNothing);
    final mark = find.descendant(of: compactBranding, matching: find.byType(AppMark));
    expect(mark, findsOneWidget);
    expect(tester.getTopLeft(mark).dy, greaterThanOrEqualTo(10));
    // This build's own channel decides the ß.
    expect(find.byKey(const Key('sidebar-beta-mark')),
        buildChannel == ReleaseChannel.beta ? findsOneWidget : findsNothing);

    await tester.tap(settings);
    await tester.pumpAndSettle();
    expect(find.byType(SettingsScreen), findsOneWidget);
    Navigator.of(tester.element(find.byType(SettingsScreen))).pop();
    await tester.pumpAndSettle();
    expect(app.sidebarVisible, isFalse);

    await tester.tap(toggle);
    await tester.pump();
    expect(find.byKey(const Key('sidebar-new-connection')), findsOneWidget);
    expect(wordmark, findsOneWidget);
    expect(compactBranding, findsNothing);
    expect(tester.getSize(terminal).width, initialWidth);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a hidden sidebar stays hidden after a restart', (tester) async {
    SharedPreferences.setMockInitialValues({});
    UpdateService.available.value = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      (call) async => call.method == 'isMaximized' ? false : null,
    );
    tester.view.physicalSize = const Size(900, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(ChangeNotifierProvider(
      create: (_) => AppState(),
      child: MaterialApp(theme: AppTheme.light(), home: const HomeScreen()),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('sidebar-toggle')));
    await tester.pumpAndSettle();
    expect((await SharedPreferences.getInstance()).getBool('commands.sidebarVisible'), isFalse);

    // A new AppState reads the saved preference, as on the next start.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(ChangeNotifierProvider(
      create: (_) => AppState(),
      child: MaterialApp(theme: AppTheme.light(), home: const HomeScreen()),
    ));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('sidebar-new-connection')), findsNothing);
    expect(find.byKey(const Key('sidebar-toggle')), findsOneWidget);
  });

  for (final dark in [false, true]) {
    testWidgets("a beta puts a small ß on the mark's corner (${dark ? 'dark' : 'light'})", (tester) async {
      final theme = dark ? AppTheme.dark() : AppTheme.light();
      await tester.pumpWidget(MaterialApp(
        theme: theme,
        home: const Scaffold(body: Center(child: RailBrand(beta: true))),
      ));
      final mark = tester.getRect(find.byType(AppMark));
      final badge = find.byKey(const Key('sidebar-beta-mark'));
      final rect = tester.getRect(badge);
      // On the lower right corner, overlapping the mark, and small.
      expect(rect.right, greaterThan(mark.right));
      expect(rect.bottom, greaterThan(mark.bottom));
      expect(rect.left, lessThan(mark.right));
      expect(rect.top, lessThan(mark.bottom));
      expect(rect.height, lessThanOrEqualTo(10));
      final text = tester.widget<Text>(find.descendant(of: badge, matching: find.text('ß')));
      expect(text.style?.fontSize, 9);
      expect(text.style?.color, theme.colorScheme.primary);
      expect((tester.widget<Container>(badge).decoration as BoxDecoration).color, theme.scaffoldBackgroundColor);
    });
  }

  testWidgets('a normal release shows the mark alone', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.dark(),
      home: const Scaffold(body: Center(child: RailBrand(beta: false))),
    ));
    expect(find.byType(AppMark), findsOneWidget);
    expect(find.text('ß'), findsNothing);
  });
}
