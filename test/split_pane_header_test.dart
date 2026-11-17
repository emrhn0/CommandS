import 'package:commands/providers/app_state.dart';
import 'package:commands/services/pane_layout.dart';
import 'package:commands/services/pty_session.dart';
import 'package:commands/widgets/terminal_tabs.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    PtySessionController.checkReachability = false;
  });
  tearDown(() => PtySessionController.checkReachability = true);

  OpenTab sshTab(String id, String title, String host) => OpenTab(
    id: id,
    controller: PtySessionController(host: host, port: 22, tabTitle: title, startImmediately: false),
  );

  Future<AppState> showSplit(WidgetTester tester, {bool split = true}) async {
    tester.view.physicalSize = const Size(1200, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final app = AppState();
    await tester.pump();
    app.tabs.addAll([
      sshTab('a', 'DEVICE-01', '192.0.2.10'),
      sshTab('b', 'DEVICE-02', '192.0.2.11'),
      sshTab('c', 'DEVICE-03', '198.51.100.20'),
    ]);
    if (split) {
      app.applyLayout(buildLayout(SplitPreset.sideBySide, ['a', 'b']));
    } else {
      app.setActiveTab(0);
    }
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: const MaterialApp(home: Scaffold(body: TerminalTabsArea())),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    return app;
  }

  Future<void> cleanUp(WidgetTester tester, AppState app) async {
    await tester.pumpWidget(const SizedBox());
    for (final tab in app.tabs) {
      tab.controller.dispose();
    }
    app.dispose();
  }

  testWidgets('a split shows one tab at the top and a small tab bar per pane', (tester) async {
    final app = await showSplit(tester);
    expect(app.activeGroupId, isNotNull);

    // The strip: the split's own tab and the tab outside it, nothing for
    // the sessions inside the split.
    expect(find.byKey(ValueKey('group-${app.activeGroupId}')), findsOneWidget);
    expect(find.byKey(const ValueKey('member-a')), findsNothing);
    expect(find.byKey(const ValueKey('member-b')), findsNothing);
    expect(find.byKey(const ValueKey('tab-c')), findsOneWidget);

    // Each pane: its own bar with the session's name, above that pane.
    final headerA = find.byKey(const ValueKey('pane-header-a'));
    final headerB = find.byKey(const ValueKey('pane-header-b'));
    expect(headerA, findsOneWidget);
    expect(headerB, findsOneWidget);
    expect(find.descendant(of: headerA, matching: find.text('DEVICE-01')), findsOneWidget);
    expect(find.descendant(of: headerB, matching: find.text('DEVICE-02')), findsOneWidget);
    expect(tester.getCenter(headerA).dx, lessThan(tester.getCenter(headerB).dx));
    expect(find.byKey(const ValueKey('pane-header-c')), findsNothing);

    await cleanUp(tester, app);
  });

  testWidgets('the close button on a pane bar closes only that session', (tester) async {
    final app = await showSplit(tester);
    await tester.tap(find.byKey(const ValueKey('pane-close-b')));
    await tester.pump(const Duration(milliseconds: 100));

    expect(app.tabs.map((t) => t.id), ['a', 'c']);
    // One session left: the split stays, b's pane is empty now.
    expect(find.byKey(const ValueKey('pane-header-a')), findsOneWidget);
    expect(find.text('Drop a tab here'), findsOneWidget);
    await cleanUp(tester, app);
  });

  testWidgets('a pane dragged by its bar onto another swaps with it; no layout picker over a split', (tester) async {
    final app = await showSplit(tester);
    final from = tester.getCenter(find.byKey(const ValueKey('pane-header-a')));
    final to = tester.getCenter(find.byKey(const ValueKey('b')));
    final drag = await tester.startGesture(from, kind: PointerDeviceKind.mouse);
    await tester.pump();
    for (var i = 1; i <= 12; i++) {
      await drag.moveTo(Offset.lerp(from, to, i / 12)!);
      await tester.pump(const Duration(milliseconds: 16));
      expect(find.byKey(const ValueKey('layout-sideBySide-0')), findsNothing,
          reason: 'the layout was set in Split View');
    }
    await drag.up();
    await tester.pump(const Duration(milliseconds: 100));
    expect(tabIdsInLayoutOrdered(app.paneLayout), ['b', 'a']);
    await cleanUp(tester, app);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('one click moves the keyboard to the other pane, at once', (tester) async {
    final app = await showSplit(tester);

    /// Which pane's terminal has the keyboard: the tab id of its pane.
    String? focusedPane() {
      final context = tester.binding.focusManager.primaryFocus?.context;
      String? id;
      context?.visitAncestorElements((e) {
        final key = e.widget.key;
        if (key is ValueKey<String> && (key.value == 'a' || key.value == 'b')) {
          id = key.value;
          return false;
        }
        return true;
      });
      return id;
    }

    Future<void> pressOn(String paneId) async {
      final pane = tester.getRect(find.byKey(ValueKey(paneId)));
      final gesture = await tester.startGesture(pane.center, kind: PointerDeviceKind.mouse);
      await tester.pump();
      // Pointer still down: the switch must not wait for the click to end
      // or for a double click to be ruled out.
      expect(focusedPane(), paneId);
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 400));
      expect(focusedPane(), paneId);
    }

    await pressOn('b');
    await pressOn('a');
    await pressOn('b');

    await cleanUp(tester, app);
  });

  testWidgets('a single pane has no pane bar', (tester) async {
    final app = await showSplit(tester, split: false);
    expect(find.byKey(const ValueKey('pane-header-a')), findsNothing);
    expect(find.byKey(const ValueKey('tab-a')), findsOneWidget);
    await cleanUp(tester, app);
  });
}
