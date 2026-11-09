import 'dart:io';

import 'package:commands/services/sftp_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses names with spaces, dotfiles, and directories', () {
    final entries = OpenSshSftpClient.parseListing(
      'sftp> ls -la "/tmp"\n'
      '-rw-r--r-- 1 user group 42 Nov  9 15:21 notes with spaces.txt\n'
      'drwxr-xr-x 2 user group 4096 Nov  9 2025 archive\n'
      '-rw-r--r-- 1 user group 1 Nov  9 15:21 .hidden\n'
      'lrwxrwxrwx 1 user group 5 Nov  9 15:21 latest -> archive\n',
    );
    expect(entries.map((e) => e.name), [
      'archive',
      '.hidden',
      'latest',
      'notes with spaces.txt',
    ]);
    expect(entries.first.isDirectory, isTrue);
    expect(entries.last.size, 42);
  });

  test('escapes SFTP paths and rejects line injection', () {
    expect(
      OpenSshSftpClient.quotePath('/tmp/a b[1].txt'),
      r'"/tmp/a b[1].txt"',
    );
    expect(
      () => OpenSshSftpClient.quotePath('/tmp/a\nrm x'),
      throwsFormatException,
    );
    expect(OpenSshSftpClient.parentRemote('/a/b'), '/a');
    expect(OpenSshSftpClient.parentRemote('/a'), '/');
  });

  test('reports command failures and keeps paths quoted', () async {
    final commands = <String>[];
    final client = OpenSshSftpClient(
      host: '192.0.2.1',
      port: 22,
      username: 'user',
      password: '',
      runner: (command) async {
        commands.add(command);
        return const SftpCommandResult('', 'Permission denied', 1);
      },
    );
    await expectLater(
      client.mkdir('/tmp/new folder'),
      throwsA(
        isA<SftpException>().having(
          (e) => e.message,
          'message',
          'Permission denied',
        ),
      ),
    );
    expect(commands, ['mkdir "/tmp/new folder"']);
    client.dispose();
  });

  test(
    'runs list, upload, download, and mkdir against local OpenSSH SFTP server',
    () async {
      if (!Platform.isWindows) return;
      final root = Platform.environment['SystemRoot'] ?? r'C:\Windows';
      final server = File('$root\\System32\\OpenSSH\\sftp-server.exe');
      if (!server.existsSync()) return;
      final temp = await Directory.systemTemp.createTemp('commands_sftp_test_');
      final client = OpenSshSftpClient(
        host: '192.0.2.1',
        port: 22,
        username: 'user',
        password: '',
        directServer: server.path,
      );
      try {
        final remoteDir = temp.path.replaceAll(r'\', '/');
        await File(temp.path + r'\source.txt').writeAsString('sample transfer');
        await client.mkdir('$remoteDir/folder');
        await client.upload(
          temp.path + r'\source.txt',
          '$remoteDir/folder/copied.txt',
        );
      await client.upload(
        temp.path + r'\source.txt',
        '$remoteDir/folder/report [1].txt',
      );
        final entries = await client.list('$remoteDir/folder');
        expect(entries.map((e) => e.name), contains('copied.txt'));
      expect(entries.map((e) => e.name), contains('report [1].txt'));
        final downloaded = File(temp.path + r'\downloaded.txt');
        await downloaded.writeAsString('old version');
        await client.download('$remoteDir/folder/copied.txt', downloaded.path);
        expect(await downloaded.readAsString(), 'sample transfer');
      await client.download('$remoteDir/folder/report [1].txt',
          temp.path + r'\bracket.txt');
      expect(await File(temp.path + r'\bracket.txt').readAsString(),
          'sample transfer');
        expect(
          temp.listSync().where((e) => e.path.contains('.commands-backup-')),
          isEmpty,
        );
        await expectLater(
          client.download('$remoteDir/folder/missing.txt', downloaded.path),
          throwsA(isA<SftpException>()),
        );
        expect(await downloaded.readAsString(), 'sample transfer');
        expect(
          temp.listSync().where((e) => e.path.contains('.commands-part-')),
          isEmpty,
        );
      } finally {
        client.dispose();
        await temp.delete(recursive: true);
      }
    },
  );
}
