import 'dart:async';
import 'dart:io';

import '../app_version.dart';
import 'session_controller.dart';

/// A hostname is accepted only from a shell prompt, never from a banner.
/// No command is sent to the remote device.
String? hostnameFromPrompt(String output) {
  final clean = output.replaceAll(
    RegExp(
      r'\x1B(?:\[[0-?]*[ -/]*[@-~]|\][^\x07\x1B]*(?:\x07|\x1B\\)|[@-Z\\-_])',
    ),
    '',
  );
  final lines = clean.split(RegExp(r'[\r\n]'));
  final tail = lines.reversed
      .map((s) => s.trim())
      .firstWhere((s) => s.isNotEmpty, orElse: () => '');
  if (tail.isEmpty || tail.length > 160) return null;
  final patterns = [
    RegExp(r'^[\w.-]+@([A-Za-z][A-Za-z0-9_.-]{0,62}):[^\r\n]{0,100}[$#]$'),
    RegExp(r'^\[[\w.-]+@([A-Za-z][A-Za-z0-9_.-]{0,62}):[^\]]{0,100}\] ?[$#]?$'),
    RegExp(r'^[\w.-]+@([A-Za-z][A-Za-z0-9_.-]{0,62})>$'),
    RegExp(r'^<([A-Za-z][A-Za-z0-9_.-]{0,62})>$'),
    RegExp(
      r'^([A-Za-z][A-Za-z0-9_.-]{0,62})(?:\([A-Za-z0-9_-]{1,30}\))? ?[>#]$',
    ),
  ];
  for (final pattern in patterns) {
    final name = pattern.firstMatch(tail)?.group(1);
    if (name != null && InternetAddress.tryParse(name) == null) return name;
  }
  return null;
}

class HostnameDiscoveryResult {
  const HostnameDiscoveryResult({
    this.hostname,
    required this.reason,
    required this.outputChars,
  });
  final String? hostname;
  final String reason;
  final int outputChars;
}

/// Watches only the first screenful, then releases the session streams.
class HostnameDiscovery {
  HostnameDiscovery({
    required Stream<String> output,
    required Stream<SessionStatus> status,
    required this.onResult,
    this.timeout = const Duration(seconds: 90),
  }) {
    _output = output.listen(_read, onDone: () => fail('session-closed'));
    _status = status.listen((value) {
      if (value == SessionStatus.running) _startTimer();
      if (value == SessionStatus.error) fail('session-error');
      if (value == SessionStatus.closed) fail('session-closed');
    });
  }

  final void Function(HostnameDiscoveryResult) onResult;
  final Duration timeout;
  late final StreamSubscription<String> _output;
  late final StreamSubscription<SessionStatus> _status;
  Timer? _timer;
  String _tail = '';
  int _outputChars = 0;
  bool _done = false;

  void _read(String text) {
    if (_done) return;
    _startTimer();
    _outputChars += text.length;
    _tail += text;
    if (_tail.length > 4096) _tail = _tail.substring(_tail.length - 4096);
    final hostname = hostnameFromPrompt(_tail);
    if (hostname != null) {
      _finish(
        HostnameDiscoveryResult(
          hostname: hostname,
          reason: 'matched-prompt',
          outputChars: _outputChars,
        ),
      );
    }
  }

  void fail(String reason) {
    _finish(HostnameDiscoveryResult(reason: reason, outputChars: _outputChars));
  }

  void _startTimer() {
    _timer ??= Timer(timeout, () => fail('timeout'));
  }

  void _finish(HostnameDiscoveryResult result) {
    if (_done) return;
    _done = true;
    _timer?.cancel();
    unawaited(_output.cancel());
    unawaited(_status.cancel());
    onResult(result);
  }

  void dispose() {
    if (_done) return;
    _done = true;
    _timer?.cancel();
    unawaited(_output.cancel());
    unawaited(_status.cancel());
  }
}

/// Local diagnostics only. Terminal text, passwords, host addresses and user
/// names are never written to the log.
class HostnameDetectionLog {
  HostnameDetectionLog({Directory? directory})
    : directory = directory ?? _defaultDirectory();

  final Directory directory;

  static Directory _defaultDirectory() {
    if (Platform.isWindows) {
      final roaming =
          Platform.environment['APPDATA'] ??
          (Platform.environment['USERPROFILE'] ?? Directory.current.path) +
              r'\AppData\Roaming';
      return Directory('$roaming\\$appDataDirName\\logs');
    }
    final home = Platform.environment['HOME'] ?? Directory.current.path;
    if (Platform.isMacOS) {
      return Directory(
        '$home/Library/Application Support/$appDataDirName/logs',
      );
    }
    final state =
        Platform.environment['XDG_STATE_HOME'] ?? '$home/.local/state';
    return Directory('$state/$appDataDirName/logs');
  }

  Future<void> record({
    required String connectionId,
    required String reason,
    required int outputChars,
    String? device,
  }) async {
    await directory.create(recursive: true);
    final line =
        '${DateTime.now().toUtc().toIso8601String()} connection=$connectionId '
        'reason=$reason outputChars=$outputChars device=${device ?? 'unknown'}\n';
    await File(
      '${directory.path}${Platform.pathSeparator}hostname-detection.log',
    ).writeAsString(line, mode: FileMode.append, flush: true);
  }
}
