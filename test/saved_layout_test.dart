import 'package:commands/models/models.dart';
import 'package:commands/providers/app_state.dart';
import 'package:commands/services/pane_layout.dart';
import 'package:commands/services/rdp_session.dart';
import 'package:commands/services/session_controller.dart';
import 'package:commands/services/storage_service.dart';
import 'package:commands/widgets/app_dialog.dart';
import 'package:commands/widgets/connection_tree.dart';
import 'package:commands/widgets/split_view_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeSession implements SessionController {
  _FakeSession(this.host);
  @override
  final String host;
  @override
  String? get tabTitle => host;
  @override
  SessionStatus status = SessionStatus.running;
  @override
  Stream<SessionStatus> get statusStream => const Stream.empty();
  @override
  void dispose() {}
}

/// Opening a saved RDP connection talks to the native RDP host; answer for it.
void _fakeRdpChannel() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('commands/rdp'),
    (call) async => call.method == 'create' ? 1 : (call.method == 'connect' ? true : null),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppState app;
  late SavedConnection ssh1, ssh2, rdp;
  late ConnectionFolder folder;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    _fakeRdpChannel();
    app = AppState();
    await Future<void>.delayed(Duration.zero); // let _load finish
    folder = ConnectionFolder(name: 'CUSTOMER-A');
    ssh1 = SavedConnection(name: 'switch-01', host: '192.0.2.11', folderId: folder.id);
    ssh2 = SavedConnection(name: 'switch-02', host: '192.0.2.12', folderId: folder.id);
    rdp = SavedConnection(name: 'server-01', host: '192.0.2.20', port: 3389,
        protocol: ConnectionProtocol.rdp, folderId: folder.id);
    app.folders.add(folder);
    app.connections.addAll([ssh1, ssh2, rdp]);
  });

  OpenTab fakeTab(SavedConnection c) {
    final t = OpenTab(id: 'tab-${c.id}', controller: _FakeSession(c.host), connectionId: c.id);
    app.tabs.add(t);
    return t;
  }

  test('saving keeps the connections, in pane order, and persists', () async {
    final a = fakeTab(rdp), b = fakeTab(ssh1), c = fakeTab(ssh2);
    final quick = OpenTab(id: 'quick', controller: _FakeSession('192.0.2.99'));
    app.tabs.add(quick);
    final saved = await app.saveLayout(
      name: 'Morning check',
      folderId: folder.id,
      preset: SplitPreset.oneLeftTwoRight,
      tabIds: [a.id, b.id, c.id],
    );
    expect(saved.connectionIds, [rdp.id, ssh1.id, ssh2.id]);
    expect(saved.preset, 'oneLeftTwoRight');
    final stored = await StorageService().loadLayouts();
    expect(stored.single.name, 'Morning check');
    expect(stored.single.folderId, folder.id);

    // A quick connection cannot be reopened, so its pane is saved empty.
    final withQuick = await app.saveLayout(
      name: 'q', folderId: null, preset: SplitPreset.sideBySide, tabIds: [quick.id, b.id]);
    expect(withQuick.connectionIds, [null, ssh1.id]);
  });

  test('opening reuses open tabs, opens the rest, and lays them out as saved', () async {
    final open = fakeTab(ssh1);
    final layout = SavedLayout(
      name: 'L', folderId: folder.id, preset: 'oneLeftTwoRight',
      connectionIds: [rdp.id, ssh1.id, null],
    );
    final filled = app.openLayout(layout);
    expect(filled, 2);
    final ids = tabIdsInLayoutOrdered(app.paneLayout);
    expect(ids.length, 2);
    expect(ids[1], open.id, reason: 'the already-open SSH tab is reused, not opened twice');
    final rdpTab = app.tabs.firstWhere((t) => t.id == ids[0]);
    expect(rdpTab.connectionId, rdp.id);
    expect(rdpTab.controller, isA<RdpSessionController>());
    expect(app.tabs.where((t) => t.connectionId == ssh1.id).length, 1);
    rdpTab.controller.dispose();
  });

  test('a connection deleted since saving just leaves its pane out', () async {
    fakeTab(ssh1);
    final layout = SavedLayout(name: 'L', preset: 'sideBySide', connectionIds: ['gone', ssh1.id]);
    expect(app.openLayout(layout), 1);
    expect(app.paneLayout, isA<PaneLeaf>());
    expect(app.openLayout(SavedLayout(name: 'x', preset: 'grid', connectionIds: ['gone'])), 0);
  });

  test('layouts travel through JSON export and import', () async {
    await app.saveLayout(name: 'Exported', folderId: folder.id, preset: SplitPreset.stacked,
        tabIds: [fakeTab(ssh1).id, fakeTab(ssh2).id]);
    final json = app.exportAll();
    final parsed = StorageService().parseJson(json);
    expect(parsed.layouts.single.name, 'Exported');

    SharedPreferences.setMockInitialValues({});
    final other = AppState();
    await Future<void>.delayed(Duration.zero);
    // Only one of the two connections is chosen on import.
    await other.importParsed(parsed.folders, [parsed.connections.firstWhere((c) => c.id == ssh1.id)],
        parsedLayouts: parsed.layouts);
    expect(other.layouts.single.connectionIds, [ssh1.id, null]);
    expect(other.layouts.single.folderId, folder.id);
  });

  test('deleting a folder moves its layouts to the top level', () async {
    await app.saveLayout(name: 'L', folderId: folder.id, preset: SplitPreset.single, tabIds: [fakeTab(ssh1).id]);
    await app.deleteFolder(folder.id);
    expect(app.layouts.single.folderId, isNull);
  });

  testWidgets('a saved layout shows in its folder and opens on click', (tester) async {
    fakeTab(ssh1);
    fakeTab(ssh2);
    await app.saveLayout(name: 'Both switches', folderId: folder.id, preset: SplitPreset.sideBySide,
        tabIds: ['tab-${ssh1.id}', 'tab-${ssh2.id}']);
    app.paneLayout = PaneLeaf('tab-${ssh1.id}');

    await tester.pumpWidget(ChangeNotifierProvider.value(
      value: app,
      child: const MaterialApp(home: Scaffold(body: SizedBox(width: 260, child: ConnectionTree()))),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('CUSTOMER-A'));
    await tester.pumpAndSettle();
    expect(find.text('Both switches'), findsOneWidget);

    await tester.tap(find.text('Both switches'));
    await tester.pumpAndSettle();
    expect(tabIdsInLayoutOrdered(app.paneLayout), ['tab-${ssh1.id}', 'tab-${ssh2.id}']);
  });

  testWidgets('Split view saves the arrangement as a layout', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    fakeTab(ssh1);
    fakeTab(ssh2);
    app.paneLayout = buildLayout(SplitPreset.sideBySide, ['tab-${ssh1.id}', 'tab-${ssh2.id}']);

    await tester.pumpWidget(ChangeNotifierProvider.value(
      value: app,
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(onPressed: () => showSplitViewDialog(context), child: const Text('open')),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save as layout…'));
    await tester.pumpAndSettle();
    await tester.enterText(find.descendant(of: find.widgetWithText(LabeledField, 'Name'), matching: find.byType(TextField)), 'Both switches');
    await tester.tap(find.widgetWithText(ElevatedButton, 'Save'));
    await tester.pumpAndSettle();

    expect(app.layouts.single.name, 'Both switches');
    expect(app.layouts.single.preset, 'sideBySide');
    expect(app.layouts.single.connectionIds, [ssh1.id, ssh2.id]);
    expect(find.textContaining('Saved to the top level'), findsOneWidget);
  });
}
