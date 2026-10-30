import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_pty/flutter_pty.dart';
import 'package:xterm/xterm.dart';

import '../models/models.dart';
import 'device_detect.dart';
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
/// The client is OpenSSH: the system `ssh` on macOS/Linux, and the one
/// Windows ships (System32\OpenSSH) on Windows. Windows used to drive PuTTY's
/// plink instead, and plink in a pseudo-console turned out to be the cause of
/// three PuTTY differences: it reads the console as plain text, so the arrow
/// keys never reached the server (no command history); it always asks the
/// server for an 80x24 terminal; and it never sends a window-change, so a
/// session in a split pane or a resized window kept wrapping at 80 columns
/// and full-screen output (apt, top, less) came out shifted. OpenSSH does all
/// three the way PuTTY's own window does. plink remains the fallback on a
/// Windows without the OpenSSH client.
///
/// Network gear is why a real client is used rather than a pure-Dart one: a
/// Cisco switch here only offers keyboard-interactive, old firmware only old
/// algorithms, and a firewall may ask a yes/no question at login.
class PtySessionController implements TerminalSessionController {
  PtySessionController({
    required this.host,
    required this.port,
    String username = '',
    String password = '',
    this.tabTitle,
  }) : _username = username,
       _password = password {
    terminal = Terminal(maxLines: 10000);
    terminal.onOutput = _onTerminalInput;
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

  /// Typed at the `login as:` prompt when the connection has none saved, and
  /// then kept, so Reconnect does not ask again.
  String _username;
  final String _password;

  @override
  late final Terminal terminal;
  Pty? _pty;
  Directory? _scratchDir;

  /// Bumped on every start, so callbacks of a session that has been replaced
  /// (Reconnect) cannot report on the new one.
  int _generation = 0;

  /// While the `login as:` prompt is up, keystrokes go here, not to a process.
  void Function(String)? _lineInput;

  final _statusController = StreamController<SessionStatus>.broadcast();
  @override
  Stream<SessionStatus> get statusStream => _statusController.stream;
  @override
  SessionStatus status = SessionStatus.starting;

  String? lastError;

  /// Told once per connection what kind of device answered, when that can
  /// be read from what it printed (see [detectDevice]).
  void Function(DeviceKind kind)? onDeviceDetected;

  /// The server's identification line (`SSH-2.0-...`), read during the
  /// reachability check. Empty when there was none.
  String serverVersion = '';

  /// The start of the session's output, kept for [detectDevice] until it
  /// has an answer or enough has gone by.
  final _sniff = StringBuffer();
  bool _sniffing = false;
  Timer? _settleTimer;
  static const _sniffLimit = 32 * 1024;
  static const _settleAfter = Duration(seconds: 15);

  void _sniffStart() {
    _sniff.clear();
    _sniffing = true;
    _settleTimer?.cancel();
    _settleTimer = null;
    _detect(settled: false);
  }

  void _sniffAdd(String text) {
    if (!_sniffing) return;
    _sniff.write(text);
    _settleTimer ??= Timer(_settleAfter, () => _detect(settled: true));
    _detect(settled: false);
    if (_sniffing && _sniff.length > _sniffLimit) _sniffStop();
  }

  void _detect({required bool settled}) {
    if (!_sniffing) return;
    final kind = detectDevice(serverVersion: serverVersion, output: _sniff.toString(), settled: settled);
    if (kind != null) {
      _sniffStop();
      onDeviceDetected?.call(kind);
    }
  }

  void _sniffStop() {
    _sniffing = false;
    _sniff.clear();
    _settleTimer?.cancel();
    _settleTimer = null;
  }

  void _setStatus(SessionStatus s) {
    status = s;
    if (!_statusController.isClosed) _statusController.add(s);
  }

  void _onTerminalInput(String data) {
    final line = _lineInput;
    if (line != null) {
      line(data);
      return;
    }
    _pty?.write(Uint8List.fromList(utf8.encode(data)));
  }

  /// Hosts and usernames end up inside a batch file, so anything that could
  /// start a second command there is rejected outright rather than escaped.
  /// Legitimate hostnames, IPv4/IPv6 literals and `DOMAIN\user` / `user@realm`
  /// forms all pass.
  static final _safeHost = RegExp(r'^[A-Za-z0-9._\-\[\]:]+$');
  static final _safeUser = RegExp(r'^[A-Za-z0-9._\-@\\$]+$');

  /// The OpenSSH client Windows ships, if it is installed (it is by default
  /// on Windows 10 1809 and later). Only that one: an `ssh` found on PATH
  /// may be Git's or Cygwin's, which do not work in a pseudo-console.
  static String? findWindowsSsh() {
    final root = Platform.environment['SystemRoot'] ?? r'C:\Windows';
    final path = '$root\\System32\\OpenSSH\\ssh.exe';
    return File(path).existsSync() ? path : null;
  }

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

  /// Starts the session again in the same tab and terminal: after the
  /// connection dropped, or to restart it (PuTTY's "Restart Session").
  @override
  void reconnect() {
    _stopProcess();
    _lineInput = null;
    terminal.write('\r\n');
    _setStatus(SessionStatus.starting);
    _start();
  }

  Future<void> _start() async {
    final generation = ++_generation;
    serverVersion = '';
    _sniffStop();
    try {
      if (!_safeHost.hasMatch(host)) {
        throw UnsafeTargetError('Refusing to connect: "$host" is not a valid host name or address.');
      }
      final ssh = Platform.isWindows ? findWindowsSsh() : _sshExecutable;
      if (ssh != null) {
        // Reach the server first, as PuTTY does before it asks anything: an
        // address with nothing behind it used to get a "login as:" prompt and
        // a green tab, as if connected.
        final problem = checkReachability ? await _reach() : null;
        if (generation != _generation) return;
        if (problem != null) {
          _fail(problem);
          return;
        }
      }
      _sniffStart();
      if (_username.isEmpty && ssh != null) {
        // OpenSSH would log in as the local account; ask, as PuTTY does.
        final typed = await _readLine('login as: ');
        if (generation != _generation) return;
        if (typed == null || typed.trim().isEmpty) {
          terminal.write('\r\n[cancelled]\r\n');
          _setStatus(SessionStatus.closed);
          return;
        }
        _username = typed.trim();
      }
      if (_username.isNotEmpty && !_safeUser.hasMatch(_username)) {
        throw UnsafeTargetError('Refusing to connect: "$_username" is not a valid user name.');
      }
      if (ssh != null) {
        await _startOpenSsh(ssh, generation);
      } else {
        await _startPlink(generation);
      }
    } on UnsafeTargetError catch (e) {
      _fail(e.message);
    } catch (e) {
      _fail(e.toString());
    }
  }

  static const _reachTimeout = Duration(seconds: 10);

  /// Tests that only exercise tabs and dialogs turn the network check off.
  @visibleForTesting
  static bool checkReachability = true;

  /// Opens and closes a TCP connection to the SSH port. Null when it
  /// answered, otherwise what went wrong, in plain words.
  Future<String?> _reach() async {
    terminal.write('Connecting to $host:$port...\r\n');
    final address = host.startsWith('[') && host.endsWith(']') ? host.substring(1, host.length - 1) : host;
    try {
      final socket = await Socket.connect(address, port, timeout: _reachTimeout);
      serverVersion = await readIdentification(socket);
      socket.destroy();
      return null;
    } on SocketException catch (e) {
      final code = e.osError?.errorCode;
      final why = switch (code) {
        10061 || 111 || 61 => 'connection refused (nothing is listening on port $port)',
        10060 || 110 || 60 => 'connection timed out',
        10065 || 113 || 65 || 10051 || 101 || 51 => 'no route to host',
        11001 || 11004 || 8 || -2 => 'host name not found',
        _ when e.message.toLowerCase().contains('timed out') => 'connection timed out',
        _ => (e.osError?.message ?? e.message).trim(),
      };
      return 'Could not connect to $host:$port: $why.';
    }
  }

  /// The `SSH-...` line a server sends as soon as it accepts a connection
  /// (RFC 4253 allows other lines before it). Gives up after a moment or a
  /// kilobyte; nothing is sent.
  @visibleForTesting
  static Future<String> readIdentification(Socket socket) async {
    final done = Completer<String>();
    final seen = <int>[];
    String? pick() {
      final lines = latin1.decode(seen).split('\n');
      // The last piece has no newline yet: it may still be arriving.
      for (final line in lines.take(lines.length - 1)) {
        if (line.startsWith('SSH-')) return line.trim();
      }
      return null;
    }

    final sub = socket.listen(
      (data) {
        seen.addAll(data);
        final line = pick();
        if (line != null && !done.isCompleted) done.complete(line);
        if (seen.length > 1024 && !done.isCompleted) done.complete('');
      },
      onError: (_) {
        if (!done.isCompleted) done.complete('');
      },
      onDone: () {
        if (!done.isCompleted) done.complete(pick() ?? '');
      },
      cancelOnError: true,
    );
    final line = await done.future.timeout(const Duration(seconds: 2), onTimeout: () => pick() ?? '');
    await sub.cancel();
    return line;
  }

  void _fail(String message) {
    lastError = message;
    terminal.write('\r\n[error] $message\r\n');
    _setStatus(SessionStatus.error);
    _cleanUpScratch();
  }

  /// A one-line prompt drawn in the terminal itself (`login as:`), with
  /// echo, Backspace, and Ctrl+C to give up. Null when given up.
  Future<String?> _readLine(String prompt) {
    final done = Completer<String?>();
    final text = StringBuffer();
    terminal.write(prompt);
    _lineInput = (data) {
      // Arrow keys and the like arrive as escape sequences; a prompt has no
      // use for them.
      if (data.startsWith('\x1b')) return;
      for (final ch in data.runes.map(String.fromCharCode)) {
        if (ch == '\r' || ch == '\n') {
          terminal.write('\r\n');
          _lineInput = null;
          done.complete(text.toString());
          return;
        } else if (ch == '\x7f' || ch == '\b') {
          if (text.isEmpty) continue;
          final s = text.toString();
          text
            ..clear()
            ..write(s.substring(0, s.length - 1));
          terminal.write('\b \b');
        } else if (ch == '\x03' || ch == '\x04') {
          _lineInput = null;
          done.complete(null);
          return;
        } else if (ch.codeUnitAt(0) >= 0x20) {
          text.write(ch);
          terminal.write(ch);
        }
      }
    };
    return done.future;
  }

  // ---- OpenSSH ----

  /// Legacy algorithms we ask OpenSSH to *append* to its own preference
  /// lists (the `+` forms below), so a modern server still negotiates a
  /// modern algorithm and only old network gear falls back this far. Cisco
  /// IOS, Aruba and older ProCurve/Huawei firmware offer nothing newer than
  /// these, and OpenSSH has disabled every one of them by default -- without
  /// them those switches fail with "no matching key exchange method found".
  static const _legacyKex = [
    'diffie-hellman-group14-sha1',
    'diffie-hellman-group-exchange-sha1',
    'diffie-hellman-group1-sha1',
  ];
  static const _legacyHostKeys = ['ssh-rsa', 'ssh-dss'];
  static const _legacyCiphers = ['aes256-cbc', 'aes192-cbc', 'aes128-cbc', '3des-cbc'];
  static const _legacyMacs = ['hmac-sha1', 'hmac-sha1-96', 'hmac-md5'];

  /// The OpenSSH we are actually driving decides which of the above still
  /// exist -- 10.x dropped `ssh-dss` outright, and naming an algorithm it
  /// does not know is a fatal "Unsupported ... algorithms" before a packet
  /// is sent. `ssh -Q` reports what this build supports; anything missing is
  /// dropped from our list. Probed once per app run.
  static final Map<String, Set<String>> _supportedAlgos = {};

  static Future<Set<String>> _supported(String ssh, String query) async {
    final hit = _supportedAlgos[query];
    if (hit != null) return hit;
    var found = <String>{};
    try {
      final r = await Process.run(ssh, ['-Q', query]);
      if (r.exitCode == 0) {
        found = (r.stdout as String).split('\n').map((e) => e.trim()).where((e) => e.isNotEmpty).toSet();
      }
    } catch (_) {
      // Leave it empty: no legacy options get added, which is the old
      // behavior rather than a broken command line.
    }
    _supportedAlgos[query] = found;
    return found;
  }

  /// `+list` option, or null when this OpenSSH supports none of [wanted].
  static Future<String?> _legacyOption(String ssh, String query, List<String> wanted) async {
    final have = await _supported(ssh, query);
    final usable = wanted.where(have.contains).toList();
    return usable.isEmpty ? null : '+${usable.join(',')}';
  }

  /// Full path first: an app bundle launched from Finder inherits a minimal
  /// PATH that does not always include /usr/bin.
  static final String _sshExecutable = File('/usr/bin/ssh').existsSync() ? '/usr/bin/ssh' : 'ssh';

  /// The arguments for one OpenSSH session, platform aside. [knownHosts] is
  /// where host keys are remembered.
  Future<List<String>> _sshArgs(String ssh, {required String knownHosts}) async {
    final args = <String>['-t', '-p', '$port'];
    for (final (query, wanted) in [
      ('kex', _legacyKex),
      ('key', _legacyHostKeys),
      ('cipher', _legacyCiphers),
      ('mac', _legacyMacs),
    ]) {
      final value = await _legacyOption(ssh, query, wanted);
      if (value == null) continue;
      switch (query) {
        case 'kex':
          args.addAll(['-o', 'KexAlgorithms=$value']);
        case 'key':
          args.addAll(['-o', 'HostKeyAlgorithms=$value', '-o', 'PubkeyAcceptedAlgorithms=$value']);
        case 'cipher':
          args.addAll(['-o', 'Ciphers=$value']);
        case 'mac':
          args.addAll(['-o', 'MACs=$value']);
      }
    }
    // A host seen for the first time is remembered without a question (as
    // PuTTY's "Accept" would); one whose key has changed is still refused.
    args.addAll(['-o', 'StrictHostKeyChecking=accept-new', '-o', 'UserKnownHostsFile=$knownHosts']);
    // Keeps idle sessions through NAT and firewall timeouts.
    args.addAll(['-o', 'ServerAliveInterval=30', '-o', 'ConnectTimeout=15']);
    if (_password.isNotEmpty) {
      // The saved password is what this connection is for: skip the
      // key/agent attempts that would each go through the helper first.
      // Network gear that only offers keyboard-interactive (the Cisco case)
      // is covered by listing it ahead of plain password auth.
      args.addAll(['-o', 'PreferredAuthentications=keyboard-interactive,password']);
      args.addAll(['-o', 'NumberOfPasswordPrompts=3']);
    }
    args.add('$_username@$host');
    return args;
  }

  Future<void> _startOpenSsh(String ssh, int generation) async {
    final dir = _scratchDir = await Directory.systemTemp.createTemp('commands_');
    final env = Map<String, String>.from(Platform.environment);
    env['TERM'] = 'xterm-256color';

    if (_password.isNotEmpty) {
      // OpenSSH has no password flag, so it goes through its askpass hook,
      // forced even though we are on a real terminal. The helper reads the
      // password from an environment variable it inherits: nothing secret is
      // written to disk, and it never reaches a command line or process
      // listing. It is asked once per prompt, with the prompt as argument; a
      // "(yes/no)" question at login (a firewall's banner acknowledgement)
      // is answered yes -- answering it with the password failed the login.
      // Host-key questions never reach it: see StrictHostKeyChecking.
      String askpass;
      if (Platform.isWindows) {
        final ps1 = File('${dir.path}\\askpass.ps1');
        await ps1.writeAsString(
          "param([string]\$Prompt = '')\r\n"
          "if (\$Prompt -match '\\(yes/no\\)') { [Console]::Out.Write('yes'); exit 0 }\r\n"
          '[Console]::Out.Write(\$env:COMMANDS_SSH_PASSWORD)\r\n',
        );
        final cmd = File('${dir.path}\\askpass.cmd');
        await cmd.writeAsString(
          '@powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass '
          '-File "%~dp0askpass.ps1" %*\r\n',
        );
        askpass = cmd.path;
      } else {
        final sh = File('${dir.path}/askpass.sh');
        await sh.writeAsString(
          '#!/bin/sh\n'
          'case "\$1" in\n'
          '  *"(yes/no)"*) printf yes ;;\n'
          '  *) printf %s "\$COMMANDS_SSH_PASSWORD" ;;\n'
          'esac\n',
        );
        await Process.run('/bin/chmod', ['700', sh.path]);
        askpass = sh.path;
      }
      env['COMMANDS_SSH_PASSWORD'] = _password;
      env['SSH_ASKPASS'] = askpass;
      env['SSH_ASKPASS_REQUIRE'] = 'force';
      env['DISPLAY'] = env['DISPLAY'] ?? ':0';
    }

    if (Platform.isWindows) {
      // Our own known_hosts, so CommandS neither reads nor fills in the
      // user's ~/.ssh. %APPDATA% is expanded by the batch file at run time,
      // which keeps a non-ASCII profile path out of the file's own encoding.
      final hostsDir = Directory('${Platform.environment['APPDATA']}\\CommandS');
      if (!hostsDir.existsSync()) hostsDir.createSync(recursive: true);
      final args = await _sshArgs(ssh, knownHosts: r'%APPDATA%\CommandS\known_hosts');
      if (generation != _generation) return;
      // flutter_pty's Windows backend concatenates argv without quoting *and*
      // repeats the executable as argv[1]; a batch wrapper sidesteps both,
      // with the real command line quoted by us. Every argument is a
      // constant, a number, or a host/user checked against _safeHost /
      // _safeUser above.
      final launcher = File('${dir.path}\\connect.cmd');
      await launcher.writeAsString(
        '@echo off\r\n'
        // UTF-8 console, or non-ASCII banners and prompts come out mangled.
        'chcp 65001 >nul\r\n'
        '"$ssh" ${args.map((a) => '"$a"').join(' ')}\r\n',
      );
      _pty = Pty.start(
        launcher.path,
        // flutter_pty only forwards a handful of POSIX-ish variables by
        // default. On Windows that drops SystemRoot, and without it ws2_32
        // cannot load its service providers -- every connection dies with
        // WSA error 10106 before a packet is sent.
        environment: env,
        columns: terminal.viewWidth,
        rows: terminal.viewHeight,
      );
    } else {
      final home = Platform.environment['HOME'] ?? '';
      final args = await _sshArgs(ssh, knownHosts: '$home/.ssh/known_hosts');
      if (generation != _generation) return;
      // flutter_pty forwards a short allowlist otherwise, and a bundle started
      // from Finder has almost no environment to begin with.
      env.putIfAbsent('LANG', () => 'en_US.UTF-8');
      env.putIfAbsent('PATH', () => '/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin');
      _pty = Pty.start(
        ssh,
        arguments: args,
        environment: env,
        columns: terminal.viewWidth,
        rows: terminal.viewHeight,
      );
    }
    _attachPty(generation, cleanUpEarly: false);
  }

  // ---- plink (Windows without OpenSSH) ----

  Future<void> _startPlink(int generation) async {
    final plink = findPlink();
    if (plink == null) {
      terminal.write(
        '\r\n[error] No SSH client found.\r\n'
        'Turn on Windows\' "OpenSSH Client" (Settings > Apps > Optional features),\r\n'
        'or install PuTTY from https://www.putty.org/.\r\n',
      );
      lastError = 'No SSH client found';
      _setStatus(SessionStatus.error);
      return;
    }

    final dir = _scratchDir = await Directory.systemTemp.createTemp('commands_');

    // -pwfile keeps the password out of the command line, and out of every
    // process listing on the machine.
    String pwArg = '';
    if (_password.isNotEmpty) {
      final pwFile = File('${dir.path}\\pw.txt');
      await pwFile.writeAsString(_password);
      pwArg = ' -pwfile "${pwFile.path}"';
    }
    final userArg = _username.isEmpty ? '' : ' -l "$_username"';
    final sessionArg = await _ensureUtf8Session() ? ' -load "$_utf8SessionName"' : '';
    if (generation != _generation) return;

    final launcher = File('${dir.path}\\connect.cmd');
    await launcher.writeAsString(
      '@echo off\r\n'
      'chcp 65001 >nul\r\n'
      '"$plink"$sessionArg -ssh -t -P $port$userArg$pwArg "$host"\r\n',
    );
    _pty = Pty.start(
      launcher.path,
      environment: Map<String, String>.from(Platform.environment),
      columns: terminal.viewWidth,
      rows: terminal.viewHeight,
    );
    // plink reads the password file at startup; the file goes soon after.
    _attachPty(generation, cleanUpEarly: true);
  }

  static const _utf8SessionName = 'CommandS-UTF8';
  static bool? _utf8SessionReady;

  /// A PuTTY saved session pinned to UTF-8, so `-load` can pull it in;
  /// plink has no command-line flag for the remote character set.
  Future<bool> _ensureUtf8Session() async {
    if (_utf8SessionReady != null) return _utf8SessionReady!;
    try {
      final result = await Process.run('reg', [
        'add',
        r'HKCU\Software\SimonTatham\PuTTY\Sessions\CommandS-UTF8',
        '/v',
        'LineCodePage',
        '/t',
        'REG_SZ',
        '/d',
        'UTF-8',
        '/f',
      ]);
      await Process.run('reg', [
        'add',
        r'HKCU\Software\SimonTatham\PuTTY\Sessions\CommandS-UTF8',
        '/v',
        'Protocol',
        '/t',
        'REG_SZ',
        '/d',
        'ssh',
        '/f',
      ]);
      _utf8SessionReady = result.exitCode == 0;
    } catch (_) {
      _utf8SessionReady = false;
    }
    return _utf8SessionReady!;
  }

  // ---- Output ----

  /// Output waiting for the next flush. A busy session (a log being tailed,
  /// a long listing) delivers many small chunks; drawing each one on its own
  /// is what made the view stutter, so they are gathered and handed to the
  /// terminal at most once per frame.
  final _pending = StringBuffer();
  Timer? _flushTimer;
  static const _flushEvery = Duration(milliseconds: 16);

  void _flush() {
    _flushTimer = null;
    if (_pending.isEmpty) return;
    final text = _pending.toString();
    _pending.clear();
    terminal.write(text);
    _sniffAdd(text);
  }

  void _attachPty(int generation, {required bool cleanUpEarly}) {
    // Decoded as one stream: a UTF-8 character split across two reads (any
    // Turkish letter can be) used to come out as two replacement marks.
    final decoder = const Utf8Decoder(allowMalformed: true)
        .startChunkedConversion(StringConversionSink.fromStringSink(_pending));
    _pty!.output.listen(
      (data) {
        if (generation != _generation) return;
        decoder.add(data);
        _flushTimer ??= Timer(_flushEvery, _flush);
      },
      onError: (Object e) {
        if (generation != _generation) return;
        lastError = e.toString();
        _flush();
        terminal.write('\r\n[error] $e\r\n');
        _setStatus(SessionStatus.error);
      },
    );

    unawaited(
      _pty!.exitCode.then((code) {
        if (generation != _generation) return;
        decoder.close();
        _flushTimer?.cancel();
        _flush();
        _cleanUpScratch();
        terminal.write(
          '\r\n[session ended, exit code $code -- right-click the tab and choose Reconnect]\r\n',
        );
        _setStatus(code == 0 ? SessionStatus.closed : SessionStatus.error);
      }),
    );

    tabTitle ??= _username.isEmpty ? host : '$_username@$host';
    _setStatus(SessionStatus.running);

    if (cleanUpEarly) {
      Future.delayed(const Duration(seconds: 15), () {
        if (generation == _generation) _cleanUpScratch();
      });
    }
  }

  void _stopProcess() {
    _generation++;
    _sniffStop();
    _flushTimer?.cancel();
    _flush();
    try {
      _pty?.kill();
    } catch (_) {}
    _pty = null;
    _cleanUpScratch();
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
    _lineInput = null;
    _stopProcess();
    _statusController.close();
  }
}
