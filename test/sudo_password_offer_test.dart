import 'package:commands/providers/app_state.dart';
import 'package:commands/services/pty_session.dart';
import 'package:commands/services/sudo_prompt_watcher.dart';
import 'package:commands/widgets/terminal_tabs.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('SudoPromptWatcher', () {
    test(
      'recognizes current sudo prompt variants through split ANSI output',
      () {
        final watcher = SudoPromptWatcher();
        expect(watcher.feed('\x1b[33m[sudo: auth'), isNull);
        expect(
          watcher.feed('enticate] Password: \x1b[0m'),
          '[sudo: authenticate] Password:',
        );
        expect(
          watcher.feed('\r\n[sudo] password for user1: '),
          '[sudo] password for user1:',
        );
        expect(
          watcher.feed('\r\nsudo password for user1: '),
          'sudo password for user1:',
        );
        expect(watcher.feed('\r\n[sudo] parola: '), '[sudo] parola:');
      },
    );

    test('ignores unrelated, embedded, completed and oversized lines', () {
      final watcher = SudoPromptWatcher();
      expect(watcher.feed('Password: '), isNull);
      expect(
        watcher.feed('\nSome log says [sudo] password for user1: '),
        isNull,
      );
      expect(watcher.feed('\n[sudo] password for user1: \r\n'), isNull);
      expect(watcher.feed('[sudo] password for user1: '), isNotNull);
      expect(watcher.feed('\n'), isNull);
      expect(watcher.feed('x' * 200 + '[sudo] Password: '), isNull);
    });

    test('dismissal suppresses a prompt until a later line', () {
      final watcher = SudoPromptWatcher();
      expect(watcher.feed('[sudo] Password: '), isNotNull);
      watcher.dismiss();
      expect(watcher.feed('\x1b[0m'), isNull);
      expect(watcher.feed('\r\n[sudo] Password: '), isNotNull);
      watcher.reset();
      expect(watcher.feed('[sudo] Password: '), isNotNull);
    });
  });

  group('sudo offer in SSH terminal', () {
    const secret = 'example-secret-value';
    const prompt = '[sudo: authenticate] Password: ';
    late AppState app;
    late PtySessionController session;
    late List<String> sent;

    Future<void> pumpSession(
      WidgetTester tester, {
      String password = secret,
    }) async {
      PtySessionController.checkReachability = false;
      SharedPreferences.setMockInitialValues({});
      app = AppState();
      await tester.pump();
      sent = [];
      session = PtySessionController(
        host: '192.0.2.10',
        port: 22,
        username: 'user1',
        password: password,
        tabTitle: 'DEVICE-01',
      );
      session.writeOverride = sent.add;
      session.status = SessionStatus.running;
      app.tabs.add(OpenTab(id: 'ssh', controller: session));
      app.setActiveTab(0);
      await tester.binding.setSurfaceSize(const Size(900, 520));
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
      session.writeOverride = null;
      await tester.pumpWidget(const SizedBox());
      session.dispose();
      await tester.pump(const Duration(seconds: 1));
    }

    testWidgets('offers but never fills until the user clicks', (tester) async {
      await pumpSession(tester);
      session.debugReceiveOutput(prompt);
      await tester.pump();
      expect(find.text('Saved password for sudo'), findsOneWidget);
      expect(find.text('Ctrl+Shift+Y'), findsOneWidget);
      final fillRect = tester.getRect(
        find.byKey(const ValueKey('sudo-fill-button')),
      );
      final cancelRect = tester.getRect(
        find.byKey(const ValueKey('sudo-cancel-button')),
      );
      final titleRect = tester.getRect(find.text('Saved password for sudo'));
      expect(fillRect.width, cancelRect.width);
      expect(fillRect.height, cancelRect.height);
      expect(titleRect.bottom, lessThan(fillRect.top));
      expect(sent, isEmpty);
      await tester.tap(find.text('Fill'));
      await tester.pump();
      expect(sent, ['$secret\r']);
      expect(find.text('Saved password for sudo'), findsNothing);
      await cleanUp(tester);
    });

    testWidgets('cancel dismisses without sending the password', (
      tester,
    ) async {
      await pumpSession(tester);
      session.debugReceiveOutput(prompt);
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('sudo-cancel-button')));
      await tester.pump();
      expect(find.text('Saved password for sudo'), findsNothing);
      expect(sent, isEmpty);
      await cleanUp(tester);
    });

    testWidgets('shortcut fills once only while the offer is present', (
      tester,
    ) async {
      await pumpSession(tester);
      session.debugReceiveOutput(prompt);
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyY);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(sent.where((s) => s == '$secret\r'), hasLength(1));
      expect(find.text('Saved password for sudo'), findsNothing);
      await cleanUp(tester);
    });

    testWidgets('no saved password and unrelated output show no offer', (
      tester,
    ) async {
      await pumpSession(tester, password: '');
      session.debugReceiveOutput(prompt);
      session.debugReceiveOutput('\r\nPassword: ');
      await tester.pump();
      expect(find.text('Saved password for sudo'), findsNothing);
      expect(sent, isEmpty);
      await cleanUp(tester);
    });

    testWidgets('manual input dismisses the offer', (tester) async {
      await pumpSession(tester);
      session.debugReceiveOutput(prompt);
      await tester.pump();
      session.sendInput('x');
      await tester.pump();
      expect(find.text('Saved password for sudo'), findsNothing);
      expect(sent, ['x']);
      await cleanUp(tester);
    });

    testWidgets('offer expires and fits a narrow terminal pane', (
      tester,
    ) async {
      await pumpSession(tester);
      await tester.binding.setSurfaceSize(const Size(340, 290));
      session.debugReceiveOutput(prompt);
      await tester.pump();
      expect(find.text('Fill'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(seconds: 91));
      expect(find.text('Fill'), findsNothing);
      await cleanUp(tester);
    });

    testWidgets('a new output line and reconnect clear the offer', (
      tester,
    ) async {
      await pumpSession(tester);
      session.debugReceiveOutput(prompt);
      await tester.pump();
      expect(find.text('Fill'), findsOneWidget);
      session.debugReceiveOutput('\r\n');
      await tester.pump();
      expect(find.text('Fill'), findsNothing);
      session.debugReceiveOutput(prompt);
      await tester.pump();
      expect(find.text('Fill'), findsOneWidget);
      session.reconnect();
      await tester.pump();
      expect(find.text('Fill'), findsNothing);
      await cleanUp(tester);
    });
  });
}
