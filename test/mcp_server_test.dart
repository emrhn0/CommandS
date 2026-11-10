import 'dart:convert';
import 'dart:io';

import 'package:commands/providers/app_state.dart';
import 'package:commands/models/models.dart';
import 'package:commands/screens/settings_screen.dart';
import 'package:commands/services/pty_session.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:commands/services/mcp_server.dart';

class _FakeGateway implements McpGateway {
  String? sent;

  @override
  List<Map<String, String>> listConnections() => [
    {'id': 'device-01', 'name': 'DEVICE-01', 'device_type': 'Palo Alto'},
  ];

  @override
  Future<String> openConnection(String connectionId) async {
    if (connectionId != 'device-01') throw ArgumentError('Unknown connection');
    return 'session-01';
  }

  @override
  Future<int> sendCommand(String sessionId, String command) async {
    if (sessionId != 'session-01') throw ArgumentError('Unknown session');
    sent = command;
    return 5;
  }

  @override
  Map<String, Object?> readOutput(String sessionId, int cursor) => {
    'output': 'ok',
    'cursor': cursor + 2,
    'status': 'running',
    'device_type': 'Palo Alto',
  };

  @override
  void close() {}
}

Future<(int, Map<String, dynamic>?)> _request(
  String url,
  Object body, {
  String? origin,
}) async {
  final uri = Uri.parse(url);
  final socket = await Socket.connect(uri.host, uri.port);
  final bytes = utf8.encode(jsonEncode(body));
  socket.write('POST ${uri.path} HTTP/1.1\r\n');
  socket.write('Host: ${uri.host}:${uri.port}\r\n');
  socket.write('Content-Type: application/json\r\n');
  socket.write('Content-Length: ${bytes.length}\r\n');
  if (origin != null) socket.write('Origin: $origin\r\n');
  socket.write('Connection: close\r\n\r\n');
  socket.add(bytes);
  await socket.flush();
  final raw = await utf8.decoder.bind(socket).join();
  final split = raw.indexOf('\r\n\r\n');
  final status = int.parse(raw.substring(0, split).split(' ')[1]);
  final text = raw.substring(split + 4);
  return (
    status,
    text.isEmpty ? null : jsonDecode(text) as Map<String, dynamic>,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('MCP handshake, tools, command and output over local HTTP', () async {
    final gateway = _FakeGateway();
    final server = McpServer(gateway, port: 0);
    await server.start(testToken: 'a' * 32);
    expect(server.enabled, isTrue);
    addTearDown(() => server.dispose());
    final url = server.url!;

    final (initStatus, init) = await _request(url, {
      'jsonrpc': '2.0',
      'id': 1,
      'method': 'initialize',
      'params': {'protocolVersion': '2025-11-25'},
    });
    expect(initStatus, 200);
    expect(init!['result']['protocolVersion'], '2025-11-25');
    expect(init['result']['instructions'], contains('device_type'));

    final (noticeStatus, notice) = await _request(url, {
      'jsonrpc': '2.0',
      'method': 'notifications/initialized',
    });
    expect(noticeStatus, 202);
    expect(notice, isNull);

    final (_, listed) = await _request(url, {
      'jsonrpc': '2.0',
      'id': 2,
      'method': 'tools/list',
    });
    final tools = listed!['result']['tools'] as List<dynamic>;
    expect(
      tools.map((t) => t['name']),
      containsAll([
        'list_connections',
        'open_connection',
        'send_command',
        'read_output',
      ]),
    );
    expect(
      tools.firstWhere((t) => t['name'] == 'list_connections')['description'],
      contains('device_type'),
    );

    Future<Map<String, dynamic>> call(
      int id,
      String name,
      Map<String, Object> args,
    ) async {
      final (status, body) = await _request(url, {
        'jsonrpc': '2.0',
        'id': id,
        'method': 'tools/call',
        'params': {'name': name, 'arguments': args},
      });
      expect(status, 200);
      return jsonDecode(body!['result']['content'][0]['text'] as String)
          as Map<String, dynamic>;
    }

    final connections = await call(3, 'list_connections', {});
    expect(connections['connections'], [
      {'id': 'device-01', 'name': 'DEVICE-01', 'device_type': 'Palo Alto'},
    ]);
    final opened = await call(4, 'open_connection', {
      'connection_id': 'device-01',
    });
    expect(opened['session_id'], 'session-01');
    final sent = await call(5, 'send_command', {
      'session_id': 'session-01',
      'command': 'show version',
    });
    expect(sent['cursor'], 5);
    expect(gateway.sent, 'show version');
    final output = await call(6, 'read_output', {
      'session_id': 'session-01',
      'cursor': 5,
    });
    expect(output['output'], 'ok');
    expect(output['cursor'], 7);
    expect(output['device_type'], 'Palo Alto');
  });

  test('secret path and foreign Origin cannot call tools', () async {
    final gateway = _FakeGateway();
    final server = McpServer(gateway, port: 0);
    await server.start(testToken: 'b' * 32);
    addTearDown(() => server.dispose());
    final url = server.url!;
    final body = {'jsonrpc': '2.0', 'id': 1, 'method': 'tools/list'};
    final (badPath, _) = await _request(
      url.replaceFirst('b' * 32, 'wrong'),
      body,
    );
    expect(badPath, 403);
    final (badOrigin, _) = await _request(
      url,
      body,
      origin: 'https://example.invalid',
    );
    expect(badOrigin, 403);
  });

  test('opt-in and secret survive an app restart', () async {
    final first = McpServer(_FakeGateway(), port: 0);
    await first.start();
    final secretPath = Uri.parse(first.url!).path;
    expect((await SharedPreferences.getInstance()).getBool('commands.mcp.enabled'), isTrue);
    first.dispose();

    final restored = McpServer(_FakeGateway(), port: 0);
    await restored.restore();
    expect(restored.enabled, isTrue);
    expect(Uri.parse(restored.url!).path, secretPath);
    await restored.stop();
    restored.dispose();
    expect((await SharedPreferences.getInstance()).getBool('commands.mcp.enabled'), isFalse);
  });

  test('simultaneous starts share one listener', () async {
    final server = McpServer(_FakeGateway(), port: 0);
    await Future.wait([server.start(), server.start()]);
    expect(server.enabled, isTrue);
    expect(server.error, isNull);
    await server.stop();
    server.dispose();
  });

  group('app gateway', () {
    late AppState app;
    late AppMcpGateway gateway;
    late List<McpApproval> asked;
    var answer = true;

    setUp(() async {
      PtySessionController.checkReachability = false;
      app = AppState();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      app.connections = [
        SavedConnection(id: 'c1', name: 'CUSTOMER-A SWITCH', host: '192.0.2.1', username: 'user1'),
        SavedConnection(
          id: 'c2',
          name: 'CUSTOMER-B FIREWALL',
          host: '192.0.2.2',
          username: 'test-user',
          password: 'fake-secret',
          device: DeviceKind.paloalto,
        ),
      ];
      asked = [];
      answer = true;
      gateway = AppMcpGateway(app, approve: (a) async {
        asked.add(a);
        return answer;
      });
      await gateway.load();
    });
    tearDown(() {
      gateway.close();
      for (final t in app.tabs) {
        t.controller.dispose();
      }
      PtySessionController.checkReachability = true;
    });

    test('lists only allowed connections, under anonymous names', () async {
      expect(gateway.listConnections(), isEmpty);
      await gateway.setAllowed('c2', true);
      final listed = gateway.listConnections();
      expect(listed, [
        {'id': 'DEVICE-01', 'name': 'DEVICE-01', 'device_type': 'Palo Alto'},
      ]);
      expect(jsonEncode(listed), isNot(contains('CUSTOMER')));
      expect(jsonEncode(listed), isNot(contains('192.0.2')));
      expect(jsonEncode(listed), isNot(contains('test-user')));
      expect(jsonEncode(listed), isNot(contains('fake-secret')));
      await gateway.setAllowed('c1', true);
      expect(gateway.listConnections().last['device_type'], 'Unknown');
    });

    test('a connection not allowed cannot be opened, by alias or real id', () async {
      await gateway.setAllowed('c1', true);
      expect(() => gateway.openConnection('c2'), throwsArgumentError);
      expect(() => gateway.openConnection('c1'), throwsArgumentError, reason: 'real ids are not names it knows');
      expect(() => gateway.openConnection('DEVICE-02'), throwsArgumentError);
    });

    test('every command waits for the user; a no sends nothing', () async {
      await gateway.setAllowed('c1', true);
      final session = await gateway.openConnection('DEVICE-01');
      final controller = app.tabs.last.controller as PtySessionController;
      final sent = <String>[];
      controller.writeOverride = sent.add;

      answer = false;
      await expectLater(gateway.sendCommand(session, 'reload'), throwsStateError);
      expect(sent, isEmpty);
      expect(asked.single.connectionName, 'CUSTOMER-A SWITCH', reason: 'the real name is shown to the user only');
      expect(asked.single.alias, 'DEVICE-01');

      answer = true;
      await gateway.sendCommand(session, 'show version');
      expect(sent, ['show version\r']);
    });

    test('with no way to ask, nothing runs', () async {
      final silent = AppMcpGateway(app);
      await silent.load();
      await silent.setAllowed('c1', true);
      final session = await silent.openConnection('DEVICE-01');
      await expectLater(silent.sendCommand(session, 'show version'), throwsStateError);
      silent.close();
    });

    test('taking access away ends it for an open session', () async {
      await gateway.setAllowed('c1', true);
      final session = await gateway.openConnection('DEVICE-01');
      await gateway.setAllowed('c1', false);
      expect(() => gateway.readOutput(session, 0), throwsStateError);
      await expectLater(gateway.sendCommand(session, 'show version'), throwsStateError);
      expect(asked, isEmpty);
    });

    test('an alias stays with its device', () async {
      await gateway.setAllowed('c1', true);
      await gateway.setAllowed('c2', true);
      await gateway.setAllowed('c1', false);
      expect(gateway.aliasOf('c2'), 'DEVICE-02');
      final reloaded = AppMcpGateway(app);
      await reloaded.load();
      expect(reloaded.aliasOf('c2'), 'DEVICE-02');
    });
  });

  test('app gateway reads output from the opened SSH tab', () async {
    PtySessionController.checkReachability = false;
    addTearDown(() => PtySessionController.checkReachability = true);
    final app = AppState();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    app.connections = [SavedConnection(id: 'device-01', name: 'DEVICE-01', host: '192.0.2.1')];
    final gateway = AppMcpGateway(app);
    await gateway.load();
    await gateway.setAllowed('device-01', true);
    final sessionId = await gateway.openConnection('DEVICE-01');
    final controller = app.tabs.last.controller as PtySessionController;
    addTearDown(() {
      gateway.close();
      controller.dispose();
      app.dispose();
    });
    controller.debugReceiveOutput('device prompt> ');
    final output = gateway.readOutput(sessionId, 0);
    expect(output['output'], 'device prompt> ');
    expect(output['cursor'], 15);
    expect(output['device_type'], 'Unknown');
    app.connections.single.device = DeviceKind.paloalto;
    expect(gateway.readOutput(sessionId, 15)['device_type'], 'Palo Alto');
  });

  testWidgets('Settings shows local MCP controls', (tester) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      (call) async => call.method.startsWith('is') ? false : null,
    );
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final app = AppState();
    final server = McpServer(_FakeGateway(), port: 0);
    addTearDown(server.dispose);
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<AppState>.value(value: app),
        ChangeNotifierProvider<McpServer>.value(value: server),
      ],
      child: const MaterialApp(home: SettingsScreen()),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Allow MCP access'), findsOneWidget);
    expect(find.byType(Switch), findsWidgets, reason: 'MCP access, and beta updates');
    expect(server.enabled, isFalse);
  });
}
