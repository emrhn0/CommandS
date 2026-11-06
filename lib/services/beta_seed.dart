import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app_version.dart';

/// Gives a freshly installed beta the normal app's connections and settings,
/// once, so it can be tried on real work. Everything stays on this machine:
/// the normal app's saved file and its password key are copied over locally.
///
/// After that the two keep separate data, as before: nothing done in the beta
/// changes the normal app.
class BetaSeed {
  static const _done = 'commands.betaSeeded';

  /// Not copied: each app keeps its own update state.
  static bool _skip(String key) => key.startsWith('commands.update.') || key == _done;

  /// Where the normal app keeps its data. Replaced in tests.
  @visibleForTesting
  static String? stablePrefsPath = Platform.isWindows
      ? '${Platform.environment['APPDATA']}\\com.commands\\commands\\shared_preferences.json'
      : null;
  @visibleForTesting
  static String? stableKeyPath = Platform.isWindows ? '${Platform.environment['APPDATA']}\\CommandS\\password.key' : null;
  @visibleForTesting
  static String? betaKeyPath = Platform.isWindows ? '${Platform.environment['APPDATA']}\\CommandS-Beta\\password.key' : null;

  /// Copies once, into a beta that has no connections of its own yet.
  static Future<void> run({bool force = false}) async {
    if (!force && buildChannel != ReleaseChannel.beta) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(_done) == true) return;
      final hasOwn = (prefs.getString('commands.connections') ?? '[]') != '[]';
      final source = await _readStable();
      if (hasOwn || source == null) {
        await prefs.setBool(_done, true);
        return;
      }
      // The key first: copied connections are useless without it, and a key
      // the beta already made is never replaced.
      final from = stableKeyPath, to = betaKeyPath;
      if (from != null && to != null && File(from).existsSync() && !File(to).existsSync()) {
        await File(to).parent.create(recursive: true);
        await File(from).copy(to);
      }
      for (final entry in source.entries) {
        if (!entry.key.startsWith('flutter.')) continue;
        final key = entry.key.substring('flutter.'.length);
        if (_skip(key)) continue;
        final value = entry.value;
        if (value is String) {
          await prefs.setString(key, value);
        } else if (value is bool) {
          await prefs.setBool(key, value);
        } else if (value is int) {
          await prefs.setInt(key, value);
        } else if (value is double) {
          await prefs.setDouble(key, value);
        } else if (value is List) {
          await prefs.setStringList(key, value.map((e) => '$e').toList());
        }
      }
      await prefs.setBool(_done, true);
    } catch (error) {
      // A beta that starts empty is still a working beta.
      debugPrint('Could not copy the normal app\'s data: ${error.runtimeType}');
    }
  }

  static Future<Map<String, dynamic>?> _readStable() async {
    final path = stablePrefsPath;
    if (path != null) {
      final file = File(path);
      if (!file.existsSync()) return null;
      final decoded = jsonDecode(await file.readAsString());
      return decoded is Map<String, dynamic> ? decoded : null;
    }
    if (Platform.isMacOS) {
      final home = Platform.environment['HOME'];
      final plist = '$home/Library/Preferences/com.commands.commands.plist';
      if (home == null || !File(plist).existsSync()) return null;
      final r = await Process.run('/usr/bin/plutil', ['-convert', 'json', '-o', '-', plist]);
      if (r.exitCode != 0) return null;
      final decoded = jsonDecode(r.stdout as String);
      if (decoded is! Map<String, dynamic>) return null;
      await _copyMacKey();
      return decoded;
    }
    return null;
  }

  /// macOS keeps the key in the Keychain, under each app's own name.
  static Future<void> _copyMacKey() async {
    const account = 'password-key';
    final own = await Process.run('/usr/bin/security', ['find-generic-password', '-s', 'CommandS Beta', '-a', account]);
    if (own.exitCode == 0) return;
    final r = await Process.run('/usr/bin/security', ['find-generic-password', '-s', 'CommandS', '-a', account, '-w']);
    if (r.exitCode != 0) return;
    final key = (r.stdout as String).trim();
    final p = await Process.start('/usr/bin/security', ['-i']);
    p.stdin.writeln('add-generic-password -s "CommandS Beta" -a $account -w $key');
    await p.stdin.close();
    await Future.wait([p.stdout.drain<void>(), p.stderr.drain<void>()]);
    await p.exitCode;
  }
}
