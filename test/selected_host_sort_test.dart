import 'package:commands/models/models.dart';
import 'package:commands/providers/app_state.dart';
import 'package:commands/widgets/connection_tree.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> showTree(WidgetTester tester, AppState app, {Size size = const Size(420, 500)}) async {
    await tester.binding.setSurfaceSize(size);
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

  testWidgets('selected hosts sort by numeric IP, preserving other slots and folders', (tester) async {
    final app = AppState();
    await tester.pump();
    final folder = ConnectionFolder(name: 'CUSTOMER-A');
    final otherFolder = ConnectionFolder(name: 'CUSTOMER-B');
    app.folders.addAll([folder, otherFolder]);
    SavedConnection host(String name, String address, String folderId) =>
        SavedConnection(name: name, host: address, folderId: folderId);
    final ten = host('DEVICE-10', '192.0.2.10', folder.id);
    final untouched = host('KEEP', '192.0.2.99', folder.id);
    final hostname = host('HOSTNAME', 'device.example', folder.id);
    final two = host('DEVICE-02', '192.0.2.2', folder.id);
    final ipv6 = host('DEVICE-V6', '2001:db8::1', folder.id);
    final otherTen = host('OTHER-10', '198.51.100.10', otherFolder.id);
    final otherTwo = host('OTHER-02', '198.51.100.2', otherFolder.id);
    app.connections.addAll([ten, untouched, hostname, two, ipv6, otherTen, otherTwo]);
    app.connectionOrder = app.connections.map((c) => c.id).toList();

    await app.sortConnectionsByIp([
      ten.id, hostname.id, two.id, ipv6.id, otherTen.id, otherTwo.id,
    ]);
    List<String> namesIn(String folderId) => app
        .sortConnections(app.connections.where((c) => c.folderId == folderId).toList())
        .map((c) => c.name)
        .toList();
    expect(namesIn(folder.id), [
      'DEVICE-02', 'KEEP', 'DEVICE-10', 'DEVICE-V6', 'HOSTNAME',
    ]);
    expect(namesIn(otherFolder.id), ['OTHER-02', 'OTHER-10']);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList('commands.connectionOrder'), app.connectionOrder);
    app.dispose();
  });

  testWidgets('host selection offers IP sorting and updates visible order', (tester) async {
    final app = AppState();
    await tester.pump();
    final folder = ConnectionFolder(name: 'CUSTOMER-A');
    app.folders.add(folder);
    final ten = SavedConnection(name: 'DEVICE-10', host: '192.0.2.10', folderId: folder.id);
    final two = SavedConnection(name: 'DEVICE-02', host: '192.0.2.2', folderId: folder.id);
    app.connections.addAll([ten, two]);
    app.connectionOrder = [ten.id, two.id];
    await showTree(tester, app);
    await tester.tap(find.byIcon(Icons.chevron_right));
    await tester.pumpAndSettle();
    await toggleSelectMode(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.text('DEVICE-10'));
    await tester.pump();
    await tester.tap(find.text('DEVICE-02'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('sort-selected')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('sort-selected')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('IP address'));
    await tester.pumpAndSettle();
    expect(app.sortConnections([...app.connections]).map((c) => c.name).toList(),
        ['DEVICE-02', 'DEVICE-10']);
    expect(tester.getCenter(find.text('DEVICE-02')).dy,
        lessThan(tester.getCenter(find.text('DEVICE-10')).dy));
    await tester.tap(find.byIcon(Icons.chevron_right));
    await tester.pumpAndSettle();
    await tester.binding.setSurfaceSize(const Size(200, 500));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
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
    await toggleSelectMode(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.text('R HOST'));
    await tester.pump();
    await tester.tap(find.text('Ö HOST'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('sort-selected')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('sort-selected')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Name (A–Z)'));
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
      await toggleSelectMode(tester);
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
    await toggleSelectMode(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.text('R FOLDER'));
    await tester.pump();
    await tester.tap(find.text('Ö FOLDER'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('sort-selected')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Name (A–Z)'));
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

  testWidgets('connections sort Z–A and by device type, unknown kinds last', (tester) async {
    final app = AppState();
    await tester.pump();
    final folder = ConnectionFolder(name: 'CUSTOMER-A');
    app.folders.add(folder);
    final unknown = SavedConnection(name: 'DEVICE-A', host: '192.0.2.1', folderId: folder.id);
    final win = SavedConnection(name: 'DEVICE-B', host: '192.0.2.2', folderId: folder.id, device: DeviceKind.windows);
    final linux = SavedConnection(name: 'DEVICE-C', host: '192.0.2.3', folderId: folder.id, device: DeviceKind.linux);
    app.connections.addAll([unknown, win, linux]);
    app.connectionOrder = app.connections.map((c) => c.id).toList();
    List<String> names() => app.sortConnections([...app.connections]).map((c) => c.name).toList();

    await app.sortConnectionsBy(app.connections.map((c) => c.id), TreeSort.nameDescending);
    expect(names(), ['DEVICE-C', 'DEVICE-B', 'DEVICE-A']);
    await app.sortConnectionsBy(app.connections.map((c) => c.id), TreeSort.nameAscending);
    expect(names(), ['DEVICE-A', 'DEVICE-B', 'DEVICE-C']);
    await app.sortConnectionsBy(app.connections.map((c) => c.id), TreeSort.deviceType);
    expect(names(), ['DEVICE-C', 'DEVICE-B', 'DEVICE-A']);
    app.dispose();
  });

  testWidgets('sorting a folder by name Z–A also orders its subfolders', (tester) async {
    final app = AppState();
    await tester.pump();
    final parent = ConnectionFolder(name: 'CUSTOMER-A');
    final a = ConnectionFolder(name: 'SITE-A', parentId: parent.id);
    final b = ConnectionFolder(name: 'SITE-B', parentId: parent.id);
    app.folders.addAll([parent, a, b]);
    app.folderOrder = [parent.id, a.id, b.id];
    final one = SavedConnection(name: 'DEVICE-01', host: '192.0.2.1', folderId: parent.id);
    final two = SavedConnection(name: 'DEVICE-02', host: '192.0.2.2', folderId: parent.id);
    app.connections.addAll([one, two]);
    app.connectionOrder = [one.id, two.id];

    await app.sortFolderContents(parent.id, TreeSort.nameDescending);
    expect(app.sortFolders(app.folders.where((f) => f.parentId == parent.id).toList()).map((f) => f.name).toList(),
        ['SITE-B', 'SITE-A']);
    expect(app.sortConnections([...app.connections]).map((c) => c.name).toList(), ['DEVICE-02', 'DEVICE-01']);
    app.dispose();
  });

  testWidgets('a folder sorts its connections from its menu, nothing selected first', (tester) async {
    final app = AppState();
    await tester.pump();
    final folder = ConnectionFolder(name: 'CUSTOMER-A');
    app.folders.add(folder);
    final ten = SavedConnection(name: 'DEVICE-10', host: '192.0.2.10', folderId: folder.id);
    final two = SavedConnection(name: 'DEVICE-02', host: '192.0.2.2', folderId: folder.id);
    app.connections.addAll([ten, two]);
    app.connectionOrder = [ten.id, two.id];
    await showTree(tester, app, size: const Size(840, 500));

    await tester.tap(find.text('CUSTOMER-A'), buttons: kSecondaryMouseButton, kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sort contents'));
    await tester.pumpAndSettle();
    expect(find.text('Open all connections'), findsOneWidget);
    final trigger = tester.getRect(find.byKey(const ValueKey('context-submenu-trigger-sort')));
    final submenu = tester.getRect(find.byKey(const ValueKey('context-submenu-sort')));
    expect(submenu.left, trigger.right);
    expect(submenu.top, trigger.top);
    expect(find.text('Device type'), findsOneWidget);
    await tester.tap(find.text('IP address'));
    await tester.pumpAndSettle();
    expect(find.text('Sort contents'), findsNothing);
    expect(find.text('IP address'), findsNothing);

    expect(app.sortConnections([...app.connections]).map((c) => c.name).toList(), ['DEVICE-02', 'DEVICE-10']);
    await tester.pumpWidget(const SizedBox());
    app.dispose();
  });

  testWidgets('the sort menu names its orders and leaves out what does not apply', (tester) async {
    final app = AppState();
    await tester.pump();
    final a = ConnectionFolder(name: 'CUSTOMER-A');
    final b = ConnectionFolder(name: 'CUSTOMER-B');
    app.folders.addAll([a, b]);
    await showTree(tester, app);
    await toggleSelectMode(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.text('CUSTOMER-A'));
    await tester.pump();
    await tester.tap(find.text('CUSTOMER-B'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('sort-selected')));
    await tester.pumpAndSettle();
    expect(find.text('Name (A–Z)'), findsOneWidget);
    expect(find.text('Name (Z–A)'), findsOneWidget);
    expect(find.text('IP address'), findsNothing, reason: 'only folders are selected');
    await tester.tap(find.text('Name (Z–A)'));
    await tester.pumpAndSettle();
    expect(app.sortFolders([...app.folders]).map((f) => f.name).toList(), ['CUSTOMER-B', 'CUSTOMER-A']);
    await tester.pumpWidget(const SizedBox());
    app.dispose();
  });
}

/// Select mode is in the list's view menu (next to the search box).
Future<void> toggleSelectMode(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('tree-view-menu')));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Select').last);
}
