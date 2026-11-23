import 'package:commands/models/models.dart';
import 'package:commands/providers/app_state.dart';
import 'package:commands/services/app_commands.dart';
import 'package:commands/services/pane_layout.dart';
import 'package:commands/services/pty_session.dart';
import 'package:commands/theme/app_theme.dart';
import 'package:commands/widgets/command_palette.dart';
import 'package:commands/widgets/connection_tree.dart';
import 'package:commands/widgets/terminal_tabs.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// An app whose opened connections are only noted, so no session starts.
class _NotingApp extends AppState {
  final opened = <SavedConnection>[];

  @override
  Future<String?> openConnection(SavedConnection conn) async {
    opened.add(conn);
    return null;
  }
}

/// [app] with a session for each of [conns], not started, the first on screen.
List<PtySessionController> _openSessions(AppState app, List<SavedConnection> conns) {
  final sessions = <PtySessionController>[];
  for (final c in conns) {
    final s = PtySessionController(host: c.host, port: c.port, startImmediately: false);
    sessions.add(s);
    app.tabs.add(OpenTab(id: 'tab-${c.name}', controller: s, connectionId: c.id));
  }
  app.activeTabIndex = 0;
  app.paneLayout = PaneLeaf(app.tabs.first.id);
  return sessions;
}

Future<void> _pumpTabs(WidgetTester tester, AppState app) async {
  tester.view.physicalSize = const Size(1100, 760);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(ChangeNotifierProvider.value(
    value: app,
    child: MaterialApp(theme: AppTheme.dark(), home: const Scaffold(body: TerminalTabsArea())),
  ));
  await tester.pump();
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      (call) async => call.method == 'isMaximized' ? false : null,
    );
  });

  group('home', () {
    testWidgets('the home button shows the welcome screen over the sessions, and a session brings them back',
        (tester) async {
      final app = AppState();
      await app.ready;
      final a = SavedConnection(name: 'DEVICE-01', host: '192.0.2.10');
      final b = SavedConnection(name: 'DEVICE-02', host: '192.0.2.11', port: 2222);
      app.connections.addAll([a, b]);
      final sessions = _openSessions(app, [a, b]);
      sessions[1].debugSetStatus(SessionStatus.running);
      await _pumpTabs(tester, app);
      expect(find.byKey(const Key('welcome-panel')), findsNothing);
      expect(find.byKey(const Key('session-status-bar')), findsOneWidget);

      await tester.tap(find.byKey(const Key('tab-home')));
      await tester.pump();
      expect(app.homeShown, isTrue);
      expect(app.tabs, hasLength(2), reason: 'the sessions keep running');
      expect(find.byKey(const Key('welcome-panel')), findsOneWidget);
      expect(find.byKey(const Key('session-status-bar')), findsNothing);
      // The open sessions, listed, and counted in the cards.
      expect(find.byKey(const Key('welcome-open-sessions')), findsOneWidget);
      expect(find.text('OPEN SESSIONS · 2'), findsOneWidget);
      final open = tester.widget<Text>(find
          .descendant(of: find.byKey(const ValueKey('welcome-stat-open')), matching: find.byType(Text))
          .first);
      expect(open.data, '2');
      // Typing a password goes to a session on screen only.
      sessions[0].debugSetStatus(SessionStatus.running);
      expect(app.canRunCommand(AppCommandId.typePassword), isFalse);

      await tester.tap(find.byKey(const ValueKey('welcome-open-tab-DEVICE-02')));
      await tester.pump();
      expect(app.homeShown, isFalse);
      expect(app.tabs[app.activeTabIndex].id, 'tab-DEVICE-02');
      expect(find.byKey(const Key('welcome-panel')), findsNothing);

      await tester.pumpWidget(const SizedBox());
      for (final s in sessions) {
        s.dispose();
      }
    });

    test('home needs an open session, and closing the last one leaves it', () async {
      final app = AppState();
      await app.ready;
      app.showHome();
      expect(app.homeShown, isFalse, reason: 'with nothing open the welcome screen is there anyway');
      final c = SavedConnection(name: 'DEVICE-01', host: '192.0.2.10');
      app.connections.add(c);
      _openSessions(app, [c]);
      app.showHome();
      expect(app.homeShown, isTrue);
      app.closeTab(0);
      expect(app.homeShown, isFalse);
    });
  });

  group('opened today', () {
    String today() {
      final t = DateTime.now();
      return '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
    }

    test('today\'s count is read back', () async {
      SharedPreferences.setMockInitialValues({'commands.openedToday': '${today()} 4'});
      final app = AppState();
      await app.ready;
      expect(app.openedToday, 4);
    });

    test('another day\'s count is not today\'s', () async {
      SharedPreferences.setMockInitialValues({'commands.openedToday': '2000-01-01 9'});
      final app = AppState();
      await app.ready;
      expect(app.openedToday, 0);
    });

    test('each session opened adds one, kept with today\'s date', () async {
      SharedPreferences.setMockInitialValues({'commands.openedToday': '2000-01-01 9'});
      final app = AppState();
      await app.ready;
      app.countOpened();
      app.countOpened();
      expect(app.openedToday, 2, reason: 'a new day starts from zero');
      await Future<void>.delayed(Duration.zero);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('commands.openedToday'), '${today()} 2');
    });
  });

  group('status bar', () {
    test('says how long a session has been open', () {
      expect(SessionStatusBar.durationLabel(const Duration(seconds: 50)), '0 min');
      expect(SessionStatusBar.durationLabel(const Duration(minutes: 42)), '42 min');
      expect(SessionStatusBar.durationLabel(const Duration(minutes: 125)), '2 h 5 min');
    });

    testWidgets('shows the protocol, the address with a port that is not the usual one, and the time',
        (tester) async {
      final app = AppState();
      await app.ready;
      final c = SavedConnection(name: 'DEVICE-01', host: '192.0.2.10', port: 2222);
      app.connections.add(c);
      final s = PtySessionController(host: c.host, port: c.port, startImmediately: false);
      final opened = DateTime(2026, 1, 1, 10);
      final tab = OpenTab(id: 't', controller: s, connectionId: c.id, openedAt: opened);
      await tester.pumpWidget(ChangeNotifierProvider.value(
        value: app,
        child: MaterialApp(
          home: Scaffold(
            body: SessionStatusBar(tab: tab, now: () => opened.add(const Duration(minutes: 42))),
          ),
        ),
      ));
      expect(find.text('SSH'), findsOneWidget);
      expect(find.text('192.0.2.10:2222'), findsOneWidget);
      expect(find.text('42 min'), findsOneWidget);

      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String;
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      await tester.tap(find.byKey(const Key('session-status-address')));
      await tester.pump();
      expect(copied, '192.0.2.10:2222');
      await tester.pumpWidget(const SizedBox());
      s.dispose();
    });
  });

  group('folder colors', () {
    test('a colour is kept, carries to the folders inside, and older saves load without one', () async {
      final app = AppState();
      await app.ready;
      await app.addFolder('CUSTOMER-A');
      final outer = app.folders.single;
      await app.addFolder('SITE-1', parentId: outer.id);
      final inner = app.folders.firstWhere((f) => f.name == 'SITE-1');
      expect(app.folderColorOf(inner.id), isNull);

      await app.setFolderColor(outer.id, AppState.folderColors.first);
      expect(app.folderColorOf(outer.id), Color(AppState.folderColors.first));
      expect(app.folderColorOf(inner.id), Color(AppState.folderColors.first));

      final c = SavedConnection(name: 'DEVICE-01', host: '192.0.2.10', folderId: inner.id);
      app.connections.add(c);
      expect(app.tabColorOf(OpenTab(id: 't', controller: PtySessionController(host: c.host, port: 22, startImmediately: false), connectionId: c.id)),
          Color(AppState.folderColors.first));

      final reloaded = AppState();
      await reloaded.ready;
      expect(reloaded.folders.firstWhere((f) => f.id == outer.id).color, AppState.folderColors.first);

      final old = ConnectionFolder.fromJson({'id': 'f', 'name': 'CUSTOMER-B', 'parentId': null});
      expect(old.color, isNull);
      expect(old.toJson().containsKey('color'), isFalse);

      await app.setFolderColor(outer.id, null);
      expect(app.folderColorOf(inner.id), isNull);
    });

    testWidgets('the colour dialog pops the picked colour, or -1 for none', (tester) async {
      int? picked;
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.dark(),
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async => picked = await showDialog<int>(
              context: context,
              builder: (_) => const FolderColorDialog(name: 'CUSTOMER-A'),
            ),
            child: const Text('open'),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('folder-swatch-${AppState.folderColors[2]}')));
      await tester.pumpAndSettle();
      expect(picked, AppState.folderColors[2]);

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('folder-color-none')));
      await tester.pumpAndSettle();
      expect(picked, -1);
    });

    testWidgets('a coloured folder\'s connection colours its tab icon', (tester) async {
      final app = AppState();
      await app.ready;
      await app.addFolder('CUSTOMER-A');
      final folder = app.folders.single;
      await app.setFolderColor(folder.id, AppState.folderColors[1]);
      final a = SavedConnection(name: 'DEVICE-01', host: '192.0.2.10');
      final b = SavedConnection(name: 'DEVICE-02', host: '192.0.2.11', folderId: folder.id);
      app.connections.addAll([a, b]);
      final sessions = _openSessions(app, [a, b]);
      await _pumpTabs(tester, app);
      // DEVICE-02's tab is not the one in use: its icon shows the folder's colour.
      final icon = tester.widget<Icon>(find.byKey(const ValueKey('tab-folder-color')));
      expect(icon.color, Color(AppState.folderColors[1]));
      // In use, the tab is filled with the accent and its icon follows the text.
      app.setActiveTab(1);
      await tester.pump();
      final theme = Theme.of(tester.element(find.byKey(const ValueKey('tab-pill-tab-DEVICE-02'))));
      expect(tester.widget<Icon>(find.byKey(const ValueKey('tab-folder-color'))).color, theme.colorScheme.onPrimary);
      await tester.pumpWidget(const SizedBox());
      for (final s in sessions) {
        s.dispose();
      }
    });
  });

  group('command palette', () {
    test('@ lists the connections whose name or address matches, recent ones first', () async {
      final app = AppState();
      await app.ready;
      final a = SavedConnection(name: 'DEVICE-01', host: '192.0.2.10');
      final b = SavedConnection(name: 'DEVICE-02', host: '192.0.2.11');
      final c = SavedConnection(name: 'SERVER-A', host: '198.51.100.5');
      app.connections.addAll([a, b, c]);
      app.recentConnectionIds = [b.id];
      expect(paletteConnections(app, 'dev').map((x) => x.name), ['DEVICE-02', 'DEVICE-01']);
      expect(paletteConnections(app, '198.51').map((x) => x.name), ['SERVER-A']);
      expect(paletteConnections(app, ''), hasLength(3));
    });

    testWidgets('typing @ and a name, then Enter, opens that connection', (tester) async {
      tester.view.physicalSize = const Size(1000, 650);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final app = _NotingApp();
      await app.ready;
      app.connections.addAll([
        SavedConnection(name: 'DEVICE-01', host: '192.0.2.10'),
        SavedConnection(name: 'SERVER-A', host: '198.51.100.5'),
      ]);
      AppCommandId? result;
      await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
        value: app,
        child: MaterialApp(
          theme: AppTheme.dark(),
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async => result = await showCommandPalette(context),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('command-palette-search')), '@serv');
      await tester.pump();
      expect(find.text('SERVER-A'), findsOneWidget);
      expect(find.text('DEVICE-01'), findsNothing);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(app.opened.map((c) => c.name), ['SERVER-A']);
      expect(result, isNull, reason: 'a connection, not a command');
      expect(find.byKey(const Key('command-palette-dialog')), findsNothing);
    });
  });

  testWidgets('the list filters are plain words, the one in use underlined', (tester) async {
    final app = AppState();
    await app.ready;
    app.connections.addAll([
      SavedConnection(name: 'DEVICE-01', host: '192.0.2.10'),
      SavedConnection(name: 'SERVER-A', host: '198.51.100.5', protocol: ConnectionProtocol.rdp),
    ]);
    tester.view.physicalSize = const Size(360, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ChangeNotifierProvider.value(
      value: app,
      child: MaterialApp(theme: AppTheme.dark(), home: const Scaffold(body: ConnectionTree())),
    ));
    await tester.pump();
    final accent = AppTheme.dark().colorScheme.primary;
    Border borderOf(String name) => (tester
            .widget<Container>(find
                .descendant(of: find.byKey(ValueKey('tree-filter-$name')), matching: find.byType(Container))
                .first)
            .decoration as BoxDecoration)
        .border as Border;
    expect(borderOf('all').bottom.color, accent);
    expect(borderOf('ssh').bottom.color, Colors.transparent);
    expect(borderOf('ssh').top, BorderSide.none, reason: 'no frame around the words');
    await tester.tap(find.byKey(const ValueKey('tree-filter-ssh')));
    await tester.pump();
    expect(borderOf('ssh').bottom.color, accent);
    expect(borderOf('all').bottom.color, Colors.transparent);
  });

  testWidgets('before anything is saved the welcome box says Get started, and the empty list points at + New',
      (tester) async {
    final app = AppState();
    await app.ready;
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ChangeNotifierProvider.value(
      value: app,
      child: MaterialApp(
        theme: AppTheme.dark(),
        home: const Scaffold(body: Row(children: [SizedBox(width: 280, child: ConnectionTree()), Expanded(child: TerminalTabsArea())])),
      ),
    ));
    await tester.pump();
    expect(tester.widget<Text>(find.byKey(const Key('welcome-recent-title'))).data, 'GET STARTED');
    expect(tester.widget<Text>(find.byKey(const Key('tree-empty-hint'))).data, contains('"+ New"'));
  });

  testWidgets('the home button is a pill, filled while the welcome screen shows', (tester) async {
    final app = AppState();
    await app.ready;
    final c = SavedConnection(name: 'DEVICE-01', host: '192.0.2.10');
    app.connections.add(c);
    final sessions = _openSessions(app, [c]);
    await _pumpTabs(tester, app);
    final scheme = AppTheme.dark().colorScheme;
    Color? fill() => tester.widget<Material>(find.byKey(const Key('tab-home'))).color;
    expect(fill(), isNot(scheme.primary));
    await tester.tap(find.byKey(const Key('tab-home')));
    await tester.pump();
    expect(fill(), scheme.primary);
    final pill = tester.widget<Container>(find.byKey(const ValueKey('tab-pill-tab-DEVICE-01')));
    expect((pill.decoration as BoxDecoration).color, isNot(scheme.primary), reason: 'no tab is in use on the home screen');
    await tester.pumpWidget(const SizedBox());
    for (final s in sessions) {
      s.dispose();
    }
  });
}
