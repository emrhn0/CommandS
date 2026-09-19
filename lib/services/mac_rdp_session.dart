import 'dart:async';
import 'dart:io';

import '../models/models.dart';
import 'session_controller.dart';

/// RDP on macOS, handed to whichever Microsoft client is installed.
///
/// The Windows path ([RdpSessionController]) embeds mstsc's own window
/// inside our tab with `SetParent`. macOS has no equivalent: AppKit will
/// not let one process adopt another process's window, so a client started
/// this way is always a window of its own. Drawing the session inside the
/// tab means speaking RDP ourselves -- which is exactly what Remote Desktop
/// Manager does on this platform, by linking FreeRDP in-process -- and that
/// is tracked separately; until it lands, launching the real client beats
/// the previous behavior, where opening an RDP tab on macOS ran the win32
/// controller and took the session down with it.
///
/// Credentials: the generated `.rdp` carries host, port, domain and
/// username, so only the password is left to type in the client. The
/// password is deliberately *not* pushed anywhere — the `password 51:b:`
/// field in an `.rdp` file is a Windows DPAPI blob that means nothing on a
/// Mac, and the Microsoft clients keep their own credentials in a private
/// keychain entry we would only be guessing at. Writing the user's password
/// into the login keychain on a guess is worse than one prompt.
class MacRdpSessionController implements SessionController {
  MacRdpSessionController(this.conn) : host = conn.host {
    tabTitle = conn.name;
    unawaited(_start());
  }

  final SavedConnection conn;
  @override
  final String host;
  @override
  String? tabTitle;

  final _statusController = StreamController<SessionStatus>.broadcast();
  @override
  Stream<SessionStatus> get statusStream => _statusController.stream;
  @override
  SessionStatus status = SessionStatus.starting;

  String? lastError;

  /// The client CommandS actually managed to launch, for the tab to name.
  String? launchedApp;

  Directory? _scratchDir;
  bool _disposed = false;

  /// Current name first, then the name it shipped under for years — both
  /// are on machines in the wild.
  static const _clients = ['Windows App', 'Microsoft Remote Desktop'];

  void _setStatus(SessionStatus s) {
    status = s;
    if (!_statusController.isClosed) _statusController.add(s);
  }

  int get _port => conn.port == 22 ? 3389 : conn.port;

  Future<void> _start() async {
    try {
      final app = _findClient();
      if (app == null) {
        lastError = 'No Microsoft RDP client found. Install "Windows App" from the Mac App Store.';
        _setStatus(SessionStatus.error);
        return;
      }

      _scratchDir = await Directory.systemTemp.createTemp('commands_rdp_');
      final rdpFile = File('${_scratchDir!.path}/${_safeFileName(conn.name)}.rdp');
      await rdpFile.writeAsString(_rdpContents());

      final result = await Process.run('/usr/bin/open', ['-a', app, rdpFile.path]);
      if (result.exitCode != 0) {
        lastError = (result.stderr as String).trim().isEmpty
            ? 'Could not launch $app (exit ${result.exitCode}).'
            : (result.stderr as String).trim();
        _setStatus(SessionStatus.error);
        return;
      }

      launchedApp = app;
      _setStatus(SessionStatus.running);
      // The client reads the file as it opens; give it a moment, then take
      // the credentials-bearing file back off disk.
      Future.delayed(const Duration(seconds: 20), _cleanUpScratch);
    } catch (e) {
      lastError = e.toString();
      _setStatus(SessionStatus.error);
      _cleanUpScratch();
    }
  }

  /// Re-launches the same session — the tab's only real control, since we
  /// do not own the window the client puts on screen.
  Future<void> relaunch() async {
    if (_disposed) return;
    _cleanUpScratch();
    _setStatus(SessionStatus.starting);
    await _start();
  }

  static String? _findClient() {
    for (final name in _clients) {
      if (Directory('/Applications/$name.app').existsSync()) return name;
    }
    // Anywhere else the user may have put it.
    for (final name in _clients) {
      final r = Process.runSync('/usr/bin/mdfind', ['kMDItemFSName == "$name.app"']);
      if ((r.stdout as String).trim().isNotEmpty) return name;
    }
    return null;
  }

  String _rdpContents() {
    final user = conn.domain != null && conn.domain!.isNotEmpty
        ? '${conn.domain}\\${conn.username}'
        : conn.username;
    final buffer = StringBuffer()
      ..writeln('full address:s:$host:$_port')
      ..writeln('prompt for credentials:i:0')
      ..writeln('screen mode id:i:1')
      ..writeln('session bpp:i:32')
      ..writeln('audiomode:i:2')
      ..writeln('redirectclipboard:i:${conn.rdpClipboard ? 1 : 0}')
      ..writeln('disable wallpaper:i:${conn.rdpWallpaper ? 0 : 1}')
      ..writeln('authentication level:i:0')
      ..writeln('negotiate security layer:i:1');
    if (user.isNotEmpty) buffer.writeln('username:s:$user');
    return buffer.toString();
  }

  static String _safeFileName(String name) {
    final cleaned = name.replaceAll(RegExp(r'[^A-Za-z0-9._\- ]'), '_').trim();
    return cleaned.isEmpty ? 'session' : cleaned;
  }

  void _cleanUpScratch() {
    final dir = _scratchDir;
    if (dir == null) return;
    _scratchDir = null;
    try {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    } catch (_) {
      // Best effort.
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _cleanUpScratch();
    _statusController.close();
  }
}
