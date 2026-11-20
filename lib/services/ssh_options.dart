import 'dart:io';

/// The value for OpenSSH's `UserKnownHostsFile=`. OpenSSH reads that value
/// as a list of files separated by whitespace, so a profile path with a
/// space in it (C:\Users\user 1) would leave the keys unsaved and every connection
/// "new". Under the home folder the path is written as `~/...`: OpenSSH
/// expands the tilde after splitting, so the space no longer matters.
/// Elsewhere a path with a space is put in double quotes, which OpenSSH
/// accepts.
String knownHostsOption(String path, {String? home}) {
  final slashed = path.replaceAll('\\', '/');
  if (!RegExp(r'\s').hasMatch(slashed)) return slashed;
  final base = (home ?? _home())?.replaceAll('\\', '/');
  if (base != null && base.isNotEmpty) {
    final prefix = base.endsWith('/') ? base : '$base/';
    if (slashed.toLowerCase().startsWith(prefix.toLowerCase())) {
      return '~/${slashed.substring(prefix.length)}';
    }
  }
  return '"$slashed"';
}

String? _home() => Platform.isWindows
    ? Platform.environment['USERPROFILE']
    : Platform.environment['HOME'];

/// The Windows askpass helper. OpenSSH runs it with the prompt as its
/// argument, and that prompt comes from the server. A batch file that
/// forwarded it with %* would let cmd.exe read quotes and & in it as
/// syntax, so the batch file takes no arguments at all; the PowerShell
/// script reads the prompt from the command line of the cmd.exe that runs
/// the batch file, as plain text.
const windowsAskpassPs1 =
    r"$prompt = ''" '\r\n'
    r'try {' '\r\n'
    r'  $parent = (Get-CimInstance Win32_Process -Filter "ProcessId=$PID").ParentProcessId' '\r\n'
    r'  $prompt = [string](Get-CimInstance Win32_Process -Filter "ProcessId=$parent").CommandLine' '\r\n'
    r'} catch {}' '\r\n'
    r"if ($prompt -match '\(yes/no\)') { [Console]::Out.Write('yes'); exit 0 }" '\r\n'
    r'[Console]::Out.Write($env:COMMANDS_SSH_PASSWORD)' '\r\n';

const windowsAskpassCmd =
    '@powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass '
    '-File "%~dp0askpass.ps1"\r\n';
