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
    expect(button, findsOneWidget);
    expect(tester.getTopLeft(button).dx, lessThan(24));
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
    app.setSidebarWidth(AppState.minSidebarWidth);
    await tester.pump();
    expect(button, findsOneWidget);
    expect(tester.getTopLeft(button).dx, lessThan(24));
    expect(tester.takeException(), isNull);

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
    expect(find.text('Show the sidebar to pick a saved connection,\nor start a new one.'), findsOneWidget);
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
    final beta = find.descendant(of: compactBranding, matching: find.text('ß'));
    expect(mark, findsOneWidget);
    expect(tester.getTopLeft(mark).dy, greaterThanOrEqualTo(10));
    if (buildChannel == ReleaseChannel.beta) {
      expect(tester.getRect(beta).top, greaterThan(tester.getRect(mark).bottom));
      final firstAccent = theme.value.colorScheme.primary;
      expect(tester.widget<Text>(beta).style?.color, firstAccent);
      theme.value = AppTheme.dark();
      await tester.pumpAndSettle();
      expect(theme.value.colorScheme.primary, isNot(firstAccent));
      expect(tester.widget<Text>(beta).style?.color, theme.value.colorScheme.primary);
    } else {
      expect(beta, findsNothing);
    }

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
}
