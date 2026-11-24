import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show ChangeNotifier, visibleForTesting;
import 'package:flutter/services.dart';

import '../models/models.dart';
import 'mac_rdp_channel.dart';
import 'rdp_keymap.dart';
import 'session_controller.dart';

/// Which program is actually going to show the remote desktop.
enum MacRdpBackend {
  /// Drawn inside the tab by the FreeRDP engine linked into the app
  /// (`packages/commands_rdp_mac`), like the ActiveX control on Windows. The
  /// normal case; the two below are only the fallback for a build without it.
  embedded,

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
/// The session is drawn inside its tab, as on Windows: the app links FreeRDP
/// (`packages/commands_rdp_mac`), which speaks RDP in-process and paints the
/// remote desktop into a Flutter texture. That is what Remote Desktop Manager
/// does on this platform; macOS has no system RDP component to embed, and
/// AppKit does not let one process adopt another's window.
///
/// A build without the engine (it is made by `tool/build_freerdp.sh`) falls
/// back to what this used to do: start FreeRDP's own client if it is
/// installed, else Microsoft's "Windows App", each in a window of its own.
///
/// Opening an RDP connection on macOS once constructed the Windows
/// controller, whose first call is into win32, and took the app down with it.
class MacRdpSessionController with ChangeNotifier implements SessionController {
  MacRdpSessionController(this.conn) : host = conn.host {
    tabTitle = conn.name;
    unawaited(_chooseBackend());
  }

  /// A controller that launches nothing, so a test never opens a real client.
  @visibleForTesting
  MacRdpSessionController.idle(this.conn) : host = conn.host {
    tabTitle = conn.name;
  }

  /// Off under `flutter test`: a test that opens an RDP connection on a Mac
  /// without the engine must not start FreeRDP or Windows App for real (it
  /// did, and Windows App kept trying to reach the test address).
  static bool launchExternalClients = !Platform.environment.containsKey('FLUTTER_TEST');

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

  /// True while the session is drawn in the tab (the normal case).
  bool get embedded => backend == MacRdpBackend.embedded;

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
    notifyListeners();
  }

  // ---- embedded session ----

  /// Picks the engine when this build has it, otherwise an external client.
  Future<void> _chooseBackend() async {
    final available = await MacRdpChannel.instance.available();
    if (_disposed) return;
    if (!available) {
      await _start();
      return;
    }
    backend = MacRdpBackend.embedded;
    backendName = 'FreeRDP';
    _sessionPassword = _password;
    _user = conn.username;
    // The pane reports its size on its first layout, so the desktop is
    // negotiated at the size it is shown at; this covers a pane that never
    // lays out (a tab opened behind others).
    _fallbackStart = Timer(const Duration(milliseconds: 1200), () {
      if (!_autoStarted) _connectEmbedded(1280, 800);
    });
    notifyListeners();
    if (_pendingSize != null && !_autoStarted) _connectEmbedded(_pendingSize!.$1, _pendingSize!.$2);
  }

  MacRdpHandle? _handle;
  bool _connecting = false;

  /// The one automatic connect (first layout, or the fallback timer) has
  /// happened. Every later attempt comes from the user.
  bool _autoStarted = false;
  Timer? _fallbackStart;
  Timer? _resizeDebounce;
  (int, int)? _pendingSize;

  /// The login used for this tab: the saved one, or what the user typed into
  /// the pane. What is typed is kept for this tab only, never saved.
  String _user = '';
  String _sessionPassword = '';

  /// The Flutter texture the remote desktop is drawn into, once connected.
  int? get textureId => _handle?.textureId;

  /// The remote desktop's size in pixels.
  int remoteWidth = 0;
  int remoteHeight = 0;

  /// The server wants a user name and password this tab does not have (none
  /// saved, or the saved one was refused); the pane asks for them.
  bool needsCredentials = false;
  String get user => _user;

  final keys = RdpKeyTranslator();

  /// The pane's size in device pixels, on every layout. Starts the session
  /// on the first one, and renegotiates the resolution once the size settles.
  void reportSize(int width, int height) {
    if (_disposed || width < 200 || height < 200) return;
    // Even sizes: some servers reject odd widths for dynamic resolution.
    width &= ~1;
    height &= ~1;
    _pendingSize = (width, height);
    if (!embedded) return;
    final handle = _handle;
    if (handle == null) {
      // Only the first layout connects on its own. After a session failed or
      // ended, a new attempt is the user's call (Reconnect, or the login
      // form): retrying on every rebuild would send the same login again and
      // again and lock the account.
      if (!_autoStarted && !_connecting && !needsCredentials) _connectEmbedded(width, height);
      return;
    }
    if (width == remoteWidth && height == remoteHeight) {
      _resizeDebounce?.cancel();
      return;
    }
    _resizeDebounce?.cancel();
    _resizeDebounce = Timer(const Duration(milliseconds: 350), () {
      if (_handle == handle && !_disposed) unawaited(MacRdpChannel.instance.resize(handle.id, width, height));
    });
  }

  Future<void> _connectEmbedded(int width, int height) async {
    if (_disposed || _connecting || _handle != null) return;
    _autoStarted = true;
    _fallbackStart?.cancel();
    if (_sessionPassword.isEmpty) {
      // NLA needs the password before anything is drawn; ask in the pane.
      needsCredentials = true;
      notifyListeners();
      return;
    }
    _connecting = true;
    needsCredentials = false;
    lastError = null;
    _setStatus(SessionStatus.starting);
    try {
      final handle = await MacRdpChannel.instance.connect(
        host: host,
        port: _port,
        username: _user,
        domain: conn.domain ?? '',
        password: _sessionPassword,
        width: width,
        height: height,
        clipboard: conn.rdpClipboard,
        wallpaper: conn.rdpWallpaper,
        onEvent: _onEvent,
      );
      if (_disposed) {
        await MacRdpChannel.instance.close(handle.id);
        return;
      }
      _handle = handle;
      keys.isoKeyboard = handle.isoKeyboard;
      remoteWidth = width;
      remoteHeight = height;
      notifyListeners();
    } on PlatformException catch (e) {
      lastError = e.message ?? e.code;
      _setStatus(SessionStatus.error);
    } catch (e) {
      lastError = e.toString();
      _setStatus(SessionStatus.error);
    } finally {
      _connecting = false;
    }
  }

  void _onEvent(MacRdpEvent event) {
    if (_disposed) return;
    switch (event.type) {
      case 'connected':
        lastError = null;
        _setStatus(SessionStatus.running);
      case 'size':
        remoteWidth = event.width;
        remoteHeight = event.height;
        notifyListeners();
      case 'closed':
        _dropHandle();
        lastError = null;
        _setStatus(SessionStatus.closed);
      case 'error':
        _dropHandle();
        lastError = event.message.isEmpty ? null : event.message;
        if (event.authFailed) {
          needsCredentials = true;
          _setStatus(SessionStatus.starting);
        } else {
          _setStatus(SessionStatus.error);
        }
    }
  }

  void _dropHandle() {
    final handle = _handle;
    _handle = null;
    if (handle != null) unawaited(MacRdpChannel.instance.close(handle.id));
  }

  /// The login typed into the pane, for this tab only.
  void signIn(String user, String password) {
    if (_disposed || password.isEmpty) return;
    _user = user.trim();
    _sessionPassword = password;
    needsCredentials = false;
    final size = _pendingSize ?? (1280, 800);
    unawaited(_connectEmbedded(size.$1, size.$2));
  }

  /// A key went down or up while the pane has the keyboard.
  void sendKey(int usbHidUsage, {required bool down, bool repeat = false}) {
    final handle = _handle;
    if (handle == null || status != SessionStatus.running) return;
    for (final stroke in keys.translate(usbHidUsage, down: down, repeat: repeat)) {
      unawaited(MacRdpChannel.instance.key(handle.id, stroke.scancode, down: stroke.down, repeat: repeat && stroke.down));
    }
  }

  /// The pane lost the keyboard: let go of anything still held.
  void releaseKeys() {
    final handle = _handle;
    final strokes = keys.releaseAll();
    if (handle == null) return;
    for (final stroke in strokes) {
      unawaited(MacRdpChannel.instance.key(handle.id, stroke.scancode, down: false));
    }
  }

  /// The pane got the keyboard.
  void focused() {
    final handle = _handle;
    if (handle != null && conn.rdpClipboard) unawaited(MacRdpChannel.instance.focus(handle.id));
  }

  /// A pointer event at ([x], [y]) in remote desktop pixels.
  void sendPointer(int flags, int x, int y) {
    final handle = _handle;
    if (handle == null || status != SessionStatus.running) return;
    unawaited(MacRdpChannel.instance.mouse(
      handle.id,
      flags,
      x.clamp(0, remoteWidth > 0 ? remoteWidth - 1 : 0),
      y.clamp(0, remoteHeight > 0 ? remoteHeight - 1 : 0),
    ));
  }

  /// The real keys never reach the session (macOS keeps Ctrl+Option+Delete
  /// to itself only on some keyboards, and there is no Delete on most Macs),
  /// so it is sent from the tab's menu, as on Windows.
  bool get canSendCtrlAltDel => _handle != null && status == SessionStatus.running;

  void sendCtrlAltDelete() {
    final handle = _handle;
    if (handle != null) unawaited(MacRdpChannel.instance.ctrlAltDel(handle.id));
  }

  // ---- launching ----

  Future<void> _start() async {
    if (!launchExternalClients) {
      lastError = 'External RDP clients are not started under test.';
      _setStatus(SessionStatus.error);
      return;
    }
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
    // The password is on the command line, which is as private as the process
    // list: on macOS only root and the owning user can read another process's
    // arguments. That is the same audience as the `.rdp` file the Microsoft
    // path writes, and it buys the user not having to type the password at all.
    _process = await Process.start(binary, freeRdpArguments());
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

  /// What FreeRDP is started with.
  @visibleForTesting
  List<String> freeRdpArguments() => [
      '/v:$host:$_port',
      if (conn.username.isNotEmpty) '/u:${conn.username}',
      if (conn.domain != null && conn.domain!.isNotEmpty) '/d:${conn.domain}',
      if (_password.isNotEmpty) '/p:$_password',
      // Resize the window, and the remote desktop is re-rendered at the new
      // size rather than scaled — the same behaviour the Windows side gets from
      // UpdateSessionDisplaySettings.
      '/dynamic-resolution',
      // These servers usually have a self-signed certificate, so there is no
      // authority to check it against. Trust on first use, like SSH's
      // known_hosts: the first certificate is remembered without a question,
      // and if a later one differs FreeRDP stops and asks, rather than
      // letting anyone in between read the session (which /cert:ignore did).
      '/cert:tofu',
      '+auto-reconnect',
      '+fonts',
      if (conn.rdpClipboard) '+clipboard' else '-clipboard',
      if (conn.rdpWallpaper) '+wallpaper' else '-wallpaper',
      '/audio-mode:0',
      '/t:${conn.name}',
    ];

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
  String _rdpContents() => rdpFileContents(
        host: host,
        port: _port,
        user: _qualifiedUser,
        clipboard: conn.rdpClipboard,
        wallpaper: conn.rdpWallpaper,
      );

  /// The .rdp file is one setting per line, so a line break inside a host or
  /// user name (possible in an imported file) would add settings of its own.
  /// Control characters are removed. The Microsoft client runs in its own
  /// window, so it can warn about a server it cannot verify
  /// (authentication level 2) instead of connecting silently.
  @visibleForTesting
  static String rdpFileContents({
    required String host,
    required int port,
    required String user,
    required bool clipboard,
    required bool wallpaper,
  }) {
    String clean(String v) => v.replaceAll(RegExp(r'[\x00-\x1F\x7F]'), '');
    final safeUser = clean(user);
    final buffer = StringBuffer()
      ..writeln('full address:s:${clean(host)}:$port')
      ..writeln('prompt for credentials:i:0')
      ..writeln('screen mode id:i:1')
      ..writeln('session bpp:i:32')
      ..writeln('audiomode:i:0')
      ..writeln('redirectclipboard:i:${clipboard ? 1 : 0}')
      ..writeln('disable wallpaper:i:${wallpaper ? 0 : 1}')
      ..writeln('authentication level:i:2')
      ..writeln('negotiate security layer:i:1');
    if (safeUser.isNotEmpty) {
      buffer.writeln('username:s:$safeUser');
    }
    return buffer.toString();
  }

  /// Puts the saved password on the clipboard so the Microsoft client's prompt
  /// is one paste. Offered as a button rather than done automatically —
  /// silently replacing whatever the user had copied is not this app's call.
  ///
  /// The password is taken back off the clipboard after
  /// [clipboardClearDelay], if it is still what the clipboard holds: left
  /// there, it would sit in clipboard managers' history and reach the user's
  /// other Apple devices through Universal Clipboard. Anything the user copied
  /// in the meantime is left alone. The timer outlives the tab on purpose, so
  /// closing the tab early does not leave the password behind.
  Future<bool> copyPasswordToClipboard() async {
    final password = _password;
    if (password.isEmpty) return false;
    await Clipboard.setData(ClipboardData(text: password));
    _clipboardTimer?.cancel();
    _clipboardTimer = Timer(clipboardClearDelay, () => unawaited(_clearClipboardIfStill(password)));
    return true;
  }

  static const clipboardClearDelay = Duration(seconds: 30);
  Timer? _clipboardTimer;

  static Future<void> _clearClipboardIfStill(String password) async {
    try {
      final current = await Clipboard.getData(Clipboard.kTextPlain);
      if (current?.text == password) {
        await Clipboard.setData(const ClipboardData(text: ''));
      }
    } catch (_) {
      // Best effort: a clipboard that cannot be read is not cleared blindly.
    }
  }

  /// Re-launches the same session — the tab's only real control, since we do
  /// not own the window the client puts on screen.
  Future<void> relaunch() async {
    if (_disposed) return;
    if (embedded) {
      _dropHandle();
      keys.releaseAll();
      lastError = null;
      final size = _pendingSize ?? (1280, 800);
      _setStatus(SessionStatus.starting);
      await _connectEmbedded(size.$1, size.$2);
      return;
    }
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
    _fallbackStart?.cancel();
    _resizeDebounce?.cancel();
    _dropHandle();
    // Closing the tab closes the session it opened -- leaving an orphaned
    // FreeRDP window behind with no tab to manage it would be worse than
    // ending it.
    try {
      _process?.kill();
    } catch (_) {}
    _process = null;
    _cleanUpScratch();
    _statusController.close();
    super.dispose();
  }
}
