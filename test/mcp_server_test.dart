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
    {'id': 'device-01', 'name': 'DEVICE-01'},
  ];

  @override
  Future<String> openConnection(String connectionId) async {
    if (connectionId != 'device-01') throw ArgumentError('Unknown connection');
    return 'session-01';
  }

  @override
  int sendCommand(String sessionId, String command) {
    if (sessionId != 'session-01') throw ArgumentError('Unknown session');
    sent = command;
    return 5;
  }

  @override
  Map<String, Object?> readOutput(String sessionId, int cursor) => {
    'output': 'ok',
    'cursor': cursor + 2,
    'status': 'running',
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
      {'id': 'device-01', 'name': 'DEVICE-01'},
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

  test('app gateway reads output from the opened SSH tab', () async {
    PtySessionController.checkReachability = false;
    addTearDown(() => PtySessionController.checkReachability = true);
    final app = AppState();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    app.connections = [SavedConnection(id: 'device-01', name: 'DEVICE-01', host: '192.0.2.1')];
    final gateway = AppMcpGateway(app);
    final sessionId = await gateway.openConnection('device-01');
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
    expect(find.byType(Switch), findsOneWidget);
    expect(server.enabled, isFalse);
  });
}
