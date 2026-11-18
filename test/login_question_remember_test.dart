import 'package:commands/models/models.dart';
import 'package:commands/providers/app_state.dart';
import 'package:commands/services/pty_session.dart';
import 'package:commands/widgets/terminal_tabs.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _user = 'user1';
const _host = '192.0.2.10';
const _question = '($_user@$_host) Do you accept and acknowledge the statement above ? (yes/no) : ';
const _password = '($_user@$_host) Password: ';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    PtySessionController.checkReachability = false;
  });
  tearDown(() => PtySessionController.checkReachability = true);

  test('a remembered answer is given by itself, then the saved password', () {
    final c = PtySessionController(host: _host, port: 22, username: _user, password: 'example-secret', startImmediately: false);
    final sent = <String>[];
    c.writeOverride = sent.add;
    c.answerLoginQuestionYes = true;
    c.debugWatchLogin(_question, user: _user, host: _host);
    expect(c.loginQuestion.value, isNull, reason: 'no bar');
    c.debugWatchLogin(_password, user: _user, host: _host);
    expect(sent, ['yes\r', 'example-secret\r']);
    c.writeOverride = null;
    c.dispose();
  });

  test('without it, the bar asks as before', () {
    final c = PtySessionController(host: _host, port: 22, username: _user, password: 'example-secret', startImmediately: false);
    final sent = <String>[];
    c.writeOverride = sent.add;
    c.debugWatchLogin(_question, user: _user, host: _host);
    expect(c.loginQuestion.value, isNotNull);
    expect(sent, isEmpty);
    c.writeOverride = null;
    c.dispose();
  });

  test('a connection keeps the choice, and an old save loads without it', () {
    final conn = SavedConnection(name: 'DEVICE-01', host: _host, answerLoginQuestionYes: true);
    expect(SavedConnection.fromJson(conn.toJson()).answerLoginQuestionYes, isTrue);
    final old = SavedConnection(name: 'DEVICE-02', host: '192.0.2.11').toJson();
    expect(old.containsKey('answerLoginQuestionYes'), isFalse);
    expect(SavedConnection.fromJson(old).answerLoginQuestionYes, isFalse);
  });

  group('the bar', () {
    Future<(AppState, PtySessionController, List<String>)> open(WidgetTester tester, SavedConnection conn) async {
      final app = AppState();
      await tester.pump();
      await app.upsertConnection(conn);
      await app.openConnection(conn);
      final c = app.tabs.single.controller as PtySessionController;
      final sent = <String>[];
      c.writeOverride = sent.add;
      await tester.binding.setSurfaceSize(const Size(1000, 500));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(ChangeNotifierProvider.value(
        value: app,
        child: const MaterialApp(home: Scaffold(body: TerminalTabsArea())),
      ));
      await tester.pump(const Duration(milliseconds: 50));
      return (app, c, sent);
    }

    Future<void> close(WidgetTester tester, AppState app, PtySessionController c) async {
      c.writeOverride = null;
      await tester.pumpWidget(const SizedBox());
      for (final t in app.tabs) {
        t.controller.dispose();
      }
      await tester.pump(const Duration(seconds: 1));
    }

    testWidgets('yes with Remember (ticked by default) saves it on the connection', (tester) async {
      final conn = SavedConnection(name: 'DEVICE-01', host: _host, username: _user, password: 'example-secret', rememberPassword: true);
      final (app, c, sent) = await open(tester, conn);
      c.debugWatchLogin(_question, user: _user, host: _host);
      await tester.pump();
      expect(find.byKey(const Key('login-question-remember')), findsOneWidget);
      await tester.tap(find.text('Yes'));
      await tester.pump();
      expect(sent, ['yes\r']);
      expect(app.connections.single.answerLoginQuestionYes, isTrue);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('commands.connections'), contains('"answerLoginQuestionYes":true'));
      await close(tester, app, c);
    });

    testWidgets('untick Remember and it is asked again next time', (tester) async {
      final conn = SavedConnection(name: 'DEVICE-01', host: _host, username: _user);
      final (app, c, sent) = await open(tester, conn);
      c.debugWatchLogin(_question, user: _user, host: _host);
      await tester.pump();
      await tester.tap(find.byKey(const Key('login-question-remember')));
      await tester.pump();
      await tester.tap(find.text('Yes'));
      await tester.pump();
      expect(sent, ['yes\r']);
      expect(app.connections.single.answerLoginQuestionYes, isFalse);
      await close(tester, app, c);
    });

    testWidgets('no is never remembered', (tester) async {
      final conn = SavedConnection(name: 'DEVICE-01', host: _host, username: _user);
      final (app, c, sent) = await open(tester, conn);
      c.debugWatchLogin(_question, user: _user, host: _host);
      await tester.pump();
      await tester.tap(find.text('No'));
      await tester.pump();
      expect(sent, ['no\r']);
      expect(app.connections.single.answerLoginQuestionYes, isFalse);
      await close(tester, app, c);
    });
  });
}
