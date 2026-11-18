import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import '../app_version.dart';

/// Why a backup was taken. The name is part of the file name.
enum BackupReason {
  daily('daily'),
  manual('manual'),
  beforeImport('before-import'),
  beforeDelete('before-delete'),
  beforeRestore('before-restore');

  const BackupReason(this.code);
  final String code;

  static BackupReason? fromCode(String code) => values.where((r) => r.code == code).firstOrNull;
}

/// One backup file on disk.
class BackupEntry {
  const BackupEntry({
    required this.file,
    required this.created,
    required this.reason,
    required this.connections,
    this.written,
  });

  final File file;
  final DateTime created;

  /// When the file was written, to order two taken in the same second.
  final DateTime? written;
  final BackupReason reason;

  /// How many connections it holds, or null when it could not be read.
  final int? connections;
}

/// Copies of the saved folders, connections and layouts, one file each, kept
/// beside the app's other data (`%APPDATA%\CommandS\backups` on Windows).
///
/// A file is never changed once written: a mistake made today cannot reach a
/// copy taken yesterday. One is taken on the first start of each day, and one
/// just before anything that removes or replaces many items at once (an
/// import, a delete, a restore). The newest [keepDaily] daily copies and the
/// newest [keepOther] of the rest are kept; older ones are removed.
///
/// The copies hold the stored values exactly as saved, so remembered
/// passwords stay encrypted in them, with the same key as the app's own.
class BackupService {
  BackupService({Directory? directory}) : directory = directory ?? defaultDirectory();

  final Directory directory;

  static const keepDaily = 30;
  static const keepOther = 20;

  /// Off under `flutter test`, which must not write into the real app data;
  /// tests turn it on with a temporary [directory].
  static bool enabled = !Platform.environment.containsKey('FLUTTER_TEST');

  /// The stored values a backup holds.
  static const keys = ['commands.folders', 'commands.connections', 'commands.layouts', 'commands.credentialProfiles'];

  static Directory defaultDirectory() {
    // Tests never reach the real app data, even with backups turned on.
    if (Platform.environment.containsKey('FLUTTER_TEST')) {
      return Directory('${Directory.systemTemp.path}${Platform.pathSeparator}commands-test-backups');
    }
    if (Platform.isWindows) {
      final roaming = Platform.environment['APPDATA'] ??
          '${Platform.environment['USERPROFILE'] ?? Directory.current.path}\\AppData\\Roaming';
      return Directory('$roaming\\$appDataDirName\\backups');
    }
    final home = Platform.environment['HOME'] ?? Directory.current.path;
    if (Platform.isMacOS) return Directory('$home/Library/Application Support/$appDataDirName/backups');
    final state = Platform.environment['XDG_STATE_HOME'] ?? '$home/.local/state';
    return Directory('$state/$appDataDirName/backups');
  }

  static String _two(int n) => n.toString().padLeft(2, '0');

  static String _stamp(DateTime t) =>
      '${t.year}-${_two(t.month)}-${_two(t.day)}_${_two(t.hour)}${_two(t.minute)}${_two(t.second)}';

  static final _name = RegExp(r'^CommandS_(\d{4})-(\d{2})-(\d{2})_(\d{2})(\d{2})(\d{2})(?:_\d+)?_([a-z-]+)\.json$');

  /// Writes a backup of what is stored now. Returns null when disabled, when
  /// nothing has been saved yet, or when the file could not be written: a
  /// backup must never stop the change it was taken for.
  Future<File?> backUp(BackupReason reason, {DateTime? now}) async {
    if (!enabled) return null;
    try {
      final prefs = await SharedPreferences.getInstance();
      final data = {for (final k in keys) k: prefs.getString(k)};
      if (data.values.every((v) => v == null)) return null;
      final time = now ?? DateTime.now();
      await directory.create(recursive: true);
      var file = File('${directory.path}${Platform.pathSeparator}CommandS_${_stamp(time)}_${reason.code}.json');
      for (var n = 2; await file.exists(); n++) {
        file = File('${directory.path}${Platform.pathSeparator}CommandS_${_stamp(time)}_${n}_${reason.code}.json');
      }
      await file.writeAsString(jsonEncode({
        'format': 'commands-backup',
        'version': 1,
        'app': appVersion,
        'created': time.toIso8601String(),
        'reason': reason.code,
        'data': data,
      }));
      await _prune();
      return file;
    } catch (_) {
      return null;
    }
  }

  /// The day's backup, if today has none yet.
  Future<File?> dailyIfDue({DateTime? now}) async {
    if (!enabled) return null;
    final time = now ?? DateTime.now();
    final today = (await list()).where((e) =>
        e.reason == BackupReason.daily &&
        e.created.year == time.year &&
        e.created.month == time.month &&
        e.created.day == time.day);
    if (today.isNotEmpty) return null;
    return backUp(BackupReason.daily, now: time);
  }

  /// The backups on disk, newest first.
  Future<List<BackupEntry>> list() async {
    if (!await directory.exists()) return [];
    final entries = <BackupEntry>[];
    await for (final f in directory.list()) {
      if (f is! File) continue;
      final m = _name.firstMatch(f.uri.pathSegments.last);
      if (m == null) continue;
      final reason = BackupReason.fromCode(m[7]!);
      if (reason == null) continue;
      final created = DateTime(
        int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!), int.parse(m[4]!), int.parse(m[5]!), int.parse(m[6]!),
      );
      entries.add(BackupEntry(
        file: f,
        created: created,
        reason: reason,
        connections: await _countConnections(f),
        written: (await f.stat()).modified,
      ));
    }
    entries.sort((a, b) {
      final byTime = b.created.compareTo(a.created);
      if (byTime != 0) return byTime;
      final byWrite = (b.written ?? b.created).compareTo(a.written ?? a.created);
      return byWrite != 0 ? byWrite : b.file.path.compareTo(a.file.path);
    });
    return entries;
  }

  static Future<int?> _countConnections(File f) async {
    try {
      final data = (jsonDecode(await f.readAsString()) as Map)['data'] as Map;
      final raw = data['commands.connections'] as String?;
      return raw == null ? 0 : (jsonDecode(raw) as List).length;
    } catch (_) {
      return null;
    }
  }

  /// Puts [entry]'s values back in storage. What is stored now is backed up
  /// first, so a restore can itself be undone. Returns false if the file
  /// could not be read; nothing is changed then.
  Future<bool> restore(BackupEntry entry) async {
    final Map data;
    try {
      final doc = jsonDecode(await entry.file.readAsString()) as Map;
      if (doc['format'] != 'commands-backup') return false;
      data = doc['data'] as Map;
      for (final k in keys) {
        final v = data[k];
        if (v != null) jsonDecode(v as String);
      }
    } catch (_) {
      return false;
    }
    await backUp(BackupReason.beforeRestore);
    final prefs = await SharedPreferences.getInstance();
    for (final k in keys) {
      // A backup from before a value existed leaves today's as it is.
      if (!data.containsKey(k)) continue;
      final v = data[k] as String?;
      if (v == null) {
        await prefs.remove(k);
      } else {
        await prefs.setString(k, v);
      }
    }
    return true;
  }

  Future<void> _prune() async {
    final all = await list();
    final daily = all.where((e) => e.reason == BackupReason.daily).skip(keepDaily);
    final other = all.where((e) => e.reason != BackupReason.daily).skip(keepOther);
    for (final e in [...daily, ...other]) {
      try {
        await e.file.delete();
      } catch (_) {}
    }
  }
}
