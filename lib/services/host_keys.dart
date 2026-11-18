import 'dart:io';

import '../app_version.dart';

/// The host keys OpenSSH has remembered for the devices CommandS connects to.
///
/// A key is remembered the first time a device is seen. When the device later
/// shows a different one (it was replaced, reset or reinstalled, or someone
/// is in between), OpenSSH refuses to connect. [forget] removes the old key,
/// once the user has said the change is theirs, so the next connection
/// remembers the new one.
class HostKeys {
  HostKeys._();

  /// Runs `ssh-keygen`; tests replace it. Arguments are passed as a list,
  /// never through a shell.
  static Future<ProcessResult> Function(String executable, List<String> arguments) run = Process.run;

  /// The file the SSH sessions use (see `PtySessionController`): the app's
  /// own on Windows, the user's on macOS and Linux.
  static String knownHostsFile() {
    if (Platform.isWindows) {
      return '${Platform.environment['APPDATA']}\\$appDataDirName\\known_hosts';
    }
    return '${Platform.environment['HOME'] ?? ''}/.ssh/known_hosts';
  }

  static String keygen() {
    if (Platform.isWindows) {
      final root = Platform.environment['SystemRoot'] ?? r'C:\Windows';
      return '$root\\System32\\OpenSSH\\ssh-keygen.exe';
    }
    return '/usr/bin/ssh-keygen';
  }

  /// How OpenSSH names [host] in the file: bare on port 22, `[host]:port`
  /// otherwise.
  static String target(String host, int port) => port == 22 ? host : '[$host]:$port';

  /// Lines OpenSSH prints when the remembered key no longer matches.
  static final changedText = RegExp(
    r'REMOTE HOST IDENTIFICATION HAS CHANGED|Host key verification failed',
    caseSensitive: false,
  );

  /// Removes the remembered key of [host] on [port]. Returns null when done
  /// (or when nothing was remembered), or what went wrong.
  static Future<String?> forget({required String host, required int port, String? file}) async {
    final path = file ?? knownHostsFile();
    if (!await File(path).exists()) return null;
    try {
      final result = await run(keygen(), ['-R', target(host, port), '-f', path]);
      if (result.exitCode == 0) return null;
      final message = '${result.stderr}'.trim();
      return message.isEmpty ? 'ssh-keygen exited with code ${result.exitCode}' : message;
    } catch (e) {
      return '$e';
    }
  }
}
