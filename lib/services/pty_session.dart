import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_pty/flutter_pty.dart';
import 'package:xterm/xterm.dart';
import 'session_controller.dart';

export 'session_controller.dart' show SessionStatus;

/// Thrown when a host/username would not survive being written into a
/// Windows batch wrapper safely.
class UnsafeTargetError implements Exception {
  UnsafeTargetError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// One SSH session, run as a real client process inside a pseudo-terminal
/// (ConPTY on Windows, forkpty elsewhere) and rendered in our own xterm view.
///
/// We drive PuTTY's `plink` on Windows rather than speaking SSH ourselves:
/// network gear negotiates auth methods a young pure-Dart client trips over
/// (a Cisco switch here only offers keyboard-interactive, which is what made
/// every saved switch fail), and plink already handles all of it. It is also
/// the engine RDM drives, and it is already on these machines. On
/// macOS/Linux we use the system `ssh` for the same reason.
class PtySessionController implements SessionController {
  PtySessionController({
    required this.host,
    required this.port,
    String username = '',
    String password = '',
    this.tabTitle,
  })  : _username = username,
        _password = password {
    terminal = Terminal(maxLines: 10000);
    terminal.onOutput = (data) {
      _pty?.write(Uint8List.fromList(utf8.encode(data)));
    };
    terminal.onResize = (w, h, pw, ph) {
      _pty?.resize(h, w);
    };
    _start();
  }

  @override
  final String host;
  final int port;
  @override
  String? tabTitle;
  final String _username;
  final String _password;

  late final Terminal terminal;
  Pty? _pty;
  Directory? _scratchDir;

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

  /// Hosts and usernames end up inside a batch file, so anything that could
  /// start a second command there is rejected outright rather than escaped.
  /// Legitimate hostnames, IPv4/IPv6 literals and `DOMAIN\user` / `user@realm`
  /// forms all pass.
  static final _safeHost = RegExp(r'^[A-Za-z0-9._\-\[\]:]+$');
  static final _safeUser = RegExp(r'^[A-Za-z0-9._\-@\\$]+$');

  /// plink.exe, in order: next to our own executable (bundled), the standard
  /// PuTTY install locations, then anything on PATH.
  static String? findPlink() {
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final candidates = <String>[
      '$exeDir\\plink.exe',
      r'C:\Program Files\PuTTY\plink.exe',
      r'C:\Program Files (x86)\PuTTY\plink.exe',
    ];
    for (final path in candidates) {
      if (File(path).existsSync()) return path;
    }
    for (final dir in (Platform.environment['PATH'] ?? '').split(';')) {
      if (dir.trim().isEmpty) continue;
      final path = '${dir.trim()}\\plink.exe';
      if (File(path).existsSync()) return path;
    }
    return null;
  }

  Future<void> _start() async {
    try {
      if (!_safeHost.hasMatch(host)) {
        throw UnsafeTargetError('Refusing to connect: "$host" is not a valid host name or address.');
      }
      if (_username.isNotEmpty && !_safeUser.hasMatch(_username)) {
        throw UnsafeTargetError('Refusing to connect: "$_username" is not a valid user name.');
      }

      if (Platform.isWindows) {
        await _startWindows();
      } else {
        _startPosix();
      }
    } on UnsafeTargetError catch (e) {
      lastError = e.message;
      terminal.write('\r\n[error] ${e.message}\r\n');
      _setStatus(SessionStatus.error);
      _cleanUpScratch();
    } catch (e) {
      lastError = e.toString();
      terminal.write('\r\n[error] $lastError\r\n');
      _setStatus(SessionStatus.error);
      _cleanUpScratch();
    }
  }

  Future<void> _startWindows() async {
    final plink = findPlink();
    if (plink == null) {
      terminal.write(
        '\r\n[error] plink.exe not found.\r\n'
        'CommandS drives PuTTY for SSH sessions. Install PuTTY from\r\n'
        'https://www.putty.org/ (or drop plink.exe next to CommandS.exe).\r\n',
      );
      lastError = 'plink.exe not found';
      _setStatus(SessionStatus.error);
      return;
    }

    _scratchDir = await Directory.systemTemp.createTemp('commands_');

    // -pwfile keeps the password out of the command line, and out of every
    // process listing on the machine.
    String pwArg = '';
    if (_password.isNotEmpty) {
      final pwFile = File('${_scratchDir!.path}\\pw.txt');
      await pwFile.writeAsString(_password);
      pwArg = ' -pwfile "${pwFile.path}"';
    }

    final userArg = _username.isEmpty ? '' : ' -l "$_username"';

    // Plink defaults to treating remote output as ISO-8859-1, so any UTF-8
    // banner/prompt with non-ASCII characters (a Turkish "İçindir." MOTD, for
    // instance) comes out mangled. There is no CLI flag for this -- the
    // charset lives in a saved session -- so we maintain one PuTTY session
    // pinned to UTF-8 and load it; the explicit host/port/user below still
    // override whatever that session stores for them.
    final sessionArg = await _ensureUtf8Session() ? ' -load "$_utf8SessionName"' : '';

    // flutter_pty's Windows backend concatenates argv without quoting *and*
    // repeats the executable as argv[1], which mangles any path containing a
    // space and feeds plink a bogus hostname. Driving a batch wrapper sidesteps
    // both: the stray arguments land on the batch file (which ignores them)
    // while the real command line lives inside the script, quoted by us.
    final launcher = File('${_scratchDir!.path}\\connect.cmd');
    await launcher.writeAsString(
      '@echo off\r\n'
      '"$plink"$sessionArg -ssh -t -P $port$userArg$pwArg "$host"\r\n',
    );

    _pty = Pty.start(
      launcher.path,
      // flutter_pty only forwards a handful of POSIX-ish variables by default.
      // On Windows that drops SystemRoot, and without it ws2_32 cannot load its
      // service providers — every connection dies with WSA error 10106 before a
      // packet is sent. Hand the child our full environment instead.
      environment: Map<String, String>.from(Platform.environment),
      columns: terminal.viewWidth,
      rows: terminal.viewHeight,
    );

    _attachPty();
  }

  static const _utf8SessionName = 'CommandS-UTF8';
  static bool? _utf8SessionReady;

  /// Creates (once per machine) a PuTTY saved session pinned to UTF-8, so
  /// `-load` can pull it in. Registry writes are cheap and idempotent;
  /// failure just means we connect without it (ASCII output is unaffected).
  Future<bool> _ensureUtf8Session() async {
    if (_utf8SessionReady != null) return _utf8SessionReady!;
    try {
      final result = await Process.run('reg', [
        'add',
        r'HKCU\Software\SimonTatham\PuTTY\Sessions\CommandS-UTF8',
        '/v', 'LineCodePage', '/t', 'REG_SZ', '/d', 'UTF-8', '/f',
      ]);
      await Process.run('reg', [
        'add',
        r'HKCU\Software\SimonTatham\PuTTY\Sessions\CommandS-UTF8',
        '/v', 'Protocol', '/t', 'REG_SZ', '/d', 'ssh', '/f',
      ]);
      _utf8SessionReady = result.exitCode == 0;
    } catch (_) {
      _utf8SessionReady = false;
    }
    return _utf8SessionReady!;
  }

  void _startPosix() {
    _pty = Pty.start(
      'ssh',
      arguments: [
        '-p', '$port',
        '-t',
        _username.isEmpty ? host : '$_username@$host',
      ],
      columns: terminal.viewWidth,
      rows: terminal.viewHeight,
    );
    _attachPty();
  }

  void _attachPty() {
    _pty!.output.listen(
      (data) => terminal.write(utf8.decode(data, allowMalformed: true)),
      onError: (Object e) {
        lastError = e.toString();
        terminal.write('\r\n[error] $e\r\n');
        _setStatus(SessionStatus.error);
      },
    );

    unawaited(_pty!.exitCode.then((code) {
      _cleanUpScratch();
      terminal.write('\r\n[session ended, exit code $code]\r\n');
      _setStatus(code == 0 ? SessionStatus.closed : SessionStatus.error);
    }));

    tabTitle ??= _username.isEmpty ? host : '$_username@$host';
    _setStatus(SessionStatus.running);

    // plink reads the password file at startup; drop the scratch directory
    // shortly after so it does not sit on disk for the whole session.
    Future.delayed(const Duration(seconds: 15), _cleanUpScratch);
  }

  void _cleanUpScratch() {
    final dir = _scratchDir;
    if (dir == null) return;
    _scratchDir = null;
    try {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    } catch (_) {
      // Best effort — a leftover temp file is not worth crashing a session for.
    }
  }

  @override
  void dispose() {
    _cleanUpScratch();
    try {
      _pty?.kill();
    } catch (_) {}
    _statusController.close();
  }
}
