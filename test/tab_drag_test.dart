import 'package:commands/providers/app_state.dart';
import 'package:commands/services/pane_layout.dart';
import 'package:commands/services/pty_session.dart';
import 'package:commands/services/session_controller.dart';
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

void main() {
  late AppState app;

  group('state', () {
    setUp(() async {
      PtySessionController.checkReachability = false;
      SharedPreferences.setMockInitialValues({});
      app = AppState();
      await Future<void>.delayed(Duration.zero);
      for (final id in ['1', '2', '3']) {
        app.tabs.add(OpenTab(id: id, controller: _FakeSession('TAB-$id')));
      }
      app.setActiveTab(0);
    });

    List<String> order() => app.tabs.map((t) => t.id).toList();

    test('moving a tab keeps the active one active', () {
      app.moveTabs(['3'], '1');
      expect(order(), ['3', '1', '2']);
      expect(app.tabs[app.activeTabIndex].id, '1');
      app.moveTabs(['3'], null);
      expect(order(), ['1', '2', '3']);
    });

    test('a split moves as one', () {
      app.applyLayout(buildLayout(SplitPreset.sideBySide, ['1', '2']));
      app.moveTabs(['1', '2'], null);
      expect(order(), ['3', '1', '2']);
    });

    test('dropped beside a pane, a tab makes a split on that side', () {
      app.dropTabBeside('2', '1', PaneSide.left);
      expect(tabIdsInLayoutOrdered(app.paneLayout), ['2', '1']);
      expect((app.paneLayout! as PaneSplit).axis, Axis.horizontal);
      expect(app.groups, hasLength(1));
    });

    test('a third tab joins the split on screen, keeping its divider', () {
      app.dropTabBeside('2', '1', PaneSide.right);
      (app.paneLayout! as PaneSplit).ratio = 0.3;
      app.dropTabBeside('3', '2', PaneSide.bottom);
      expect(tabIdsInLayoutOrdered(app.paneLayout), ['1', '2', '3']);
      expect((app.paneLayout! as PaneSplit).ratio, 0.3);
      expect(app.groups, hasLength(1));
    });

    test('no more panes than Split view can show', () {
      app.tabs.add(OpenTab(id: '4', controller: _FakeSession('TAB-4')));
      app.tabs.add(OpenTab(id: '5', controller: _FakeSession('TAB-5')));
      app.dropTabBeside('2', '1', PaneSide.right);
      app.dropTabBeside('3', '1', PaneSide.bottom);
      app.dropTabBeside('4', '2', PaneSide.bottom);
      expect(app.canDropTabBeside('5', '1'), isFalse);
      app.dropTabBeside('5', '1', PaneSide.right);
      expect(tabIdsInLayout(app.paneLayout), hasLength(4));
    });

    test('a layout from the picker places the tab and fills the rest', () {
      app.dropTabInPreset('3', SplitPreset.sideBySide, 1);
      expect(tabIdsInLayoutOrdered(app.paneLayout), ['1', '3']);
      expect(order(), containsAll(['1', '2', '3']), reason: 'the tab that did not fit stays open');
    });

    test('paneSideAt reads the nearest edge, and nothing in the middle', () {
      const size = Size(100, 100);
      expect(paneSideAt(size, const Offset(5, 50)), PaneSide.left);
      expect(paneSideAt(size, const Offset(95, 50)), PaneSide.right);
      expect(paneSideAt(size, const Offset(50, 5)), PaneSide.top);
      expect(paneSideAt(size, const Offset(50, 95)), PaneSide.bottom);
      expect(paneSideAt(size, const Offset(50, 50)), isNull);
    });
  });

  group('mouse', () {
    Future<void> pumpTabs(WidgetTester tester) async {
      PtySessionController.checkReachability = false;
      SharedPreferences.setMockInitialValues({});
      app = AppState();
      await tester.pump();
      for (final id in ['1', '2', '3']) {
        app.tabs.add(
          OpenTab(
            id: id,
            controller: PtySessionController(host: '192.0.2.$id', port: 22, username: 'user1', tabTitle: 'TAB-$id'),
          ),
        );
      }
      app.setActiveTab(0);
      await tester.binding.setSurfaceSize(const Size(1000, 600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: app,
          child: const MaterialApp(home: Scaffold(body: TerminalTabsArea())),
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }

    Future<void> cleanUp(WidgetTester tester) async {
      for (final t in app.tabs) {
        t.controller.dispose();
      }
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
    }

    Future<TestGesture> lift(WidgetTester tester, Offset from, Offset to) async {
      final g = await tester.startGesture(from, kind: PointerDeviceKind.mouse);
      await tester.pump(const Duration(milliseconds: 50));
      for (var i = 1; i <= 10; i++) {
        await g.moveTo(Offset.lerp(from, to, i / 10)!);
        await tester.pump(const Duration(milliseconds: 16));
      }
      return g;
    }

    Future<void> drop(WidgetTester tester, TestGesture g) async {
      await g.up();
      await tester.pump(const Duration(milliseconds: 200));
    }

    testWidgets('a tab dragged along the strip changes place', (tester) async {
      await pumpTabs(tester);
      final to = tester.getTopLeft(find.text('TAB-1')).translate(-8, 8);
      await drop(tester, await lift(tester, tester.getCenter(find.text('TAB-3')), to));
      expect(app.tabs.map((t) => t.id), ['3', '1', '2']);
      expect(app.draggingTabId, isNull);
      await cleanUp(tester);
    });

    testWidgets('a click on a tab still selects it', (tester) async {
      await pumpTabs(tester);
      await tester.tap(find.text('TAB-2'));
      await tester.pump(const Duration(milliseconds: 50));
      expect(app.tabs[app.activeTabIndex].id, '2');
      await cleanUp(tester);
    });

    testWidgets('dragged to the edge of the pane, a preview shows and the drop splits', (tester) async {
      await pumpTabs(tester);
      final g = await lift(tester, tester.getCenter(find.text('TAB-2')), const Offset(960, 300));
      expect(find.byKey(const ValueKey('snap-preview')), findsOneWidget);
      await drop(tester, g);
      expect(tabIdsInLayoutOrdered(app.paneLayout), ['1', '2']);
      expect(app.draggingTabId, isNull, reason: 'RDP sessions must come back');
      expect(find.byKey(const ValueKey('snap-preview')), findsNothing);
      await cleanUp(tester);
    });

    testWidgets('dropped in the middle of the pane, nothing changes', (tester) async {
      await pumpTabs(tester);
      await drop(tester, await lift(tester, tester.getCenter(find.text('TAB-2')), const Offset(500, 320)));
      expect(tabIdsInLayoutOrdered(app.paneLayout), ['1']);
      expect(app.draggingTabId, isNull);
      await cleanUp(tester);
    });

    testWidgets('the layout picker appears on a drag and arranges the panes', (tester) async {
      await pumpTabs(tester);
      expect(find.byKey(const ValueKey('layout-sideBySide-1')), findsNothing);
      final from = tester.getCenter(find.text('TAB-2'));
      final g = await lift(tester, from, from + const Offset(0, 80));
      final slot = find.byKey(const ValueKey('layout-sideBySide-1'));
      expect(slot, findsOneWidget);
      final to = tester.getCenter(slot);
      for (var i = 1; i <= 5; i++) {
        await g.moveTo(Offset.lerp(from + const Offset(0, 80), to, i / 5)!);
        await tester.pump(const Duration(milliseconds: 16));
      }
      await drop(tester, g);
      expect(tabIdsInLayoutOrdered(app.paneLayout), ['1', '2']);
      expect(find.byKey(const ValueKey('layout-sideBySide-1')), findsNothing);
      await cleanUp(tester);
    });
  });
}
