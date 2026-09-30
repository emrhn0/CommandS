import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import '../models/models.dart';
import 'session_controller.dart';

/// Which program is actually going to show the remote desktop.
enum MacRdpBackend {
  /// FreeRDP's SDL client, if the user has it (`brew install freerdp`). Takes
  /// the whole connection — password included — on the command line, so the
  /// session opens straight onto the remote desktop with nothing to type, and
  /// renegotiates resolution as its window is resized.
  freerdp,

  /// Microsoft's own client ("Windows App", previously "Microsoft Remote
  /// Desktop"). Reads the host, port, domain and username out of a generated
  /// `.rdp`, then asks for the password itself.
  microsoft,
}

/// RDP on macOS.
///
/// The Windows path ([RdpSessionController]) hosts Microsoft's RDP ActiveX
/// control inside the tab. macOS has no equivalent: there is no system RDP
/// component to embed, and AppKit will not let one process adopt another
/// process's window, so any client started from here is a window of its own.
/// Drawing the session inside the tab means speaking RDP in-process — which is
/// what Remote Desktop Manager does on this platform, by linking FreeRDP — and
/// that is tracked separately. Until it lands, the job here is to get the user
/// onto the remote desktop with as little friction as the platform allows,
/// which mostly means preferring FreeRDP when it is installed, because it is
/// the only option that can be handed a password.
///
/// What this replaced: opening an RDP connection on macOS used to construct the
/// Windows controller, whose first call is into win32, and take the app down
/// with it.
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

  /// Which client was used, and what it is called, for the pane to explain
  /// what just happened and what is left for the user to do.
  MacRdpBackend? backend;
  String? backendName;

  /// True when the session needed no password typed anywhere.
  bool get credentialsHandedOver =>
      backend == MacRdpBackend.freerdp && _password.isNotEmpty;

  /// True when a FreeRDP install would remove the remaining password prompt.
  bool get freerdpWouldHelp =>
      backend == MacRdpBackend.microsoft && _password.isNotEmpty;

  Process? _process;
  Directory? _scratchDir;
  bool _disposed = false;

  String get _password => conn.rememberPassword ? conn.password : '';

  int get _port => conn.port == 22 ? 3389 : conn.port;

  String get _qualifiedUser => conn.domain != null && conn.domain!.isNotEmpty
      ? '${conn.domain}\\${conn.username}'
      : conn.username;

  void _setStatus(SessionStatus s) {
    if (_disposed) return;
    status = s;
    if (!_statusController.isClosed) _statusController.add(s);
  }

  // ---- launching ----

  Future<void> _start() async {
    try {
      final freerdp = _findFreeRdp();
      if (freerdp != null) {
        await _startFreeRdp(freerdp);
        return;
      }
      final app = _findMicrosoftClient();
      if (app != null) {
        await _startMicrosoftClient(app);
        return;
      }
      lastError =
          'No RDP client found. Install Microsoft "Windows App" from the Mac '
          'App Store, or run "brew install freerdp" for a client CommandS can '
          'hand your saved password to.';
      _setStatus(SessionStatus.error);
    } catch (e) {
      lastError = e.toString();
      _setStatus(SessionStatus.error);
      _cleanUpScratch();
    }
  }

  /// Homebrew on Apple silicon, Homebrew on Intel, then MacPorts. The SDL
  /// client is the one to want: `xfreerdp` needs an X server, which a Mac
  /// normally does not have running.
  static const _freeRdpCandidates = [
    '/opt/homebrew/bin/sdl-freerdp3',
    '/opt/homebrew/bin/sdl-freerdp',
    '/usr/local/bin/sdl-freerdp3',
    '/usr/local/bin/sdl-freerdp',
    '/opt/local/bin/sdl-freerdp3',
    '/opt/local/bin/sdl-freerdp',
  ];

  static String? _findFreeRdp() {
    for (final path in _freeRdpCandidates) {
      if (File(path).existsSync()) return path;
    }
    return null;
  }

  Future<void> _startFreeRdp(String binary) async {
    final args = <String>[
      '/v:$host:$_port',
      if (conn.username.isNotEmpty) '/u:${conn.username}',
      if (conn.domain != null && conn.domain!.isNotEmpty) '/d:${conn.domain}',
      if (_password.isNotEmpty) '/p:$_password',
      // Resize the window, and the remote desktop is re-rendered at the new
      // size rather than scaled — the same behaviour the Windows side gets from
      // UpdateSessionDisplaySettings.
      '/dynamic-resolution',
      // These servers are typically on the user's own network with a
      // self-signed certificate, and there is no dialog to show for it here.
      '/cert:ignore',
      '+auto-reconnect',
      '+fonts',
      if (conn.rdpClipboard) '+clipboard' else '-clipboard',
      if (conn.rdpWallpaper) '+wallpaper' else '-wallpaper',
      '/audio-mode:0',
      '/t:${conn.name}',
    ];
    // The password is on the command line, which is as private as the process
    // list: on macOS only root and the owning user can read another process's
    // arguments. That is the same audience as the `.rdp` file the Microsoft
    // path writes, and it buys the user not having to type the password at all.
    _process = await Process.start(binary, args);
    backend = MacRdpBackend.freerdp;
    backendName = 'FreeRDP';
    _setStatus(SessionStatus.running);
    unawaited(_process!.exitCode.then((code) {
      if (_disposed) return;
      if (code == 0) {
        _setStatus(SessionStatus.closed);
      } else {
        lastError = 'FreeRDP exited with code $code.';
        _setStatus(SessionStatus.error);
      }
    }));
  }

  /// Current name first, then the name it shipped under for years — both are
  /// on machines in the wild.
  static const _microsoftClients = ['Windows App', 'Microsoft Remote Desktop'];

  static String? _findMicrosoftClient() {
    for (final name in _microsoftClients) {
      if (Directory('/Applications/$name.app').existsSync()) return name;
    }
    // Anywhere else the user may have put it.
    for (final name in _microsoftClients) {
      final result =
          Process.runSync('/usr/bin/mdfind', ['kMDItemFSName == "$name.app"']);
      if ((result.stdout as String).trim().isNotEmpty) return name;
    }
    return null;
  }

  Future<void> _startMicrosoftClient(String app) async {
    _scratchDir = await Directory.systemTemp.createTemp('commands_rdp_');
    final rdpFile =
        File('${_scratchDir!.path}/${_safeFileName(conn.name)}.rdp');
    await rdpFile.writeAsString(_rdpContents());

    final result = await Process.run('/usr/bin/open', ['-a', app, rdpFile.path]);
    if (result.exitCode != 0) {
      final stderr = (result.stderr as String).trim();
      lastError = stderr.isEmpty
          ? 'Could not launch $app (exit ${result.exitCode}).'
          : stderr;
      _setStatus(SessionStatus.error);
      _cleanUpScratch();
      return;
    }
    backend = MacRdpBackend.microsoft;
    backendName = app;
    _setStatus(SessionStatus.running);
    // The client reads the file as it opens; give it a moment, then take the
    // file back off disk rather than leaving the connection details around.
    Timer(const Duration(seconds: 20), _cleanUpScratch);
  }

  /// The password is deliberately *not* written into the `.rdp`: the
  /// `password 51:b:` field is a Windows DPAPI blob and means nothing on a Mac,
  /// and the Microsoft clients keep credentials in a private keychain entry we
  /// would only be guessing at. Writing the user's password into the login
  /// keychain on a guess is worse than one prompt — and [copyPasswordToClipboard]
  /// makes that prompt a paste.
  String _rdpContents() {
    final buffer = StringBuffer()
      ..writeln('full address:s:$host:$_port')
      ..writeln('prompt for credentials:i:0')
      ..writeln('screen mode id:i:1')
      ..writeln('session bpp:i:32')
      ..writeln('audiomode:i:0')
      ..writeln('redirectclipboard:i:${conn.rdpClipboard ? 1 : 0}')
      ..writeln('disable wallpaper:i:${conn.rdpWallpaper ? 0 : 1}')
      ..writeln('authentication level:i:0')
      ..writeln('negotiate security layer:i:1');
    if (_qualifiedUser.isNotEmpty) {
      buffer.writeln('username:s:$_qualifiedUser');
    }
    return buffer.toString();
  }

  /// Puts the saved password on the clipboard so the Microsoft client's prompt
  /// is one paste. Offered as a button rather than done automatically —
  /// silently replacing whatever the user had copied is not this app's call.
  Future<bool> copyPasswordToClipboard() async {
    if (_password.isEmpty) return false;
    await Clipboard.setData(ClipboardData(text: _password));
    return true;
  }

  /// Re-launches the same session — the tab's only real control, since we do
  /// not own the window the client puts on screen.
  Future<void> relaunch() async {
    if (_disposed) return;
    _cleanUpScratch();
    _process = null;
    backend = null;
    backendName = null;
    lastError = null;
    _setStatus(SessionStatus.starting);
    await _start();
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
    // Closing the tab closes the session it opened -- leaving an orphaned
    // FreeRDP window behind with no tab to manage it would be worse than
    // ending it.
    try {
      _process?.kill();
    } catch (_) {}
    _process = null;
    _cleanUpScratch();
    _statusController.close();
  }
}
