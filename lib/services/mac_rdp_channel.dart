import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart';

/// What the native macOS RDP engine reports about one session.
class MacRdpEvent {
  const MacRdpEvent(this.type, {this.width = 0, this.height = 0, this.message = '', this.authFailed = false});

  /// `connected`, `size`, `closed` or `error`.
  final String type;
  final int width;
  final int height;
  final String message;

  /// The server refused the user name or password: worth asking again.
  final bool authFailed;

  factory MacRdpEvent.fromMap(Map<Object?, Object?> m) => MacRdpEvent(
        m['type'] as String? ?? '',
        width: (m['width'] as num?)?.toInt() ?? 0,
        height: (m['height'] as num?)?.toInt() ?? 0,
        message: m['message'] as String? ?? '',
        authFailed: m['authFailed'] as bool? ?? false,
      );
}

/// The session the native side created: its id, and the Flutter texture the
/// remote desktop is drawn into.
class MacRdpHandle {
  const MacRdpHandle({required this.id, required this.textureId, required this.isoKeyboard});
  final int id;
  final int textureId;

  /// The Mac's keyboard is an ISO one (see [rdpScancodeForHid]).
  final bool isoKeyboard;
}

/// Talks to `packages/commands_rdp_mac`: FreeRDP linked into the app, so a
/// session is drawn inside its tab the way the ActiveX control is on Windows.
class MacRdpChannel {
  MacRdpChannel._() {
    _channel.setMethodCallHandler(_onCall);
  }

  static MacRdpChannel instance = MacRdpChannel._();

  /// A fresh instance for a test, with a mock handler on [channelName].
  @visibleForTesting
  static void resetForTest() => instance = MacRdpChannel._();

  static const channelName = 'commands/rdp_mac';
  static const _channel = MethodChannel(channelName);

  final Map<int, void Function(MacRdpEvent)> _listeners = {};
  bool? _available;

  Future<dynamic> _onCall(MethodCall call) async {
    if (call.method != 'event') return null;
    final args = (call.arguments as Map).cast<Object?, Object?>();
    final id = (args['id'] as num?)?.toInt();
    if (id == null) return null;
    _listeners[id]?.call(MacRdpEvent.fromMap(args));
    return null;
  }

  /// True when this build has the engine (a macOS build with the plugin). A
  /// build without it falls back to an external client.
  Future<bool> available() async {
    final known = _available;
    if (known != null) return known;
    try {
      _available = await _channel.invokeMethod<bool>('available') ?? false;
    } on MissingPluginException {
      _available = false;
    } on PlatformException {
      _available = false;
    }
    return _available!;
  }

  Future<MacRdpHandle> connect({
    required String host,
    required int port,
    required String username,
    required String domain,
    required String password,
    required int width,
    required int height,
    required bool clipboard,
    required bool wallpaper,
    required void Function(MacRdpEvent) onEvent,
  }) async {
    final result = await _channel.invokeMapMethod<String, Object?>('connect', {
      'host': host,
      'port': port,
      'username': username,
      'domain': domain,
      'password': password,
      'width': width,
      'height': height,
      'clipboard': clipboard,
      'wallpaper': wallpaper,
    });
    if (result == null) throw PlatformException(code: 'connect', message: 'No session was created.');
    final handle = MacRdpHandle(
      id: (result['id'] as num).toInt(),
      textureId: (result['textureId'] as num).toInt(),
      isoKeyboard: result['isoKeyboard'] as bool? ?? false,
    );
    _listeners[handle.id] = onEvent;
    return handle;
  }

  Future<void> key(int id, int scancode, {required bool down, bool repeat = false}) =>
      _channel.invokeMethod('key', {'id': id, 'scancode': scancode, 'down': down, 'repeat': repeat});

  Future<void> mouse(int id, int flags, int x, int y) =>
      _channel.invokeMethod('mouse', {'id': id, 'flags': flags, 'x': x, 'y': y});

  Future<void> resize(int id, int width, int height) =>
      _channel.invokeMethod('resize', {'id': id, 'width': width, 'height': height});

  Future<void> ctrlAltDel(int id) => _channel.invokeMethod('ctrlAltDel', {'id': id});

  /// The tab got the keyboard: offers the Mac clipboard to the server if it
  /// changed since.
  Future<void> focus(int id) => _channel.invokeMethod('focus', {'id': id});

  Future<void> close(int id) async {
    _listeners.remove(id);
    try {
      await _channel.invokeMethod('close', {'id': id});
    } catch (_) {
      // The session is going away either way.
    }
  }
}
