import 'dart:async';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app_version.dart';

/// Removes terminal control sequences (colours, cursor moves, titles) so a
/// log reads as plain text. Output arrives in chunks, so a sequence cut at
/// the end of one chunk is held until the next.
class TerminalTextCleaner {
  static const _sequence =
      r'\x1B(?:\[[0-?]*[ -/]*[@-~]|\][^\x07\x1B]*(?:\x07|\x1B\\)|[PX^_][^\x1B]*\x1B\\|[()*+][0-~]|[ -/]*[0-Z\\^-~])';
  static final _codes = RegExp('$_sequence|[\\x00-\\x08\\x0B\\x0C\\x0E-\\x1A\\x1C-\\x1F\\x7F]');
  static final _whole = RegExp('^(?:$_sequence)');
  static const _maxHeld = 4096;

  String _held = '';

  String clean(String chunk) {
    var text = _held + chunk;
    _held = '';
    final escape = text.lastIndexOf('\x1B');
    if (escape >= 0) {
      final tail = text.substring(escape);
      if (!_whole.hasMatch(tail)) {
        text = text.substring(0, escape);
        // A sequence that never ends is dropped rather than held forever.
        if (tail.length <= _maxHeld) _held = tail;
      }
    }
    return text.replaceAll(_codes, '');
  }
}

/// The selected root is local to this installation, never part of exports.
class SessionLogSettings {
  static const preferenceKey = 'commands.sessionLogDirectory';

  static Future<String> directory() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(preferenceKey);
    if (saved != null && saved.trim().isNotEmpty) return saved;
    return defaultDirectory(Platform.environment);
  }

  /// Logs hold device output, so by default they stay on this computer. The
  /// Documents folder is often synced to a cloud drive (OneDrive, iCloud),
  /// and a roaming profile would copy them to a server.
  static Future<String> defaultDirectory(Map<String, String> env) async {
    final sep = Platform.pathSeparator;
    final local = env['LOCALAPPDATA'];
    if (Platform.isWindows && local != null && local.isNotEmpty) {
      return '$local$sep$appDataDirName${sep}Session Logs';
    }
    final home = env['HOME'];
    if (Platform.isMacOS && home != null && home.isNotEmpty) {
      return '$home/Library/Application Support/$appDataDirName/Session Logs';
    }
    final support = await getApplicationSupportDirectory();
    return '${support.path}${sep}Session Logs';
  }

  static Future<void> setDirectory(String path) async {
    if (path.trim().isEmpty || !Directory(path).isAbsolute) {
      throw ArgumentError.value(
        path,
        'path',
        'An absolute directory is required',
      );
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(preferenceKey, path);
  }
}

/// Writes the decoded SSH output as UTF-8, in the order shown by the terminal.
/// Keystrokes are never written here. Each file is claimed exclusively so two
/// sessions started in the same second cannot overwrite one another.
class SessionLogRecorder {
  SessionLogRecorder._(this.path, this._file, this.onError);

  final String path;
  final RandomAccessFile _file;
  final void Function(Object error)? onError;
  Future<void> _writes = Future<void>.value();
  Future<void>? _closing;
  bool _stopping = false;
  bool _failed = false;

  static Future<SessionLogRecorder> start({
    required String root,
    required String host,
    DateTime? now,
    void Function(Object error)? onError,
  }) async {
    final time = now ?? DateTime.now();
    final safeHost = _safeHost(host);
    final date =
        '${time.year.toString().padLeft(4, '0')}-${_two(time.month)}-${_two(time.day)}';
    // Colon is forbidden in Windows file names. Hyphens work on every target.
    final stamp =
        '${_two(time.hour)}-${_two(time.minute)}-${_two(time.second)}';
    final separator = Platform.pathSeparator;
    final directory = Directory('$root$separator$safeHost$separator$date');
    await directory.create(recursive: true);
    for (var suffix = 0; suffix < 10000; suffix++) {
      final name = suffix == 0 ? '$stamp.log' : '$stamp-$suffix.log';
      final file = File('${directory.path}$separator$name');
      try {
        await file.create(exclusive: true);
      } on FileSystemException {
        if (await file.exists()) continue;
        rethrow;
      }
      try {
        return SessionLogRecorder._(
          file.path,
          await file.open(mode: FileMode.append),
          onError,
        );
      } catch (_) {
        await file.delete();
        rethrow;
      }
    }
    throw FileSystemException(
      'No available session log filename',
      directory.path,
    );
  }

  static String _two(int number) => number.toString().padLeft(2, '0');

  static String _safeHost(String value) {
    final cleaned = value
        .trim()
        .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), '_')
        .replaceAll(RegExp(r'[. ]+$'), '');
    if (cleaned.isEmpty || cleaned == '.' || cleaned == '..') {
      return 'unknown-host';
    }
    // Windows treats these as device names even when an extension follows.
    if (RegExp(
      r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)',
      caseSensitive: false,
    ).hasMatch(cleaned)) {
      return '_$cleaned';
    }
    return cleaned;
  }

  final _cleaner = TerminalTextCleaner();

  void write(String output) {
    if (_stopping || _failed || output.isEmpty) return;
    final text = _cleaner.clean(output);
    if (text.isEmpty) return;
    _writes = _writes.then((_) async {
      if (_failed) return;
      try {
        await _file.writeString(text);
      } catch (error) {
        _failed = true;
        onError?.call(error);
      }
    });
  }

  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    _stopping = true;
    await _writes;
    try {
      if (!_failed) await _file.flush();
    } finally {
      await _file.close();
    }
  }
}
