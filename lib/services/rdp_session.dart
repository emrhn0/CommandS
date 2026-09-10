import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';
import '../models/models.dart';
import 'session_controller.dart';

const int _bmClick = 0x00F5;
const int _bmGetCheck = 0x00F0;
const int _swpFrameChanged = 0x0020;
const int _rdwInvalidate = 0x0001;
const int _rdwUpdateNow = 0x0100;
const int _rdwAllChildren = 0x0080;

/// RDP has no pure-Dart client worth embedding, so we drive the OS's own
/// one (`mstsc.exe`) and pull its window into ours instead of leaving it as
/// a separate floating window. mstsc is launched pointed at a generated
/// `.rdp` file (clipboard/wallpaper and friends come from there), then once
/// its session window shows up — confirmed via live inspection to be class
/// `TscShellContainerClass`, a *separate* top-level window from the
/// "popup parent" frame that only ever hosts the security warning — we
/// strip its caption/border, `SetParent` it under CommandS's own window,
/// and keep it glued to wherever the tab's placeholder widget sits (see
/// [RdpEmbedView]). The "Unknown publisher" warning lives in its own
/// dialog the whole time, so a scan for its "Connect" button runs on every
/// tick regardless of embed state — clicking it the instant it exists.
///
/// The credential prompt is worked around separately, by pre-seeding
/// Windows Credential Manager with `cmdkey` (removed again once connected)
/// so mstsc never has to ask in the first place.
class RdpSessionController implements SessionController {
  RdpSessionController(this.conn) : host = conn.host {
    tabTitle = conn.name;
    // mstsc is *not* launched here. RDM's own behavior (confirmed against
    // it directly) is to size the connection to whatever its window
    // happens to be at the moment you open it and leave it there --
    // matching that beats guessing at a fixed/generic resolution up front:
    // [RdpEmbedView]'s first `reposition()` call, within a frame or two of
    // this controller existing, hands over the pane's *real* on-screen
    // size, which is used to launch mstsc negotiating exactly that
    // resolution -- filling the pane from the very first frame instead of
    // negotiating some other size and stretching/shrinking into place.
    // A short fallback timer covers the case where that callback never
    // arrives for some reason (no layout ever happens) so this can't hang
    // on the "starting" spinner forever.
    Timer(const Duration(milliseconds: 800), () {
      if (!_disposed && !_started) _beginWith(1280, 800);
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

  String? lastError;

  Process? _process;
  bool _started = false;
  int _lockedWidth = 0;
  int _lockedHeight = 0;
  int _childHwnd = 0;
  int _ourHwnd = 0;
  int? _lastLeft;
  int? _lastTop;
  Directory? _scratchDir;
  Timer? _pollTimer;
  bool _disposed = false;
  bool _credentialSeeded = false;
  String get _credentialTarget => 'TERMSRV/${conn.host}';

  void _setStatus(SessionStatus s) {
    status = s;
    if (!_statusController.isClosed) _statusController.add(s);
  }

  /// Called once, by whichever fires first: [reposition]'s first real call
  /// with the pane's on-screen size, or the constructor's fallback timer.
  /// Further calls are no-ops.
  void _beginWith(int desktopWidth, int desktopHeight) {
    if (_started) return;
    _started = true;
    _lockedWidth = desktopWidth;
    _lockedHeight = desktopHeight;
    unawaited(_start(desktopWidth, desktopHeight));
  }

  Future<void> _start(int desktopWidth, int desktopHeight) async {
    try {
      if (conn.password.isNotEmpty) {
        await _seedCredential();
      }

      _scratchDir = await Directory.systemTemp.createTemp('commands_rdp_');
      final rdpFile = File('${_scratchDir!.path}\\session.rdp');
      final buffer = StringBuffer()
        ..writeln('full address:s:${conn.host}:${conn.port == 22 ? 3389 : conn.port}')
        ..writeln('username:s:${conn.username}')
        ..writeln('screen mode id:i:1')
        ..writeln('use multimon:i:0')
        ..writeln('session bpp:i:32')
        // "dynamic resolution" (having the *server* re-render at a new
        // resolution on every resize, which is what plain mstsc looks so
        // sharp doing) was tried here and reverted -- confirmed live it
        // makes mstsc actively fight embedding: something in its own
        // resolution-negotiation path resets the window's position/size on
        // its own terms, undoing every SetWindowPos call this app makes to
        // keep it glued to the pane (window ended up off-screen entirely).
        //
        // Confirmed live against RDM directly instead: it sizes a
        // connection to whatever its own window happens to be *at the
        // moment you open it* and doesn't try to live-track further resizes
        // after that (you have to reopen the connection to pick up a new
        // size) -- matching that here beats guessing a generic resolution,
        // since the negotiated size now genuinely matches the pane instead
        // of needing "smart sizing" to stretch/shrink a mismatched image
        // into place (soft/blurry, and letterboxed if the aspect ratio
        // didn't match either). "smart sizing" stays on purely as a safety
        // net for whatever this size guess is off by, and for later window
        // resizes this app does still keep glued to the pane's bounds.
        ..writeln('desktopwidth:i:$desktopWidth')
        ..writeln('desktopheight:i:$desktopHeight')
        ..writeln('smart sizing:i:1')
        ..writeln('authentication level:i:0')
        ..writeln('redirectclipboard:i:${conn.rdpClipboard ? 1 : 0}')
        ..writeln('disable wallpaper:i:${conn.rdpWallpaper ? 0 : 1}')
        ..writeln('disable full window drag:i:1')
        ..writeln('allow font smoothing:i:1')
        ..writeln('prompt for credentials:i:0')
        ..writeln('enablecredsspsupport:i:1');
      if (conn.domain != null && conn.domain!.isNotEmpty) {
        buffer.writeln('domain:s:${conn.domain}');
      }
      await rdpFile.writeAsString(buffer.toString());

      _process = await Process.start('mstsc.exe', [rdpFile.path]);
      unawaited(_process!.exitCode.then((_) {
        if (!_disposed) {
          _setStatus(SessionStatus.closed);
        }
      }));

      var tick = 0;
      _pollTimer = Timer.periodic(const Duration(milliseconds: 200), (t) {
        if (_disposed) {
          t.cancel();
          return;
        }
        tick++;
        if (tick <= 15) _debugLogWindows(tick);

        if (_childHwnd == 0) {
          _findAndEmbed(tick);
        } else {
          _ensureStillParented();
        }
        // The "Unknown publisher" warning is a window *owned* by the main
        // frame, not a child of it -- EnumChildWindows never walks into
        // owned-but-not-child windows, so it has to be found separately at
        // the top level (confirmed via live logging: main frame class
        // TSC_POPUP_PARENT_WNDCLASS, warning class #32770, owner = main
        // frame's hwnd) before its Connect button can be reached at all.
        _handleSecurityDialog();
        if (_childHwnd != 0 && status != SessionStatus.running) {
          _setStatus(SessionStatus.running);
          unawaited(_clearCredential());
        }
      });

      // mstsc sometimes never shows a window (bad host, immediate failure) —
      // give up cleanly instead of polling forever.
      Timer(const Duration(seconds: 20), () {
        if (!_disposed && _childHwnd == 0) {
          _pollTimer?.cancel();
          lastError = 'Remote Desktop window never appeared.';
          _setStatus(SessionStatus.error);
        }
      });
    } catch (e) {
      lastError = e.toString();
      _setStatus(SessionStatus.error);
    }
  }

  /// Pre-loads the credential mstsc will look for on its own, so it never
  /// has to ask. Windows Credential Manager entries are global to the user
  /// account, so this is removed again as soon as we're connected (or the
  /// attempt fails) rather than left behind.
  Future<void> _seedCredential() async {
    try {
      final result = await Process.run('cmdkey', [
        '/generic:$_credentialTarget',
        '/user:${conn.username}',
        '/pass:${conn.password}',
      ]);
      _credentialSeeded = result.exitCode == 0;
    } catch (_) {
      _credentialSeeded = false;
    }
  }

  Future<void> _clearCredential() async {
    if (!_credentialSeeded) return;
    _credentialSeeded = false;
    try {
      await Process.run('cmdkey', ['/delete:$_credentialTarget']);
    } catch (_) {}
  }

  // TEMP diagnostic — pulled once embedding is confirmed solid across
  // enough real hosts.
  void _debugLog(String line) {
    try {
      File('${Directory.systemTemp.path}\\commands_rdp_debug.log')
          .writeAsStringSync('$line\n', mode: FileMode.append);
    } catch (_) {}
  }

  void _debugLogWindows(int tick) {
    final pid = _process?.pid;
    if (pid == null) return;
    final lines = <String>[];
    final cb = NativeCallable<BOOL Function(IntPtr, IntPtr)>.isolateLocal(
      (int hwnd, int lParam) {
        final winPid = calloc<Uint32>();
        try {
          GetWindowThreadProcessId(hwnd, winPid);
          if (winPid.value != pid) return 1;
          final classBuf = wsalloc(256);
          final len = GetWindowTextLength(hwnd);
          final textBuf = wsalloc(len + 1);
          try {
            GetClassName(hwnd, classBuf, 256);
            GetWindowText(hwnd, textBuf, len + 1);
            final owner = GetWindow(hwnd, GW_OWNER);
            final vis = IsWindowVisible(hwnd);
            lines.add(
              '  hwnd=$hwnd class=${classBuf.toDartString()} title="${textBuf.toDartString()}" visible=$vis owner=$owner',
            );
          } finally {
            free(classBuf);
            free(textBuf);
          }
        } finally {
          calloc.free(winPid);
        }
        return 1;
      },
      exceptionalReturn: 1,
    );
    try {
      EnumWindows(cb.nativeFunction, 0);
    } finally {
      cb.close();
    }
    try {
      File('${Directory.systemTemp.path}\\commands_rdp_debug.log').writeAsStringSync(
        'tick $tick pid=$pid embedded=$_childHwnd:\n${lines.isEmpty ? '  (no windows for this pid)' : lines.join('\n')}\n',
        mode: FileMode.append,
      );
    } catch (_) {}
  }

  /// mstsc's actual session surface -- confirmed via live inspection to be a
  /// *separate* top-level window from the "popup parent" frame that only
  /// hosts the security warning first. Embedding the popup-parent window (as
  /// an earlier version of this code did) reparents an empty placeholder:
  /// the real remote-desktop content renders into `TscShellContainerClass`
  /// instead and was left behind as its own floating, native-chrome window.
  /// It starts invisible and only appears once the session actually starts
  /// rendering, so this is naturally re-checked every tick until it shows up.
  static const _mstscMainClass = 'TscShellContainerClass';

  /// Older mstsc builds render the live session directly into the
  /// popup-parent frame instead of a separate container window. It's
  /// visible several ticks before [_mstscMainClass] ever shows up (it hosts
  /// the security warning first), so it's only accepted as a fallback once
  /// [_legacyFallbackAfterTicks] ticks have passed without the real
  /// container window appearing -- otherwise it gets grabbed first and,
  /// since embedding only runs while unset, locks onto the empty frame.
  static const _mstscLegacyClass = 'TSC_POPUP_PARENT_WNDCLASS';
  static const _legacyFallbackAfterTicks = 25; // ~5s at the 200ms poll interval

  /// Looks for mstsc's session window (see [_mstscMainClass] /
  /// [_mstscLegacyClass]) owned by our child process and, if found,
  /// reparents it under CommandS's own window as a borderless child.
  void _findAndEmbed(int tick) {
    final pid = _process?.pid;
    if (pid == null) return;

    int foundHwnd = 0;
    int legacyHwnd = 0;
    final callback = NativeCallable<BOOL Function(IntPtr, IntPtr)>.isolateLocal(
      (int hwnd, int lParam) {
        final winPid = calloc<Uint32>();
        try {
          GetWindowThreadProcessId(hwnd, winPid);
          if (winPid.value != pid || IsWindowVisible(hwnd) == 0) return 1;
          final classBuf = wsalloc(256);
          try {
            GetClassName(hwnd, classBuf, 256);
            final cls = classBuf.toDartString();
            if (cls == _mstscMainClass) {
              foundHwnd = hwnd;
              return 0;
            }
            if (cls == _mstscLegacyClass) {
              legacyHwnd = hwnd;
            }
          } finally {
            free(classBuf);
          }
        } finally {
          calloc.free(winPid);
        }
        return 1;
      },
      exceptionalReturn: 1,
    );

    try {
      EnumWindows(callback.nativeFunction, 0);
    } finally {
      callback.close();
    }

    if (foundHwnd == 0 && tick >= _legacyFallbackAfterTicks) foundHwnd = legacyHwnd;
    if (foundHwnd == 0) return;

    final ourHwnd = _findOwnWindow();
    _debugLog('_findAndEmbed: mstscHwnd=$foundHwnd ourHwnd=$ourHwnd');
    if (ourHwnd == 0) return;

    // Strip title bar/border, then move under our window. SWP_FRAMECHANGED
    // is required after SetWindowLongPtr -- without it Windows keeps
    // painting the old (captioned) frame even though the style bits changed.
    final style = GetWindowLongPtr(foundHwnd, GWL_STYLE);
    final newStyle = (style & ~WS_POPUP & ~WS_CAPTION & ~WS_THICKFRAME) | WS_CHILD;
    SetWindowLongPtr(foundHwnd, GWL_STYLE, newStyle);
    final prevParent = SetParent(foundHwnd, ourHwnd);
    SetWindowPos(foundHwnd, 0, 0, 0, 0, 0, SWP_NOZORDER | SWP_NOMOVE | SWP_NOSIZE | _swpFrameChanged);
    ShowWindow(foundHwnd, SW_SHOW);
    _debugLog('_findAndEmbed: SetParent prevParent=$prevParent lastError=${GetLastError()}');

    _childHwnd = foundHwnd;
    _ourHwnd = ourHwnd;
  }

  /// Something about mstsc's own window -- confirmed live: it reasserts
  /// itself as a top-level window (`GetParent` back to the desktop) some
  /// seconds after a successful `SetParent`, even though nothing in this
  /// class ever calls SetParent again -- undoes the embed with no visible
  /// symptom in this app (the borderless-child style survives, so it still
  /// happens to sit in the right screen position, just no longer actually
  /// parented). Checked every tick and silently re-applied if it drifted,
  /// the same way [reposition] re-asserts `SW_SHOW` every frame regardless
  /// of whether anything actually hid it.
  void _ensureStillParented() {
    if (_childHwnd == 0 || _ourHwnd == 0) return;
    if (GetParent(_childHwnd) == _ourHwnd) return;
    final style = GetWindowLongPtr(_childHwnd, GWL_STYLE);
    final newStyle = (style & ~WS_POPUP & ~WS_CAPTION & ~WS_THICKFRAME) | WS_CHILD;
    SetWindowLongPtr(_childHwnd, GWL_STYLE, newStyle);
    SetParent(_childHwnd, _ourHwnd);
    SetWindowPos(_childHwnd, 0, 0, 0, 0, 0, SWP_NOZORDER | SWP_NOMOVE | SWP_NOSIZE | _swpFrameChanged);
    ShowWindow(_childHwnd, SW_SHOW);
    _debugLog('_ensureStillParented: re-parented $_childHwnd under $_ourHwnd');
  }

  /// CommandS's own top-level window, found by *our* process id rather than
  /// `FindWindow(className, null)` -- that call matches the first window of
  /// that class *anywhere on the system*, and every default Flutter Windows
  /// app is built with the exact same class name
  /// ("FLUTTER_RUNNER_WIN32_WINDOW"). With any other Flutter app running
  /// (including an older/second CommandS instance) it could silently grab
  /// the wrong one and reparent mstsc under a window that isn't even
  /// visible, which looks identical to embedding never having happened.
  int _findOwnWindow() {
    final ownPid = GetCurrentProcessId();
    int hwnd = 0;
    final cb = NativeCallable<BOOL Function(IntPtr, IntPtr)>.isolateLocal(
      (int h, int lParam) {
        final winPid = calloc<Uint32>();
        try {
          GetWindowThreadProcessId(h, winPid);
          if (winPid.value != ownPid || IsWindowVisible(h) == 0) return 1;
          final classBuf = wsalloc(256);
          try {
            GetClassName(h, classBuf, 256);
            if (classBuf.toDartString() == 'FLUTTER_RUNNER_WIN32_WINDOW') {
              hwnd = h;
              return 0;
            }
          } finally {
            free(classBuf);
          }
        } finally {
          calloc.free(winPid);
        }
        return 1;
      },
      exceptionalReturn: 1,
    );
    try {
      EnumWindows(cb.nativeFunction, 0);
    } finally {
      cb.close();
    }
    return hwnd;
  }

  static const _warningDialogClass = '#32770';

  /// Finds the unsigned-.rdp "Unknown publisher" warning -- a *top-level*
  /// window owned by mstsc's main frame, not a child of it, confirmed live
  /// (class `#32770`, `owner` = the main frame's hwnd) -- and, if present,
  /// ticks the "Clipboard" checkbox this session actually asked for (those
  /// resource checkboxes are a second consent gate on top of whatever the
  /// .rdp file already requests; leaving one unchecked here silently
  /// overrides the matching `redirect*:i:1` line) before clicking Connect.
  /// A no-op once the warning is gone, so it is safe to call every tick.
  void _handleSecurityDialog() {
    final pid = _process?.pid;
    if (pid == null) return;

    int dialogHwnd = 0;
    final enumTop = NativeCallable<BOOL Function(IntPtr, IntPtr)>.isolateLocal(
      (int hwnd, int lParam) {
        final winPid = calloc<Uint32>();
        try {
          GetWindowThreadProcessId(hwnd, winPid);
          if (winPid.value != pid || IsWindowVisible(hwnd) == 0) return 1;
          final classBuf = wsalloc(256);
          try {
            GetClassName(hwnd, classBuf, 256);
            if (classBuf.toDartString() == _warningDialogClass) {
              dialogHwnd = hwnd;
              return 0;
            }
          } finally {
            free(classBuf);
          }
        } finally {
          calloc.free(winPid);
        }
        return 1;
      },
      exceptionalReturn: 1,
    );
    try {
      EnumWindows(enumTop.nativeFunction, 0);
    } finally {
      enumTop.close();
    }
    if (dialogHwnd == 0) return;

    int connectHwnd = 0;
    int clipboardHwnd = 0;
    final enumChild = NativeCallable<BOOL Function(IntPtr, IntPtr)>.isolateLocal(
      (int hwnd, int lParam) {
        final classBuf = wsalloc(256);
        try {
          GetClassName(hwnd, classBuf, 256);
          if (classBuf.toDartString() == 'Button') {
            final len = GetWindowTextLength(hwnd);
            final textBuf = wsalloc(len + 1);
            try {
              GetWindowText(hwnd, textBuf, len + 1);
              final text = textBuf.toDartString().replaceAll('&', '').toLowerCase();
              if (text.contains('connect')) connectHwnd = hwnd;
              if (text.contains('clipboard')) clipboardHwnd = hwnd;
            } finally {
              free(textBuf);
            }
          }
        } finally {
          free(classBuf);
        }
        return 1;
      },
      exceptionalReturn: 1,
    );
    try {
      EnumChildWindows(dialogHwnd, enumChild.nativeFunction, 0);
    } finally {
      enumChild.close();
    }

    if (conn.rdpClipboard && clipboardHwnd != 0) {
      final checked = SendMessage(clipboardHwnd, _bmGetCheck, 0, 0);
      if (checked == 0) SendMessage(clipboardHwnd, _bmClick, 0, 0);
    }
    if (connectHwnd != 0) {
      SendMessage(connectHwnd, _bmClick, 0, 0);
    }
  }

  /// Called by [RdpEmbedView] after every layout pass with the placeholder's
  /// on-screen rectangle, in logical pixels relative to our window's client
  /// area (i.e. Flutter's own global coordinate space — which already *is*
  /// client-area-relative, since Flutter doesn't know about OS chrome).
  void reposition(ui.Rect logicalRect, double devicePixelRatio) {
    if (!_started) {
      final w = (logicalRect.width * devicePixelRatio).round();
      final h = (logicalRect.height * devicePixelRatio).round();
      // A pane can briefly report a zero/tiny size mid-layout (e.g. right
      // as a split is created) -- not a real size worth locking in as the
      // negotiated resolution, so wait for an actual one instead.
      if (w >= 200 && h >= 150) _beginWith(w, h);
      return;
    }
    if (_childHwnd == 0) return;
    // Width/height are deliberately *not* taken from the live rect here --
    // confirmed live against RDM that it doesn't resize an active
    // connection's content to follow the window growing either (you have
    // to reopen the connection to pick up a new size), and doing it here
    // means stretching the fixed resolution mstsc actually negotiated
    // (locked in once, in [_beginWith]) via "smart sizing" -- which was
    // exactly the blur this app had after maximizing before this. So only
    // the top-left corner tracks the pane; the negotiated size stays put,
    // same trade-off RDM itself makes.
    final left = (logicalRect.left * devicePixelRatio).round();
    final top = (logicalRect.top * devicePixelRatio).round();
    // Position tracking is polled on a timer (see RdpEmbedView) rather than
    // driven purely by layout events, so this runs constantly whether or
    // not the pane actually moved. Forcing SetWindowPos + a synchronous
    // RedrawWindow every single tick regardless was repainting the live
    // RDP surface 5x/second for no reason -- visible as a constant flicker.
    // Skipping the no-op case fixes that outright, and self-healing (the
    // actual point of polling instead of only reacting to events) still
    // works exactly the same on the ticks where something did move.
    if (left == _lastLeft && top == _lastTop) return;
    _lastLeft = left;
    _lastTop = top;
    // SWP_SHOWWINDOW here too: something along the embed/rebuild path was
    // leaving the reparented window's visible bit cleared even after the
    // explicit ShowWindow(SW_SHOW) right after SetParent -- moving it is
    // frequent enough (every layout pass) that just re-asserting visibility
    // every time is a cheap, self-healing fix regardless of the exact cause.
    SetWindowPos(
      _childHwnd,
      0,
      left,
      top,
      _lockedWidth,
      _lockedHeight,
      SWP_NOZORDER | SWP_SHOWWINDOW,
    );
    // Belt-and-braces: force mstsc's RDP surface to actually repaint itself
    // into the new position/parent rather than trusting it noticed on its
    // own from the resize alone.
    RedrawWindow(_childHwnd, nullptr, 0, _rdwInvalidate | _rdwUpdateNow | _rdwAllChildren);
  }

  void hide() {
    if (_childHwnd != 0) ShowWindow(_childHwnd, SW_HIDE);
  }

  void show() {
    if (_childHwnd != 0) ShowWindow(_childHwnd, SW_SHOW);
  }

  @override
  void dispose() {
    _disposed = true;
    _pollTimer?.cancel();
    unawaited(_clearCredential());
    try {
      if (_childHwnd != 0) DestroyWindow(_childHwnd);
    } catch (_) {}
    try {
      _process?.kill();
    } catch (_) {}
    try {
      if (_scratchDir != null && _scratchDir!.existsSync()) {
        _scratchDir!.deleteSync(recursive: true);
      }
    } catch (_) {}
    _statusController.close();
  }
}
