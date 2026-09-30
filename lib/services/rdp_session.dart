import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/models.dart';
import 'session_controller.dart';

/// RDP on Windows, through Microsoft's Remote Desktop ActiveX control
/// (`mstscax.dll`) hosted in a child window of ours — see
/// `windows/runner/rdp_ax_host.cpp` for the native half.
///
/// This replaced an earlier approach that launched `mstsc.exe` and pulled its
/// top-level window into ours with `SetParent`. Everything that path had to
/// work around is simply gone here, because the control is the API Microsoft
/// supports for exactly this:
///
///   * No child process, so no hunting for a window by class name, no window
///     handle dying mid-negotiation, and no window re-asserting itself as
///     top-level behind our back.
///   * The password is a property on the control. The old path had to write it
///     into Windows Credential Manager with `cmdkey` first, where it was
///     readable by anything running as this user until we deleted it again.
///   * No `.rdp` file, so the unsigned-file "Unknown publisher" warning that
///     used to be dismissed by synthesising clicks onto its Connect button
///     never appears.
///   * The remote desktop is renegotiated at the pane's exact pixel size on
///     resize (`UpdateSessionDisplaySettings`), so a resized pane is sharp
///     rather than a stretched copy of the resolution negotiated at connect
///     time. The manual "reconnect to fit" button only survives as a fallback
///     for servers older than 2012 R2, which have no dynamic resolution.
class RdpSessionController implements SessionController {
  RdpSessionController(this.conn) : host = conn.host {
    tabTitle = conn.name;
    // The native window is created on the first layout pass that reports a
    // believable pane size (see [reposition]) so the session is negotiated at
    // the size it will actually be displayed at. This timer only covers the
    // case where no such layout ever arrives, so a tab can't sit on the
    // spinner forever.
    Timer(const Duration(milliseconds: 1200), () {
      if (!_disposed && !_started) _begin(const ui.Rect.fromLTWH(0, 0, 1280, 800), 1.0);
    });
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

  /// What the control said went wrong, in its own words
  /// (`IMsRdpClient.GetErrorDescription`) — far better than anything this app
  /// could infer, and the reason disconnects are reported rather than guessed.
  String? lastError;

  /// Set once the session is live. Null until then.
  bool? _dynamicResolution;

  /// True when the server renegotiates resolution on resize. Where it is
  /// false, resizing scales the existing image and the manual reconnect
  /// control is worth offering.
  bool get supportsDynamicResolution => _dynamicResolution ?? false;

  int? _hostId;
  bool _started = false;
  bool _disposed = false;
  bool _active = true;

  ui.Rect? _lastBounds;
  int? _sessionWidth;
  int? _sessionHeight;
  Timer? _resizeDebounce;

  void _setStatus(SessionStatus s) {
    if (_disposed) return;
    status = s;
    if (!_statusController.isClosed) _statusController.add(s);
  }

  int get _port => conn.port == 22 ? 3389 : conn.port;

  // ---- lifecycle ----

  Future<void> _begin(ui.Rect bounds, double devicePixelRatio) async {
    if (_started || _disposed) return;
    _started = true;
    final physical = _physical(bounds, devicePixelRatio);
    _lastBounds = bounds;
    _sessionWidth = physical.width;
    _sessionHeight = physical.height;
    try {
      final id = await RdpChannel.instance.create(
        x: physical.x,
        y: physical.y,
        width: physical.width,
        height: physical.height,
      );
      if (_disposed) {
        await RdpChannel.instance.destroy(id);
        return;
      }
      _hostId = id;
      RdpChannel.instance.register(id, _onNativeEvent);
      if (!_active) await RdpChannel.instance.setVisible(id, false);
      _dynamicResolution = await RdpChannel.instance.connect(
        id: id,
        host: conn.host,
        port: _port,
        username: conn.username,
        domain: conn.domain ?? '',
        password: conn.rememberPassword ? conn.password : '',
        width: physical.width,
        height: physical.height,
        dpi: (devicePixelRatio * 96).round(),
        clipboard: conn.rdpClipboard,
        wallpaper: conn.rdpWallpaper,
      );
    } on PlatformException catch (e) {
      lastError = e.message ?? e.code;
      _setStatus(SessionStatus.error);
    } catch (e) {
      lastError = e.toString();
      _setStatus(SessionStatus.error);
    }
  }

  void _onNativeEvent(RdpNativeEvent event) {
    if (_disposed) return;
    switch (event.type) {
      case 'connecting':
        _setStatus(SessionStatus.starting);
      case 'connected':
      case 'loggedIn':
      case 'reconnected':
        lastError = null;
        _setStatus(SessionStatus.running);
        // The control is told not to grab focus on connect, so a background
        // tab finishing its handshake can't steal the keyboard from whatever
        // the user is actually looking at. The visible pane does want it.
        if (_active) focus();
      case 'reconnecting':
        // Still the same session; the control is retrying on its own. Report
        // it as starting so the pane shows progress instead of a live-looking
        // black rectangle.
        _setStatus(SessionStatus.starting);
      case 'closed':
        // Ended the way sessions are meant to end: logged off, disconnected
        // from inside the session, or ended by the server. The native side
        // makes that call — the control's reason code can't, since a rejected
        // password reports the same code as a deliberate disconnect.
        lastError = null;
        _hideSurface();
        _setStatus(SessionStatus.closed);
      case 'disconnected':
        lastError = _describe(event);
        _hideSurface();
        _setStatus(SessionStatus.error);
      case 'fatal':
        lastError = event.message.isEmpty
            ? 'The Remote Desktop client hit a fatal error (code ${event.code}).'
            : event.message;
        _hideSurface();
        _setStatus(SessionStatus.error);
      case 'logonError':
        // Negative codes are informational (e.g. -2 "the user was prompted"),
        // which is not a failure — the control is showing its own credential
        // prompt inside the pane and the user can still get in.
        if (event.code >= 0) {
          lastError = 'Logon failed (code ${event.code}).';
          _setStatus(SessionStatus.error);
        }
      case 'sizeChanged':
        _sessionWidth = event.width;
        _sessionHeight = event.height;
    }
  }

  /// A dead session's window still covers the pane with its last frame (or
  /// black), and Flutter cannot draw the explanation on top of a native child
  /// window — so the window goes away and the pane says what happened.
  void _hideSurface() {
    final id = _hostId;
    if (id != null) RdpChannel.instance.setVisible(id, false);
  }

  /// The control's own wording, plus the one case where its wording is useless.
  /// A rejected password comes back as "An internal error has occurred." with
  /// no extended reason — confirmed against a real server — which tells the
  /// user nothing, so the likely cause is named instead.
  String _describe(RdpNativeEvent event) {
    final text = event.message.trim();
    final unhelpful = text.isEmpty ||
        text.toLowerCase().startsWith('an internal error');
    if (unhelpful && event.extendedCode == 0) {
      return 'Could not sign in to $host. The username, password or domain may '
          'be wrong, or the server may not allow this account to connect '
          'remotely.';
    }
    if (text.isEmpty) {
      return 'Disconnected (code ${event.code}/${event.extendedCode}).';
    }
    return text;
  }

  // ---- geometry ----

  ({int x, int y, int width, int height}) _physical(ui.Rect rect, double dpr) => (
        x: (rect.left * dpr).round(),
        y: (rect.top * dpr).round(),
        width: (rect.width * dpr).round(),
        height: (rect.height * dpr).round(),
      );

  /// Called by the view after layout and on a light timer with the pane's
  /// on-screen rectangle in logical pixels, relative to our window's client
  /// area (which is also Flutter's global coordinate space, since Flutter
  /// knows nothing about OS chrome).
  void reposition(ui.Rect bounds, double devicePixelRatio) {
    if (_disposed) return;
    if (!_started) {
      // A pane briefly reports a tiny or zero size mid-layout (a split being
      // created, a new tab's entrance transition). Negotiating against one of
      // those locks the session to a size it will never actually be displayed
      // at, so wait for something believable.
      if (bounds.width * devicePixelRatio >= 200 &&
          bounds.height * devicePixelRatio >= 150) {
        _begin(bounds, devicePixelRatio);
      }
      return;
    }
    final id = _hostId;
    if (id == null) return;
    if (bounds == _lastBounds) return;
    final previous = _lastBounds;
    _lastBounds = bounds;
    final physical = _physical(bounds, devicePixelRatio);
    RdpChannel.instance.setBounds(
      id: id,
      x: physical.x,
      y: physical.y,
      width: physical.width,
      height: physical.height,
    );
    // Only a size change needs the remote desktop renegotiated; a pane that
    // merely moved (the other half of a split being resized, the sidebar
    // collapsing) keeps the resolution it has.
    final sizeChanged = previous == null ||
        previous.width != bounds.width ||
        previous.height != bounds.height;
    if (!sizeChanged) return;
    // Renegotiating on every frame of a drag would ask the server for a new
    // desktop size dozens of times per second; settle first.
    _resizeDebounce?.cancel();
    _resizeDebounce = Timer(const Duration(milliseconds: 350), () {
      _applySessionSize(physical.width, physical.height, devicePixelRatio);
    });
  }

  Future<void> _applySessionSize(int width, int height, double dpr) async {
    final id = _hostId;
    if (id == null || _disposed) return;
    if (width < 200 || height < 200) return;
    if (width == _sessionWidth && height == _sessionHeight) return;
    final ok = await RdpChannel.instance.resizeSession(
      id: id,
      width: width,
      height: height,
      dpi: (dpr * 96).round(),
    );
    if (ok) {
      _sessionWidth = width;
      _sessionHeight = height;
    } else {
      // Either the control predates RDP 8.1 or the server refused the new
      // size. Leave the image scaled rather than reconnecting behind the
      // user's back; [reconnectAtCurrentSize] is the deliberate way out.
      _dynamicResolution = false;
    }
  }

  // ---- tab state ----

  void setActive(bool active) {
    if (_active == active) return;
    _active = active;
    final id = _hostId;
    if (id == null) return;
    // A session that has already failed or ended had its window hidden so the
    // pane could explain why; coming back to that tab must not put the dead
    // window back over the explanation.
    final dead = status == SessionStatus.error || status == SessionStatus.closed;
    RdpChannel.instance.setVisible(id, active && !dead);
    if (active && !dead) RdpChannel.instance.focus(id);
  }

  void focus() {
    final id = _hostId;
    if (id != null && _active) RdpChannel.instance.focus(id);
  }

  /// Windows swallows the real Ctrl+Alt+Del before any app sees it, so a
  /// windowed session can only get one by asking the control to inject it.
  void sendCtrlAltDelete() {
    final id = _hostId;
    if (id != null) RdpChannel.instance.sendCtrlAltDel(id);
  }

  /// Tears the session down and negotiates a fresh one at the pane's current
  /// size. Needed only where dynamic resolution isn't available (see
  /// [supportsDynamicResolution]) or to retry after a failure.
  ///
  /// [bounds] is read by the caller at the moment of the button press, before
  /// anything here tears the old session down — the status change back to
  /// `starting` rebuilds the widget tree, so a size read taken afterwards
  /// races that rebuild and can land on a stale or default-sized pane.
  Future<void> reconnect(ui.Rect? bounds, double devicePixelRatio) async {
    if (_disposed) return;
    final id = _hostId;
    _hostId = null;
    _started = false;
    _sessionWidth = null;
    _sessionHeight = null;
    _lastBounds = null;
    lastError = null;
    _dynamicResolution = null;
    _resizeDebounce?.cancel();
    _setStatus(SessionStatus.starting);
    if (id != null) {
      RdpChannel.instance.unregister(id);
      await RdpChannel.instance.destroy(id);
    }
    if (bounds != null &&
        bounds.width * devicePixelRatio >= 200 &&
        bounds.height * devicePixelRatio >= 150) {
      await _begin(bounds, devicePixelRatio);
    }
    // Otherwise the next reposition() supplies the size, same as first connect.
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _resizeDebounce?.cancel();
    final id = _hostId;
    _hostId = null;
    if (id != null) {
      RdpChannel.instance.unregister(id);
      RdpChannel.instance.destroy(id);
    }
    _statusController.close();
  }
}

/// One event from the native host.
class RdpNativeEvent {
  const RdpNativeEvent({
    required this.type,
    required this.message,
    required this.code,
    required this.extendedCode,
    required this.width,
    required this.height,
  });

  final String type;
  final String message;
  final int code;
  final int extendedCode;
  final int width;
  final int height;
}

/// The single method channel onto `windows/runner/rdp_plugin.cpp`, fanning
/// native events back out to whichever session they belong to. Sessions are
/// identified by the integer id the native side mints per host window, so
/// several RDP tabs (including tiled ones) stay independent.
class RdpChannel {
  RdpChannel._() {
    _channel.setMethodCallHandler(_onCall);
  }

  static final RdpChannel instance = RdpChannel._();

  final _channel = const MethodChannel('commands/rdp');
  final _listeners = <int, void Function(RdpNativeEvent)>{};

  void register(int id, void Function(RdpNativeEvent) listener) {
    _listeners[id] = listener;
  }

  void unregister(int id) => _listeners.remove(id);

  Future<dynamic> _onCall(MethodCall call) async {
    if (call.method != 'event') return null;
    final args = (call.arguments as Map).cast<String, Object?>();
    final id = args['id'] as int? ?? -1;
    final listener = _listeners[id];
    if (listener == null) return null;
    listener(RdpNativeEvent(
      type: args['type'] as String? ?? '',
      message: args['message'] as String? ?? '',
      code: args['code'] as int? ?? 0,
      extendedCode: args['extendedCode'] as int? ?? 0,
      width: args['width'] as int? ?? 0,
      height: args['height'] as int? ?? 0,
    ));
    return null;
  }

  Future<int> create({
    required int x,
    required int y,
    required int width,
    required int height,
  }) async {
    final id = await _channel.invokeMethod<int>('create', {
      'x': x,
      'y': y,
      'width': width,
      'height': height,
    });
    if (id == null) throw PlatformException(code: 'rdp_create_failed');
    return id;
  }

  Future<bool> connect({
    required int id,
    required String host,
    required int port,
    required String username,
    required String domain,
    required String password,
    required int width,
    required int height,
    required int dpi,
    required bool clipboard,
    required bool wallpaper,
  }) async {
    final dynamicResolution = await _channel.invokeMethod<bool>('connect', {
      'id': id,
      'host': host,
      'port': port,
      'username': username,
      'domain': domain,
      'password': password,
      'width': width,
      'height': height,
      'dpi': dpi,
      'clipboard': clipboard,
      'wallpaper': wallpaper,
    });
    return dynamicResolution ?? false;
  }

  Future<void> setBounds({
    required int id,
    required int x,
    required int y,
    required int width,
    required int height,
  }) =>
      _channel.invokeMethod<void>('setBounds', {
        'id': id,
        'x': x,
        'y': y,
        'width': width,
        'height': height,
      });

  Future<bool> resizeSession({
    required int id,
    required int width,
    required int height,
    required int dpi,
  }) async {
    final ok = await _channel.invokeMethod<bool>('resizeSession', {
      'id': id,
      'width': width,
      'height': height,
      'dpi': dpi,
    });
    return ok ?? false;
  }

  Future<void> setVisible(int id, bool visible) =>
      _channel.invokeMethod<void>('setVisible', {'id': id, 'visible': visible});

  Future<void> focus(int id) => _channel.invokeMethod<void>('focus', {'id': id});

  Future<void> sendCtrlAltDel(int id) =>
      _channel.invokeMethod<void>('sendCtrlAltDel', {'id': id});

  Future<void> disconnect(int id) =>
      _channel.invokeMethod<void>('disconnect', {'id': id});

  Future<void> destroy(int id) =>
      _channel.invokeMethod<void>('destroy', {'id': id});

  /// Hides every live session while the app has a dialog open, and brings them
  /// back when it closes. See [RdpModalObserver].
  Future<void> setSuspended(bool suspended) =>
      _channel.invokeMethod<void>('setSuspended', {'suspended': suspended});
}

/// Hides embedded RDP sessions for as long as a dialog, menu or other pushed
/// route is on screen.
///
/// A session is a top-level window owned by the app window, so the compositor
/// always draws it above the app — which is exactly what makes it stay visible
/// while Flutter repaints, and exactly what would put it in front of a modal
/// dialog that is meant to be in front of everything. Since the dialog is the
/// thing the user is currently interacting with, the session gives way.
///
/// Only on Windows; nothing else has an embedded session to hide.
class RdpModalObserver extends NavigatorObserver {
  int _depth = 0;

  void _apply(int delta) {
    if (!Platform.isWindows) return;
    final wasOpen = _depth > 0;
    _depth = (_depth + delta).clamp(0, 1 << 20);
    final isOpen = _depth > 0;
    if (wasOpen != isOpen) RdpChannel.instance.setSuspended(isOpen);
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    // The app's own home route is pushed at startup with nothing beneath it;
    // it is the page, not something covering it.
    if (previousRoute != null) _apply(1);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (previousRoute != null) _apply(-1);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (previousRoute != null) _apply(-1);
  }
}
