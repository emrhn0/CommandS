import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:commands/providers/app_state.dart';
import 'package:commands/models/models.dart';
import 'package:commands/screens/settings_screen.dart';
import 'package:commands/services/mcp_catalog.dart';
import 'package:commands/services/storage_service.dart';
import 'package:commands/services/pty_session.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:commands/services/mcp_server.dart';

class _ClosingGateway extends _FakeGateway {
  int closed = 0;

  @override
  void close() => closed++;
}

class _FakeGateway implements McpGateway {
  String? sent;

  @override
  Future<Map<String, Object>> createFolder(Map<String, dynamic> args) => throw UnimplementedError();

  @override
  Future<Map<String, Object>> createConnections(Map<String, dynamic> args) => throw UnimplementedError();

  @override
  List<Map<String, Object>> listConnections() => [
    {'id': 'device-01', 'name': 'DEVICE-01', 'device_type': 'Palo Alto'},
  ];

  @override
  List<Map<String, Object>> listSessions() => [
    {
      'session_id': 'session-01',
      'connection_id': 'device-01',
      'status': 'running',
    },
  ];

  @override
  Future<String> openConnection(String connectionId, {bool newSession = false}) async {
    if (connectionId != 'device-01') throw ArgumentError('Unknown connection');
    return newSession ? 'session-02' : 'session-01';
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

  test('MCP creates a subfolder and saves a batch with approval, without opening sessions', () async {
    final app = AppState();
    await app.ready;
    await app.addFolder('CUSTOMER-A');
    await app.upsertConnection(SavedConnection(
      name: 'EXISTING', host: '192.0.2.10', folderId: app.folders.single.id,
      rememberPassword: true, password: 'example-password',
    ));
    final approvals = <McpCatalogApproval>[];
    final gateway = AppMcpGateway(app, approveCatalog: (request) async {
      approvals.add(request);
      return true;
    });
    final server = McpServer(gateway, port: 0);
    addTearDown(app.dispose);
    addTearDown(gateway.dispose);
    addTearDown(server.dispose);
    await server.start(testToken: 'a' * 32);

    Future<Map<String, dynamic>> call(String tool, Map<String, Object> args) async {
      final (status, body) = await _request(server.url!, {
        'jsonrpc': '2.0', 'id': 1, 'method': 'tools/call',
        'params': {'name': tool, 'arguments': args},
      });
      expect(status, 200);
      return body!['result'] as Map<String, dynamic>;
    }

    Object? result(Map<String, dynamic> response) {
      expect(response['isError'], isNull, reason: '$response');
      return jsonDecode(response['content'][0]['text'] as String);
    }

    const path = ['CUSTOMER-A', 'Switch'];
    const request = {
      'folder_path': path,
      'connections': [
        {'name': 'DEVICE-01', 'host': '192.0.2.11', 'device_type': 'aruba'},
        {'name': 'DEVICE-02', 'host': '192.0.2.12', 'protocol': 'rdp'},
        {'name': 'DEVICE-01 again', 'host': '192.0.2.11'},
        {'name': 'A different name', 'host': '192.0.2.10'},
      ],
    };
    expect((await call('create_connections', request))['isError'], isTrue);
    expect(approvals, isEmpty);
    expect(result(await call('create_folder', {'path': path, 'kind': 'network'})), {'created': true});
    expect(result(await call('create_folder', {'path': ['customer-a', 'switch']})), {'created': false});
    expect(result(await call('create_connections', request)), {'created': 2, 'skipped': 2});
    expect(result(await call('create_connections', request)), {'created': 0, 'skipped': 4});
    expect(approvals, hasLength(2));
    expect(approvals.last.path, path);
    expect(approvals.last.connections, hasLength(2));
    expect(approvals.last.connections.first, contains('192.0.2.11'));

    final folders = await StorageService().loadFolders();
    final child = folders.singleWhere((f) => f.name == 'Switch');
    expect(child.parentId, folders.first.id);
    expect(child.kind, FolderKind.network);
    final saved = await StorageService().loadConnections();
    expect(saved.map((c) => c.name), ['EXISTING', 'DEVICE-01', 'DEVICE-02']);
    expect(saved.first.password, 'example-password');
    expect(saved.skip(1).map((c) => c.folderId), [child.id, child.id]);
    expect(saved[1].device, DeviceKind.aruba);
    expect(saved[1].deviceManual, isTrue);
    expect(saved[2].port, 3389);
    expect(app.tabs, isEmpty);
    expect(gateway.listConnections(), isEmpty);
  });

  test('catalog validates every row and requires permission for both writes', () async {
    final app = AppState();
    var approvals = 0;
    final catalog = McpCatalog(app, (_) async {
      approvals++;
      return false;
    });
    addTearDown(app.dispose);
    const row = {'name': 'DEVICE-01', 'host': '192.0.2.11'};
    await expectLater(catalog.createConnections({
      'folder_path': [],
      'connections': [row, {...row, 'password': 'example-password'}],
    }), throwsArgumentError);
    await expectLater(catalog.createConnections({
      'folder_path': [],
      'connections': [{...row, 'protocol': 'telnet'}],
    }), throwsArgumentError);
    expect(approvals, 0);
    await expectLater(catalog.createFolder({'path': ['CUSTOMER-A']}), throwsStateError);
    await expectLater(catalog.createConnections({
      'folder_path': [],
      'connections': [row],
    }), throwsStateError);
    expect(approvals, 2);
    expect(app.folders, isEmpty);
    expect(app.connections, isEmpty);
  });

  test('revoking MCP access invalidates a pending catalog approval', () async {
    final app = AppState();
    final asked = Completer<void>();
    final answer = Completer<bool>();
    final gateway = AppMcpGateway(app, approveCatalog: (_) {
      asked.complete();
      return answer.future;
    });
    addTearDown(app.dispose);
    addTearDown(gateway.dispose);
    final pending = gateway.createFolder({'path': ['CUSTOMER-A']});
    await asked.future;
    final failure = expectLater(pending, throwsStateError);
    gateway.close();
    answer.complete(true);
    await failure;
    expect(app.folders, isEmpty);
    expect(await StorageService().loadFolders(), isEmpty);
  });

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
        'list_sessions',
        'create_folder',
        'create_connections',
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
    expect(await call(7, 'list_sessions', {}), {
      'sessions': [
        {
          'session_id': 'session-01',
          'connection_id': 'device-01',
          'status': 'running',
        },
      ],
    });
    expect(await call(8, 'open_connection', {
      'connection_id': 'device-01',
      'new_session': true,
    }), {'session_id': 'session-02'});
    final (_, invalidOpen) = await _request(url, {
      'jsonrpc': '2.0',
      'id': 9,
      'method': 'tools/call',
      'params': {
        'name': 'open_connection',
        'arguments': {'connection_id': 'device-01', 'new_session': 'true'},
      },
    });
    expect(invalidOpen!['result']['isError'], isTrue);
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

  test('a new address locks out the old one and survives a restart', () async {
    final gateway = _ClosingGateway();
    final server = McpServer(gateway, port: 0);
    await server.start();
    final oldUrl = server.url!;
    final body = {'jsonrpc': '2.0', 'id': 1, 'method': 'tools/list'};
    expect((await _request(oldUrl, body)).$1, 200);

    await server.regenerateUrl();
    final newUrl = server.url!;
    expect(newUrl, isNot(oldUrl));
    expect(Uri.parse(newUrl).pathSegments.last, hasLength(64));
    expect(gateway.closed, 1, reason: 'sessions opened with the old address end');
    expect((await _request(oldUrl, body)).$1, 403);
    expect((await _request(newUrl, body)).$1, 200);
    server.dispose();

    final restored = McpServer(_FakeGateway(), port: 0);
    await restored.restore();
    expect(Uri.parse(restored.url!).path, Uri.parse(newUrl).path);
    await restored.stop();
    restored.dispose();
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

  test('MCP uses the saved port when enabled after a restart', () async {
    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = probe.port;
    await probe.close();
    final server = McpServer(_FakeGateway());
    addTearDown(server.dispose);
    expect(server.port, 8765);
    for (final invalid in [0, 65536]) {
      await expectLater(server.setPort(invalid), throwsArgumentError);
    }
    await server.setPort(port);
    expect(server.enabled, isFalse);

    final restored = McpServer(_FakeGateway());
    addTearDown(restored.dispose);
    await restored.restore();
    expect(restored.port, port);
    expect(restored.enabled, isFalse);
    await restored.start();
    expect(Uri.parse(restored.url!).port, port);
  });

  test('moving a running MCP server preserves sessions and replaces its URL', () async {
    final occupied = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = occupied.port;
    var released = false;
    addTearDown(() async {
      if (!released) await occupied.close();
    });
    final gateway = _ClosingGateway();
    final server = McpServer(gateway, port: 0);
    addTearDown(server.dispose);
    await server.start();
    final oldUrl = Uri.parse(server.url!);
    const ping = {'jsonrpc': '2.0', 'id': 1, 'method': 'ping'};

    await expectLater(server.setPort(port), throwsA(isA<SocketException>()));
    expect(server.url, oldUrl.toString());
    expect((await _request(server.url!, ping)).$1, 200);
    expect((await SharedPreferences.getInstance()).containsKey('commands.mcp.port'), isFalse);

    await occupied.close();
    released = true;
    await server.setPort(port);
    final newUrl = Uri.parse(server.url!);
    expect(newUrl.port, port);
    expect(newUrl.path, isNot(oldUrl.path));
    expect(gateway.closed, 0);
    expect((await _request(newUrl.toString(), ping)).$1, 200);
    expect((await _request(newUrl.replace(path: oldUrl.path).toString(), ping)).$1, 403);
    await expectLater(_request(oldUrl.toString(), ping), throwsA(isA<SocketException>()));
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

    test('lists only allowed connections, with name, address and username but no password', () async {
      expect(gateway.listConnections(), isEmpty);
      await gateway.setAllowed('c2', true);
      final listed = gateway.listConnections();
      expect(listed, [
        {
          'id': 'a1',
          'name': 'CUSTOMER-B FIREWALL',
          'host': '192.0.2.2',
          'port': 22,
          'username': 'test-user',
          'device_type': 'Palo Alto',
        },
      ]);
      expect(jsonEncode(listed), isNot(contains('CUSTOMER-A')), reason: 'not allowed');
      expect(jsonEncode(listed), isNot(contains('fake-secret')));
      expect(jsonEncode(listed), isNot(contains('password')));
      await gateway.setAllowed('c1', true);
      final unknown = gateway.listConnections().firstWhere((c) => c['id'] == gateway.aliasOf('c1'));
      expect(unknown['device_type'], 'Unknown');
    });

    test('a connection not allowed cannot be opened, by alias or real id', () async {
      await gateway.setAllowed('c1', true);
      expect(() => gateway.openConnection('c2'), throwsArgumentError);
      expect(() => gateway.openConnection('c1'), throwsArgumentError, reason: 'real ids are not names it knows');
      expect(() => gateway.openConnection('DEVICE-02'), throwsArgumentError);
      expect(() => gateway.openConnection('a2'), throwsArgumentError);
    });

    test('a tab the agent opened is marked as such; the user tab is not', () async {
      await gateway.setAllowed('c1', true);
      await app.openConnection(app.connections.first);
      final own = app.tabs.last.id;
      var notified = 0;
      gateway.addListener(() => notified++);
      final session = await gateway.openConnection('a1');
      expect(gateway.isAgentTab(session), isTrue);
      expect(gateway.isAgentTab(own), isFalse);
      expect(notified, greaterThan(0), reason: 'the tab bar redraws to show the mark');
    });

    test('parallel opens reuse a starting MCP session, never a user tab', () async {
      await gateway.setAllowed('c1', true);
      await app.openConnection(app.connections.first);
      final alias = gateway.aliasOf('c1')!;
      final sessions = await Future.wait([
        gateway.openConnection(alias),
        gateway.openConnection(alias),
      ]);
      final session = sessions.first;
      expect(sessions, [session, session]);
      expect(app.tabs, hasLength(2));
      expect(session, isNot(app.tabs.first.id));
      expect(gateway.listSessions(), [
        {'session_id': session, 'connection_id': alias, 'status': 'starting'},
      ]);

      final controller = app.tabs.last.controller as PtySessionController;
      controller.debugSetStatus(SessionStatus.running);
      expect(await gateway.openConnection(alias), session);
      expect(gateway.listSessions().single['status'], 'running');
      expect(app.tabs, hasLength(2));
    });

    test('explicit opens create a second session and dead tabs are skipped', () async {
      await gateway.setAllowed('c1', true);
      final alias = gateway.aliasOf('c1')!;
      final original = await gateway.openConnection(alias);
      final extra = await gateway.openConnection(alias, newSession: true);
      expect(extra, isNot(original));
      expect(gateway.listSessions().map((s) => s['session_id']), [original, extra]);
      expect(await gateway.openConnection(alias), original);

      final controller = app.tabs.first.controller as PtySessionController;
      controller.debugSetStatus(SessionStatus.error);
      expect(await gateway.openConnection(alias), extra);
      expect(gateway.listSessions().map((s) => s['session_id']), [extra]);

      app.closeTab(1);
      expect(gateway.listSessions(), isEmpty);
      final replacement = await gateway.openConnection(alias);
      expect(replacement, isNot(isIn([original, extra])));
      expect(gateway.listSessions().single['session_id'], replacement);
    });

    test('different saved connections at the same address use separate tabs', () async {
      app.connections[1] = SavedConnection(
        id: 'c2',
        name: app.connections.first.name,
        host: app.connections.first.host,
      );
      await gateway.setAllowedAll(['c1', 'c2'], true);
      final aliases = ['c1', 'c2'].map((id) => gateway.aliasOf(id)!).toList();
      final sessions = await Future.wait(aliases.map(gateway.openConnection));

      expect(sessions.toSet(), hasLength(2));
      expect(gateway.listSessions().map((s) => s['connection_id']), aliases);
    });

    test('editing the target prevents reuse of its old tab', () async {
      await gateway.setAllowed('c1', true);
      final alias = gateway.aliasOf('c1')!;
      final original = await gateway.openConnection(alias);
      app.connections[0] = SavedConnection(
        id: 'c1',
        name: app.connections.first.name,
        host: '198.51.100.1',
      );

      expect(gateway.listSessions(), isEmpty);
      final replacement = await gateway.openConnection(alias);
      expect(replacement, isNot(original));
      expect(gateway.listSessions().single['session_id'], replacement);
    });

    test('rotating the MCP address releases the session but leaves its tab open', () async {
      final server = McpServer(gateway, port: 0);
      addTearDown(server.dispose);
      await server.start();
      await gateway.setAllowed('c1', true);
      final alias = gateway.aliasOf('c1')!;
      final original = await gateway.openConnection(alias);

      await server.regenerateUrl();
      expect(app.tabs.single.id, original);
      expect(gateway.listSessions(), isEmpty);
      expect(() => gateway.readOutput(original, 0), throwsArgumentError);
      expect(await gateway.openConnection(alias), isNot(original));
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
      expect(asked.single.alias, 'a1');

      answer = true;
      await gateway.sendCommand(session, 'show version');
      expect(sent, ['show version\r']);
    });

    test('on a network device, show runs at once and a change still asks', () async {
      await gateway.setAllowed('c2', true);
      final session = await gateway.openConnection('DEVICE-01');
      final controller = app.tabs.last.controller as PtySessionController;
      final sent = <String>[];
      controller.writeOverride = sent.add;

      answer = false;
      await gateway.sendCommand(session, 'set cli pager off');
      await gateway.sendCommand(session, 'show system info | match sw-version');
      expect(sent, ['set cli pager off\r', 'show system info | match sw-version\r']);
      expect(asked, isEmpty);

      await expectLater(gateway.sendCommand(session, 'configure'), throwsStateError);
      expect(asked.single.command, 'configure');
      expect(sent, hasLength(2), reason: 'a refused change sends nothing');
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
      expect(gateway.listSessions(), isEmpty);
      expect(() => gateway.readOutput(session, 0), throwsStateError);
      await expectLater(gateway.sendCommand(session, 'show version'), throwsStateError);
      expect(asked, isEmpty);
    });

    test('an alias stays with its device', () async {
      await gateway.setAllowed('c1', true);
      await gateway.setAllowed('c2', true);
      await gateway.setAllowed('c1', false);
      expect(gateway.aliasOf('c2'), 'a2');
      final reloaded = AppMcpGateway(app);
      await reloaded.load();
      expect(reloaded.aliasOf('c2'), 'a2');
    });

    test('existing permissions support both short and legacy IDs', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('commands.mcp.allowed', '{"c1":4,"c2":100}');
      await gateway.load();

      expect(gateway.listConnections().map((entry) => entry['id']), ['a4', 'k0']);
      await gateway.openConnection('a4');
      expect(app.tabs.last.connectionId, 'c1');
      await gateway.openConnection('DEVICE-100');
      expect(app.tabs.last.connectionId, 'c2');
    });

    test('a revoked ID is not reassigned after a restart', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('commands.mcp.allowed', '{"c1":4,"c2":100}');
      await gateway.load();
      await gateway.setAllowed('c2', false);

      final reloaded = AppMcpGateway(app);
      addTearDown(reloaded.dispose);
      await reloaded.load();
      app.connections.add(SavedConnection(id: 'c3', name: 'DEVICE-03', host: '192.0.2.3'));
      await reloaded.setAllowed('c3', true);
      expect(reloaded.aliasOf('c3'), 'k1');
      await expectLater(reloaded.openConnection('k0'), throwsArgumentError);
      await expectLater(reloaded.openConnection('DEVICE-100'), throwsArgumentError);
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
      child: const MaterialApp(home: SettingsScreen(initialPage: SettingsPage.privacy)),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Allow MCP access'), findsOneWidget);
    expect(find.text('MCP server port'), findsOneWidget);
    expect(find.byType(Switch), findsWidgets, reason: 'MCP access, and beta updates');
    expect(server.enabled, isFalse);

    await tester.tap(find.text('Change port'));
    await tester.pumpAndSettle();
    final dialog = find.byType(AlertDialog);
    final field = find.descendant(of: dialog, matching: find.byType(TextFormField));
    await tester.enterText(field, '65536');
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
    expect(find.text('Enter a port from 1 to 65535.'), findsOneWidget);
    expect(server.port, 0);

    final probe = (await tester.runAsync(
      () => ServerSocket.bind(InternetAddress.loopbackIPv4, 0),
    ))!;
    addTearDown(probe.close);
    final port = probe.port;
    await tester.enterText(field, port.toString());
    await tester.runAsync(() async {
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await server.stop();
    });
    await tester.pumpAndSettle();
    expect(find.text('Could not use this port. It may already be in use.'), findsOneWidget);
    expect(server.port, 0);

    await tester.runAsync(() async {
      await probe.close();
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await server.start();
    });
    await tester.pumpAndSettle();
    expect(dialog, findsNothing);
    expect(find.text(port.toString()), findsOneWidget);
    expect(find.text(server.url!), findsOneWidget);
  });

  testWidgets('Settings makes a new MCP address after asking', (tester) async {
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
    await tester.runAsync(() => server.start(testToken: 'd' * 32));
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<AppState>.value(value: app),
        ChangeNotifierProvider<McpServer>.value(value: server),
      ],
      child: const MaterialApp(home: SettingsScreen(initialPage: SettingsPage.privacy)),
    ));
    await tester.pumpAndSettle();
    final before = server.url!;
    expect(find.text(before), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('mcp-new-url')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(server.url, before, reason: 'cancel keeps the address');

    await tester.tap(find.byKey(const ValueKey('mcp-new-url')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'New address'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
    expect(server.url, isNot(before));
    expect(find.text(server.url!), findsOneWidget);
    await tester.runAsync(server.stop);
  });

  testWidgets('Settings picks MCP connections from the folder tree', (tester) async {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      (call) async => call.method.startsWith('is') ? false : null,
    );
    tester.view.physicalSize = const Size(1200, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final app = AppState();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await app.addFolder('CUSTOMER-A');
      final a = app.folders.single.id;
      await app.addFolder('Site 1', parentId: a);
      final site = app.folders.firstWhere((f) => f.name == 'Site 1').id;
      await app.upsertConnection(SavedConnection(name: 'SWITCH-01', host: '192.0.2.1', folderId: a));
      await app.upsertConnection(SavedConnection(name: 'SWITCH-02', host: '192.0.2.2', folderId: site));
      await app.upsertConnection(SavedConnection(name: 'SWITCH-03', host: '192.0.2.3', folderId: site));
      await app.upsertConnection(SavedConnection(
        name: 'SERVER-01', host: '192.0.2.4', folderId: a, protocol: ConnectionProtocol.rdp,
      ));
    });
    final gateway = AppMcpGateway(app);
    final server = McpServer(gateway, port: 0);
    addTearDown(server.dispose);
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<AppState>.value(value: app),
        ChangeNotifierProvider<McpServer>.value(value: server),
      ],
      child: const MaterialApp(home: SettingsScreen(initialPage: SettingsPage.privacy)),
    ));
    await tester.pumpAndSettle();

    Finder row(String label) => find.ancestor(
          of: find.text(label),
          matching: find.byWidgetPredicate(
            (w) => w.key is ValueKey && '${(w.key as ValueKey).value}'.startsWith('mcp-'),
          ),
        ).first;
    Finder box(String label) => find.descendant(of: row(label), matching: find.byType(Checkbox)).first;

    // Folders start closed; RDP connections are not offered at all.
    expect(find.text('CUSTOMER-A'), findsOneWidget);
    expect(find.text('SWITCH-01'), findsNothing);
    expect(find.text('0 of 3 allowed'), findsOneWidget);

    // Ticking a folder allows everything in it, subfolders included.
    await tester.tap(box('CUSTOMER-A'));
    await tester.pumpAndSettle();
    expect(gateway.allowedConnections.map((c) => c.name).toSet(), {'SWITCH-01', 'SWITCH-02', 'SWITCH-03'});
    expect(find.text('3 of 3 allowed'), findsOneWidget);
    // The internal MCP id is not shown next to a connection:
    // the checkbox already says it is allowed, and the agent is sent the
    // real name now, so the id would only confuse.
    expect(find.text(gateway.aliasOf(app.connections.first.id)!), findsNothing);

    // Opening it shows the tree; unticking one leaves the folder half-ticked.
    await tester.tap(find.text('CUSTOMER-A'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Site 1'));
    await tester.pumpAndSettle();
    await tester.tap(box('SWITCH-02'));
    await tester.pumpAndSettle();
    expect(gateway.isAllowed(app.connections.firstWhere((c) => c.name == 'SWITCH-02').id), isFalse);
    expect(tester.widget<Checkbox>(box('CUSTOMER-A')).value, isNull);
    expect(find.text('2/3'), findsOneWidget);

    // A half-ticked folder ticks the rest; ticked again, it clears.
    await tester.tap(box('CUSTOMER-A'));
    await tester.pumpAndSettle();
    expect(gateway.allowedConnections, hasLength(3));
    await tester.tap(box('CUSTOMER-A'));
    await tester.pumpAndSettle();
    expect(gateway.allowedConnections, isEmpty);

    // The search narrows the tree to matching connections.
    await tester.enterText(find.byKey(const ValueKey('mcp-search')), '03');
    await tester.pumpAndSettle();
    expect(find.text('SWITCH-03'), findsOneWidget);
    expect(find.text('SWITCH-01'), findsNothing);
  });

  test('allowing several at once keeps each anonymous name', () async {
    SharedPreferences.setMockInitialValues({});
    final app = AppState();
    final gateway = AppMcpGateway(app);
    await gateway.setAllowed('a', true);
    await gateway.setAllowedAll(['b', 'a', 'c'], true);
    expect(gateway.aliasOf('a'), 'a1');
    expect(gateway.aliasOf('b'), 'a2');
    expect(gateway.aliasOf('c'), 'a3');
    await gateway.setAllowedAll(['a', 'c'], false);
    expect(gateway.isAllowed('a'), isFalse);
    expect(gateway.aliasOf('b'), 'a2');
    final saved = jsonDecode((await SharedPreferences.getInstance()).getString('commands.mcp.allowed')!);
    expect(saved, {'b': 2});
  });

  test('9,999 granted connections get distinct short IDs', () async {
    final app = AppState();
    await app.ready;
    addTearDown(app.dispose);
    final gateway = AppMcpGateway(app);
    addTearDown(gateway.dispose);
    final keys = List.generate(9999, (i) => 'connection-${i + 1}');
    await gateway.setAllowedAll(keys, true);

    final ids = keys.map((key) => gateway.aliasOf(key)!).toSet();
    expect(ids, hasLength(9999));
    expect(ids.every(RegExp(r'^[a-z]{1,3}[0-9]$').hasMatch), isTrue);
    expect(gateway.aliasOf(keys.last), 'all9');
  });
}
