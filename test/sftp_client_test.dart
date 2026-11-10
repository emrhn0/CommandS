import 'dart:io';

import 'package:commands/services/sftp_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('listings as servers print them', () {
    test('Linux, with a "?" link count, a Turkish month and a name with spaces', () {
      const output =
          'sftp> ls -la "/home/user1"\r\n'
          'drwxr-xr-x    ? user1    user1        4096 Kas  9 22:31 .\r\n'
          'drwxr-xr-x    3 0        0            4096 Oct  8  2025 ..\r\n'
          'drwx------    2 user1    user1        4096 Nov  9 22:31 .ssh\r\n'
          '-rw-r--r--    1 user1    user1        2840 Nov  9 22:31 my notes.txt\r\n'
          'lrwxrwxrwx    1 user1    user1          11 Nov  9 22:31 latest -> my notes.txt\r\n';
      final entries = OpenSshSftpClient.parseListing(output);
      expect(entries.map((e) => e.name), ['.ssh', 'latest', 'my notes.txt']);
      expect(entries.first.isDirectory, isTrue);
      expect(entries.last.size, 2840);
    });

    test(
      'day before month, as the real Windows sftp.exe printed it in a lab',
      () {
        const output =
            'sftp> ls -la "/home/user1"\r\n'
            'drwxrwxrwx   1 0        0               0 09 Nov 22:35 configs\r\n'
            '-rw-rw-rw-   1 0        0            2840 09 Nov 22:35 my notes.txt\r\n'
            'sftp> bye\r\n';
        final entries = OpenSshSftpClient.parseListing(output);
        expect(entries.map((e) => e.name), ['configs', 'my notes.txt']);
        expect(entries.last.size, 2840);
      },
    );

    test('masked permissions and whole paths, as a real server showed them', () {
      const output =
          'sftp> ls -la "/home/user1"\r\n'
          'drwx******    ? user1    user1        4096 Oct  8 13:48 /home/user1/.\r\n'
          'drwxr-xr-x    ? root     root         4096 Oct  8 13:40 /home/user1/..\r\n'
          'drwx******    ? user1    user1        4096 Oct  8 13:48 /home/user1/.ssh\r\n'
          '-rw-******    ? user1    user1         807 Oct  8 13:40 /home/user1/.profile\r\n'
          '-rw-r--r--    ? user1    user1        2840 Nov  9 22:31 /home/user1/my notes.txt\r\n';
      final entries = OpenSshSftpClient.parseListing(output);
      expect(entries.map((e) => e.name), ['.ssh', '.profile', 'my notes.txt']);
      expect(entries.first.isDirectory, isTrue);
      expect(entries.last.size, 2840);
    });

    test('an empty folder is empty', () {
      expect(
        OpenSshSftpClient.parseListing('sftp> ls -la "/tmp/empty"\r\n'),
        isEmpty,
      );
    });

    test('a listing that cannot be read is an error, not an empty folder', () {
      expect(
        () => OpenSshSftpClient.parseListing(
          'sftp> ls -la "/x"\r\nsomething unexpected\r\n',
        ),
        throwsA(isA<SftpException>()),
      );
    });
  });

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

  test('upload reports progress and rejects a mismatched SHA-256', () async {
    final temp = await Directory.systemTemp.createTemp('commands_sftp_hash_');
    final source = File('${temp.path}${Platform.pathSeparator}source.txt');
    await source.writeAsString('original bytes');
    final progress = <SftpProgress>[];
    final client = OpenSshSftpClient(
      host: '192.0.2.1',
      port: 22,
      username: 'user',
      password: '',
      runner: (command) async {
        if (command.startsWith('put ')) {
          return const SftpCommandResult('', '', 0);
        }
        if (command.startsWith('get ')) {
          final encoded = RegExp(r'^get ".*" "(.*)"$').firstMatch(command)![1]!;
          await File(encoded.replaceAll(r'\\', r'\'))
              .writeAsString('changed bytes');
          return const SftpCommandResult('', '', 0);
        }
        throw StateError('Unexpected command: $command');
      },
    );
    try {
      await expectLater(
        client.upload(
          source.path,
          '/remote/source.txt',
          onProgress: progress.add,
        ),
        throwsA(
          isA<SftpException>().having(
            (e) => e.message,
            'message',
            'SHA-256 verification failed',
          ),
        ),
      );
      expect(progress.where((p) => !p.verifying), isEmpty);
      expect(progress.last.verifying, isTrue);
      expect(progress.last.total, await source.length());
    } finally {
      client.dispose();
      await temp.delete(recursive: true);
    }
  });

  test('upload does not log in again to poll the remote size', () async {
    final temp = await Directory.systemTemp.createTemp('commands_sftp_poll_');
    final source = File('${temp.path}${Platform.pathSeparator}source.txt');
    await source.writeAsString('same bytes');
    final commands = <String>[];
    final client = OpenSshSftpClient(
      host: '192.0.2.1',
      port: 22,
      username: 'user',
      password: '',
      runner: (command) async {
        commands.add(command.split(' ').first);
        if (command.startsWith('put ')) {
          // Long enough for several progress samples.
          await Future<void>.delayed(const Duration(milliseconds: 1000));
          return const SftpCommandResult('', '', 0);
        }
        if (command.startsWith('get ')) {
          final encoded = RegExp(r'^get ".*" "(.*)"$').firstMatch(command)![1]!;
          await File(encoded.replaceAll(r'\\', r'\')).writeAsString('same bytes');
          return const SftpCommandResult('', '', 0);
        }
        return const SftpCommandResult('', '', 0);
      },
    );
    try {
      await client.upload(source.path, '/remote/source.txt', onProgress: (_) {});
      expect(commands, ['put', 'get']);
    } finally {
      client.dispose();
      await temp.delete(recursive: true);
    }
  });

  test('download goes ahead when the server cannot list a single file', () async {
    final temp = await Directory.systemTemp.createTemp('commands_sftp_nolist_');
    final destination = File('${temp.path}${Platform.pathSeparator}destination.txt');
    final progress = <SftpProgress>[];
    final client = OpenSshSftpClient(
      host: '192.0.2.1',
      port: 22,
      username: 'user',
      password: '',
      runner: (command) async {
        if (command.startsWith('ls -la ')) {
          return const SftpCommandResult('', 'Can\'t ls: not a directory', 1);
        }
        if (command.startsWith('get ')) {
          final encoded = RegExp(r'^get ".*" "(.*)"$').firstMatch(command)![1]!;
          await File(encoded.replaceAll(r'\\', r'\')).writeAsString('content');
          return const SftpCommandResult('', '', 0);
        }
        throw StateError('Unexpected command: $command');
      },
    );
    try {
      await client.download('/remote/source.txt', destination.path, onProgress: progress.add);
      expect(await destination.readAsString(), 'content');
      expect(progress.first.total, 0);
      expect(progress.last.verifying, isTrue);
    } finally {
      client.dispose();
      await temp.delete(recursive: true);
    }
  });

  test('download mismatch preserves the existing destination', () async {
    final temp = await Directory.systemTemp.createTemp('commands_sftp_hash_');
    final destination = File(
      '${temp.path}${Platform.pathSeparator}destination.txt',
    );
    await destination.writeAsString('keep this');
    var reads = 0;
    final client = OpenSshSftpClient(
      host: '192.0.2.1',
      port: 22,
      username: 'user',
      password: '',
      runner: (command) async {
        if (command.startsWith('ls -la ')) {
          return const SftpCommandResult(
            '-rw-r--r-- 1 user group 5 Nov 9 15:21 source.txt\n',
            '',
            0,
          );
        }
        if (command.startsWith('get ')) {
          final encoded = RegExp(r'^get ".*" "(.*)"$').firstMatch(command)![1]!;
          await File(encoded.replaceAll(r'\\', r'\'))
              .writeAsString(reads++ == 0 ? 'first' : 'other');
          return const SftpCommandResult('', '', 0);
        }
        throw StateError('Unexpected command: $command');
      },
    );
    try {
      await expectLater(
        client.download('/remote/source.txt', destination.path),
        throwsA(isA<SftpException>()),
      );
      expect(await destination.readAsString(), 'keep this');
      expect(
        temp.listSync().where((e) => e.path.contains('.commands-part-')),
        isEmpty,
      );
    } finally {
      client.dispose();
      await temp.delete(recursive: true);
    }
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
        final uploadProgress = <SftpProgress>[];
        final downloadProgress = <SftpProgress>[];
        await File(temp.path + r'\source.txt').writeAsString('sample transfer');
        await client.mkdir('$remoteDir/folder');
        await client.upload(
          temp.path + r'\source.txt',
          '$remoteDir/folder/copied.txt',
          onProgress: uploadProgress.add,
        );
        expect(uploadProgress.last.verifying, isTrue);
        await client.upload(
          temp.path + r'\source.txt',
          '$remoteDir/folder/report [1].txt',
        );
        final entries = await client.list('$remoteDir/folder');
        expect(entries.map((e) => e.name), contains('copied.txt'));
        expect(entries.map((e) => e.name), contains('report [1].txt'));
        final downloaded = File(temp.path + r'\downloaded.txt');
        await downloaded.writeAsString('old version');
        await client.download('$remoteDir/folder/copied.txt', downloaded.path,
            onProgress: downloadProgress.add);
        expect(downloadProgress.last.verifying, isTrue);
        expect(await downloaded.readAsString(), 'sample transfer');
        await client.download(
          '$remoteDir/folder/report [1].txt',
          temp.path + r'\bracket.txt',
        );
        expect(
          await File(temp.path + r'\bracket.txt').readAsString(),
          'sample transfer',
        );
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
