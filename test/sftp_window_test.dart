import 'package:commands/providers/app_state.dart';
import 'package:commands/services/pty_session.dart';
import 'package:commands/services/sftp_client.dart';
import 'package:commands/services/sftp_transfer.dart';
import 'package:commands/widgets/sftp_browser.dart';
import 'package:commands/widgets/sftp_window.dart';
import 'package:commands/widgets/terminal_tabs.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeSftp implements SftpClient {
  @override
  Future<String> home() async => '/home/user1';
  @override
  Future<List<SftpEntry>> list(String path) async => const [
    SftpEntry('notes.txt', isDirectory: false, size: 10),
  ];
  @override
  Future<void> upload(
    String localPath,
    String remotePath, {
    SftpProgressCallback? onProgress,
  }) async {}
  @override
  Future<void> download(
    String remotePath,
    String localPath, {
    SftpProgressCallback? onProgress,
  }) async {}
  @override
  Future<void> mkdir(String path) async {}
  @override
  void dispose() {}
}

class _FakeLocal implements LocalFileBrowser {
  @override
  Future<void> mkdir(String path) async {}
  @override
  String get initialPath => 'C:/Files';
  @override
  String join(String path, String name) => '$path/$name';
  @override
  String parent(String path) => 'C:/';
  @override
  Future<List<LocalFileEntry>> list(String path) async => const [
    LocalFileEntry('local.txt', isDirectory: false, size: 8),
  ];
}

void main() {
  const args = SftpWindowArguments(
    title: 'DEVICE-01',
    host: '192.0.2.10',
    port: 2222,
    username: 'user1',
    password: 'example-secret-value',
    sshOptions: ['-o', 'Ciphers=+aes128-cbc'],
    dark: true,
    sessionId: 'session-1',
    language: 'tr',
  );

  test('a window\'s arguments survive the trip to the new engine', () {
    final back = SftpWindowArguments.decode(args.encode())!;
    expect(back.host, '192.0.2.10');
    expect(back.port, 2222);
    expect(back.username, 'user1');
    expect(back.password, 'example-secret-value');
    expect(back.sshOptions, ['-o', 'Ciphers=+aes128-cbc']);
    expect(back.dark, isTrue);
    expect(back.sessionId, 'session-1');
    expect(back.language, 'tr');
  });

  test('the main window is not taken for an SFTP window', () {
    expect(SftpWindowArguments.decode(''), isNull);
    expect(SftpWindowArguments.decode('{"type":"other"}'), isNull);
    expect(SftpWindowArguments.decode('not json'), isNull);
  });

  test('transfer history crosses the window argument boundary', () {
    final withHistory = SftpWindowArguments(
      title: 'DEVICE-01', host: '192.0.2.10', port: 22,
      username: 'user1', password: '', sshOptions: const [], dark: false,
      transfers: [SftpTransfer('report.txt', 'upload', status: 'Completed')],
    );
    final decoded = SftpWindowArguments.decode(withHistory.encode())!;
    expect(decoded.transfers.single.name, 'report.txt');
    expect(decoded.transfers.single.direction, 'upload');
    expect(decoded.transfers.single.status, 'Completed');
    final panelHistory = <SftpTransfer>[];
    SftpTransfer.restore(panelHistory, [
      <Object?, Object?>{
        'name': 'report.txt', 'direction': 'upload',
        'status': 'Completed',
      },
    ]);
    expect(panelHistory.single.name, 'report.txt');
    // A verified transfer stays verified across windows.
    SftpTransfer.restore(panelHistory, [
      <Object?, Object?>{'name': 'report.txt', 'direction': 'upload', 'status': 'Verified'},
    ]);
    expect(panelHistory.single.status, 'Verified');
  });

  testWidgets('a window shows the existing session history', (tester) async {
    final withHistory = SftpWindowArguments(
      title: 'DEVICE-01', host: '192.0.2.10', port: 22,
      username: 'user1', password: '', sshOptions: const [], dark: false,
      transfers: [SftpTransfer('report.txt', 'download', status: 'Completed')],
    );
    await tester.binding.setSurfaceSize(const Size(1200, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(SftpWindowApp(
      args: withHistory, createClient: (_) async => _FakeSftp(),
      localBrowser: _FakeLocal(), onShrink: () {},
    ));
    await tester.pumpAndSettle();
    expect(find.text('report.txt'), findsOneWidget);
    expect(find.text('Completed'), findsOneWidget);
    expect(find.text('No transfers yet'), findsNothing);
  });

  testWidgets('the window shows both sides, and the shrink button closes it', (tester) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      (call) async => call.method.startsWith('is') ? false : null,
    );
    var closed = false;
    await tester.binding.setSurfaceSize(const Size(1200, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      SftpWindowApp(
        args: args,
        createClient: (_) async => _FakeSftp(),
        localBrowser: _FakeLocal(),
        onShrink: () => closed = true,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('SFTP · DEVICE-01'), findsOneWidget);
    expect(find.text('LOCAL FILES'), findsOneWidget);
    expect(find.text('REMOTE FILES'), findsOneWidget);
    expect(find.text('notes.txt'), findsOneWidget);
    expect(find.text('local.txt'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('sftp-shrink')));
    expect(closed, isTrue);
  });

  testWidgets(
    'SFTP opens from the tab\'s menu, with no bar above the terminal',
    (tester) async {
      PtySessionController.checkReachability = false;
      addTearDown(() => PtySessionController.checkReachability = true);
      SharedPreferences.setMockInitialValues({});
      final app = AppState();
      await tester.pump();
      final c = PtySessionController(
        host: '192.0.2.10',
        port: 22,
        username: 'user1',
        tabTitle: 'DEVICE-01',
      );
      c.writeOverride = (_) {};
      app.tabs.add(OpenTab(id: 'a', controller: c));
      app.setActiveTab(0);
      await tester.binding.setSurfaceSize(const Size(1000, 600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: app,
          child: const MaterialApp(home: Scaffold(body: TerminalTabsArea())),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byKey(const ValueKey('toggle-sftp')), findsNothing);

      await tester.tap(find.text('DEVICE-01'), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      await tester.tap(find.text('SFTP files'));
      // The panel starts connecting, with a spinner that never settles here.
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(c.sftpOpen.value, isTrue);

      c.sftpOpen.value = false;
      await tester.pumpWidget(const SizedBox());
      c.writeOverride = null;
      c.dispose();
      await tester.pump(const Duration(seconds: 1));
    },
  );
}
