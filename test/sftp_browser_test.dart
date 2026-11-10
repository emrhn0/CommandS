import 'dart:io';

import 'package:commands/services/sftp_client.dart';
import 'package:commands/widgets/sftp_browser.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeSftp implements SftpClient {
  final folders = <String, List<SftpEntry>>{
    '/home/user': [
      const SftpEntry('archive', isDirectory: true, size: 0),
      const SftpEntry('remote.txt', isDirectory: false, size: 12),
    ],
    '/home/user/archive': [
      const SftpEntry('older.txt', isDirectory: false, size: 8),
    ],
  };
  final uploads = <String>[];
  final downloads = <String>[];
  bool failList = false;
  bool disposed = false;

  @override
  Future<String> home() async => '/home/user';
  @override
  Future<List<SftpEntry>> list(String path) async {
    if (failList) throw const SftpException('Access denied');
    return folders[path] ?? [];
  }

  @override
  Future<void> upload(String localPath, String remotePath) async {
    uploads.add('$localPath -> $remotePath');
    folders['/home/user']!.add(
      SftpEntry(remotePath.split('/').last, isDirectory: false, size: 8),
    );
  }

  @override
  Future<void> download(String remotePath, String localPath) async {
    downloads.add('$remotePath -> $localPath');
  }

  @override
  Future<void> mkdir(String path) async {}
  @override
  void dispose() => disposed = true;
}

class _FakeLocal implements LocalFileBrowser {
  final created = <String>[];
  final entries = <LocalFileEntry>[
    const LocalFileEntry('local.txt', isDirectory: false, size: 8),
    const LocalFileEntry('report.txt', isDirectory: false, size: 3),
  ];
  @override
  String get initialPath => 'C:/Files';
  @override
  String join(String path, String name) => '$path/$name';
  @override
  String parent(String path) => 'C:/';
  @override
  Future<List<LocalFileEntry>> list(String path) async => List.of(entries);
  @override
  Future<void> mkdir(String path) async {
    created.add(path);
    entries.add(LocalFileEntry(baseName(path), isDirectory: true, size: 0));
  }
}

Future<void> _pumpBrowser(WidgetTester tester, _FakeSftp sftp, {_FakeLocal? local}) async {
  await tester.binding.setSurfaceSize(const Size(900, 700));
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 340,
          child: SftpBrowser(
            createClient: (_) async => sftp,
            localBrowser: local ?? _FakeLocal(),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('creates a local folder and refresh shows filesystem changes', (tester) async {
    final local = _FakeLocal();
    await _pumpBrowser(tester, _FakeSftp(), local: local);
    await tester.tap(find.byTooltip('New local folder'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'new folder');
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();
    expect(local.created, ['C:/Files/new folder']);
    expect(find.text('new folder'), findsOneWidget);

    local.entries.add(const LocalFileEntry('external.txt', isDirectory: false, size: 4));
    await tester.tap(find.byTooltip('Refresh').last);
    await tester.pumpAndSettle();
    expect(find.text('external.txt'), findsOneWidget);
  });

  testWidgets('rejects a local folder name with a path separator', (tester) async {
    final local = _FakeLocal();
    await _pumpBrowser(tester, _FakeSftp(), local: local);
    await tester.tap(find.byTooltip('New local folder'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'nested/folder');
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();
    expect(local.created, isEmpty);
    expect(find.text('Invalid folder name'), findsOneWidget);
  });

  test('disk browser creates a folder and rejects an existing name', () async {
    final root = await Directory.systemTemp.createTemp('commands_local_folder_test_');
    final browser = DiskFileBrowser();
    try {
      final path = browser.join(root.path, 'new folder');
      await browser.mkdir(path);
      expect((await browser.list(root.path)).map((e) => e.name), contains('new folder'));
      await expectLater(browser.mkdir(path), throwsA(isA<FileSystemException>()));
    } finally {
      await root.delete(recursive: true);
    }
  });

  testWidgets('navigates remote folders and uploads selected local file', (
    tester,
  ) async {
    final sftp = _FakeSftp();
    await _pumpBrowser(tester, sftp);
    expect(tester.takeException(), isNull);
    expect(find.text('REMOTE FILES'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('sftp-entry-archive')));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byKey(const ValueKey('sftp-entry-archive')));
    await tester.pumpAndSettle();
    expect(find.text('older.txt'), findsOneWidget);
    await tester.tap(find.byTooltip('Parent folder').first);
    await tester.pumpAndSettle();
    expect(find.text('remote.txt'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('sftp-entry-local.txt')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('sftp-upload')));
    await tester.pumpAndSettle();
    expect(sftp.uploads, ['C:/Files/local.txt -> /home/user/local.txt']);
    expect(find.text('Completed'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(sftp.disposed, isTrue);
  });

  testWidgets('downloads remote file and confirms replacement', (tester) async {
    final sftp = _FakeSftp();
    sftp.folders['/home/user']!.add(
      const SftpEntry('report.txt', isDirectory: false, size: 3),
    );
    await _pumpBrowser(tester, sftp);
    await tester.tap(find.byKey(const ValueKey('sftp-entry-report.txt')).first);
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('sftp-download')));
    await tester.pumpAndSettle();
    expect(find.text('Replace file?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(sftp.downloads, isEmpty);
    await tester.tap(find.byKey(const ValueKey('sftp-download')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Replace'));
    await tester.pumpAndSettle();
    expect(sftp.downloads, ['/home/user/report.txt -> C:/Files/report.txt']);
  });

  testWidgets('shows SFTP errors and offers password retry', (tester) async {
    final sftp = _FakeSftp()..failList = true;
    await _pumpBrowser(tester, sftp);
    expect(find.text('Access denied'), findsOneWidget);
    expect(find.text('Use SFTP password'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a pasted path opens that folder', (tester) async {
    final sftp = _FakeSftp();
    await _pumpBrowser(tester, sftp);
    final field = find.descendant(
      of: find.byKey(const ValueKey('path-Remote files')),
      matching: find.byType(TextField),
    );
    await tester.tap(field);
    await tester.pump();
    await tester.enterText(field, '/home/user/archive');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.text('older.txt'), findsOneWidget);
  });

  testWidgets('a letter jumps to the next name with it; arrows move; Backspace goes up', (tester) async {
    final sftp = _FakeSftp();
    sftp.folders['/home/user']!.addAll(const [
      SftpEntry('data.txt', isDirectory: false, size: 1),
      SftpEntry('docs.txt', isDirectory: false, size: 1),
    ]);
    await _pumpBrowser(tester, sftp);
    bool selected(String name) {
      final row = tester.widget(find.byKey(ValueKey('sftp-entry-$name')).first);
      return (row as dynamic).selected as bool;
    }

    await tester.tap(find.byKey(const ValueKey('sftp-entry-archive')).first);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyD);
    await tester.pump();
    expect(selected('data.txt'), isTrue);
    await tester.pump(const Duration(seconds: 1));
    await tester.sendKeyEvent(LogicalKeyboardKey.keyD);
    await tester.pump();
    expect(selected('docs.txt'), isTrue, reason: 'the same letter again: the next one');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(selected('data.txt'), isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.home);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.text('older.txt'), findsOneWidget, reason: 'Enter opened the folder');
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pumpAndSettle();
    expect(find.text('remote.txt'), findsOneWidget, reason: 'Backspace went back up');
  });
}
