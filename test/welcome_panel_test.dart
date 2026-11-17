import 'package:commands/models/models.dart';
import 'package:commands/providers/app_state.dart';
import 'package:commands/services/pty_session.dart';
import 'package:commands/widgets/launch_splash.dart';
import 'package:commands/widgets/terminal_tabs.dart';
import 'package:commands/widgets/welcome_panel.dart';
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

  SavedConnection conn(String name, {ConnectionProtocol protocol = ConnectionProtocol.ssh}) => SavedConnection(
        name: name,
        host: '192.0.2.${name.hashCode % 200 + 1}',
        port: protocol == ConnectionProtocol.rdp ? 3389 : 22,
        protocol: protocol,
      );

  Future<void> closeAll(WidgetTester tester, AppState app) async {
    await tester.pumpWidget(const SizedBox());
    for (final tab in app.tabs) {
      tab.controller.dispose();
    }
    app.dispose();
  }

  group('recent connections', () {
    testWidgets('opening a saved connection puts it first, kept after a restart', (tester) async {
      final app = AppState();
      await tester.pump();
      final a = conn('DEVICE-01');
      final b = conn('DEVICE-02');
      app.connections.addAll([a, b]);
      await app.openConnection(a);
      await app.openConnection(b);
      await app.openConnection(a);
      expect(app.recentConnections, [a, b]);
      await tester.pump();
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList('commands.recentConnections'), [a.id, b.id]);
      await closeAll(tester, app);
    });

    testWidgets('a quick connection is not remembered, and the list stops at six', (tester) async {
      final app = AppState();
      await tester.pump();
      final saved = [for (var i = 1; i <= 8; i++) conn('DEVICE-0$i')];
      app.connections.addAll(saved);
      for (final c in saved) {
        await app.openConnection(c);
      }
      await app.openConnection(conn('UNSAVED'));
      expect(app.recentConnectionIds, hasLength(AppState.maxRecentConnections));
      expect(app.recentConnections.first, saved.last);
      await closeAll(tester, app);
    });

    testWidgets('a deleted connection drops out of the list', (tester) async {
      final app = AppState();
      await tester.pump();
      final a = conn('DEVICE-01');
      final b = conn('DEVICE-02');
      app.connections.addAll([a, b]);
      await app.openConnection(a);
      await app.openConnection(b);
      app.connections.remove(a);
      expect(app.recentConnections, [b]);
      await closeAll(tester, app);
    });
  });

  group('welcome panel', () {
    Future<AppState> show(WidgetTester tester, {List<SavedConnection> recent = const []}) async {
      tester.view.physicalSize = const Size(1000, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final app = AppState();
      await tester.pump();
      app.connections.addAll(recent);
      app.recentConnectionIds = [for (final c in recent) c.id];
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: app,
          child: const MaterialApp(home: Scaffold(body: TerminalTabsArea())),
        ),
      );
      await tester.pump();
      return app;
    }

    testWidgets('shows with no tab open, and lists the recent connections', (tester) async {
      final a = conn('DEVICE-01');
      final b = conn('SERVER-A', protocol: ConnectionProtocol.rdp);
      final app = await show(tester, recent: [a, b]);
      expect(find.byKey(const Key('welcome-panel')), findsOneWidget);
      expect(find.text('2 connections, 0 folders'), findsOneWidget);
      expect(find.text('DEVICE-01'), findsOneWidget);
      expect(find.text('SERVER-A'), findsOneWidget);
      expect(find.text('RDP'), findsOneWidget);
      expect(find.text(b.host), findsOneWidget, reason: 'the default port is not repeated');
      await closeAll(tester, app);
    });

    testWidgets('one click on a recent connection opens it and the panel goes', (tester) async {
      final a = conn('DEVICE-01');
      final app = await show(tester, recent: [a]);
      await tester.tap(find.byKey(Key('welcome-recent-${a.id}')));
      await tester.pump(const Duration(milliseconds: 100));
      expect(app.tabs.single.connectionId, a.id);
      expect(find.byKey(const Key('welcome-panel')), findsNothing);
      await closeAll(tester, app);
    });

    testWidgets('with nothing opened yet it says how to start', (tester) async {
      final app = await show(tester);
      expect(find.textContaining('Pick a saved connection on the left'), findsOneWidget);
      expect(find.byKey(const Key('welcome-new-connection')), findsOneWidget);
      await closeAll(tester, app);
    });

    test('the greeting follows the time of day', () {
      expect(WelcomePanel.greetingFor(DateTime(2026, 1, 1, 8)), 'Good morning');
      expect(WelcomePanel.greetingFor(DateTime(2026, 1, 1, 14)), 'Good afternoon');
      expect(WelcomePanel.greetingFor(DateTime(2026, 1, 1, 21)), 'Good evening');
      expect(WelcomePanel.greetingFor(DateTime(2026, 1, 1, 2)), 'Good evening');
    });
  });

  group('launch splash', () {
    tearDown(() => LaunchSplash.enabled = false);

    testWidgets('is off under flutter test, so the app shows at once', (tester) async {
      expect(LaunchSplash.enabled, isFalse);
      await tester.pumpWidget(const MaterialApp(home: LaunchSplash(child: Text('app'))));
      expect(find.text('app'), findsOneWidget);
      expect(find.byKey(const Key('launch-splash')), findsNothing);
    });

    testWidgets('shows the name over the app, lets clicks through, then goes', (tester) async {
      LaunchSplash.enabled = true;
      var taps = 0;
      await tester.pumpWidget(MaterialApp(
        home: LaunchSplash(
          child: Center(child: TextButton(onPressed: () => taps++, child: const Text('app'))),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byKey(const Key('launch-splash')), findsOneWidget);
      expect(find.text('S'), findsNothing, reason: 'the name is one rich text');
      await tester.tap(find.text('app'), warnIfMissed: false);
      expect(taps, 1, reason: 'the app underneath is already live');
      await tester.pump(LaunchSplash.duration);
      await tester.pump();
      expect(find.byKey(const Key('launch-splash')), findsNothing);
      expect(find.text('app'), findsOneWidget);
    });
  });
}
