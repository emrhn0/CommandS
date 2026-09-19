import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

/// Carries saved connections across the 1.0.24 sandbox change on macOS.
///
/// Up to 1.0.23 the release build was sandboxed, so `NSUserDefaults` — where
/// shared_preferences keeps everything CommandS stores — lived inside the
/// app's container. Dropping the sandbox (an SSH client has to reach the
/// network and the user's own ~/.ssh) moves those defaults to the normal
/// `~/Library/Preferences` location, and an upgraded install would have come
/// up with an empty connection tree. This copies the old container's values
/// over, once, when the new location has nothing in it yet.
///
/// Best effort throughout: a failure here costs the user an import, not a
/// working app.
class MacPrefsMigration {
  static const _kFolders = 'commands.folders';
  static const _kConnections = 'commands.connections';

  /// shared_preferences namespaces every key it writes.
  static const _prefix = 'flutter.';

  static const _bundleId = 'com.commands.commands';

  static Future<void> run() async {
    if (!Platform.isMacOS) return;

    final prefs = await SharedPreferences.getInstance();
    // Anything already here means this install has its own data — either a
    // fresh start the user has since filled in, or a migration that already
    // happened. Either way, leave it alone.
    if (prefs.getString(_kFolders) != null || prefs.getString(_kConnections) != null) return;

    final home = Platform.environment['HOME'];
    if (home == null || home.isEmpty) return;
    final containerPlist = File(
      '$home/Library/Containers/$_bundleId/Data/Library/Preferences/$_bundleId.plist',
    );
    if (!containerPlist.existsSync()) return;

    final old = await _readPlist(containerPlist);
    if (old == null) return;

    for (final key in [_kFolders, _kConnections]) {
      final value = old['$_prefix$key'];
      if (value is String && value.isNotEmpty) await prefs.setString(key, value);
    }
    // Terminal colors are cheap to bring along too.
    for (final key in ['commands.terminalBg', 'commands.terminalFg']) {
      final value = old['$_prefix$key'];
      if (value is int) await prefs.setInt(key, value);
    }
  }

  /// `plutil` is part of macOS, so the plist is read without pulling in a
  /// parser of our own.
  static Future<Map<String, dynamic>?> _readPlist(File plist) async {
    try {
      final result = await Process.run('/usr/bin/plutil', ['-convert', 'json', '-o', '-', plist.path]);
      if (result.exitCode != 0) return null;
      final decoded = jsonDecode(result.stdout as String);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }
}
