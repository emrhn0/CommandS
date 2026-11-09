import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../app_version.dart';

class SftpEntry {
  const SftpEntry(this.name, {required this.isDirectory, required this.size});
  final String name;
  final bool isDirectory;
  final int size;
}

class SftpCommandResult {
  const SftpCommandResult(this.stdout, this.stderr, this.exitCode);
  final String stdout;
  final String stderr;
  final int exitCode;
}

abstract class SftpClient {
  Future<String> home();
  Future<List<SftpEntry>> list(String path);
  Future<void> upload(String localPath, String remotePath);
  Future<void> download(String remotePath, String localPath);
  Future<void> mkdir(String path);
  void dispose();
}

typedef SftpCommandRunner = Future<SftpCommandResult> Function(String command);

/// Uses the same OpenSSH implementation and host-key store as SSH tabs.
/// Each operation is a separate SFTP invocation so failures cannot desync
/// command output from the file browser.
class OpenSshSftpClient implements SftpClient {
  OpenSshSftpClient({
    required this.host,
    required this.port,
    required this.username,
    required this.password,
    this.sshOptions = const [],
    this.runner,
    this.directServer,
  });

  final String host;
  final int port;
  final String username;
  final String password;
  final List<String> sshOptions;
  final SftpCommandRunner? runner;
  @visibleForTesting
  final String? directServer;
  final Set<Process> _processes = {};
  bool _disposed = false;

  static String quotePath(String path) {
    if (path.isEmpty || path.contains(RegExp(r'[\r\n\x00]'))) {
      throw const FormatException('Invalid SFTP path');
    }
    // sftp parses one quoted pathname. Extra escapes before glob characters
    // corrupt Windows target names such as "report [1].txt".
    final escaped = path.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
    return '"$escaped"';
  }

  static String joinRemote(String parent, String name) =>
      '${parent == '/' ? '' : parent}/$name';

  static String parentRemote(String path) {
    final clean = path.endsWith('/') && path.length > 1
        ? path.substring(0, path.length - 1)
        : path;
    final slash = clean.lastIndexOf('/');
    return slash <= 0 ? '/' : clean.substring(0, slash);
  }

  static final _listingLine = RegExp(
    r'^([bcdlps-])\S{9}[+@.]?\s+\d+\s+\S+\s+\S+\s+(\d+)\s+\S+\s+\d+\s+(?:\d{4}|\d{1,2}:\d{2})\s+(.+)$',
  );

  @visibleForTesting
  static List<SftpEntry> parseListing(String output) {
    final entries = <SftpEntry>[];
    for (final line in const LineSplitter().convert(output)) {
      final match = _listingLine.firstMatch(line.trimRight());
      if (match == null) continue;
      var name = match[3]!;
      if (match[1] == 'l') name = name.split(' -> ').first;
      if (name == '.' || name == '..') continue;
      entries.add(
        SftpEntry(
          name,
          isDirectory: match[1] == 'd',
          size: int.parse(match[2]!),
        ),
      );
    }
    entries.sort((a, b) {
      if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return entries;
  }

  Future<SftpCommandResult> _run(String command) async {
    if (_disposed) throw StateError('SFTP client closed');
    final result = await (runner?.call(command) ?? _runOpenSsh(command));
    if (result.exitCode != 0) {
      final detail = result.stderr.trim().isNotEmpty
          ? result.stderr.trim()
          : result.stdout.trim();
      throw SftpException(detail.isEmpty ? 'SFTP command failed' : detail);
    }
    return result;
  }

  @override
  Future<String> home() async {
    final output = (await _run('pwd')).stdout;
    final match = RegExp(r'Remote working directory:\s*(.+)')
        .firstMatch(output);
    if (match == null) {
      throw const SftpException('Could not read remote directory');
    }
    return match[1]!.trim();
  }

  @override
  Future<List<SftpEntry>> list(String path) async {
    final output = (await _run('ls -la ${quotePath(path)}')).stdout;
    return parseListing(output);
  }

  @override
  Future<void> upload(String localPath, String remotePath) async {
    await _run('put ${quotePath(localPath)} ${quotePath(remotePath)}');
  }

  @override
  Future<void> download(String remotePath, String localPath) async {
    final suffix = DateTime.now().microsecondsSinceEpoch.toString();
    final partial = File('$localPath.commands-part-$suffix');
    File? backup;
    try {
      await _run('get ${quotePath(remotePath)} ${quotePath(partial.path)}');
      final destination = File(localPath);
      if (await destination.exists()) {
        backup = await destination.rename('$localPath.commands-backup-$suffix');
      }
      try {
        await partial.rename(localPath);
      } catch (_) {
        if (backup != null) await backup.rename(localPath);
        rethrow;
      }
      if (backup != null) {
        try {
          await backup.delete();
        } on FileSystemException {
          // The completed download is usable; the backup can be removed later.
        }
      }
    } finally {
      if (await partial.exists()) await partial.delete();
    }
  }

  @override
  Future<void> mkdir(String path) async {
    await _run('mkdir ${quotePath(path)}');
  }

  Future<SftpCommandResult> _runOpenSsh(String command) async {
    final sftp = Platform.isWindows
        ? '${Platform.environment['SystemRoot'] ?? r'C:\Windows'}\\System32\\OpenSSH\\sftp.exe'
        : (File('/usr/bin/sftp').existsSync() ? '/usr/bin/sftp' : 'sftp');
    if (Platform.isWindows && !File(sftp).existsSync()) {
      throw const SftpException('OpenSSH SFTP client is not installed');
    }
    final dir = await Directory.systemTemp.createTemp('commands_sftp_');
    try {
      final env = Map<String, String>.from(Platform.environment);
      if (password.isNotEmpty) {
        final helper = await _writeAskpass(dir);
        env['COMMANDS_SSH_PASSWORD'] = password;
        env['SSH_ASKPASS'] = helper;
        env['SSH_ASKPASS_REQUIRE'] = 'force';
        env['DISPLAY'] = env['DISPLAY'] ?? ':0';
      }
      final knownHosts = Platform.isWindows
          ? '${Platform.environment['APPDATA']}\\$appDataDirName\\known_hosts'
          : '${Platform.environment['HOME'] ?? ''}/.ssh/known_hosts';
      if (Platform.isWindows) {
        await Directory('${Platform.environment['APPDATA']}\\$appDataDirName')
            .create(recursive: true);
      }
      // -b adds BatchMode=yes internally; the earlier explicit option wins,
      // allowing SSH_ASKPASS to answer password/keyboard-interactive prompts.
      final args = <String>[
        '-o',
        'BatchMode=no',
        '-b',
        '-',
        '-N',
        '-P',
        '$port',
        '-o',
        'StrictHostKeyChecking=accept-new',
        '-o',
        'UserKnownHostsFile=$knownHosts',
        '-o',
        'ConnectTimeout=15',
        '-o',
        'ServerAliveInterval=30',
        ...sshOptions,
        if (password.isNotEmpty) ...[
          '-o',
          'PreferredAuthentications=keyboard-interactive,password',
          '-o',
          'NumberOfPasswordPrompts=3',
        ],
        if (directServer != null) ...[
          '-D',
          directServer!,
        ] else
          '$username@$host',
      ];
      final process = await Process.start(sftp, args, environment: env);
      _processes.add(process);
      try {
        final out = process.stdout.transform(utf8.decoder).join();
        final err = process.stderr.transform(utf8.decoder).join();
        process.stdin.write('$command\nbye\n');
        await process.stdin.close();
        final code = await process.exitCode;
        return SftpCommandResult(await out, await err, code);
      } finally {
        _processes.remove(process);
      }
    } finally {
      await dir.delete(recursive: true);
    }
  }

  Future<String> _writeAskpass(Directory dir) async {
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
      return cmd.path;
    }
    final file = File('${dir.path}/askpass.sh');
    await file.writeAsString(
      '#!/bin/sh\ncase "\$1" in\n'
      '  *"(yes/no)"*) printf yes ;;\n'
      '  *) printf %s "\$COMMANDS_SSH_PASSWORD" ;;\n'
      'esac\n',
    );
    await Process.run('/bin/chmod', ['700', file.path]);
    return file.path;
  }

  @override
  void dispose() {
    _disposed = true;
    for (final process in _processes) {
      process.kill();
    }
    _processes.clear();
  }
}

class SftpException implements Exception {
  const SftpException(this.message);
  final String message;
  @override
  String toString() => message;
}
