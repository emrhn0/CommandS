import 'package:commands/models/models.dart';
import 'package:commands/providers/app_state.dart';
import 'package:commands/services/pty_session.dart';
import 'package:commands/theme/app_mark.dart';
import 'package:commands/widgets/launch_splash.dart';
import 'package:commands/widgets/terminal_tabs.dart';
import 'package:commands/widgets/welcome_panel.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
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
    Future<AppState> show(WidgetTester tester,
        {List<SavedConnection> recent = const [], List<SavedConnection> saved = const []}) async {
      tester.view.physicalSize = const Size(1000, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final app = AppState();
      await tester.pump();
      app.connections.addAll(recent);
      app.connections.addAll(saved);
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
      // The numbers in small cards: saved, open now, opened today, folders.
      Text stat(String key) => tester.widget<Text>(
          find.descendant(of: find.byKey(ValueKey('welcome-stat-$key')), matching: find.byType(Text)).first);
      expect(stat('connections').data, '2');
      expect(stat('open').data, '0');
      expect(stat('folders').data, '0');
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

    testWidgets('the header is the mark, CommandS in two colours, a pulsing dot and the line', (tester) async {
      final app = await show(tester);
      expect(find.byType(AppMark), findsOneWidget);
      final word = tester.widget<Text>(find.byKey(const Key('welcome-wordmark'))).textSpan! as TextSpan;
      expect(word.toPlainText(), 'CommandS');
      final s = word.children!.last as TextSpan;
      expect(s.text, 'S');
      expect(s.style!.color, Theme.of(tester.element(find.byType(AppMark))).colorScheme.primary);
      expect(find.byKey(const Key('wordmark-cursor')), findsOneWidget, reason: 'a terminal cursor after the name');
      expect(find.byKey(const Key('welcome-pulse')), findsOneWidget);
      await closeAll(tester, app);
    });

    testWidgets('the line changes while the panel stays up', (tester) async {
      final app = await show(tester);
      await app.setBatterySaverEnabled(false);
      await tester.pump();
      String line() => tester
          .widget<Text>(find.descendant(of: find.byType(AnimatedSwitcher), matching: find.byType(Text)).last)
          .data!;
      final first = line();
      await tester.pump(WelcomePanel.rotateEvery);
      await tester.pump(const Duration(milliseconds: 400));
      expect(line(), isNot(first));
      await closeAll(tester, app);
    });

    testWidgets('battery saver stops idle frames and greeting rotation until turned off', (tester) async {
      final oldAnimate = WelcomePanel.animate;
      WelcomePanel.animate = true;
      addTearDown(() => WelcomePanel.animate = oldAnimate);
      final app = await show(tester);
      String line() => tester
          .widget<Text>(find.descendant(of: find.byType(AnimatedSwitcher), matching: find.byType(Text)).last)
          .data!;
      final first = line();
      await tester.pump(WelcomePanel.rotateEvery);
      expect(line(), first);
      expect(tester.binding.hasScheduledFrame, isFalse);

      await app.setBatterySaverEnabled(false);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      expect(tester.binding.hasScheduledFrame, isTrue);

      await app.setBatterySaverEnabled(true);
      await tester.pump();
      await tester.pump(WelcomePanel.rotateEvery);
      expect(line(), first);
      expect(tester.binding.hasScheduledFrame, isFalse);
      await closeAll(tester, app);
    });

    testWidgets('a matching address suffix goes in the right column of a recent connection', (tester) async {
      final named = SavedConnection(name: 'SWITCH-01 - 192.0.2.30', host: '192.0.2.30');
      final plain = SavedConnection(name: 'DEVICE-01', host: '192.0.2.31');
      final customPort = SavedConnection(name: 'DEVICE-02 - 192.0.2.32', host: '192.0.2.32', port: 2222);
      final app = await show(tester, recent: [named, plain, customPort]);
      final formattedAddress = find.text(named.host);
      final plainAddress = find.text(plain.host);
      expect(formattedAddress, findsOneWidget);
      expect(tester.getTopRight(formattedAddress).dx, tester.getTopRight(plainAddress).dx);
      expect(find.text('SWITCH-01'), findsOneWidget);
      expect(find.text('DEVICE-02'), findsOneWidget);
      expect(find.text('192.0.2.32:2222'), findsOneWidget);
      expect(named.name, 'SWITCH-01 - 192.0.2.30');
      await closeAll(tester, app);
    });

    testWidgets('hovering a recent connection lights it up with an arrow and a hand cursor', (tester) async {
      final a = conn('DEVICE-01');
      final app = await show(tester, recent: [a]);
      final arrow = find.byKey(Key('welcome-recent-arrow-${a.id}'));
      double arrowOpacity() =>
          tester.widget<AnimatedOpacity>(find.ancestor(of: arrow, matching: find.byType(AnimatedOpacity))).opacity;
      expect(arrowOpacity(), 0);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      await tester.pump();
      await mouse.moveTo(tester.getCenter(find.byKey(Key('welcome-recent-${a.id}'))));
      await tester.pump(const Duration(milliseconds: 200));
      expect(arrowOpacity(), 1);
      expect(
        RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1),
        SystemMouseCursors.click,
      );
      await mouse.moveTo(Offset.zero);
      await tester.pump(const Duration(milliseconds: 200));
      expect(arrowOpacity(), 0);
      await closeAll(tester, app);
    });

    testWidgets('the arrow sits at the right edge of the row, whatever the name', (tester) async {
      final short = conn('A');
      final named = SavedConnection(name: 'SWITCH-01 - 192.0.2.30', host: '192.0.2.30');
      final app = await show(tester, recent: [short, named]);
      for (final c in [short, named]) {
        final row = tester.getRect(find.byKey(Key('welcome-recent-${c.id}')));
        final arrow = tester.getRect(find.byKey(Key('welcome-recent-arrow-${c.id}')));
        expect(row.right - arrow.right, lessThan(16), reason: '${c.name}: the arrow is pinned right');
      }
      await closeAll(tester, app);
    });

    testWidgets('each recent connection shows its outermost folder, dimmed', (tester) async {
      final site = ConnectionFolder(name: 'Customer A');
      final inner = ConnectionFolder(name: 'Folder A', parentId: site.id);
      final nested = conn('SWITCH-01')..folderId = inner.id;
      final loose = conn('DEVICE-01');
      tester.view.physicalSize = const Size(1000, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final app = AppState();
      await tester.pump();
      app.folders.addAll([site, inner]);
      app.connections.addAll([nested, loose]);
      app.recentConnectionIds = [nested.id, loose.id];
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: app,
          child: const MaterialApp(home: Scaffold(body: TerminalTabsArea())),
        ),
      );
      await tester.pump();
      expect(find.byKey(Key('welcome-recent-site-${nested.id}')), findsOneWidget);
      expect(find.text('Customer A'), findsOneWidget);
      expect(find.text('Folder A'), findsNothing, reason: 'only the outermost folder');
      expect(find.byKey(Key('welcome-recent-site-${loose.id}')), findsNothing, reason: 'no folder, no label');
      await closeAll(tester, app);
    });

    testWidgets('with nothing saved yet it lists the first steps', (tester) async {
      final app = await show(tester);
      expect(find.byKey(const Key('welcome-first-steps')), findsOneWidget);
      expect(find.text('Add your first connection'), findsOneWidget);
      expect(find.text('Import from another app'), findsOneWidget);
      expect(find.byKey(const Key('welcome-new-connection')), findsOneWidget);
      // The shortcuts line, from Settings > Hotkeys.
      expect(find.byKey(const Key('welcome-shortcuts')), findsOneWidget);
      expect(find.text('Search'), findsOneWidget);
      expect(find.text('Commands'), findsOneWidget);
      await closeAll(tester, app);
    });

    testWidgets('with connections saved but none opened yet it says how to start', (tester) async {
      final app = await show(tester, saved: [conn('DEVICE-01')]);
      expect(find.byKey(const Key('welcome-first-steps')), findsNothing);
      expect(find.textContaining('Pick a saved connection on the left'), findsOneWidget);
      await closeAll(tester, app);
    });

    test('the greeting follows the part of the day', () {
      DateTime at(int hour) => DateTime(2026, 1, 1, hour);
      expect(WelcomePanel.greetingsFor(at(5)).first, 'Good morning');
      expect(WelcomePanel.greetingsFor(at(11)).first, 'Good morning');
      expect(WelcomePanel.greetingsFor(at(12)).first, 'Good afternoon');
      expect(WelcomePanel.greetingsFor(at(18)).first, 'Good evening');
      expect(WelcomePanel.greetingsFor(at(23)).first, 'Good night');
      expect(WelcomePanel.greetingsFor(at(3)).first, 'Good night');
    });

    test('the plain greeting comes first in each part of the day, then the lighter lines', () {
      final picker = GreetingPicker(seed: 3);
      final morning = DateTime(2026, 1, 1, 9);
      expect(picker.next(morning), 0, reason: 'Good morning first');
      final later = [for (var i = 0; i < 5; i++) picker.next(morning.add(Duration(minutes: 10 * i)))];
      expect(later, isNot(contains(0)), reason: 'then not the plain one again');
      expect(later.toSet(), hasLength(5), reason: 'each lighter line in turn');
      expect(picker.next(DateTime(2026, 1, 1, 13)), 0, reason: 'Good afternoon when the afternoon starts');
      expect(picker.next(DateTime(2026, 1, 1, 14)), isNot(0));
      expect(picker.next(DateTime(2026, 1, 1, 23)), 0, reason: 'Good night');
      expect(picker.next(DateTime(2026, 1, 2, 2)), isNot(0), reason: 'past midnight is the same night');
      expect(picker.next(DateTime(2026, 1, 2, 6)), 0, reason: 'a new morning');
    });

    test('every pick is a line of its part of the day', () {
      final picker = GreetingPicker(seed: 7);
      for (var hour = 0; hour < 24; hour++) {
        final time = DateTime(2026, 1, 1, hour);
        for (var i = 0; i < 6; i++) {
          final index = picker.next(time);
          expect(index, inInclusiveRange(0, WelcomePanel.greetingsFor(time).length - 1));
        }
      }
    });

    test('twenty-two different lines in all', () {
      final lines = {for (var h = 0; h < 24; h++) ...WelcomePanel.greetingsFor(DateTime(2026, 1, 1, h))};
      expect(lines, hasLength(22));
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
      await tester.tap(find.text('app'), warnIfMissed: false);
      expect(taps, 1, reason: 'the app underneath is already live');
      await tester.pump(LaunchSplash.duration);
      await tester.pump();
      expect(find.byKey(const Key('launch-splash')), findsNothing);
      expect(find.text('app'), findsOneWidget);
    });

    testWidgets('mark, name, version pill and a bar that fills in about two seconds', (tester) async {
      LaunchSplash.enabled = true;
      await tester.pumpWidget(const MaterialApp(home: LaunchSplash(child: SizedBox())));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(AppMark), findsOneWidget);
      expect(find.byKey(const Key('launch-splash-version')), findsOneWidget);
      expect(find.textContaining('SSH'), findsNothing, reason: 'no protocol line any more');
      double fill() => tester
          .widget<LinearProgressIndicator>(
            find.descendant(of: find.byKey(const Key('launch-splash-bar')), matching: find.byType(LinearProgressIndicator)),
          )
          .value!;
      final early = fill();
      await tester.pump(const Duration(milliseconds: 1000));
      expect(fill(), greaterThan(early));
      expect(fill(), lessThan(1));
      await tester.pump(const Duration(milliseconds: 900));
      expect(fill(), 1.0, reason: 'full after about two seconds');
      await tester.pump(LaunchSplash.duration);
    });

    testWidgets('its text sits on a Material, so it has no yellow underline', (tester) async {
      LaunchSplash.enabled = true;
      await tester.pumpWidget(const MaterialApp(home: LaunchSplash(child: SizedBox())));
      await tester.pump(const Duration(milliseconds: 500));
      final version = find.descendant(of: find.byKey(const Key('launch-splash-version')), matching: find.byType(Text));
      expect(find.ancestor(of: version, matching: find.byType(Material)), findsWidgets);
      final style = DefaultTextStyle.of(tester.element(version)).style;
      expect(style.decoration, isNot(TextDecoration.underline));
      await tester.pump(LaunchSplash.duration);
    });

    test('the version reads as a pill label', () {
      expect(LaunchSplash.versionLabel('v1.6.0-beta.3'), 'v1.6.0 beta 3');
      expect(LaunchSplash.versionLabel('v1.6.0'), 'v1.6.0');
    });
  });
}
