import 'dart:convert';

import 'package:commands/models/models.dart';
import 'package:commands/providers/app_state.dart';
import 'package:commands/services/storage_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The tree is walked from the top, so a folder, connection or layout that
/// cannot be reached from there was stored but never shown.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<AppState> start([Map<String, Object> stored = const {}]) async {
    SharedPreferences.setMockInitialValues(stored);
    final app = AppState();
    await app.ready;
    return app;
  }

  bool reachable(AppState app, String? folderId) {
    final seen = <String>{};
    var cursor = folderId;
    while (cursor != null) {
      if (!seen.add(cursor)) return false;
      final f = app.folders.where((x) => x.id == cursor).firstOrNull;
      if (f == null) return false;
      cursor = f.parentId;
    }
    return true;
  }

  test('an imported connection in a folder that does not exist comes to the top', () async {
    final app = await start();
    await app.importParsed(const [], [SavedConnection(name: 'DEVICE-01', host: '192.0.2.10', folderId: 'missing')]);
    expect(app.connections.single.folderId, isNull);
  });

  test('an imported folder inside a folder that does not exist comes to the top', () async {
    final app = await start();
    final folder = ConnectionFolder(id: 'a', name: 'CUSTOMER-A', parentId: 'missing');
    await app.importParsed([folder], [SavedConnection(name: 'DEVICE-01', host: '192.0.2.10', folderId: 'a')]);
    expect(app.folders.single.parentId, isNull);
    expect(app.connections.single.folderId, 'a', reason: 'the connection stays in its folder');
  });

  test('imported folders inside one another in a loop are shown again', () async {
    final app = await start();
    await app.importParsed(
      [
        ConnectionFolder(id: 'a', name: 'CUSTOMER-A', parentId: 'c'),
        ConnectionFolder(id: 'b', name: 'CUSTOMER-B', parentId: 'a'),
        ConnectionFolder(id: 'c', name: 'CUSTOMER-C', parentId: 'b'),
      ],
      [SavedConnection(name: 'DEVICE-01', host: '192.0.2.10', folderId: 'b')],
    );
    for (final f in app.folders) {
      expect(reachable(app, f.id), isTrue, reason: '${f.name} is reachable from the top');
    }
    expect(app.folders.where((f) => f.parentId == null).map((f) => f.id), ['a'],
        reason: 'only the loop is broken, the rest keeps its nesting');
    expect(app.connections.single.folderId, 'b');
  });

  test('a stored loop and stored orphans are fixed on start and saved', () async {
    final layout = SavedLayout(name: 'LAYOUT-1', preset: 'sideBySide', connectionIds: ['c1'], folderId: 'missing');
    final app = await start({
      'commands.folders': jsonEncode([
        ConnectionFolder(id: 'a', name: 'CUSTOMER-A', parentId: 'b').toJson(),
        ConnectionFolder(id: 'b', name: 'CUSTOMER-B', parentId: 'a').toJson(),
      ]),
      'commands.connections': jsonEncode([
        SavedConnection(id: 'c1', name: 'DEVICE-01', host: '192.0.2.10', folderId: 'missing').toJson(),
      ]),
      'commands.layouts': jsonEncode([layout.toJson()]),
    });
    expect(app.folders.every((f) => reachable(app, f.id)), isTrue);
    expect(app.connections.single.folderId, isNull);
    expect(app.layouts.single.folderId, isNull);

    final storage = StorageService();
    expect((await storage.loadConnections()).single.folderId, isNull, reason: 'saved, not only fixed in memory');
    expect((await storage.loadLayouts()).single.folderId, isNull);
    final folders = await storage.loadFolders();
    expect(folders.where((f) => f.parentId == null), hasLength(1));
    app.dispose();
  });

  test('deleting a folder drops it from the folder order', () async {
    final app = await start();
    await app.addFolder('CUSTOMER-A');
    await app.addFolder('CUSTOMER-B');
    final a = app.folders.firstWhere((f) => f.name == 'CUSTOMER-A');
    final b = app.folders.firstWhere((f) => f.name == 'CUSTOMER-B');
    app.folderOrder = [b.id, a.id];
    await app.deleteFolder(a.id);
    expect(app.folderOrder, [b.id]);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList('commands.folderOrder'), [b.id]);
  });
}
