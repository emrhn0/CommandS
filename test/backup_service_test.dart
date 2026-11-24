import 'dart:convert';
import 'dart:io';

import 'package:commands/models/models.dart';
import 'package:commands/providers/app_state.dart';
import 'package:commands/services/backup_service.dart';
import 'package:commands/services/storage_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

String _connections(List<String> names) => jsonEncode([
      for (var i = 0; i < names.length; i++) SavedConnection(name: names[i], host: '192.0.2.${10 + i}').toJson(),
    ]);

void main() {
  late Directory dir;
  late BackupService backups;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('commands-backups-');
    backups = BackupService(directory: dir);
    BackupService.enabled = true;
    final shared = BackupService.defaultDirectory();
    if (await shared.exists()) await shared.delete(recursive: true);
  });

  tearDown(() async {
    BackupService.enabled = false;
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  test('tests can never write into the real app data', () {
    expect(BackupService.defaultDirectory().path, startsWith(Directory.systemTemp.path));
  });

  test('a backup holds the stored values as they are, passwords still sealed', () async {
    final stored = _connections(['DEVICE-01', 'DEVICE-02']);
    SharedPreferences.setMockInitialValues({'commands.connections': stored, 'commands.folders': '[]'});
    final file = await backups.backUp(BackupReason.manual, now: DateTime(2026, 11, 18, 9, 30));
    expect(file, isNotNull);
    expect(file!.uri.pathSegments.last, 'CommandS_2026-11-18_093000_manual.json');
    final doc = jsonDecode(await file.readAsString()) as Map;
    expect(doc['format'], 'commands-backup');
    expect((doc['data'] as Map)['commands.connections'], stored);
    final entries = await backups.list();
    expect(entries.single.connections, 2);
    expect(entries.single.reason, BackupReason.manual);
  });

  test('nothing saved yet, nothing backed up', () async {
    SharedPreferences.setMockInitialValues({});
    expect(await backups.backUp(BackupReason.manual), isNull);
    expect(await backups.list(), isEmpty);
  });

  test('the daily backup is taken once a day', () async {
    SharedPreferences.setMockInitialValues({'commands.connections': _connections(['DEVICE-01'])});
    expect(await backups.dailyIfDue(now: DateTime(2026, 11, 18, 8)), isNotNull);
    expect(await backups.dailyIfDue(now: DateTime(2026, 11, 18, 17)), isNull);
    expect(await backups.dailyIfDue(now: DateTime(2026, 11, 19, 8)), isNotNull);
    expect(await backups.list(), hasLength(2));
  });

  test('old backups are removed: 30 daily and 20 others are kept', () async {
    SharedPreferences.setMockInitialValues({'commands.connections': _connections(['DEVICE-01'])});
    for (var d = 0; d < 35; d++) {
      await backups.backUp(BackupReason.daily, now: DateTime(2026, 1, 1).add(Duration(days: d)));
    }
    for (var m = 0; m < 25; m++) {
      await backups.backUp(BackupReason.beforeDelete, now: DateTime(2026, 3, 1, 10, m));
    }
    final all = await backups.list();
    expect(all.where((e) => e.reason == BackupReason.daily), hasLength(BackupService.keepDaily));
    expect(all.where((e) => e.reason != BackupReason.daily), hasLength(BackupService.keepOther));
    expect(all.where((e) => e.reason == BackupReason.daily).last.created, DateTime(2026, 1, 6), reason: 'the oldest went');
  });

  test('two backups in the same second do not overwrite each other', () async {
    SharedPreferences.setMockInitialValues({'commands.connections': _connections(['DEVICE-01'])});
    final t = DateTime(2026, 11, 18, 9);
    await backups.backUp(BackupReason.beforeDelete, now: t);
    await backups.backUp(BackupReason.beforeDelete, now: t);
    expect(await backups.list(), hasLength(2));
  });

  test('a restore puts the values back, after backing up what is there now', () async {
    final before = _connections(['DEVICE-01', 'DEVICE-02', 'DEVICE-03']);
    SharedPreferences.setMockInitialValues({'commands.connections': before});
    await backups.backUp(BackupReason.daily, now: DateTime(2026, 11, 17));
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('commands.connections', _connections(['DEVICE-01']));
    final entry = (await backups.list()).single;
    expect(await backups.restore(entry), isTrue);
    expect(prefs.getString('commands.connections'), before);
    final kept = await backups.list();
    expect(kept.where((e) => e.reason == BackupReason.beforeRestore).single.connections, 1);
  });

  test('a backup that cannot be read changes nothing', () async {
    SharedPreferences.setMockInitialValues({'commands.connections': _connections(['DEVICE-01'])});
    final file = File('${dir.path}${Platform.pathSeparator}CommandS_2026-11-18_090000_manual.json');
    await file.writeAsString('not json');
    final entry = (await backups.list()).single;
    expect(await backups.restore(entry), isFalse);
    final prefs = await SharedPreferences.getInstance();
    expect(jsonDecode(prefs.getString('commands.connections')!), hasLength(1));
  });

  group('a save that cannot be read', () {
    test('is never overwritten by the empty list the app started with', () async {
      SharedPreferences.setMockInitialValues({'commands.connections': '[{"broken'});
      final storage = StorageService();
      expect(await storage.loadConnections(), isEmpty);
      expect(storage.loadFailed, isTrue);
      await storage.saveConnections([SavedConnection(name: 'NEW', host: '192.0.2.20')]);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('commands.connections'), '[{"broken', reason: 'left for a restore');
    });

    test('the app says so, and a restore brings the connections back', () async {
      final good = _connections(['DEVICE-01', 'DEVICE-02']);
      SharedPreferences.setMockInitialValues({'commands.connections': good});
      final app = AppState();
      await app.ready;
      await app.dailyBackup;
      final saved = (await app.backups.list()).isEmpty ? await app.backups.backUp(BackupReason.manual) : null;
      expect(saved != null || (await app.backups.list()).isNotEmpty, isTrue);

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('commands.connections', '[{"broken');
      final broken = AppState();
      await broken.ready;
      await broken.dailyBackup;
      expect(broken.storageLoadFailed, isTrue);
      expect(broken.connections, isEmpty);
      await broken.upsertConnection(SavedConnection(name: 'NEW', host: '192.0.2.20'));
      expect(prefs.getString('commands.connections'), '[{"broken');

      final entry = (await broken.backups.list()).firstWhere((e) => e.connections == 2);
      expect(await broken.restoreBackup(entry), isTrue);
      expect(broken.storageLoadFailed, isFalse);
      expect(broken.connections.map((c) => c.name), containsAll(['DEVICE-01', 'DEVICE-02']));
      app.dispose();
      broken.dispose();
      await BackupService.defaultDirectory().delete(recursive: true);
    });
  });

  test('deleting a connection takes a backup first', () async {
    SharedPreferences.setMockInitialValues({'commands.connections': _connections(['DEVICE-01'])});
    final app = AppState();
    await app.ready;
    await app.dailyBackup;
    final target = BackupService.defaultDirectory();
    final before = await target.exists() ? (await app.backups.list()).length : 0;
    await app.deleteConnection(app.connections.single.id);
    final after = await app.backups.list();
    expect(after.length, before + 1);
    expect(after.first.reason, BackupReason.beforeDelete);
    expect(after.first.connections, 1, reason: 'taken before the delete');
    app.dispose();
    await target.delete(recursive: true);
  });

  test('deleting a saved layout takes a backup first', () async {
    final layout = SavedLayout(name: 'LAYOUT-1', preset: 'sideBySide', connectionIds: ['c1']);
    SharedPreferences.setMockInitialValues({
      'commands.connections': _connections(['DEVICE-01']),
      'commands.layouts': jsonEncode([layout.toJson()]),
    });
    final app = AppState();
    await app.ready;
    await app.dailyBackup;
    final target = BackupService.defaultDirectory();
    final before = await target.exists() ? (await app.backups.list()).length : 0;
    await app.deleteLayout(layout.id);
    final after = await app.backups.list();
    expect(after.length, before + 1);
    expect(after.first.reason, BackupReason.beforeDelete);
    app.dispose();
    await target.delete(recursive: true);
  });
}
