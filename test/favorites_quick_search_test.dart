import 'package:commands/models/models.dart';
import 'package:commands/providers/app_state.dart';
import 'package:commands/screens/home_screen.dart';
import 'package:commands/services/update_service.dart';
import 'package:commands/theme/app_theme.dart';
import 'package:commands/services/pty_session.dart';
import 'package:commands/widgets/connection_tree.dart';
import 'package:commands/widgets/quick_search.dart';
import 'package:commands/widgets/welcome_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    PtySessionController.checkReachability = false;
  });
  tearDown(() => PtySessionController.checkReachability = true);

  late ConnectionFolder site;
  late ConnectionFolder inner;
  late SavedConnection sw;
  late SavedConnection fw;
  late SavedConnection srv;

  Future<AppState> loaded(WidgetTester tester) async {
    final app = AppState();
    await tester.pump();
    site = ConnectionFolder(name: 'Customer A');
    inner = ConnectionFolder(name: 'Folder A', parentId: site.id);
    sw = SavedConnection(name: 'SWITCH-01', host: '192.0.2.21', folderId: inner.id);
    fw = SavedConnection(name: 'FW-01', host: '192.0.2.1', folderId: site.id);
    srv = SavedConnection(name: 'SERVER-A', host: '198.51.100.20');
    app.folders.addAll([site, inner]);
    app.connections.addAll([sw, fw, srv]);
    return app;
  }

  testWidgets('a favorite is remembered, and a deleted one drops out', (tester) async {
    final app = await loaded(tester);
    await app.toggleFavorite(fw.id);
    await app.toggleFavorite(srv.id);
    expect(app.favoriteConnections, [fw, srv]);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList('commands.favorites'), [fw.id, srv.id]);
    await app.toggleFavorite(fw.id);
    expect(app.isFavorite(fw.id), isFalse);
    app.connections.remove(srv);
    expect(app.favoriteConnections, isEmpty);
    app.dispose();
  });

  testWidgets('quick search finds names, addresses and folders, favorites first', (tester) async {
    final app = await loaded(tester);
    await app.toggleFavorite(srv.id);
    expect(quickSearch(app, '192.0.2.2').map((r) => r.id), [sw.id]);
    expect(quickSearch(app, 'folder a').single.folder, inner);
    final all = quickSearch(app, '-0');
    expect(all.map((r) => r.connection?.name), ['FW-01', 'SWITCH-01']);
    expect(quickSearch(app, 'a').first.connection, srv, reason: 'the favorite comes first');
    expect(quickSearch(app, '').map((r) => r.id), [srv.id], reason: 'no query: favorites, then recent');
    app.dispose();
  });

  Future<void> pumpSearch(WidgetTester tester, AppState app) async {
    tester.view.physicalSize = const Size(1000, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ChangeNotifierProvider.value(
      value: app,
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(onPressed: () => showQuickSearch(context), child: const Text('open')),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('Enter on a connection connects to it', (tester) async {
    final app = await loaded(tester);
    await pumpSearch(tester, app);
    await tester.enterText(find.byKey(const Key('quick-search-field')), 'switch');
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('quick-search')), findsNothing);
    expect(app.tabs.single.connectionId, sw.id);
    for (final t in app.tabs) {
      t.controller.dispose();
    }
    app.dispose();
  });

  testWidgets('arrows choose, and a folder is shown in the list', (tester) async {
    final app = await loaded(tester);
    await pumpSearch(tester, app);
    await tester.enterText(find.byKey(const Key('quick-search-field')), 'a');
    await tester.pump();
    final results = quickSearch(app, 'a');
    final folderAt = results.indexWhere((r) => r.folder == site);
    for (var i = 0; i < folderAt; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    }
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(app.revealRequest.value, site.id);
    expect(app.tabs, isEmpty);
    app.dispose();
  });

  testWidgets('the tree stars favorites and opens the folders of what it is asked to show', (tester) async {
    final app = await loaded(tester);
    await app.toggleFavorite(sw.id);
    await tester.pumpWidget(ChangeNotifierProvider.value(
      value: app,
      child: const MaterialApp(home: Scaffold(body: SizedBox(width: 300, height: 500, child: ConnectionTree()))),
    ));
    await tester.pump();
    expect(find.text('SWITCH-01'), findsNothing, reason: 'its folders start closed');
    app.reveal(sw.id);
    await tester.pumpAndSettle();
    expect(find.text('SWITCH-01'), findsOneWidget);
    expect(find.byKey(ValueKey('favorite-star-${sw.id}')), findsOneWidget);
    expect(find.byKey(ValueKey('favorite-star-${fw.id}')), findsNothing);
    app.dispose();
  });

  testWidgets('favorites have their own part of the welcome panel', (tester) async {
    final app = await loaded(tester);
    await tester.pumpWidget(ChangeNotifierProvider.value(
      value: app,
      child: const MaterialApp(home: Scaffold(body: WelcomePanel())),
    ));
    await tester.pump();
    expect(find.byKey(const Key('welcome-favorites')), findsNothing);
    await app.toggleFavorite(fw.id);
    await tester.pump();
    expect(find.byKey(const Key('welcome-favorites')), findsOneWidget);
    expect(find.byKey(Key('welcome-favorite-${fw.id}')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    app.dispose();
  });

  testWidgets('the title bar magnifier and Ctrl+K open quick search', (tester) async {
    UpdateService.available.value = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      (call) async => call.method == 'isMaximized' ? false : null,
    );
    tester.view.physicalSize = const Size(1000, 650);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late AppState app;
    await tester.pumpWidget(ChangeNotifierProvider(
      create: (_) => app = AppState(),
      child: MaterialApp(theme: AppTheme.light(), home: const HomeScreen()),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('quick-search-button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('quick-search')), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('quick-search')), findsNothing);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('quick-search')), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(app.tabs, isEmpty);
  });
}
