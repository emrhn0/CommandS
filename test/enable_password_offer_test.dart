import 'package:commands/providers/app_state.dart';
import 'package:commands/services/enable_prompt_watcher.dart';
import 'package:commands/services/pty_session.dart';
import 'package:commands/widgets/terminal_tabs.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('EnablePromptWatcher', () {
    test('offers for Cisco and Dell style prompts after an explicit enable', () {
      final watcher = EnablePromptWatcher();
      expect(watcher.feed('Password: '), isNull);
      for (final ch in 'enable'.split('')) {
        watcher.input(ch);
      }
      watcher.input('\r');
      expect(watcher.feed('DEVICE-01>enable\r\n\x1b[33mPass'), isNull);
      expect(watcher.feed('word: \x1b[0m'), 'Password:');
      watcher.dismiss();
      expect(watcher.feed('Password: '), isNull);

      watcher.input('enable\r\n');
      expect(watcher.feed('DEVICE-02>enable\r\nEnable password: '), 'Enable password:');
      watcher.reset();
      watcher.input('enable\r');
      expect(watcher.feed('DEVICE-03>enable\r\nEnter Password: '), 'Enter Password:');
    });

    test('rejects unrelated commands, stale prompts and completed output', () {
      var now = DateTime(2026);
      final watcher = EnablePromptWatcher(clock: () => now);
      watcher.input('disable\r');
      expect(watcher.feed('Password: '), isNull);
      watcher.input('enable secret\r');
      expect(watcher.feed('Password: '), isNull);
      watcher.input('enable\r');
      expect(watcher.feed('Password: \r\n'), isNull);
      watcher.input('enable\r');
      expect(watcher.feed('DEVICE-01# '), isNull);
      expect(watcher.feed('Password: '), isNull);
      watcher.input('enable\r');
      now = now.add(EnablePromptWatcher.window + const Duration(seconds: 1));
      expect(watcher.feed('Password: '), isNull);
    });

    test('manual input cancels a pending enable offer', () {
      final watcher = EnablePromptWatcher();
      watcher.input('enable\r');
      expect(watcher.feed('Password: '), 'Password:');
      watcher.input('x');
      expect(watcher.feed('Password: '), isNull);
    });
  });

  group('enable offer in SSH terminal', () {
    late AppState app;
    late PtySessionController session;
    late List<String> sent;

    Future<void> pumpSession(WidgetTester tester, {String enablePassword = 'enable-example-secret'}) async {
      PtySessionController.checkReachability = false;
      addTearDown(() => PtySessionController.checkReachability = true);
      SharedPreferences.setMockInitialValues({});
      app = AppState();
      await tester.pump();
      sent = [];
      session = PtySessionController(
        host: '192.0.2.10',
        port: 22,
        username: 'user1',
        password: 'ssh-example-secret',
        enablePassword: enablePassword,
        tabTitle: 'DEVICE-01',
        startImmediately: false,
      );
      session.writeOverride = sent.add;
      session.status = SessionStatus.running;
      app.tabs.add(OpenTab(id: 'ssh', controller: session));
      app.setActiveTab(0);
      await tester.binding.setSurfaceSize(const Size(900, 520));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(ChangeNotifierProvider.value(
        value: app,
        child: const MaterialApp(home: Scaffold(body: TerminalTabsArea())),
      ));
      await tester.pump();
    }

    Future<void> cleanUp(WidgetTester tester) async {
      session.writeOverride = null;
      await tester.pumpWidget(const SizedBox());
      session.dispose();
      app.dispose();
    }

    testWidgets('shows a fill offer and sends only the enable password on click', (tester) async {
      await pumpSession(tester);
      session.debugReceiveOutput('Password: ');
      await tester.pump();
      expect(find.text('Saved enable password'), findsNothing);

      session.sendInput('enable\r');
      session.debugReceiveOutput('DEVICE-01>enable\r\nPassword: ');
      await tester.pump();
      expect(find.text('Saved enable password'), findsOneWidget);
      expect(sent, ['enable\r']);
      await tester.tap(find.byKey(const ValueKey('enable-fill-button')));
      await tester.pump();
      expect(sent, ['enable\r', 'enable-example-secret\r']);
      expect(find.text('Saved enable password'), findsNothing);
      await cleanUp(tester);
    });

    testWidgets('cancel and manual input never send the enable password', (tester) async {
      await pumpSession(tester);
      session.sendInput('enable\r');
      session.debugReceiveOutput('Password: ');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('enable-cancel-button')));
      await tester.pump();
      expect(sent, ['enable\r']);

      session.sendInput('enable\r');
      session.debugReceiveOutput('Password: ');
      await tester.pump();
      session.sendInput('x');
      await tester.pump();
      expect(find.text('Saved enable password'), findsNothing);
      expect(sent, ['enable\r', 'enable\r', 'x']);
      await cleanUp(tester);
    });

    testWidgets('nothing is offered without a separate enable password', (tester) async {
      await pumpSession(tester, enablePassword: '');
      session.sendInput('enable\r');
      session.debugReceiveOutput('Password: ');
      await tester.pump();
      expect(find.text('Saved enable password'), findsNothing);
      expect(sent, ['enable\r']);
      await cleanUp(tester);
    });

    testWidgets('shortcut fills once and reconnect clears the offer', (tester) async {
      await pumpSession(tester);
      session.sendInput('enable\r');
      session.debugReceiveOutput('Enable password: ');
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyY);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(sent.where((s) => s == 'enable-example-secret\r'), hasLength(1));
      expect(find.text('Saved enable password'), findsNothing);

      session.sendInput('enable\r');
      session.debugReceiveOutput('Password: ');
      await tester.pump();
      expect(find.text('Saved enable password'), findsOneWidget);
      session.reconnect();
      await tester.pump();
      expect(find.text('Saved enable password'), findsNothing);
      await cleanUp(tester);
    });
  });
}
