import 'dart:async';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app_version.dart';
import '../l10n/strings.dart';

/// Turns terminal output into the plain text a reader would see on screen.
///
/// Colours, titles and other control sequences are removed. The current line
/// is edited the way the terminal edits it, so what was typed and then
/// erased (backspace, cursor left, erase to end of line, a redrawn prompt)
/// does not reach the log: only the line as it finally stood. A line is
/// returned once it ends; [flush] gives the unfinished last one.
///
/// Output arrives in chunks, so a sequence cut at the end of one chunk is
/// held until the next.
///
/// [columns] is the terminal's width. A line longer than that wraps onto the
/// next row of the screen, and a shell moves around a long command row by
/// row (carriage return, cursor up), so those moves need the width to land
/// in the right place. Without it every line is taken as one endless row.
class TerminalTextCleaner {
  TerminalTextCleaner({this.columns});

  final int Function()? columns;

  int get _width {
    final w = columns?.call() ?? 0;
    return w > 0 ? w : 1 << 30;
  }

  /// Where the cursor's screen row starts. Just past the last column the
  /// cursor still belongs to the row it filled (the terminal wraps only once
  /// the next character comes).
  int _rowStart() {
    final w = _width;
    final row = _cursor > 0 && _cursor % w == 0 ? (_cursor - 1) ~/ w : _cursor ~/ w;
    return row * w;
  }

  static const _sequence =
      r'\x1B(?:\[[0-?]*[ -/]*[@-~]|\][^\x07\x1B]*(?:\x07|\x1B\\)|[PX^_][^\x1B]*\x1B\\|[()*+][0-~]|[ -/]*[0-Z\\^-~])';
  static final _token = RegExp('$_sequence|[\\x00-\\x1F\\x7F]');
  static final _whole = RegExp('^(?:$_sequence)');
  static final _csi = RegExp(r'^\x1B\[([0-?]*)[ -/]*([@-~])$');
  static const _maxHeld = 4096;

  /// A line longer than this is written out as it is, so a stream with no
  /// line breaks cannot grow without end.
  static const _maxLine = 65536;

  String _held = '';

  /// The line being drawn, one entry per character, and the cursor in it.
  final List<String> _line = [];
  int _cursor = 0;

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
    final out = StringBuffer();
    var at = 0;
    for (final m in _token.allMatches(text)) {
      if (m.start > at) _put(text.substring(at, m.start));
      _control(m.group(0)!, out);
      at = m.end;
    }
    if (at < text.length) _put(text.substring(at));
    if (_line.length > _maxLine) out.write(_take());
    return out.toString();
  }

  /// The last line, which has not ended yet.
  String flush() => _take();

  String _take() {
    final line = _line.join().trimRight();
    _line.clear();
    _cursor = 0;
    return line;
  }

  /// Printable text overwrites the line from the cursor, as on screen.
  void _put(String text) {
    _afterCr = false;
    for (final rune in text.runes) {
      final ch = String.fromCharCode(rune);
      while (_line.length < _cursor) {
        _line.add(' ');
      }
      if (_cursor < _line.length) {
        _line[_cursor] = ch;
      } else {
        _line.add(ch);
      }
      _cursor++;
    }
  }

  /// The last thing seen was a carriage return, so a line feed now ends the
  /// line with "\r\n", as it came.
  bool _afterCr = false;

  void _control(String code, StringBuffer out) {
    final afterCr = _afterCr;
    // A colour reset between the two does not split "\r\n".
    _afterCr = code == '\r' || (afterCr && code.startsWith('\x1B'));
    switch (code) {
      case '\n':
        out.write('${_take()}${afterCr ? '\r\n' : '\n'}');
        return;
      case '\r':
        _cursor = _rowStart();
        return;
      case '\b':
        // As on screen, not back past the row's start.
        if (_cursor > _rowStart()) _cursor--;
        return;
      case '\t':
        _put('\t');
        return;
    }
    final csi = _csi.firstMatch(code);
    if (csi == null) return;
    final params = csi.group(1)!;
    final n = int.tryParse(params.split(';').first) ?? 0;
    final count = n == 0 ? 1 : n;
    final rowStart = _rowStart();
    final rowEnd = rowStart + _width;
    void blank(int from, int to) {
      if (to >= _line.length) {
        if (from < _line.length) _line.removeRange(from, _line.length);
        return;
      }
      for (var i = from; i < to; i++) {
        _line[i] = ' ';
      }
    }

    switch (csi.group(2)) {
      case 'D': // cursor left, not past the row's start
        _cursor = (_cursor - count).clamp(rowStart, _cursor);
      case 'C': // cursor right
        _cursor = (_cursor + count).clamp(_cursor, rowEnd - 1);
      case 'A': // up a row, within this line
        _cursor = (_cursor - count * _width).clamp(0, _cursor);
      case 'B': // down a row
        _cursor += count * _width;
      case 'G': // to column
        _cursor = rowStart + count - 1;
      case 'K': // erase in this row
        if (n == 0) {
          blank(_cursor, rowEnd);
        } else if (n == 1) {
          blank(rowStart, _cursor + 1);
        } else if (n == 2) {
          blank(rowStart, rowEnd);
        }
      case 'J': // erase below: the rest of this line goes
        if (n == 0) blank(_cursor, 1 << 30);
      case 'P': // delete characters
        if (_cursor < _line.length) {
          _line.removeRange(_cursor, (_cursor + count).clamp(_cursor, _line.length));
        }
      case '@': // insert blanks
        if (_cursor < _line.length) _line.insertAll(_cursor, List.filled(count, ' '));
      case 'X': // erase characters
        for (var i = _cursor; i < _cursor + count && i < _line.length; i++) {
          _line[i] = ' ';
        }
    }
  }
}

/// The log folder picked in Settings is gone: deleted, renamed or moved.
/// It is not made again under the old name, which would leave logs where
/// nobody looks; a folder has to be chosen again.
class SessionLogFolderMissing implements Exception {
  const SessionLogFolderMissing(this.path);
  final String path;

  @override
  String toString() => tr(
    'The log folder {path} no longer exists. Choose a log folder in Settings > Session logs.',
    {'path': path},
  );
}

/// The selected root is local to this installation, never part of exports.
class SessionLogSettings {
  static const preferenceKey = 'commands.sessionLogDirectory';

  /// The folder picked in Settings, or null for the default one.
  static Future<String?> chosenDirectory() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(preferenceKey);
    return saved != null && saved.trim().isNotEmpty ? saved : null;
  }

  /// Where logs go. The default folder is made when needed; a folder picked
  /// in Settings that has gone throws [SessionLogFolderMissing].
  static Future<String> directory() async {
    final saved = await chosenDirectory();
    if (saved != null) {
      // One quick look; synchronous, so it also works where async file
      // I/O is held back (widget tests).
      if (!Directory(saved).existsSync()) throw SessionLogFolderMissing(saved);
      return saved;
    }
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
  SessionLogRecorder._(this.path, this._file, this.onError, int Function()? columns)
    : _cleaner = TerminalTextCleaner(columns: columns);

  final String path;
  final RandomAccessFile _file;
  final void Function(Object error)? onError;
  Future<void> _writes = Future<void>.value();
  Future<void>? _closing;
  bool _stopping = false;
  bool _failed = false;

  /// Starts a log for the connection [name] (the host when it has none),
  /// kept as the connection list keeps it: under [folders], the names of
  /// its folder and the folders above it, outermost first, then a folder of
  /// its own: root/Folder/Subfolder/Name/Name_17_11_2026.txt. A second log
  /// of the same day gets " (2)", and so on.
  static Future<SessionLogRecorder> start({
    required String root,
    required String host,
    String? name,
    List<String> folders = const [],
    DateTime? now,
    void Function(Object error)? onError,
    int Function()? columns,
  }) async {
    final time = now ?? DateTime.now();
    final safeName = _safeHost((name == null || name.trim().isEmpty) ? host : name);
    final date = '${_two(time.day)}_${_two(time.month)}_${time.year.toString().padLeft(4, '0')}';
    final separator = Platform.pathSeparator;
    final path = [root, for (final f in folders) _safeHost(f), safeName].join(separator);
    final directory = Directory(path);
    await directory.create(recursive: true);
    for (var suffix = 0; suffix < 10000; suffix++) {
      final base = '${safeName}_$date';
      final name = suffix == 0 ? '$base.txt' : '$base (${suffix + 1}).txt';
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
          columns,
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

  final TerminalTextCleaner _cleaner;

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
    // The prompt the session stopped at, which has no line break yet.
    final last = _cleaner.flush();
    if (last.isNotEmpty && !_failed) {
      _writes = _writes.then((_) async {
        if (_failed) return;
        try {
          await _file.writeString(last);
        } catch (error) {
          _failed = true;
          onError?.call(error);
        }
      });
    }
    await _writes;
    try {
      if (!_failed) await _file.flush();
    } finally {
      await _file.close();
    }
  }
}
