import 'package:commands/models/models.dart';
import 'package:commands/providers/app_state.dart';
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

  Future<void> showTabs(WidgetTester tester, AppState app) async {
    tester.view.physicalSize = const Size(1000, 650);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: const MaterialApp(home: Scaffold(body: TerminalTabsArea())),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }

  Future<void> duplicateFromMenu(WidgetTester tester, OpenTab original) async {
    final tab = tester.getRect(find.byKey(ValueKey('tab-${original.id}')));
    await tester.tapAt(
      Offset(tab.right - 8, tab.center.dy),
      buttons: kSecondaryMouseButton,
    );
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('Reconnect'), findsOneWidget);
    expect(find.text('Duplicate'), findsOneWidget);
    await tester.tap(find.text('Duplicate'));
    await tester.pump(const Duration(milliseconds: 100));
  }

  testWidgets('saved SSH tab duplicates into an independent active tab', (
    tester,
  ) async {
    final app = AppState();
    await tester.pump();
    final saved = SavedConnection(
      name: 'DEVICE-01',
      host: '192.0.2.10',
      port: 2222,
      username: 'user1',
      recordSessionByDefault: true,
    );
    app.connections.add(saved);
    await app.openConnection(saved);
    final original = app.tabs.single;
    await showTabs(tester, app);
    await duplicateFromMenu(tester, original);

    expect(app.tabs, hasLength(2));
    expect(app.tabs.first, same(original));
    final copy = app.tabs.last;
    expect(copy.id, isNot(original.id));
    expect(copy.controller, isNot(same(original.controller)));
    expect(copy.connectionId, saved.id);
    expect(app.activeTabIndex, 1);
    final ssh = copy.controller as PtySessionController;
    expect(ssh.host, saved.host);
    expect(ssh.port, saved.port);
    expect(ssh.connectionForDuplicate().username, saved.username);
    expect(ssh.recordByDefault, isTrue);

    await tester.pumpWidget(const SizedBox());
    for (final tab in app.tabs) {
      tab.controller.dispose();
    }
    app.dispose();
  });

  testWidgets(
    'quick SSH tab duplicates its current username and remains unsaved',
    (tester) async {
      final app = AppState();
      await tester.pump();
      final ssh = PtySessionController(
        host: '198.51.100.20',
        port: 2200,
        username: 'user2',
        startImmediately: false,
      );
      final original = OpenTab(id: 'quick', controller: ssh);
      app.tabs.add(original);
      app.setActiveTab(0);
      await showTabs(tester, app);
      await duplicateFromMenu(tester, original);

      expect(app.tabs, hasLength(2));
      expect(app.tabs.first, same(original));
      final copy = app.tabs.last;
      expect(copy.controller, isNot(same(ssh)));
      final copiedSsh = copy.controller as PtySessionController;
      expect(copiedSsh.host, ssh.host);
      expect(copiedSsh.port, ssh.port);
      expect(copiedSsh.connectionForDuplicate().username, 'user2');
      expect(app.unsavedConnectionOf(copy), isNotNull);
      expect(app.connections, isEmpty);

      await tester.pumpWidget(const SizedBox());
      for (final tab in app.tabs) {
        tab.controller.dispose();
      }
      app.dispose();
    },
  );

  test('duplicate settings retain the saved SSH password in memory', () {
    final ssh = PtySessionController(
      host: '192.0.2.30',
      port: 22,
      username: 'user1',
      password: 'example-password',
      startImmediately: false,
    );
    final duplicate = ssh.connectionForDuplicate(id: 'saved-connection');
    expect(duplicate.id, 'saved-connection');
    expect(duplicate.rememberPassword, isTrue);
    expect(duplicate.password, 'example-password');
    ssh.dispose();
  });
}
