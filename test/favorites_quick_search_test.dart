import 'dart:io';

import 'package:commands/models/models.dart';
import 'package:commands/providers/app_state.dart';
import 'package:commands/screens/home_screen.dart';
import 'package:commands/services/update_service.dart';
import 'package:commands/theme/app_theme.dart';
import 'package:commands/services/pty_session.dart';
import 'package:commands/widgets/connection_tree.dart';
import 'package:commands/widgets/quick_search.dart';
import 'package:commands/widgets/welcome_panel.dart';
import 'package:flutter/gestures.dart';
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
    expect(quickSearch(app, 'folder a').map((r) => (r.id, r.depth)), [(inner.id, 0), (sw.id, 1)],
        reason: 'a found folder comes with what is inside it');
    final all = quickSearch(app, '-0');
    expect(all.map((r) => r.connection?.name), ['FW-01', 'SWITCH-01']);
    expect(quickSearch(app, 'a').first.folder, site, reason: 'a found folder comes first');
    expect(quickSearch(app, 'a').firstWhere((r) => r.depth == 0 && r.connection != null).connection, srv,
        reason: 'then the connections, the favorite first');
    expect(quickSearch(app, '').map((r) => r.id), [srv.id], reason: 'no query: favorites, then recent');
    app.dispose();
  });

  testWidgets('a found folder lists everything inside it, in list order, each once', (tester) async {
    final app = await loaded(tester);
    // "Customer A" holds "Folder A" (with SWITCH-01) and FW-01.
    expect(
      quickSearch(app, 'customer').map((r) => (r.id, r.depth)),
      [(site.id, 0), (inner.id, 1), (sw.id, 2), (fw.id, 1)],
    );
    // FW-01 matches "0" itself, but it is listed inside its found folder only.
    final both = quickSearch(app, 'a').map((r) => r.id).toList();
    expect(both.toSet().length, both.length, reason: 'nothing twice');
    expect(both, [site.id, inner.id, sw.id, fw.id, srv.id], reason: 'the folder and its contents, then the rest');
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

  testWidgets('the search window shows a found folder\'s contents, indented', (tester) async {
    final app = await loaded(tester);
    await pumpSearch(tester, app);
    await tester.enterText(find.byKey(const Key('quick-search-field')), 'customer');
    await tester.pump();
    expect(find.byKey(Key('quick-search-${site.id}')), findsOneWidget);
    expect(find.byKey(Key('quick-search-${sw.id}')), findsOneWidget);
    expect(find.byKey(Key('quick-search-${fw.id}')), findsOneWidget);
    final folderIcon = tester.getTopLeft(find.descendant(
      of: find.byKey(Key('quick-search-${site.id}')),
      matching: find.byIcon(Icons.folder_outlined),
    ));
    final innerText = tester.getTopLeft(find.text('SWITCH-01'));
    expect(innerText.dx, greaterThan(folderIcon.dx + 30), reason: 'two levels in');
    app.dispose();
  });

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

  testWidgets('the welcome search turns the recent list into results, folders with their contents', (tester) async {
    final app = await loaded(tester);
    app.recentConnectionIds.add(srv.id);
    tester.view.physicalSize = const Size(1000, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ChangeNotifierProvider.value(
      value: app,
      child: const MaterialApp(home: Scaffold(body: WelcomePanel())),
    ));
    await tester.pump();
    expect(find.byKey(Key('welcome-recent-${srv.id}')), findsOneWidget);

    await tester.enterText(find.byKey(const Key('welcome-search')), 'customer');
    await tester.pump();
    expect(find.byKey(const Key('welcome-search-results')), findsOneWidget);
    expect(find.byKey(Key('welcome-recent-${srv.id}')), findsNothing, reason: 'the results take its place');
    for (final id in [site.id, inner.id, sw.id, fw.id]) {
      expect(find.byKey(Key('welcome-search-$id')), findsOneWidget);
    }

    // Down twice: past the folders to SWITCH-01, which Enter opens.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(app.tabs.single.connectionId, sw.id);

    // Esc empties the box and the recent list comes back.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.byKey(const Key('welcome-search-results')), findsNothing);
    expect(find.byKey(Key('welcome-recent-${srv.id}')), findsOneWidget);
    for (final t in app.tabs) {
      t.controller.dispose();
    }
    await tester.pumpWidget(const SizedBox());
    app.dispose();
  });

  testWidgets('a folder found from the welcome search is shown in the list', (tester) async {
    final app = await loaded(tester);
    await tester.pumpWidget(ChangeNotifierProvider.value(
      value: app,
      child: const MaterialApp(home: Scaffold(body: WelcomePanel())),
    ));
    await tester.pump();
    await tester.enterText(find.byKey(const Key('welcome-search')), 'folder a');
    await tester.pump();
    await tester.tap(find.byKey(Key('welcome-search-${inner.id}')));
    await tester.pump();
    expect(app.revealRequest.value, inner.id);
    expect(app.tabs, isEmpty);
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
    // The title bar has its search box in the middle, the welcome panel too.
    final box = tester.getCenter(find.byKey(const Key('quick-search-button')));
    expect((box.dx - 500).abs(), lessThan(1));
    expect(box.dy, lessThan(32));
    expect(tester.getTopLeft(find.byKey(const ValueKey('title-bar-name'))).dx,
        lessThan((Platform.isMacOS ? 78 : 0) + 24),
        reason: 'the name starts the bar, after the window buttons on a Mac');
    expect(find.byKey(const Key('welcome-search')), findsOneWidget);
    // Ctrl+K outside a terminal (inside one it belongs to the session)
    // opens where the mouse is, not in the title bar.
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(700, 90));
    await mouse.moveTo(const Offset(700, 90));
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('quick-search')), findsOneWidget);
    expect(find.byKey(const Key('quick-search-anchored')), findsNothing);
    expect(find.byKey(const Key('quick-search-at-pointer')), findsOneWidget);
    final atMouse = tester.getRect(find.byKey(const Key('quick-search')));
    expect(atMouse.top, greaterThan(90), reason: 'just under the mouse');
    expect(atMouse.top, lessThan(110));
    expect((atMouse.center.dx - 700).abs(), lessThan(1), reason: 'centred on it');
    await mouse.removePointer();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('quick-search')), findsNothing);
    app.connections.add(SavedConnection(name: 'DEVICE-01', host: '192.0.2.10'));
    app.openConnection(app.connections.single);
    await tester.pumpAndSettle();
    // With a session open it stays where it is.
    expect(tester.getCenter(find.byKey(const Key('quick-search-button'))), box);

    await tester.tap(find.byKey(const Key('quick-search-button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('quick-search')), findsOneWidget);
    // The box itself becomes the field, the same size and place, and the
    // results open under it.
    expect(find.byKey(const Key('quick-search-anchored')), findsOneWidget);
    final boxRect = tester.getRect(find.byKey(const Key('quick-search-button')));
    expect(tester.getRect(find.byKey(const Key('quick-search-box'))), boxRect);
    final panel = tester.getRect(find.byKey(const Key('quick-search')));
    expect(panel.top, greaterThan(boxRect.bottom));
    expect((panel.center.dx - box.dx).abs(), lessThan(1));
    await tester.enterText(find.byKey(const Key('quick-search-field')), 'DEVICE');
    await tester.pump();
    expect(tester.getRect(find.byKey(const Key('quick-search-box'))), boxRect, reason: 'typing keeps its size');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('quick-search')), findsNothing);

    expect(app.tabs, hasLength(1));
    for (final t in app.tabs) {
      t.controller.dispose();
    }
  });
}
