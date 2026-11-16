import 'dart:io';

import 'package:commands/providers/app_state.dart';
import 'package:commands/models/models.dart';
import 'package:commands/screens/settings_screen.dart';
import 'package:commands/services/open_path.dart';
import 'package:commands/services/pane_layout.dart';
import 'package:commands/services/pty_session.dart';
import 'package:commands/services/session_log.dart';
import 'package:commands/services/storage_service.dart';
import 'package:commands/widgets/terminal_tabs.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('commands-session-log-test-');
    SharedPreferences.setMockInitialValues({
      SessionLogSettings.preferenceKey: root.path,
    });
  });
  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('settings persist the selected directory', () async {
    final selected = '${root.path}${Platform.pathSeparator}selected';
    await Directory(selected).create();
    await SessionLogSettings.setDirectory(selected);
    expect(await SessionLogSettings.directory(), selected);
  });

  test('a chosen log folder that was renamed or deleted is reported, not made again', () async {
    final chosen = Directory('${root.path}${Platform.pathSeparator}logs');
    await chosen.create();
    await SessionLogSettings.setDirectory(chosen.path);
    await chosen.rename('${root.path}${Platform.pathSeparator}renamed');
    await expectLater(SessionLogSettings.directory(), throwsA(isA<SessionLogFolderMissing>()));
    expect(await chosen.exists(), isFalse);
  });

  test('automatic recording into a folder that has gone fails without making it again', () async {
    final chosen = '${root.path}${Platform.pathSeparator}gone';
    await SessionLogSettings.setDirectory(chosen);
    final session = PtySessionController(
      host: '192.0.2.10',
      port: 22,
      recordByDefault: true,
      startImmediately: false,
    );
    session.debugSetStatus(SessionStatus.running);
    for (var i = 0; i < 50 && session.recordingError.value == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(session.recordingError.value, contains('no longer exists'));
    expect(session.recordingPath.value, isNull);
    expect(await Directory(chosen).exists(), isFalse);
    session.dispose();
  });

  test('by default logs stay on this computer, not in Documents', () async {
    final dir = await SessionLogSettings.defaultDirectory({
      'LOCALAPPDATA': r'C:\Users\user1\AppData\Local',
      'HOME': '/Users/user1',
    });
    expect(dir.toLowerCase(), isNot(contains('documents')));
    if (Platform.isWindows) {
      expect(dir, r'C:\Users\user1\AppData\Local\CommandS\Session Logs');
    } else if (Platform.isMacOS) {
      expect(dir, '/Users/user1/Library/Application Support/CommandS/Session Logs');
    }
  });

  test('terminal codes are removed, also when split across chunks', () {
    final cleaner = TerminalTextCleaner();
    expect(cleaner.clean('\x1B[1;32muser1@switch-01\x1B[0m:~\$ ls\r\n'), 'user1@switch-01:~\$ ls\r\n');
    expect(cleaner.clean('\x1B]0;switch-01\x07title gone\r\n'), 'title gone\r\n');
    // A sequence cut in half is held until the rest arrives; a line comes
    // out once it ends, or from flush() when the session stops.
    expect(cleaner.clean('before \x1B['), '');
    expect(cleaner.clean('31mred\x1B[0m after'), '');
    expect(cleaner.flush(), 'before red after');
    // Tabs and line breaks stay; bell and other controls go.
    expect(cleaner.clean('a\tb\x07c\r\n'), 'a\tbc\r\n');
    expect(cleaner.clean('one\ntwo\n'), 'one\ntwo\n');
    // A device that clears its prompt by moving back and writing spaces.
    expect(cleaner.clean('\x1B[42D          \x1B[42D<switch-01>'), '');
    expect(cleaner.flush(), '<switch-01>');
  });

  test('what was typed and erased before Enter does not reach the log', () {
    final cleaner = TerminalTextCleaner(columns: () => 80);
    const prompt = 'user1@server-a:~\$ ';
    // bash echoes each key; Backspace comes back as "\b\x1B[K".
    final typed = [
      prompt, 's', '\b\x1B[K', 'l', 's', ' ', 'ğ', '\b\x1B[K', '-', 'l', '\r\n',
      'total 0\r\n', prompt,
    ];
    expect(typed.map(cleaner.clean).join(), '${prompt}ls -l\r\ntotal 0\r\n');
    expect(cleaner.flush(), prompt.trimRight());

    // Some shells and devices answer Backspace with "\b \b".
    expect(cleaner.clean('> pinx\b \bg 192.0.2.10\r\n'), '> ping 192.0.2.10\r\n');
    // Cursor left then delete characters, as when fixing the middle of a line.
    expect(cleaner.clean('> show runnning\x1B[4D\x1B[P\r\n'), '> show running\r\n');
    // Ctrl+U: back to the prompt and erase the rest.
    expect(cleaner.clean('> wrong command\r> \x1B[K\x1B[3Gshow version\r\n'), '> show version\r\n');
  });

  test('a long command that wraps on screen is logged whole', () {
    final cleaner = TerminalTextCleaner(columns: () => 10);
    // The first row fills up; readline forces the wrap with a space and a
    // carriage return, which go to the start of the new row, not the line.
    // A typo on the second row is then erased.
    expect(cleaner.clean('\$ echo abc \rd xyz\b\x1B[K!\r\n'), '\$ echo abcd xy!\r\n');
  });

  test('a log file holds plain text', () async {
    final recorder = await SessionLogRecorder.start(root: root.path, host: '192.0.2.10');
    recorder.write('\x1B[1mbold\x1B');
    recorder.write('[0m plain\r\n');
    await recorder.close();
    expect(await File(recorder.path).readAsString(), 'bold plain\r\n');
  });

  test('connection recording default survives JSON, XML and CSV', () {
    final oldSave = SavedConnection.fromJson({
      'id': 'old',
      'name': 'DEVICE-01',
      'host': '192.0.2.10',
    });
    expect(oldSave.recordSessionByDefault, isFalse);
    final connection = SavedConnection(
      name: 'DEVICE-01',
      host: '192.0.2.10',
      recordSessionByDefault: true,
    );
    expect(
      SavedConnection.fromJson(connection.toJson()).recordSessionByDefault,
      isTrue,
    );
    final storage = StorageService();
    final xml = storage.exportXml(folders: [], connections: [connection]);
    expect(
      storage.parseXml(xml).connections.single.recordSessionByDefault,
      isTrue,
    );
    final csv = storage.exportCsv(folders: [], connections: [connection]);
    expect(
      storage.parseCsv(csv).connections.single.recordSessionByDefault,
      isTrue,
    );
  });

  test('enabled SSH starts a log when the session begins', () async {
    final session = PtySessionController(
      host: '192.0.2.10',
      port: 22,
      recordByDefault: true,
      startImmediately: false,
    );
    session.debugSetStatus(SessionStatus.running);
    session.debugReceiveOutput('first banner line\n');
    for (var i = 0; i < 50 && session.recordingPath.value == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    final path = session.recordingPath.value;
    expect(path, isNotNull);
    session.debugReceiveOutput('ready\n');
    await session.stopRecording();
    expect(await File(path!).readAsString(), 'first banner line\nready\n');
    session.dispose();

    final disabled = PtySessionController(
      host: '192.0.2.11',
      port: 22,
      startImmediately: false,
    );
    disabled.debugSetStatus(SessionStatus.running);
    expect(disabled.recordingPath.value, isNull);
    disabled.dispose();
  });

  test(
    'saved SSH connection passes its recording default to the session',
    () async {
      PtySessionController.checkReachability = false;
      final app = AppState();
      final connection = SavedConnection(
        name: 'DEVICE-01',
        host: '192.0.2.10',
        recordSessionByDefault: true,
      );
      await app.openConnection(connection);
      final session = app.tabs.single.controller as PtySessionController;
      expect(session.recordByDefault, isTrue);
      session.dispose();
    },
  );

  test('closing before auto recording starts is not a failure', () async {
    final session = PtySessionController(
      host: '192.0.2.10',
      port: 22,
      recordByDefault: true,
      startImmediately: false,
    );
    session.debugSetStatus(SessionStatus.running);
    session.debugSetStatus(SessionStatus.closed);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(session.recordingPath.value, isNull);
    expect(session.recordingError.value, isNull);
    session.dispose();
  });

  test('UTF-8 output uses host/date/time and never overwrites a second log', () async {
    final at = DateTime(2026, 11, 11, 14, 5, 9);
    final first = await SessionLogRecorder.start(
      root: root.path,
      host: 'DEVICE-01',
      now: at,
    );
    first.write('Türkçe\r\n');
    first.write('ready\n');
    await first.close();
    expect(
      first.path,
      endsWith(
        'DEVICE-01${Platform.pathSeparator}2026-11-11${Platform.pathSeparator}14-05-09.log',
      ),
    );
    expect(await File(first.path).readAsString(), 'Türkçe\r\nready\n');

    final second = await SessionLogRecorder.start(
      root: root.path,
      host: 'DEVICE-01',
      now: at,
    );
    second.write('second\n');
    await second.close();
    expect(second.path, endsWith('14-05-09-1.log'));
    expect(await File(first.path).readAsString(), 'Türkçe\r\nready\n');
    expect(await File(second.path).readAsString(), 'second\n');
  });

  test('unsafe host components cannot escape the log root', () async {
    final log = await SessionLogRecorder.start(
      root: root.path,
      host: '..',
      now: DateTime(2026, 11, 11),
    );
    expect(log.path, contains('unknown-host${Platform.pathSeparator}'));
    await log.close();
  });

  test('SSH controller logs remote output but never typed input', () async {
    final sent = <String>[];
    final session = PtySessionController(
      host: '192.0.2.10',
      port: 22,
      username: 'user',
      startImmediately: false,
    );
    session.writeOverride = sent.add;
    session.status = SessionStatus.running;
    final path = await session.startRecording(root.path);
    session.sendInput('private-input');
    session.debugReceiveOutput('remote output\r\n');
    await session.stopRecording();
    expect(session.recordingPath.value, isNull);
    expect(await File(path).readAsString(), 'remote output\r\n');
    expect(sent, ['private-input']);
    session.writeOverride = null;
    session.dispose();
  });

  testWidgets('SSH button shows a recording indicator and stops recording', (
    tester,
  ) async {
    final app = AppState();
    await tester.pump();
    final session = PtySessionController(
      host: '192.0.2.10',
      port: 22,
      username: 'user',
      tabTitle: 'DEVICE-01',
      startImmediately: false,
    );
    session.status = SessionStatus.running;
    app.tabs.add(OpenTab(id: 'ssh', controller: session));
    app.setActiveTab(0);
    await tester.binding.setSurfaceSize(const Size(1200, 550));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: const MaterialApp(home: Scaffold(body: TerminalTabsArea())),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byKey(const ValueKey('session-log-button')), findsOneWidget);
    expect(
      tester
          .widget<TextButton>(find.byKey(const ValueKey('session-log-button')))
          .onPressed,
      isNotNull,
    );
    final logPath = '${root.path}${Platform.pathSeparator}example.log';
    session.recordingPath.value = logPath;
    await tester.pump();
    expect(find.text('Stop recording'), findsOneWidget);
    expect(find.byIcon(Icons.circle), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('session-log-button')));
    await tester.pump();
    expect(session.recordingPath.value, isNull);
    expect(find.text('Record session'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    session.dispose();
  });

  testWidgets('the saved-log message opens the log file, then goes away by itself', (tester) async {
    final opened = <String>[];
    final original = OpenPath.launcher;
    OpenPath.launcher = (executable, arguments) async => opened.add(arguments.single);
    addTearDown(() => OpenPath.launcher = original);
    final app = AppState();
    await tester.pump();
    final session = PtySessionController(
      host: '192.0.2.10',
      port: 22,
      tabTitle: 'DEVICE-01',
      startImmediately: false,
    )..status = SessionStatus.running;
    app.tabs.add(OpenTab(id: 'ssh', controller: session));
    app.setActiveTab(0);
    await tester.binding.setSurfaceSize(const Size(1200, 550));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: const MaterialApp(home: Scaffold(body: TerminalTabsArea())),
      ),
    );
    final logPath = '${root.path}${Platform.pathSeparator}example.log';

    // Not used: gone after a few seconds.
    session.recordingPath.value = logPath;
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('session-log-button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Open file'), findsOneWidget);
    await tester.pump(const Duration(seconds: 10));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Open file'), findsNothing);
    expect(opened, isEmpty);

    // Used: opens the very file that was saved.
    session.recordingPath.value = logPath;
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('session-log-button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('Open file'));
    await tester.pump();
    expect(opened, [logPath]);

    await tester.pumpWidget(const SizedBox());
    session.dispose();
  });

  testWidgets('settings say when the chosen log folder has gone, and do not open or make it', (tester) async {
    const windowManager = MethodChannel('window_manager');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(windowManager, (call) async => call.method == 'isMaximized' ? false : null);
    addTearDown(() => messenger.setMockMethodCallHandler(windowManager, null));
    final gone = '${root.path}${Platform.pathSeparator}renamed-away';
    SharedPreferences.setMockInitialValues({SessionLogSettings.preferenceKey: gone});
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: AppState(),
        child: const MaterialApp(home: SettingsScreen(initialPage: SettingsPage.sessionLogs)),
      ),
    );
    await tester.runAsync(() async {
      for (var i = 0; i < 50; i++) {
        if (find.textContaining('no longer exists').evaluate().isNotEmpty) return;
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    await tester.pump();
    expect(find.textContaining('no longer exists'), findsOneWidget);
    final open = tester.widget<OutlinedButton>(
      find.ancestor(of: find.text('Open folder'), matching: find.byWidgetPredicate((w) => w is OutlinedButton)),
    );
    expect(open.onPressed, isNull);
    expect(await tester.runAsync(() => Directory(gone).exists()), isFalse);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('settings open the log folder', (tester) async {
    const windowManager = MethodChannel('window_manager');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(windowManager, (call) async => call.method == 'isMaximized' ? false : null);
    addTearDown(() => messenger.setMockMethodCallHandler(windowManager, null));
    final opened = <String>[];
    final original = OpenPath.launcher;
    OpenPath.launcher = (executable, arguments) async => opened.add(arguments.single);
    addTearDown(() => OpenPath.launcher = original);
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: AppState(),
        child: const MaterialApp(home: SettingsScreen(initialPage: SettingsPage.sessionLogs)),
      ),
    );
    await tester.runAsync(() async {
      for (var i = 0; i < 50; i++) {
        if (find.text(root.path).evaluate().isNotEmpty) return;
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    await tester.pump();
    expect(find.text('Open folder'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('open-log-folder')));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump();
    expect(opened, [root.path]);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('split SSH sessions offer a choice of recording target', (
    tester,
  ) async {
    final app = AppState();
    await tester.pump();
    final first = PtySessionController(
      host: '192.0.2.10',
      port: 22,
      tabTitle: 'DEVICE-01',
      startImmediately: false,
    )..status = SessionStatus.running;
    final second = PtySessionController(
      host: '192.0.2.11',
      port: 22,
      tabTitle: 'DEVICE-02',
      startImmediately: false,
    )..status = SessionStatus.running;
    app.tabs.addAll([
      OpenTab(id: 'a', controller: first),
      OpenTab(id: 'b', controller: second),
    ]);
    app.groups.add(
      TabGroup(
        id: 'both',
        layout: PaneSplit(
          axis: Axis.horizontal,
          first: const PaneLeaf('a'),
          second: const PaneLeaf('b'),
        ),
      ),
    );
    app.activateGroup('both');
    await tester.binding.setSurfaceSize(const Size(1200, 550));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: const MaterialApp(home: Scaffold(body: TerminalTabsArea())),
      ),
    );
    await tester.pump();
    expect(find.text('Session logs'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('session-log-button')));
    await tester.pump();
    expect(find.textContaining('DEVICE-01 — Record session'), findsOneWidget);
    expect(find.textContaining('DEVICE-02 — Record session'), findsOneWidget);
    await tester.tapAt(const Offset(500, 300));
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    first.dispose();
    second.dispose();
  });

  testWidgets('settings show the selected log directory', (tester) async {
    final app = AppState();
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: const MaterialApp(home: SettingsScreen(initialPage: SettingsPage.sessionLogs)),
      ),
    );
    await tester.pump();
    expect(find.text('Session logs'), findsNWidgets(2), reason: 'sidebar and page title');
    expect(find.text('Choose log folder'), findsOneWidget);
    await tester.runAsync(() async {
      for (var i = 0; i < 50; i++) {
        if (find.text(root.path).evaluate().isNotEmpty) return;
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    await tester.pump();
    expect(find.text(root.path), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });
}
