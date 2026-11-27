import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:commands/models/models.dart';
import 'package:commands/providers/app_state.dart';
import 'package:commands/services/pty_session.dart';
import 'package:commands/services/storage_service.dart';
import 'package:commands/widgets/quick_connect_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _QuickConnectApp extends AppState {
  final targets = <(String, int)>[];

  @override
  void openQuickTelnet({required String host, required int port}) {
    targets.add((host, port));
  }
}

void main() {
  testWidgets('quick connect sends Telnet targets to the Telnet opener', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final app = _QuickConnectApp();
    await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
      value: app,
      child: const MaterialApp(home: Scaffold(body: QuickConnectBar())),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Quick connect protocol'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Telnet'));
    await tester.pumpAndSettle();
    expect(find.text('Telnet is not encrypted.'), findsOneWidget);

    final input = find.byType(TextField);
    for (final target in ['192.0.2.11', '192.0.2.11:2323']) {
      await tester.enterText(input, target);
      await tester.tap(find.byTooltip('Connect'));
      await tester.pumpAndSettle();
    }
    expect(app.targets, [('192.0.2.11', 23), ('192.0.2.11', 2323)]);

    await tester.enterText(input, '192.0.2.11:65536');
    await tester.tap(find.byTooltip('Connect'));
    await tester.pumpAndSettle();
    expect(find.text('Enter a valid Telnet host and port.'), findsOneWidget);
    expect(app.targets, hasLength(2));
  });

  test('Telnet connections keep their protocol and port in all export formats', () {
    final storage = StorageService();
    final connection = SavedConnection(
      name: 'DEVICE-01',
      host: '192.0.2.11',
      protocol: ConnectionProtocol.telnet,
      port: 2323,
    );
    final connections = [connection];
    final json = storage.exportJson(folders: [], connections: connections);
    final xml = storage.exportXml(folders: [], connections: connections);
    final csv = storage.exportCsv(folders: [], connections: connections);
    for (final parsed in [
      storage.parseJson(json),
      storage.parseXml(xml),
      storage.parseCsv(csv),
    ]) {
      expect(parsed.connections.single.protocol, ConnectionProtocol.telnet);
      expect(parsed.connections.single.port, 2323);
    }
    final withoutPort = SavedConnection.fromJson(connection.toJson()..remove('port'));
    expect(withoutPort.port, 23);
  });

  test('a Telnet tab keeps its protocol when duplicated', () {
    final session = PtySessionController(
      host: '192.0.2.11',
      port: 2323,
      protocol: ConnectionProtocol.telnet,
      startImmediately: false,
    );
    addTearDown(session.dispose);
    expect(session.isSsh, isFalse);
    expect(session.connectionForDuplicate().protocol, ConnectionProtocol.telnet);
    expect(session.connectionForDuplicate().port, 2323);
  });

  test('Plink shows the Telnet login prompt and sends keyboard input', () async {
    final listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(listener.close);
    final connected = Completer<Socket>();
    final received = Completer<String>();
    final arrow = Completer<void>();
    final reader = StringBuffer();
    final subscription = listener.listen((peer) {
      if (connected.isCompleted) {
        peer.destroy();
        return;
      }
      connected.complete(peer);
      peer.listen((bytes) {
        reader.write(latin1.decode(bytes));
        if (!received.isCompleted && reader.toString().contains('test-user\r')) {
          received.complete(reader.toString());
        }
        if (!arrow.isCompleted && reader.toString().contains('\x1b[A')) {
          arrow.complete();
        }
      });
      // Negotiate remote echo and suppress go-ahead, then ask for login.
      peer.add([255, 251, 1, 255, 251, 3]);
      peer.write('Username: ');
    });
    addTearDown(subscription.cancel);

    final session = PtySessionController(
      host: InternetAddress.loopbackIPv4.address,
      port: listener.port,
      protocol: ConnectionProtocol.telnet,
      username: 'saved-user',
      password: 'example-secret',
      startImmediately: false,
    );
    addTearDown(session.dispose);
    final output = StringBuffer();
    final prompt = Completer<void>();
    final outputSubscription = session.outputStream.listen((text) {
      output.write(text);
      if (!prompt.isCompleted && output.toString().contains('Username:')) {
        prompt.complete();
      }
    });
    addTearDown(outputSubscription.cancel);
    session.reconnect();
    final peer = await connected.future.timeout(const Duration(seconds: 8));
    addTearDown(peer.destroy);
    await prompt.future.timeout(const Duration(seconds: 5));
    expect(reader.toString(), isNot(contains('saved-user')));
    expect(reader.toString(), isNot(contains('example-secret')));
    session.sendInput('test-user\r');
    expect(await received.future.timeout(const Duration(seconds: 5)), contains('test-user\r'));
    session.sendInput('\x1b[A');
    await arrow.future.timeout(const Duration(seconds: 3));
  }, skip: Platform.isWindows && PtySessionController.findPlink() != null
      ? false
      : 'Requires Windows Plink.');
}
