import 'package:commands/l10n/collate.dart';
import 'package:commands/models/models.dart';
import 'package:commands/providers/app_state.dart';
import 'package:commands/widgets/connection_tree.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late AppState app;
  late ConnectionFolder outer, inner, other;

  Future<void> pumpTree(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    app = AppState();
    await tester.pump();
    outer = ConnectionFolder(name: 'CUSTOMER-A');
    inner = ConnectionFolder(name: 'SITE-1', parentId: outer.id);
    other = ConnectionFolder(name: 'CUSTOMER-B');
    app.folders.addAll([outer, inner, other]);
    app.connections.addAll([
      SavedConnection(name: 'DEVICE-01', host: '192.0.2.10', folderId: outer.id),
      SavedConnection(name: 'DEVICE-02', host: '192.0.2.11', folderId: inner.id),
      SavedConnection(name: 'DEVICE-03', host: '192.0.2.12', folderId: other.id),
      SavedConnection(name: 'DEVICE-04', host: '192.0.2.13'),
    ]);
    await tester.binding.setSurfaceSize(const Size(400, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: const MaterialApp(home: Scaffold(body: SizedBox(width: 360, child: ConnectionTree()))),
      ),
    );
    await tester.pumpAndSettle();
  }

  final selectButton = find.byKey(const ValueKey('select-mode'));
  final bar = find.byKey(const ValueKey('selection-bar'));
  Finder tick(String id) => find.byKey(ValueKey('tick-$id'));
  bool ticked(WidgetTester tester, String id) => tester.widget<Checkbox>(tick(id)).value!;

  testWidgets('Select shows empty boxes and the bar; pressing it again turns it off', (tester) async {
    await pumpTree(tester);
    expect(tick(outer.id), findsNothing);
    await tester.tap(selectButton);
    await tester.pumpAndSettle();
    expect(bar, findsOneWidget);
    expect(ticked(tester, outer.id), isFalse, reason: 'nothing is ticked to begin with');
    expect(ticked(tester, other.id), isFalse);

    await tester.tap(find.text('CUSTOMER-B'));
    await tester.pumpAndSettle();
    expect(ticked(tester, other.id), isTrue);
    expect(ticked(tester, outer.id), isFalse);

    await tester.tap(selectButton);
    await tester.pumpAndSettle();
    expect(tick(outer.id), findsNothing);
    expect(bar, findsNothing);
  });

  testWidgets('the bar selects everything, and a second press lets it all go', (tester) async {
    await pumpTree(tester);
    await tester.tap(selectButton);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('select-all')));
    await tester.pumpAndSettle();
    expect(find.descendant(of: bar, matching: find.text('7')), findsOneWidget);
    expect(ticked(tester, outer.id), isTrue);
    await tester.tap(find.byKey(const ValueKey('select-all')));
    await tester.pumpAndSettle();
    expect(find.descendant(of: bar, matching: find.text('0')), findsOneWidget);
    expect(ticked(tester, outer.id), isFalse);
    expect(bar, findsOneWidget, reason: 'still in select mode');
  });

  testWidgets('deleting a ticked folder deletes what is inside it, subfolders included', (tester) async {
    await pumpTree(tester);
    await tester.tap(selectButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('CUSTOMER-A'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('delete-selected')));
    await tester.pumpAndSettle();
    expect(find.text('Delete 2 folders and 2 connections?'), findsOneWidget);
    await tester.tap(find.widgetWithText(ElevatedButton, 'Delete'));
    await tester.pumpAndSettle();
    expect(app.folders.map((f) => f.name), ['CUSTOMER-B']);
    expect(app.connections.map((c) => c.name), ['DEVICE-03', 'DEVICE-04']);
  });

  test('deleting a subfolder leaves its parent and the parent\'s own connections', () async {
    SharedPreferences.setMockInitialValues({});
    final state = AppState();
    // Let it finish loading (empty) before the test's own data goes in.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final a = ConnectionFolder(name: 'CUSTOMER-A');
    final sub = ConnectionFolder(name: 'SITE-1', parentId: a.id);
    final deeper = ConnectionFolder(name: 'RACK-1', parentId: sub.id);
    state.folders.addAll([a, sub, deeper]);
    state.connections.addAll([
      SavedConnection(name: 'DEVICE-01', host: '192.0.2.10', folderId: a.id),
      SavedConnection(name: 'DEVICE-02', host: '192.0.2.11', folderId: deeper.id),
    ]);
    await state.deleteItems(folderIds: [sub.id]);
    expect(state.folders.map((f) => f.name), ['CUSTOMER-A']);
    expect(state.connections.map((c) => c.name), ['DEVICE-01']);
  });

  test('Turkish alphabetical order', () {
    final names = ['Pınar', 'Ömer', 'ozan', 'Irmak', 'İzmir', 'Çanakkale', 'cami', 'Şile', 'sahil', 'Zeytin', 'ılık'];
    names.sort(compareTurkish);
    expect(names, ['cami', 'Çanakkale', 'ılık', 'Irmak', 'İzmir', 'ozan', 'Ömer', 'Pınar', 'sahil', 'Şile', 'Zeytin']);
  });

  test('sorting selected folders orders only them, each level on its own', () async {
    SharedPreferences.setMockInitialValues({});
    final state = AppState();
    // Let it finish loading (empty) before the test's own data goes in.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final p = ConnectionFolder(name: 'Pazar');
    final keep = ConnectionFolder(name: 'AAA-KEEP');
    final o = ConnectionFolder(name: 'Ödemiş');
    final r = ConnectionFolder(name: 'Rize');
    final parent = ConnectionFolder(name: 'PARENT');
    final i = ConnectionFolder(name: 'İnegöl', parentId: parent.id);
    final dotless = ConnectionFolder(name: 'Isparta', parentId: parent.id);
    state.folders.addAll([p, keep, o, r, parent, i, dotless]);
    // A hand-made order: R, P, KEEP, Ö, PARENT.
    await state.placeFolders([r.id, p.id, keep.id, o.id, parent.id], null);
    await state.placeFolders([i.id, dotless.id], parent.id);

    await state.sortFoldersByName([p.id, o.id, r.id, i.id, dotless.id]);

    List<String> level(String? parentId) =>
        state.sortFolders(state.folders.where((f) => f.parentId == parentId).toList()).map((f) => f.name).toList();
    // KEEP and PARENT stay where they were; Ö, P, R fill the other places.
    expect(level(null), ['Ödemiş', 'Pazar', 'AAA-KEEP', 'Rize', 'PARENT']);
    expect(level(parent.id), ['Isparta', 'İnegöl']);
    expect(i.parentId, parent.id);

    // Kept after a restart.
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList('commands.folderOrder'), state.folderOrder);
  });
}
