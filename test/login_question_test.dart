import 'package:commands/providers/app_state.dart';
import 'package:commands/services/login_watcher.dart';
import 'package:commands/services/pty_session.dart';
import 'package:commands/widgets/terminal_tabs.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const user = 'user1';
  const host = '192.0.2.10';
  const question = '($user@$host) Do you accept and acknowledge the statement above ? (yes/no) : ';
  const password = '($user@$host) Password: ';

  LoginWatcher watcher([DateTime Function()? clock]) => LoginWatcher(user: user, host: host, clock: clock);

  group('LoginWatcher', () {
    test('finds the question, without the prefix', () {
      final e = watcher().feed('WARNING\r\n$question');
      expect((e as LoginQuestion).text, 'Do you accept and acknowledge the statement above ? (yes/no) :');
    });

    test('finds it through colour codes, a split read, and a wrapped line', () {
      final w = watcher();
      expect(w.feed('\x1b[0m($user@$host) Do you accept and\r\n ack'), isNull);
      expect(w.feed('nowledge ? (yes/no) : \x1b[K'), isA<LoginQuestion>());
    });

    test('the password prompt counts only after a question, and only once', () {
      final w = watcher();
      expect(w.feed(password), isNull, reason: 'no question came first');
      expect(w.feed(question), isA<LoginQuestion>());
      expect(w.feed('yes\r\n'), isNull);
      expect(w.feed(password), isA<LoginPasswordPrompt>());
      expect(w.feed(password), isNull);
    });

    test('another user or host is not this login', () {
      final w = watcher();
      expect(w.feed('(user2@$host) Do you accept ? (yes/no) : '), isNull);
      expect(w.feed('($user@192.0.2.99) Do you accept ? (yes/no) : '), isNull);
      expect(w.feed('Do you accept ? (yes/no) : '), isNull);
    });

    test('a question already passed is not a prompt', () {
      expect(watcher().feed('$question\r\nmore output\r\n'), isNull);
    });

    test('after a no, a password prompt is left alone', () {
      final w = watcher();
      w.feed(question);
      w.declined();
      expect(w.feed(password), isNull);
    });

    test('long after login began, nothing counts', () {
      var now = DateTime(2026);
      final w = watcher(() => now);
      now = now.add(LoginWatcher.window + const Duration(seconds: 1));
      expect(w.feed(question), isNull);
    });
  });

  group('the bar', () {
    late AppState app;
    late PtySessionController c;
    late List<String> sent;

    Future<void> pumpSession(WidgetTester tester, {required String savedPassword}) async {
      PtySessionController.checkReachability = false;
      SharedPreferences.setMockInitialValues({});
      app = AppState();
      await tester.pump();
      sent = [];
      c = PtySessionController(host: host, port: 22, username: user, password: savedPassword, tabTitle: 'DEVICE-01');
      c.writeOverride = sent.add;
      app.tabs.add(OpenTab(id: 'a', controller: c));
      app.setActiveTab(0);
      await tester.binding.setSurfaceSize(const Size(900, 500));
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
      c.writeOverride = null;
      await tester.pumpWidget(const SizedBox());
      c.dispose();
      await tester.pump(const Duration(seconds: 1));
    }

    testWidgets('yes answers the question and fills in the saved password', (tester) async {
      const secret = 'example-secret-value';
      await pumpSession(tester, savedPassword: secret);
      expect(find.text('Yes'), findsNothing);
      c.debugWatchLogin(question, user: user, host: host);
      await tester.pump();
      expect(find.text('Do you accept and acknowledge the statement above ? (yes/no) :'), findsOneWidget);
      expect(find.textContaining('No password is saved'), findsNothing);

      await tester.tap(find.text('Yes'));
      await tester.pump();
      expect(sent, ['yes\r']);
      expect(find.text('Yes'), findsNothing);

      c.debugWatchLogin(password, user: user, host: host);
      expect(sent, ['yes\r', '$secret\r']);
      await cleanUp(tester);
    });

    testWidgets('no answers no, and no password is sent', (tester) async {
      await pumpSession(tester, savedPassword: 'example-secret-value');
      c.debugWatchLogin(question, user: user, host: host);
      await tester.pump();
      await tester.tap(find.text('No'));
      await tester.pump();
      c.debugWatchLogin(password, user: user, host: host);
      expect(sent, ['no\r']);
      await cleanUp(tester);
    });

    testWidgets('with nothing saved it says so, and sends only the answer', (tester) async {
      await pumpSession(tester, savedPassword: '');
      c.debugWatchLogin(question, user: user, host: host);
      await tester.pump();
      expect(find.textContaining('No password is saved'), findsOneWidget);
      await tester.tap(find.text('Yes'));
      await tester.pump();
      c.debugWatchLogin(password, user: user, host: host);
      expect(sent, ['yes\r']);
      await cleanUp(tester);
    });
  });
}
