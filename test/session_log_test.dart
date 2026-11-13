import 'dart:io';

import 'package:commands/providers/app_state.dart';
import 'package:commands/models/models.dart';
import 'package:commands/screens/settings_screen.dart';
import 'package:commands/services/pane_layout.dart';
import 'package:commands/services/pty_session.dart';
import 'package:commands/services/session_log.dart';
import 'package:commands/services/storage_service.dart';
import 'package:commands/widgets/terminal_tabs.dart';
import 'package:flutter/material.dart';
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
    await SessionLogSettings.setDirectory(selected);
    expect(await SessionLogSettings.directory(), selected);
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
    session.recordingPath.value =
        '${root.path}${Platform.pathSeparator}example.log';
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
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );
    await tester.pump();
    expect(find.text('Session logs'), findsOneWidget);
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
