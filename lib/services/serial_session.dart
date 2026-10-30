import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_pty/flutter_pty.dart';
import 'package:win32/win32.dart';
import 'package:xterm/xterm.dart';

import 'session_controller.dart';

/// What the quick connect box was given for a serial console: `3` is COM3
/// at 9600 baud, `3:115200` sets the speed. On macOS the port is a device
/// name under /dev (`tty.usbserial-120`). Null when it is not a usable port.
({String port, int baud})? parseSerialTarget(String text, {bool windows = true}) {
  final parts = text.trim().split(':');
  if (parts.isEmpty || parts.length > 2) return null;
  final baud = parts.length == 2 ? int.tryParse(parts[1].trim()) : SerialSessionController.defaultBaud;
  if (baud == null || baud < 50 || baud > 4000000) return null;
  final name = parts[0].trim();
  if (windows) {
    final n = int.tryParse(name);
    if (n == null || n < 1 || n > 256) return null;
    return (port: 'COM$n', baud: baud);
  }
  if (!RegExp(r'^[A-Za-z0-9._\-]{1,64}$').hasMatch(name)) return null;
  return (port: '/dev/$name', baud: baud);
}

/// A serial console (a network device's console port) in a tab.
///
/// Windows: the port is opened by the app itself through the Win32 comm
/// API, in a background isolate, and the terminal's bytes go to it as they
/// are -- arrow keys and Ctrl combinations included. PuTTY's plink can also
/// do serial, but inside a pseudo-console it drops the arrow keys, which is
/// what a console's command history needs.
///
/// Settings are PuTTY's defaults, which network gear consoles expect: 9600
/// baud unless given, 8 data bits, no parity, 1 stop bit; flow control off.
///
/// macOS: the system's `screen` attached to the /dev device.
class SerialSessionController implements TerminalSessionController {
  SerialSessionController({
    required this.port,
    this.baud = defaultBaud,
    @visibleForTesting this.configurePort = true,
  }) {
    terminal = Terminal(maxLines: 10000);
    terminal.onOutput = (data) => _send(Uint8List.fromList(utf8.encode(data)));
    terminal.onResize = (w, h, pw, ph) => _pty?.resize(h, w);
    _start();
  }

  static const int defaultBaud = 9600;

  /// `COM3`, or `/dev/tty.usbserial-120` on macOS.
  final String port;
  final int baud;

  /// False only in tests, where a named pipe stands in for the port.
  final bool configurePort;

  @override
  late final Terminal terminal;

  @override
  String get host => port;

  @override
  String? get tabTitle => baud == defaultBaud ? port : '$port ($baud)';

  final _statusController = StreamController<SessionStatus>.broadcast();
  @override
  Stream<SessionStatus> get statusStream => _statusController.stream;
  @override
  SessionStatus status = SessionStatus.starting;
  String? lastError;

  void _setStatus(SessionStatus s) {
    status = s;
    if (!_statusController.isClosed) _statusController.add(s);
  }

  int _generation = 0;
  Isolate? _isolate;
  SendPort? _toPort;
  ReceivePort? _fromPort;
  Pty? _pty;
  final _decoder = const Utf8Decoder(allowMalformed: true);
  ByteConversionSink? _decoding;
  final _pending = StringBuffer();
  Timer? _flushTimer;

  void _send(Uint8List bytes) {
    if (Platform.isWindows) {
      _toPort?.send(bytes);
    } else {
      _pty?.write(bytes);
    }
  }

  void _output(List<int> bytes) {
    _decoding?.add(bytes);
    // Drawn at most once per frame, as in SSH sessions.
    _flushTimer ??= Timer(const Duration(milliseconds: 16), _flush);
  }

  void _flush() {
    _flushTimer = null;
    if (_pending.isEmpty) return;
    final text = _pending.toString();
    _pending.clear();
    terminal.write(text);
  }

  void _start() {
    final generation = ++_generation;
    _decoding = _decoder.startChunkedConversion(StringConversionSink.fromStringSink(_pending));
    if (Platform.isWindows) {
      unawaited(_startWindows(generation));
    } else {
      _startPosix(generation);
    }
  }

  Future<void> _startWindows(int generation) async {
    final from = _fromPort = ReceivePort();
    from.listen((message) {
      if (generation != _generation) return;
      if (message is SendPort) {
        _toPort = message;
      } else if (message is Uint8List) {
        _output(message);
      } else if (message is String && message == 'open') {
        terminal.write('[connected to $port, $baud baud, 8N1 -- press Enter if the console is quiet]\r\n');
        _setStatus(SessionStatus.running);
      } else if (message is List && message.length == 2 && message[0] == 'error') {
        _flush();
        lastError = message[1] as String;
        terminal.write('\r\n[error] $lastError\r\n');
        _setStatus(SessionStatus.error);
        _stop();
      } else if (message == 'closed') {
        _flush();
        terminal.write('\r\n[$port closed -- right-click the tab and choose Reconnect]\r\n');
        _setStatus(SessionStatus.closed);
        _stop();
      }
    });
    try {
      _isolate = await Isolate.spawn(_serialIsolate, (
        from.sendPort,
        port,
        baud,
        configurePort,
      ), debugName: 'serial $port');
    } catch (e) {
      lastError = '$e';
      terminal.write('\r\n[error] $e\r\n');
      _setStatus(SessionStatus.error);
    }
  }

  void _startPosix(int generation) {
    // macOS ships screen; it holds the port and passes keys through as-is.
    const screen = '/usr/bin/screen';
    if (!File(screen).existsSync() || !File(port).existsSync()) {
      lastError = File(port).existsSync() ? 'screen not found' : '$port does not exist';
      terminal.write('[error] $lastError\r\n');
      _setStatus(SessionStatus.error);
      return;
    }
    final env = Map<String, String>.from(Platform.environment)..['TERM'] = 'xterm-256color';
    final pty = _pty = Pty.start(
      screen,
      arguments: [port, '$baud'],
      environment: env,
      columns: terminal.viewWidth,
      rows: terminal.viewHeight,
    );
    pty.output.listen((d) {
      if (generation == _generation) _output(d);
    });
    unawaited(
      pty.exitCode.then((code) {
        if (generation != _generation) return;
        _flush();
        terminal.write('\r\n[$port closed -- right-click the tab and choose Reconnect]\r\n');
        _setStatus(code == 0 ? SessionStatus.closed : SessionStatus.error);
      }),
    );
    _setStatus(SessionStatus.running);
  }

  void _stop() {
    _flushTimer?.cancel();
    _flush();
    _toPort?.send(null); // asks the isolate to close the port
    _toPort = null;
    final isolate = _isolate;
    _isolate = null;
    // The isolate closes the handle itself; this is only if it is stuck.
    if (isolate != null) {
      Timer(const Duration(seconds: 2), () => isolate.kill(priority: Isolate.immediate));
    }
    _fromPort?.close();
    _fromPort = null;
    try {
      _pty?.kill();
    } catch (_) {}
    _pty = null;
  }

  @override
  void reconnect() {
    _generation++;
    _stop();
    terminal.write('\r\n');
    _setStatus(SessionStatus.starting);
    _start();
  }

  @override
  void dispose() {
    _generation++;
    _stop();
    _statusController.close();
  }
}

// ---- Windows: the port, in its own isolate --------------------------------

/// Opens [port] and shuttles bytes until told to stop (a null message) or
/// the port goes away. Reads block for at most 20 ms when nothing arrives,
/// so writes queued from the UI go out within that.
Future<void> _serialIsolate((SendPort, String, int, bool) args) async {
  final (toUi, port, baud, configure) = args;
  final inbox = ReceivePort();
  toUi.send(inbox.sendPort);

  final handle = openSerialPort(port, baud, configure: configure);
  if (handle.error != null) {
    toUi.send(['error', handle.error]);
    inbox.close();
    return;
  }
  final h = handle.handle!;
  toUi.send('open');

  var running = true;
  final writes = <Uint8List>[];
  inbox.listen((m) {
    if (m == null) {
      running = false;
    } else if (m is Uint8List) {
      writes.add(m);
    }
  });

  final buffer = calloc<Uint8>(4096);
  final count = calloc<Uint32>();
  try {
    while (running) {
      while (writes.isNotEmpty) {
        final data = writes.removeAt(0);
        final p = calloc<Uint8>(data.length);
        p.asTypedList(data.length).setAll(0, data);
        final ok = WriteFile(h, p, data.length, count, nullptr);
        calloc.free(p);
        if (ok == 0) {
          running = false;
          break;
        }
      }
      if (!running) break;
      if (ReadFile(h, buffer, 4096, count, nullptr) == 0) {
        // Unplugged (a USB adapter pulled out), or the driver gave up.
        toUi.send('closed');
        break;
      }
      if (count.value > 0) {
        toUi.send(Uint8List.fromList(buffer.asTypedList(count.value)));
      }
      // Lets the inbox deliver keystrokes between reads.
      await Future<void>.delayed(Duration.zero);
    }
  } finally {
    calloc.free(buffer);
    calloc.free(count);
    CloseHandle(h);
    inbox.close();
  }
}

/// Opens and configures a COM port: [baud] 8N1, no flow control, DTR and
/// RTS raised (as PuTTY does), reads returning as soon as anything arrives
/// or after 20 ms. Returns the handle, or a message saying what is wrong.
@visibleForTesting
({int? handle, String? error}) openSerialPort(String port, int baud, {bool configure = true}) {
  // \\.\ prefix: required from COM10 up, harmless below.
  final path = port.startsWith(r'\\') ? port : '\\\\.\\$port';
  final name = path.toNativeUtf16();
  final h = CreateFile(name, GENERIC_READ | GENERIC_WRITE, 0, nullptr, OPEN_EXISTING, 0, NULL);
  calloc.free(name);
  if (h == INVALID_HANDLE_VALUE) {
    // Windows' last-error code does not survive reliably between FFI calls,
    // so ask whether the device exists instead: if it does, it is almost
    // always held open by another program (PuTTY, a vendor tool).
    return (
      handle: null,
      error: _deviceExists(port)
          ? '$port is in use by another program, or cannot be opened.'
          : '$port not found. Check the port number in Device Manager.',
    );
  }
  if (!configure) return (handle: h, error: null);

  final dcb = calloc<DCB>();
  final timeouts = calloc<COMMTIMEOUTS>();
  try {
    dcb.ref.DCBlength = sizeOf<DCB>();
    if (GetCommState(h, dcb) == 0) {
      CloseHandle(h);
      return (handle: null, error: '$port is not a serial port.');
    }
    dcb.ref
      ..BaudRate = baud
      ..ByteSize = 8
      ..Parity =
          0 // NOPARITY
      ..StopBits =
          0 // ONESTOPBIT
      // fBinary (bit 0) | fDtrControl = DTR_CONTROL_ENABLE (bits 4-5 = 1) |
      // fRtsControl = RTS_CONTROL_ENABLE (bits 12-13 = 1). Everything else
      // off: no parity check, no CTS/DSR/XON-XOFF flow control, no abort on
      // error.
      ..bitfield = 0x1 | (0x1 << 4) | (0x1 << 12);
    if (SetCommState(h, dcb) == 0) {
      CloseHandle(h);
      return (handle: null, error: '$port does not accept $baud baud, 8N1.');
    }
    timeouts.ref
      ..ReadIntervalTimeout = 0xFFFFFFFF
      ..ReadTotalTimeoutMultiplier = 0xFFFFFFFF
      ..ReadTotalTimeoutConstant = 20
      ..WriteTotalTimeoutMultiplier = 0
      ..WriteTotalTimeoutConstant = 2000;
    SetCommTimeouts(h, timeouts);
    PurgeComm(h, PURGE_RXCLEAR | PURGE_TXCLEAR);
    return (handle: h, error: null);
  } finally {
    calloc.free(dcb);
    calloc.free(timeouts);
  }
}

/// Whether Windows knows a device by this name (COM3 -> \Device\Serial2).
bool _deviceExists(String port) {
  if (port.startsWith(r'\')) return true;
  final name = port.toNativeUtf16();
  final target = calloc<Uint16>(512).cast<Utf16>();
  try {
    return QueryDosDevice(name, target, 512) != 0;
  } finally {
    calloc.free(name);
    calloc.free(target);
  }
}
