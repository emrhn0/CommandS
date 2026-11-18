import 'package:commands/providers/app_state.dart';
import 'package:commands/services/pane_layout.dart';
import 'package:commands/services/pty_session.dart';
import 'package:commands/widgets/terminal_tabs.dart';
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

  late Map<String, List<String>> sent;

  OpenTab sshTab(String id, String title, String host) {
    final c = PtySessionController(host: host, port: 22, tabTitle: title, startImmediately: false);
    c.writeOverride = (data) => sent[id]!.add(data);
    sent[id] = [];
    return OpenTab(id: id, controller: c);
  }

  PtySessionController session(AppState app, String id) =>
      app.tabs.firstWhere((t) => t.id == id).controller as PtySessionController;

  /// Typing on the keyboard into [id]'s terminal.
  void type(AppState app, String id, String text) => session(app, id).terminal.textInput(text);

  Future<AppState> showSplit(WidgetTester tester) async {
    sent = {};
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
    app.applyLayout(buildLayout(SplitPreset.sideBySide, ['a', 'b']));
    await tester.pumpWidget(ChangeNotifierProvider.value(
      value: app,
      child: const MaterialApp(home: Scaffold(body: TerminalTabsArea())),
    ));
    await tester.pump(const Duration(milliseconds: 100));
    return app;
  }

  Future<void> cleanUp(WidgetTester tester, AppState app) async {
    await tester.pumpWidget(const SizedBox());
    for (final tab in app.tabs) {
      (tab.controller as PtySessionController).writeOverride = null;
      tab.controller.dispose();
    }
    app.dispose();
  }

  testWidgets('each split pane has a tick; ticked panes get what is typed into any of them', (tester) async {
    final app = await showSplit(tester);
    expect(find.byKey(const ValueKey('pane-broadcast-a')), findsOneWidget);
    expect(find.byKey(const ValueKey('pane-broadcast-b')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('pane-broadcast-a')));
    await tester.tap(find.byKey(const ValueKey('pane-broadcast-b')));
    await tester.pump();
    expect(find.text('Multi-type'), findsNWidgets(2));

    type(app, 'a', 'show vlan\r');
    expect(sent['a'], ['show vlan\r']);
    expect(sent['b'], ['show vlan\r']);
    type(app, 'b', 'exit\r');
    expect(sent['a'], ['show vlan\r', 'exit\r']);
    expect(sent['c'], isEmpty, reason: 'not ticked, not in the split');
    await cleanUp(tester, app);
  });

  testWidgets('unticking stops it, and one ticked pane alone types only into itself', (tester) async {
    final app = await showSplit(tester);
    app.toggleBroadcast('a');
    app.toggleBroadcast('b');
    app.toggleBroadcast('b');
    await tester.pump();
    type(app, 'a', 'x');
    expect(sent['a'], ['x']);
    expect(sent['b'], isEmpty);
    expect(find.text('Multi-type'), findsOneWidget);
    await cleanUp(tester, app);
  });

  testWidgets('what an agent sends is not repeated into the other panes', (tester) async {
    final app = await showSplit(tester);
    app.toggleBroadcast('a');
    app.toggleBroadcast('b');
    session(app, 'a').sendInput('show version\r');
    expect(sent['a'], ['show version\r']);
    expect(sent['b'], isEmpty);
    await cleanUp(tester, app);
  });

  testWidgets('a closed tab leaves the group', (tester) async {
    final app = await showSplit(tester);
    app.toggleBroadcast('a');
    app.toggleBroadcast('b');
    app.closeTab(app.tabs.indexWhere((t) => t.id == 'b'));
    await tester.pump();
    expect(app.broadcastTabIds, {'a'});
    await cleanUp(tester, app);
  });
}
