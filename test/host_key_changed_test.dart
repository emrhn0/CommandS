import 'dart:io';

import 'package:commands/providers/app_state.dart';
import 'package:commands/services/host_keys.dart';
import 'package:commands/services/pty_session.dart';
import 'package:commands/widgets/terminal_tabs.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// What OpenSSH prints when a remembered key no longer matches.
const _warning = '@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@\r\n'
    '@    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @\r\n'
    '@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@\r\n'
    'IT IS POSSIBLE THAT SOMEONE IS DOING SOMETHING NASTY!\r\n'
    'Host key verification failed.\r\n';

void main() {
  final realRun = HostKeys.run;
  late List<List<String>> runs;

  setUp(() {
    runs = [];
    HostKeys.run = (exe, args) async {
      runs.add([exe, ...args]);
      return ProcessResult(0, 0, '', '');
    };
  });
  tearDown(() => HostKeys.run = realRun);

  test('OpenSSH names a host on another port in brackets', () {
    expect(HostKeys.target('192.0.2.10', 22), '192.0.2.10');
    expect(HostKeys.target('192.0.2.10', 2222), '[192.0.2.10]:2222');
  });

  test('forgetting runs ssh-keygen -R on the known_hosts file, with no shell', () async {
    final dir = await Directory.systemTemp.createTemp('commands-hosts-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}${Platform.pathSeparator}known_hosts')..writeAsStringSync('x\n');
    expect(await HostKeys.forget(host: '192.0.2.10', port: 2222, file: file.path), isNull);
    expect(runs.single.sublist(1), ['-R', '[192.0.2.10]:2222', '-f', file.path]);
    expect(runs.single.first, endsWith(Platform.isWindows ? 'ssh-keygen.exe' : 'ssh-keygen'));
  });

  test('with no known_hosts file there is nothing to forget', () async {
    expect(await HostKeys.forget(host: '192.0.2.10', port: 22, file: '/nonexistent/known_hosts'), isNull);
    expect(runs, isEmpty);
  });

  test('a failing ssh-keygen is reported', () async {
    final dir = await Directory.systemTemp.createTemp('commands-hosts-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}${Platform.pathSeparator}known_hosts')..writeAsStringSync('x\n');
    HostKeys.run = (exe, args) async => ProcessResult(0, 1, '', 'cannot write');
    expect(await HostKeys.forget(host: '192.0.2.10', port: 22, file: file.path), 'cannot write');
  });

  group('the session', () {
    late AppState app;
    late PtySessionController c;

    Future<void> pumpSession(WidgetTester tester) async {
      PtySessionController.checkReachability = false;
      SharedPreferences.setMockInitialValues({});
      app = AppState();
      await tester.pump();
      c = PtySessionController(host: '192.0.2.10', port: 22, username: 'user1', tabTitle: 'DEVICE-01');
      c.writeOverride = (_) {};
      app.tabs.add(OpenTab(id: 'a', controller: c));
      app.setActiveTab(0);
      await tester.binding.setSurfaceSize(const Size(1000, 500));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(ChangeNotifierProvider.value(
        value: app,
        child: const MaterialApp(home: Scaffold(body: TerminalTabsArea())),
      ));
      await tester.pump(const Duration(milliseconds: 50));
    }

    Future<void> cleanUp(WidgetTester tester) async {
      c.writeOverride = null;
      await tester.pumpWidget(const SizedBox());
      c.dispose();
      await tester.pump(const Duration(seconds: 1));
    }

    testWidgets('the warning from OpenSSH brings up the bar, even split across reads', (tester) async {
      await pumpSession(tester);
      expect(find.byKey(const Key('host-key-changed-bar')), findsNothing);
      c.debugReceiveOutput(_warning.substring(0, 80));
      c.debugReceiveOutput(_warning.substring(80));
      await tester.pump();
      expect(find.byKey(const Key('host-key-changed-bar')), findsOneWidget);
      expect(find.textContaining("192.0.2.10's identity has changed"), findsOneWidget);
      await cleanUp(tester);
    });

    testWidgets('ordinary output does not', (tester) async {
      await pumpSession(tester);
      c.debugReceiveOutput('Welcome to DEVICE-01\r\nLast login: today\r\n');
      await tester.pump();
      expect(c.hostKeyChanged.value, isFalse);
      await cleanUp(tester);
    });

    testWidgets('close hides it without touching the key', (tester) async {
      await pumpSession(tester);
      c.debugReceiveOutput(_warning);
      await tester.pump();
      await tester.tap(find.text('Close'));
      await tester.pump();
      expect(find.byKey(const Key('host-key-changed-bar')), findsNothing);
      expect(runs, isEmpty);
      await cleanUp(tester);
    });
  });
}
