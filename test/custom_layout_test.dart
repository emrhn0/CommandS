import 'package:commands/models/models.dart';
import 'package:commands/providers/app_state.dart';
import 'package:commands/services/pane_layout.dart';
import 'package:commands/services/session_controller.dart';
import 'package:commands/widgets/split_view_dialog.dart';
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

Future<AppState> _loaded() async {
  final app = AppState();
  await app.ready;
  return app;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('shapes', () {
    test('every preset as a shape has the same panes as before', () {
      for (final p in SplitPreset.values) {
        final shape = presetShape(p);
        expect(zoneCount(shape), p.slots, reason: p.name);
        final got = zoneRects(shape);
        final want = presetSlotRects(p);
        for (var i = 0; i < want.length; i++) {
          expect(got[i].left, closeTo(want[i].left, 1e-9), reason: '${p.name} $i');
          expect(got[i].top, closeTo(want[i].top, 1e-9), reason: '${p.name} $i');
          expect(got[i].right, closeTo(want[i].right, 1e-9), reason: '${p.name} $i');
          expect(got[i].bottom, closeTo(want[i].bottom, 1e-9), reason: '${p.name} $i');
        }
      }
    });

    test('split, remove and resize zones', () {
      ZoneNode shape = const ZoneLeaf();
      shape = splitZone(shape, 0, Axis.horizontal); // 1 | 2
      shape = splitZone(shape, 1, Axis.vertical); // 1 | (2 / 3)
      expect(zoneCount(shape), 3);
      expect(zoneRects(shape)[2], const Rect.fromLTRB(0.5, 0.5, 1, 1));

      shape = setZoneRatio(shape, const [], 0.25);
      expect(zoneRects(shape)[0].right, 0.25);
      shape = setZoneRatio(shape, const [], 0.0);
      expect(zoneRects(shape)[0].right, minZoneRatio, reason: 'no pane thinner than the minimum');

      shape = removeZone(shape, 1);
      expect(zoneCount(shape), 2);
      expect(zoneRects(shape)[1], Rect.fromLTRB(minZoneRatio, 0, 1, 1), reason: 'the neighbour takes the room');
      expect(zoneCount(removeZone(const ZoneLeaf(), 0)), 1, reason: 'the last pane stays');
    });

    test('a shape is filled in zone order; empty zones collapse', () {
      final shape = presetShape(SplitPreset.grid);
      final tree = buildFromShape(shape, ['a', null, 'c', 'd']);
      expect(tabIdsInLayoutOrdered(tree), ['a', 'c', 'd']);
      expect(buildFromShape(shape, [null, null]), isNull);
    });

    test('a double click makes the whole row even, not just two panes', () {
      // Three side by side, uneven: two nested splits.
      var shape = splitZone(splitZone(const ZoneLeaf(), 0, Axis.horizontal, ratio: 0.2), 1, Axis.horizontal, ratio: 0.7);
      shape = splitZone(shape, 0, Axis.vertical); // the first column also split top and bottom
      final even = equalizeZones(shape, const [true]); // the inner divider
      final rects = zoneRects(even);
      expect(rects[0].right, closeTo(1 / 3, 1e-9));
      expect(rects[2].left, closeTo(1 / 3, 1e-9));
      expect(rects[3].left, closeTo(2 / 3, 1e-9));
      expect(rects[1].top, 0.5, reason: 'the split across the first column stays as it was');
    });

    test('a ratio near a half, third or quarter snaps to it', () {
      expect(snapZoneRatio(0.34), 1 / 3);
      expect(snapZoneRatio(0.49), 0.5);
      expect(snapZoneRatio(0.26), 0.25);
      expect(snapZoneRatio(0.41), 0.41);
    });

    test('JSON keeps a shape and survives a broken one', () {
      final shape = splitZone(presetShape(SplitPreset.threeColumns), 2, Axis.vertical);
      final again = ZoneNode.fromJson(shape.toJson());
      expect(zoneRects(again), zoneRects(shape));
      expect(zoneCount(ZoneNode.fromJson('nonsense')), 1);
      expect(zoneCount(ZoneNode.fromJson({'split': 'horizontal', 'ratio': 5})), 2);
    });
  });

  group('kept in AppState', () {
    test('custom layouts are saved, renamed and deleted across restarts', () async {
      final app = await _loaded();
      final layout = CustomLayout(
        id: 'custom-1',
        name: 'Wide left',
        shape: setZoneRatio(presetShape(SplitPreset.sideBySide), const [], 0.7),
      );
      await app.saveCustomLayout(layout);
      var again = await _loaded();
      expect(again.customLayouts.single.name, 'Wide left');
      expect(zoneRects(again.customLayouts.single.shape)[0].right, closeTo(0.7, 1e-9));

      await again.saveCustomLayout(CustomLayout(id: 'custom-1', name: 'Renamed', shape: layout.shape));
      again = await _loaded();
      expect(again.customLayouts.map((l) => l.name), ['Renamed']);

      await again.deleteCustomLayout('custom-1');
      expect((await _loaded()).customLayouts, isEmpty);
    });

    test('a saved arrangement keeps its custom shape, even after the custom layout is gone', () async {
      final app = await _loaded();
      final a = SavedConnection(name: 'DEVICE-01', host: '192.0.2.10');
      final b = SavedConnection(name: 'DEVICE-02', host: '192.0.2.11');
      final c = SavedConnection(name: 'DEVICE-03', host: '192.0.2.12');
      app.connections.addAll([a, b, c]);
      app.tabs.addAll([
        OpenTab(id: 't1', controller: _FakeSession('one'), connectionId: a.id),
        OpenTab(id: 't2', controller: _FakeSession('two'), connectionId: b.id),
        OpenTab(id: 't3', controller: _FakeSession('three'), connectionId: c.id),
      ]);
      final shape = splitZone(splitZone(const ZoneLeaf(), 0, Axis.vertical), 1, Axis.horizontal);
      final saved = await app.saveLayout(name: 'Top + two', folderId: null, shape: shape, tabIds: ['t1', 't2', 't3']);
      expect(saved.preset, 'custom');
      expect(SavedLayout.fromJson(saved.toJson()).shape, isNotNull);

      expect(app.openLayout(saved), 3);
      final root = app.paneLayout as PaneSplit;
      expect(root.axis, Axis.vertical, reason: 'the custom shape, not a preset');
      expect(tabIdsInLayoutOrdered(root), ['t1', 't2', 't3']);
    });
  });

  testWidgets('Custom: draw a layout, pick it, apply it, then delete it', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final app = AppState();
    await tester.pump();
    app.tabs.addAll([
      OpenTab(id: 'a', controller: _FakeSession('DEVICE-01')),
      OpenTab(id: 'b', controller: _FakeSession('DEVICE-02')),
      OpenTab(id: 'c', controller: _FakeSession('DEVICE-03')),
    ]);
    app.paneLayout = const PaneLeaf('a');
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
    expect(find.text('1. Choose a layout'), findsOneWidget);

    // The Custom tile opens the editor with one zone.
    await tester.tap(find.byKey(const ValueKey('custom-layout-new')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('zone-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('zone-1')), findsNothing);
    final canvas = tester.getRect(find.byKey(const ValueKey('zone-canvas')));

    // Over a zone a line follows the mouse: horizontal to begin with.
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: canvas.topLeft + const Offset(5, 5));
    addTearDown(mouse.removePointer);
    await mouse.moveTo(canvas.topLeft + Offset(canvas.width * 0.3, canvas.height * 0.5));
    await tester.pump();
    expect(find.byKey(const ValueKey('split-preview')), findsOneWidget);

    // Vertical line, click at 30 % across: two zones side by side, split there.
    await tester.tap(find.text('Vertical split'));
    await tester.pumpAndSettle();
    await tester.tapAt(canvas.topLeft + Offset(canvas.width * 0.3, canvas.height * 0.5));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('zone-1')), findsOneWidget);
    expect(tester.getRect(find.byKey(const ValueKey('zone-0'))).right, closeTo(canvas.left + canvas.width * 0.3, 8));

    // Horizontal line, click in the right zone: it splits top and bottom.
    await tester.tap(find.text('Horizontal split'));
    await tester.pumpAndSettle();
    final right = tester.getRect(find.byKey(const ValueKey('zone-1')));
    await tester.tapAt(right.center);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('zone-2')), findsOneWidget);

    // The divider stays under the mouse while dragged.
    final divider = find.byKey(const ValueKey('zone-divider-'));
    final from = tester.getCenter(divider);
    final to = Offset(canvas.left + canvas.width * 0.7, from.dy);
    final drag = await tester.startGesture(from, kind: PointerDeviceKind.mouse);
    for (var i = 1; i <= 10; i++) {
      await drag.moveTo(Offset.lerp(from, to, i / 10)!);
      await tester.pump();
    }
    expect(tester.getCenter(divider).dx, closeTo(to.dx, canvas.width * 0.02));
    expect(find.text('70% | 30%'), findsOneWidget, reason: 'the shares show while dragging');
    await drag.up();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('zone-share')), findsNothing);

    expect(tester.widget<ElevatedButton>(find.byKey(const ValueKey('custom-layout-save'))).onPressed, isNull,
        reason: 'a name is needed');
    await tester.enterText(find.byKey(const ValueKey('custom-layout-name')), 'Mine');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('custom-layout-save')));
    await tester.pumpAndSettle();

    final custom = app.customLayouts.single;
    expect(custom.name, 'Mine');
    expect(zoneCount(custom.shape), 3);
    expect(zoneRects(custom.shape)[0].right, closeTo(0.7, 0.02));
    expect(find.text('Mine'), findsWidgets, reason: 'its tile is next to the presets, and picked');

    // The third pane starts empty; a click on a tab fills it.
    await tester.tap(find.text('DEVICE-03'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();
    final root = app.paneLayout as PaneSplit;
    expect(root.ratio, closeTo(0.7, 0.02));
    expect(tabIdsInLayoutOrdered(root), ['a', 'b', 'c']);

    // Back in the dialog, the pencil on its tile edits or deletes it.
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('edit-custom-thumb-${custom.id}')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('custom-layout-delete')));
    await tester.pumpAndSettle();
    expect(app.customLayouts, isEmpty);
    expect(find.text('Mine'), findsNothing);
  });
}
