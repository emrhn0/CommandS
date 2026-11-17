import 'package:commands/models/models.dart';
import 'package:commands/providers/app_state.dart';
import 'package:commands/services/pane_layout.dart';
import 'package:commands/services/pty_session.dart';
import 'package:commands/services/session_controller.dart';
import 'package:commands/widgets/connection_tree.dart';
import 'package:commands/widgets/split_view_dialog.dart';
import 'package:commands/widgets/terminal_tabs.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeSession implements SessionController {
  _FakeSession(this.host);
  @override
  final String host;
  @override
  String? get tabTitle => host;
  @override
  SessionStatus status = SessionStatus.running;
  @override
  Stream<SessionStatus> get statusStream => const Stream.empty();
  @override
  void dispose() {}
}

OpenTab _tab(String id) => OpenTab(id: id, controller: _FakeSession('DEVICE-$id'));

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    PtySessionController.checkReachability = false;
  });
  tearDown(() => PtySessionController.checkReachability = true);

  group('model', () {
    test('an empty zone can stay as an empty pane', () {
      final shape = presetShape(SplitPreset.grid);
      final kept = buildFromShape(shape, ['a', null, 'c', 'd'], keepEmpty: true)!;
      expect(tabIdsInLayoutOrdered(kept), ['a', 'c', 'd']);
      final empties = <String>[];
      mapPanes(kept, (p) {
        if (p is PaneEmpty) empties.add(p.id);
        return p;
      });
      expect(empties, hasLength(1));

      final filled = fillEmptyPane(kept, empties.single, 'b');
      expect(tabIdsInLayoutOrdered(filled), ['a', 'b', 'c', 'd'], reason: 'in the empty place, not at the end');
      expect(tabIdsInLayoutOrdered(removeEmptyPane(kept, empties.single)), ['a', 'c', 'd']);
      expect(withoutEmptyPanes(kept) is PaneSplit, isTrue);
      expect(buildFromShape(shape, [null, null, null, null], keepEmpty: true), isNull);
    });
  });

  group('AppState', () {
    Future<AppState> splitWithEmpty() async {
      final app = AppState();
      await app.ready;
      app.tabs.addAll([_tab('a'), _tab('b'), _tab('c')]);
      app.applyLayout(buildFromShape(presetShape(SplitPreset.threeColumns), ['a', null, 'b'], keepEmpty: true));
      return app;
    }

    String emptyIdOf(AppState app) {
      String? id;
      mapPanes(app.paneLayout, (p) {
        if (p is PaneEmpty) id = p.id;
        return p;
      });
      return id!;
    }

    test('an applied layout keeps its empty pane, and a tab dropped there fills it', () async {
      final app = await splitWithEmpty();
      expect(app.activeGroupId, isNotNull);
      expect(tabIdsInLayoutOrdered(app.paneLayout), ['a', 'b']);
      app.dropTabInEmptyPane(emptyIdOf(app), 'c');
      expect(tabIdsInLayoutOrdered(app.paneLayout), ['a', 'c', 'b']);
      expect(app.activeGroup!.tabIds, ['a', 'c', 'b']);
    });

    test('a pane of the same split dropped on the empty one moves there', () async {
      final app = await splitWithEmpty();
      app.dropTabInEmptyPane(emptyIdOf(app), 'a');
      expect(tabIdsInLayoutOrdered(app.paneLayout), ['a', 'b']);
      final rects = <String>[];
      mapPanes(app.paneLayout, (p) {
        rects.add(p is PaneLeaf ? p.tabId : 'empty');
        return p;
      });
      expect(rects, ['empty', 'a', 'b'], reason: 'its old place is the empty one now');
    });

    test('closing a session leaves its pane empty; the layout keeps its shape', () async {
      final app = AppState();
      await app.ready;
      app.tabs.addAll([_tab('a'), _tab('b'), _tab('c'), _tab('d')]);
      app.applyLayout(buildFromShape(presetShape(SplitPreset.grid), ['a', 'b', 'c', 'd'], keepEmpty: true));
      List<String> panes() {
        final out = <String>[];
        mapPanes(app.paneLayout, (p) {
          out.add(p is PaneLeaf ? p.tabId : 'empty');
          return p;
        });
        return out;
      }

      app.closeTab(app.tabs.indexWhere((t) => t.id == 'b'));
      expect(panes(), ['a', 'empty', 'c', 'd'], reason: 'b closed: its place is empty, nothing moved');
      expect(app.activeGroup, isNotNull);

      app.takeOutOfSplit('d');
      expect(panes(), ['a', 'empty', 'c', 'empty'], reason: 'taken out to a tab of its own: same');
    });

    test('a split left with one session stays a split, its panes where they were', () async {
      final app = await splitWithEmpty();
      app.closeTab(app.tabs.indexWhere((t) => t.id == 'b'));
      expect(app.paneLayout, isA<PaneSplit>());
      expect(tabIdsInLayoutOrdered(app.paneLayout), ['a']);
      expect(app.activeGroup, isNotNull);
    });

    test('a folder opens with everything inside it, a subfolder only with its own', () async {
      final app = AppState();
      await app.ready;
      final parent = ConnectionFolder(name: 'Folder A');
      final sub = ConnectionFolder(name: 'Sub', parentId: parent.id);
      final other = ConnectionFolder(name: 'Folder B');
      app.folders.addAll([parent, sub, other]);
      app.connections.addAll([
        SavedConnection(name: 'DEVICE-01', host: '192.0.2.10', folderId: parent.id),
        SavedConnection(name: 'DEVICE-02', host: '192.0.2.11', folderId: sub.id),
        SavedConnection(name: 'DEVICE-03', host: '192.0.2.12', folderId: other.id),
      ]);
      expect(app.connectionsUnder(parent.id).map((c) => c.name), ['DEVICE-02', 'DEVICE-01']);
      expect(app.connectionsUnder(sub.id).map((c) => c.name), ['DEVICE-02']);
      expect(await app.openFolder(sub.id), 1);
      expect(app.tabs.single.controller.tabTitle, 'DEVICE-02');
      for (final t in app.tabs) {
        t.controller.dispose();
      }
    });
  });

  testWidgets('the empty pane shows in the split and takes a tab dragged from the strip', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final app = AppState();
    await tester.pump();
    app.tabs.addAll([
      OpenTab(id: 'a', controller: PtySessionController(host: '192.0.2.10', port: 22, startImmediately: false)),
      OpenTab(id: 'b', controller: PtySessionController(host: '192.0.2.11', port: 22, startImmediately: false)),
      OpenTab(id: 'c', controller: PtySessionController(host: '192.0.2.12', port: 22, startImmediately: false)),
    ]);
    app.applyLayout(buildFromShape(presetShape(SplitPreset.threeColumns), ['a', null, 'b'], keepEmpty: true));
    await tester.pumpWidget(ChangeNotifierProvider.value(
      value: app,
      child: const MaterialApp(home: Scaffold(body: TerminalTabsArea())),
    ));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Drop a tab here'), findsOneWidget);

    final chip = find.byKey(const ValueKey('tab-c'));
    final from = tester.getCenter(chip);
    final to = tester.getCenter(find.text('Drop a tab here'));
    final drag = await tester.startGesture(from, kind: PointerDeviceKind.mouse);
    await tester.pump();
    for (var i = 1; i <= 12; i++) {
      await drag.moveTo(Offset.lerp(from, to, i / 12)!);
      await tester.pump(const Duration(milliseconds: 16));
    }
    await drag.up();
    await tester.pump(const Duration(milliseconds: 100));
    expect(tabIdsInLayoutOrdered(app.paneLayout), ['a', 'c', 'b']);
    expect(find.text('Drop a tab here'), findsNothing);

    await tester.pumpWidget(const SizedBox());
    for (final t in app.tabs) {
      t.controller.dispose();
    }
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('a connection dragged from the list into an empty pane opens there', (tester) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final app = AppState();
    await tester.pump();
    final conn = SavedConnection(name: 'DEVICE-09', host: '192.0.2.19');
    app.connections.add(conn);
    app.tabs.addAll([
      OpenTab(id: 'a', controller: PtySessionController(host: '192.0.2.10', port: 22, startImmediately: false)),
      OpenTab(id: 'b', controller: PtySessionController(host: '192.0.2.11', port: 22, startImmediately: false)),
    ]);
    app.applyLayout(buildFromShape(presetShape(SplitPreset.threeColumns), ['a', null, 'b'], keepEmpty: true));
    await tester.pumpWidget(ChangeNotifierProvider.value(
      value: app,
      child: const MaterialApp(
        home: Scaffold(
          body: Row(children: [SizedBox(width: 280, child: ConnectionTree()), Expanded(child: TerminalTabsArea())]),
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 100));

    final from = tester.getCenter(find.text('DEVICE-09'));
    final to = tester.getCenter(find.text('Drop a tab here'));
    final drag = await tester.startGesture(from, kind: PointerDeviceKind.mouse);
    await tester.pump();
    for (var i = 1; i <= 12; i++) {
      await drag.moveTo(Offset.lerp(from, to, i / 12)!);
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(find.text('Drop here'), findsOneWidget);
    await drag.up();
    await tester.pump(const Duration(milliseconds: 100));

    // A new tab for it, in the empty pane's place; the split stays as it was.
    expect(app.tabs, hasLength(3));
    final opened = app.tabs.last;
    expect(opened.connectionId, conn.id);
    expect(tabIdsInLayoutOrdered(app.paneLayout), ['a', opened.id, 'b']);
    expect(app.groups.single.tabIds, ['a', opened.id, 'b']);
    expect(find.text('Drop a tab here'), findsNothing);

    await tester.pumpWidget(const SizedBox());
    for (final t in app.tabs) {
      t.controller.dispose();
    }
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('a tab in a short pane of the Split View window shows its name on one line', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final app = AppState();
    await tester.pump();
    // Four rows of two: panes far shorter than the stacked look needs.
    ZoneNode shape = presetShape(SplitPreset.stacked);
    shape = splitZone(shape, 0, Axis.vertical);
    shape = splitZone(shape, 2, Axis.vertical);
    for (var i = 3; i >= 0; i--) {
      shape = splitZone(shape, i, Axis.horizontal);
    }
    expect(zoneCount(shape), 8);
    await app.saveCustomLayout(CustomLayout(id: 'custom-8', name: 'Eight', shape: shape));
    app.tabs.addAll([for (var i = 1; i <= 8; i++) _tab('$i')]);
    app.paneLayout = const PaneLeaf('1');
    await tester.pumpWidget(ChangeNotifierProvider.value(
      value: app,
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(child: TextButton(onPressed: () => showSplitViewDialog(context), child: const Text('open'))),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Eight'));
    await tester.pumpAndSettle();
    for (var i = 3; i <= 8; i++) {
      await tester.tap(find.widgetWithText(GestureDetector, 'DEVICE-$i').last);
      await tester.pump();
    }
    await tester.pumpAndSettle();
    // No overflow, and each name is drawn in its pane.
    expect(tester.takeException(), isNull);
    expect(find.text('DEVICE-8'), findsNWidgets(2), reason: 'its pane and its chip');
  });

  testWidgets('right-click a folder: Open all connections', (tester) async {
    final app = AppState();
    await tester.pump();
    final folder = ConnectionFolder(name: 'Folder A');
    app.folders.add(folder);
    app.connections.addAll([
      SavedConnection(name: 'DEVICE-01', host: '192.0.2.10', folderId: folder.id),
      SavedConnection(name: 'DEVICE-02', host: '192.0.2.11', folderId: folder.id),
    ]);
    await tester.pumpWidget(ChangeNotifierProvider.value(
      value: app,
      child: const MaterialApp(home: Scaffold(body: SizedBox(width: 320, height: 500, child: ConnectionTree()))),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Folder A'), buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open all connections'));
    await tester.pumpAndSettle();
    expect(app.tabs.map((t) => t.controller.tabTitle), ['DEVICE-01', 'DEVICE-02']);
    // All made at once, the first one on screen.
    expect(app.activeTabIndex, 0);
    expect(app.paneLayout, isA<PaneLeaf>());
    expect((app.paneLayout! as PaneLeaf).tabId, app.tabs.first.id);
    await tester.pumpWidget(const SizedBox());
    for (final t in app.tabs) {
      t.controller.dispose();
    }
  });
}
