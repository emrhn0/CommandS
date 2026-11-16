import 'package:commands/models/models.dart';
import 'package:commands/providers/app_state.dart';
import 'package:commands/widgets/connection_tree.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> showTree(WidgetTester tester, AppState app) async {
    await tester.binding.setSurfaceSize(const Size(420, 500));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: const MaterialApp(
          home: Scaffold(body: SizedBox(width: 340, child: ConnectionTree())),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('selected hosts sort in their own slots and keep their folders', (
    tester,
  ) async {
    final app = AppState();
    await tester.pump();
    final first = ConnectionFolder(name: 'CUSTOMER-A');
    final second = ConnectionFolder(name: 'CUSTOMER-B');
    app.folders.addAll([first, second]);
    SavedConnection host(String name, String folderId, String address) =>
        SavedConnection(name: name, host: address, folderId: folderId);
    final r = host('R HOST', first.id, '192.0.2.10');
    final untouched = host('KEEP', first.id, '192.0.2.11');
    final odiaeresis = host('Ö HOST', first.id, '192.0.2.12');
    final p = host('P HOST', first.id, '192.0.2.13');
    final o = host('O HOST', first.id, '192.0.2.14');
    final dotted = host('İ HOST', second.id, '192.0.2.15');
    final dotless = host('I HOST', second.id, '192.0.2.16');
    app.connections.addAll([r, untouched, odiaeresis, p, o, dotted, dotless]);
    app.connectionOrder = app.connections.map((c) => c.id).toList();

    await app.sortConnectionsByName([
      r.id,
      odiaeresis.id,
      p.id,
      o.id,
      dotted.id,
      dotless.id,
    ]);
    List<String> namesIn(String folderId) => app
        .sortConnections(
          app.connections.where((c) => c.folderId == folderId).toList(),
        )
        .map((c) => c.name)
        .toList();
    expect(namesIn(first.id), ['O HOST', 'KEEP', 'Ö HOST', 'P HOST', 'R HOST']);
    expect(namesIn(second.id), ['I HOST', 'İ HOST']);
    expect(
      app.connections.every(
        (c) => c.folderId == first.id || c.folderId == second.id,
      ),
      isTrue,
    );
    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getStringList('commands.connectionOrder'),
      app.connectionOrder,
    );
    app.dispose();
  });

  testWidgets('host-only selection offers A–Z and reorders the visible hosts', (
    tester,
  ) async {
    final app = AppState();
    await tester.pump();
    final folder = ConnectionFolder(name: 'CUSTOMER-A');
    app.folders.add(folder);
    final r = SavedConnection(
      name: 'R HOST',
      host: '192.0.2.10',
      folderId: folder.id,
    );
    final o = SavedConnection(
      name: 'Ö HOST',
      host: '192.0.2.11',
      folderId: folder.id,
    );
    app.connections.addAll([r, o]);
    app.connectionOrder = [r.id, o.id];
    await showTree(tester, app);
    await tester.tap(find.byIcon(Icons.chevron_right));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('select-mode')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('R HOST'));
    await tester.pump();
    await tester.tap(find.text('Ö HOST'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('sort-selected')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('sort-selected')));
    await tester.pumpAndSettle();
    expect(
      app.sortConnections([...app.connections]).map((c) => c.name).toList(),
      ['Ö HOST', 'R HOST'],
    );
    expect(
      tester.getCenter(find.text('Ö HOST')).dy,
      lessThan(tester.getCenter(find.text('R HOST')).dy),
    );
    expect(find.byKey(const ValueKey('selection-bar')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    app.dispose();
  });

  testWidgets(
    'hosts in different folders do not offer an ineffective sort action',
    (tester) async {
      final app = AppState();
      await tester.pump();
      final first = ConnectionFolder(name: 'CUSTOMER-A');
      final second = ConnectionFolder(name: 'CUSTOMER-B');
      app.folders.addAll([first, second]);
      app.connections.addAll([
        SavedConnection(name: 'HOST-A', host: '192.0.2.10', folderId: first.id),
        SavedConnection(
          name: 'HOST-B',
          host: '192.0.2.11',
          folderId: second.id,
        ),
      ]);
      await showTree(tester, app);
      await tester.tap(find.byIcon(Icons.chevron_right).first);
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.chevron_right).last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('select-mode')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('HOST-A'));
      await tester.pump();
      await tester.tap(find.text('HOST-B'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('sort-selected')), findsNothing);
      await tester.pumpWidget(const SizedBox());
      app.dispose();
    },
  );

  testWidgets('mixed selection sorts folders and hosts independently', (
    tester,
  ) async {
    final app = AppState();
    await tester.pump();
    final rFolder = ConnectionFolder(name: 'R FOLDER');
    final oFolder = ConnectionFolder(name: 'Ö FOLDER');
    app.folders.addAll([rFolder, oFolder]);
    app.folderOrder = [rFolder.id, oFolder.id];
    final rHost = SavedConnection(
      name: 'R HOST',
      host: '192.0.2.10',
      folderId: rFolder.id,
    );
    final oHost = SavedConnection(
      name: 'Ö HOST',
      host: '192.0.2.11',
      folderId: rFolder.id,
    );
    app.connections.addAll([rHost, oHost]);
    app.connectionOrder = [rHost.id, oHost.id];
    await showTree(tester, app);
    await tester.tap(find.byIcon(Icons.chevron_right).first);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('select-mode')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('R FOLDER'));
    await tester.pump();
    await tester.tap(find.text('Ö FOLDER'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('sort-selected')));
    await tester.pumpAndSettle();
    expect(app.sortFolders([...app.folders]).map((f) => f.name).toList(), [
      'Ö FOLDER',
      'R FOLDER',
    ]);
    expect(
      app.sortConnections([...app.connections]).map((c) => c.name).toList(),
      ['Ö HOST', 'R HOST'],
    );
    await tester.pumpWidget(const SizedBox());
    app.dispose();
  });
}
