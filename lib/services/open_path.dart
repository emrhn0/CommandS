import 'dart:io';

/// Opens a file with its default app, or a folder in Explorer / Finder.
///
/// The path is passed as one argument, never through a shell, so nothing in
/// it can be read as a command. Tests replace [launcher].
class OpenPath {
  OpenPath._();

  static Future<void> Function(String executable, List<String> arguments) launcher = _start;

  static Future<void> _start(String executable, List<String> arguments) async {
    await Process.start(executable, arguments, mode: ProcessStartMode.detached);
  }

  static Future<void> open(String path) {
    if (Platform.isMacOS) return launcher('/usr/bin/open', [path]);
    if (Platform.isWindows) return launcher('explorer.exe', [path]);
    return launcher('xdg-open', [path]);
  }
}
