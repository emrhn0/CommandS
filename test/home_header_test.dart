import 'package:commands/providers/app_state.dart';
import 'package:commands/screens/home_screen.dart';
import 'package:commands/services/update_service.dart';
import 'package:commands/theme/app_theme.dart';
import 'package:commands/widgets/terminal_tabs.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('New Connection shares header with Settings and opens its dialog', (tester) async {
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
    expect((tester.getCenter(button).dy - tester.getCenter(find.byIcon(Icons.settings_outlined)).dy).abs(),
        lessThan(4));

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

  testWidgets('title bar toggles sidebar without losing its width', (tester) async {
    SharedPreferences.setMockInitialValues({});
    UpdateService.available.value = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      (call) async => call.method == 'isMaximized' ? false : null,
    );
    tester.view.physicalSize = const Size(900, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    late AppState app;
    await tester.pumpWidget(ChangeNotifierProvider(
      create: (_) => app = AppState(),
      child: MaterialApp(theme: AppTheme.light(), home: const HomeScreen()),
    ));
    await tester.pumpAndSettle();
    app.setSidebarWidth(300);
    await tester.pump();

    final toggle = find.byKey(const Key('sidebar-toggle'));
    final terminal = find.byType(TerminalTabsArea);
    final initialWidth = tester.getSize(terminal).width;
    expect(find.byKey(const Key('sidebar-new-connection')), findsOneWidget);

    await tester.tap(toggle);
    await tester.pump();
    expect(find.byKey(const Key('sidebar-new-connection')), findsNothing);
    expect(tester.getSize(terminal).width, greaterThan(initialWidth + 250));
    expect(app.sidebarWidth, 300);

    await tester.tap(toggle);
    await tester.pump();
    expect(find.byKey(const Key('sidebar-new-connection')), findsOneWidget);
    expect(tester.getSize(terminal).width, initialWidth);
    expect(tester.takeException(), isNull);
  });
}
