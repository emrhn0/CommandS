import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app_version.dart';
import '../models/models.dart';
import '../providers/app_state.dart';
import 'mcp_catalog.dart';
import 'mcp_command_policy.dart';
import 'pty_session.dart';

/// What the user is asked before a command reaches a device. The real
/// connection name is shown only here, on this computer.
class McpApproval {
  const McpApproval({required this.connectionName, required this.alias, required this.command});
  final String connectionName;
  final String alias;
  final String command;
}

/// Only saved SSH connections the user allowed one by one are exposed, each
/// with a stable id (`a1`...), its name, host address, port and device
/// type and username, so the agent can tell which device is which and log in
/// context is clear. The password is never in the tool results. On network devices,
/// show and display commands run at once; every other command waits for the
/// user's yes (see mcp_command_policy.dart).
abstract class McpGateway {
  List<Map<String, Object>> listConnections();
  List<Map<String, Object>> listSessions();
  Future<String> openConnection(String connectionId, {bool newSession = false});
  Future<Map<String, Object>> createFolder(Map<String, dynamic> args);
  Future<Map<String, Object>> createConnections(Map<String, dynamic> args);
  Future<int> sendCommand(String sessionId, String command);
  Map<String, Object?> readOutput(String sessionId, int cursor);
  void close();
}

class AppMcpGateway extends ChangeNotifier implements McpGateway {
  AppMcpGateway(this.app, {this.approve, Future<bool> Function(McpCatalogApproval)? approveCatalog})
      : _catalog = McpCatalog(app, approveCatalog);

  final AppState app;
  final McpCatalog _catalog;

  @override
  Future<Map<String, Object>> createFolder(Map<String, dynamic> args) => _catalog.createFolder(args);

  @override
  Future<Map<String, Object>> createConnections(Map<String, dynamic> args) => _catalog.createConnections(args);

  /// Asks the user about one command. No answer, or no way to ask, is a no.
  final Future<bool> Function(McpApproval approval)? approve;

  final _sessions = <String, _CapturedSession>{};

  /// Allowed connection ids, each with the number of its id. The
  /// number stays with a connection, so a name the agent saw keeps meaning
  /// the same device.
  final Map<String, int> _allowed = {};
  static const _allowedKey = 'commands.mcp.allowed';
  static const _lastAliasKey = 'commands.mcp.lastAlias';
  int _lastAlias = 0;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_allowedKey);
    _allowed.clear();
    if (raw != null) {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        decoded.forEach((k, v) {
          if (k is String && v is int && v > 0) _allowed[k] = v;
        });
      }
    }
    // Older settings only have the map. Once an ID has been issued, keep
    // the counter even if that connection's permission is later removed.
    _lastAlias = _allowed.values.fold(prefs.getInt(_lastAliasKey) ?? 0, max);
    notifyListeners();
  }

  bool isAllowed(String connectionId) => _allowed.containsKey(connectionId);

  /// The id (`a1`...) an allowed connection is shown to the agent under.
  String? aliasOf(String connectionId) {
    final n = _allowed[connectionId];
    return n == null ? null : _shortAlias(n);
  }

  static String _shortAlias(int number) {
    // Letter groups go a, b, ..., z, aa, ab, ...; the last digit is decimal.
    var group = number ~/ 10 + 1;
    var letters = '';
    while (group > 0) {
      group--;
      letters = String.fromCharCode(0x61 + group % 26) + letters;
      group ~/= 26;
    }
    return '$letters${number % 10}';
  }

  static String _legacyAlias(int number) => 'DEVICE-${number.toString().padLeft(2, '0')}';

  Future<void> setAllowed(String connectionId, bool allowed) => setAllowedAll([connectionId], allowed);

  /// Allows or removes several connections at once, as when a whole folder is
  /// ticked in Settings. New ones get the next unused numbers in the order given.
  Future<void> setAllowedAll(Iterable<String> connectionIds, bool allowed) async {
    for (final id in connectionIds) {
      if (allowed) {
        _allowed.putIfAbsent(id, () => ++_lastAlias);
      } else {
        _allowed.remove(id);
      }
    }
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    // Persist the counter first. A failed second write may skip IDs, but a
    // later grant cannot hand out the same number to another connection.
    if (!await prefs.setInt(_lastAliasKey, _lastAlias)) {
      throw StateError('Could not save the MCP connection ID counter.');
    }
    await prefs.setString(_allowedKey, jsonEncode(_allowed));
  }

  /// Allowed SSH connections that still exist.
  Iterable<SavedConnection> get allowedConnections => app.connections.where(
    (c) => c.protocol == ConnectionProtocol.ssh && isAllowed(c.id),
  );

  SavedConnection _byAlias(String alias) {
    for (final c in allowedConnections) {
      final number = _allowed[c.id]!;
      if (_shortAlias(number) == alias || _legacyAlias(number) == alias) return c;
    }
    throw ArgumentError('Connection not found, or not allowed for this agent.');
  }

  /// What the agent is told about each allowed connection. The password
  /// stays in CommandS: the session logs in on its own.
  @override
  List<Map<String, Object>> listConnections() => [
    for (final c in allowedConnections)
      {
        'id': aliasOf(c.id)!,
        'name': c.name,
        'host': c.host,
        'port': c.port,
        'username': app.resolved(c).username,
        'device_type': c.device?.label ?? 'Unknown',
      },
  ];

  /// Whether a tab was opened by the agent, for the mark on its tab.
  bool isAgentTab(String tabId) => _sessions.containsKey(tabId);

  Iterable<MapEntry<String, _CapturedSession>> get _liveSessions sync* {
    for (final tab in app.tabs) {
      final session = _sessions[tab.id];
      if (session != null &&
          identical(tab.controller, session.controller) &&
          session.isOpen) {
        yield MapEntry(tab.id, session);
      }
    }
  }

  @override
  List<Map<String, Object>> listSessions() {
    final allowed = {for (final c in allowedConnections) c.id: c};
    return [
      for (final entry in _liveSessions)
        if (allowed[entry.value.connectionId] case final connection?
            when entry.value.matches(connection))
          {
            'session_id': entry.key,
            'connection_id': aliasOf(connection.id)!,
            'status': entry.value.controller.status.name,
          },
    ];
  }

  @override
  Future<String> openConnection(String connectionId, {bool newSession = false}) async {
    final connection = _byAlias(connectionId);
    if (!newSession) {
      for (final entry in _liveSessions) {
        if (entry.value.matches(connection)) return entry.key;
      }
    }
    // Open and register the tab before yielding to another MCP request.
    final tab = app.openConnectionTab(connection);
    final controller = tab.controller;
    if (controller is! PtySessionController) {
      throw StateError('Not an SSH session.');
    }
    _sessions[tab.id] = _CapturedSession(controller, connection.id);
    notifyListeners();
    return tab.id;
  }

  _CapturedSession _session(String id) {
    final session = _sessions[id];
    if (session == null ||
        !app.tabs.any(
          (t) => t.id == id && identical(t.controller, session.controller),
        )) {
      session?.close();
      if (_sessions.remove(id) != null) notifyListeners();
      throw ArgumentError('MCP session not found.');
    }
    // Access taken away after the session was opened ends it for the agent.
    if (!isAllowed(session.connectionId)) {
      throw StateError('This connection is no longer allowed for this agent.');
    }
    return session;
  }

  @override
  Future<int> sendCommand(String sessionId, String command) async {
    if (command.isEmpty ||
        command.length > 4096 ||
        command.contains('\r') ||
        command.contains('\n') ||
        command.contains('\u0000')) {
      throw ArgumentError('Command must be one line of 1–4096 characters.');
    }
    // Control and invisible characters would reach the device as keys: a
    // Ctrl+U or backspace can erase what the user saw or the policy checked.
    if (hasHiddenCharacters(command)) {
      throw ArgumentError('Command must not contain control or invisible characters.');
    }
    final session = _session(sessionId);
    if (!session.isOpen) {
      throw StateError('Session is closed.');
    }
    final connection = app.connections.firstWhere((c) => c.id == session.connectionId);
    final ask = approve;
    final yes = runsWithoutAsking(command, connection.device) ||
        ask != null &&
        await ask(McpApproval(
          connectionName: connection.name,
          alias: aliasOf(connection.id)!,
          command: command,
        ));
    if (!yes) throw StateError('The user did not allow this command.');
    // Checked again: the session may have closed while the user decided.
    final current = _session(sessionId);
    final cursor = current.end;
    current.controller.sendInput('$command\r');
    return cursor;
  }

  @override
  Map<String, Object?> readOutput(String sessionId, int cursor) {
    final session = _session(sessionId);
    final index = app.connections.indexWhere(
      (c) => c.id == session.connectionId,
    );
    return {
      ...session.read(cursor),
      'device_type': index < 0
          ? 'Unknown'
          : app.connections[index].device?.label ?? 'Unknown',
    };
  }

  @override
  void close() {
    _catalog.revokePendingRequests();
    for (final session in _sessions.values) {
      session.close();
    }
    _sessions.clear();
    notifyListeners();
  }
}

class _CapturedSession {
  _CapturedSession(this.controller, this.connectionId) {
    _subscription = controller.outputStream.listen(_append);
  }

  final PtySessionController controller;
  final String connectionId;
  late final StreamSubscription<String> _subscription;
  String _output = '';
  int _start = 0;
  static const _retain = 65536;
  static const _page = 8192;

  int get end => _start + _output.length;

  bool get isOpen =>
      controller.status == SessionStatus.starting ||
      controller.status == SessionStatus.running;

  // Editing a saved address must not route new requests to the old device.
  bool matches(SavedConnection connection) =>
      connectionId == connection.id &&
      controller.host == connection.host &&
      controller.port == connection.port;

  void _append(String text) {
    _output += text;
    if (_output.length > _retain) {
      final drop = _output.length - _retain;
      _output = _output.substring(drop);
      _start += drop;
    }
  }

  Map<String, Object?> read(int cursor) {
    if (cursor < 0 || cursor > end) {
      throw ArgumentError('Invalid output cursor.');
    }
    final actual = max(cursor, _start);
    final next = min(actual + _page, end);
    return {
      'output': _output.substring(actual - _start, next - _start),
      'cursor': next,
      'has_more': next < end,
      'truncated': cursor < _start,
      'status': controller.status.name,
      if (controller.lastError != null) 'error': controller.lastError,
    };
  }

  void close() => unawaited(_subscription.cancel());
}

/// A local, opt-in Streamable HTTP MCP endpoint. A random URL path is the
/// bearer secret so a Secure MCP Tunnel can forward without custom headers.
class McpServer extends ChangeNotifier {
  McpServer(this.gateway, {this._port = 8765});

  final McpGateway gateway;
  int _port;
  HttpServer? _server;
  Future<void>? _listenerChange;
  bool _disposed = false;
  String? _token;
  String? error;
  static const _enabledKey = 'commands.mcp.enabled';
  static const _tokenKey = 'commands.mcp.token';
  static const _portKey = 'commands.mcp.port';
  static const _maxBody = 1024 * 1024;

  int get port => _port;
  bool get enabled => _server != null;
  String? get url =>
      enabled ? 'http://127.0.0.1:${_server!.port}/mcp/$_token' : null;

  static bool isValidPort(int port) => port >= 1 && port <= 65535;

  // Keep settings operations from binding or closing each other's listeners.
  Future<void> _withListener(Future<void> Function() change) {
    Future<void> run() async {
      if (!_disposed) await change();
    }

    final next = _listenerChange?.then(
      (_) => run(),
      onError: (Object _, StackTrace _) => run(),
    ) ?? run();
    _listenerChange = next;
    return next.whenComplete(() {
      if (identical(_listenerChange, next)) _listenerChange = null;
    });
  }

  Future<void> restore() => _withListener(() async {
    final prefs = await SharedPreferences.getInstance();
    if (_disposed || enabled) return;
    if (prefs.getBool(_enabledKey) == true) {
      await _start(null);
    } else {
      _loadPort(prefs);
      notifyListeners();
    }
  });

  void _loadPort(SharedPreferences prefs) {
    final saved = prefs.get(_portKey);
    if (saved is int && isValidPort(saved)) _port = saved;
  }

  Future<void> start({String? testToken}) => _withListener(() async {
    if (!enabled) await _start(testToken);
  });

  Future<void> _start(String? testToken) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (_disposed) return;
      _loadPort(prefs);
      final saved = prefs.getString(_tokenKey);
      _token =
          testToken ??
          (saved != null && saved.length >= 32 ? saved : _newToken());
      final HttpServer server;
      try {
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
      } on SocketException {
        // Someone else holds the port, perhaps another user of this machine
        // waiting for the agent to send the old address. That address is no
        // longer safe, so it is replaced; the agent needs the new one.
        if (testToken == null) await prefs.setString(_tokenKey, _newToken());
        rethrow;
      }
      if (_disposed) {
        await server.close(force: true);
        return;
      }
      _server = server;
      server.listen(_handle);
      if (testToken == null) {
        await prefs.setString(_tokenKey, _token!);
        await prefs.setBool(_enabledKey, true);
      }
      error = null;
    } catch (e) {
      final server = _server;
      await server?.close(force: true);
      error = e.toString();
      _server = null;
    }
    if (!_disposed) notifyListeners();
  }

  Future<void> stop() => _withListener(() async {
    final server = _server;
    _server = null;
    await server?.close(force: true);
    gateway.close();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_enabledKey, false);
    if (!_disposed) notifyListeners();
  });

  /// Check the new port before releasing the old listener. The terminal
  /// sessions belong to the gateway and survive the switch.
  Future<void> setPort(int port) => _withListener(() async {
    if (!isValidPort(port)) throw ArgumentError.value(port, 'port');
    if (_port == port) return;
    final previous = _server;
    HttpServer? replacement;
    try {
      final listener = replacement = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        port,
      );
      if (_disposed) return;
      final prefs = await SharedPreferences.getInstance();
      // A client using the old port might send its URL to the next listener
      // there. Issue a fresh secret before publishing the new address.
      final token = _newToken();
      final oldToken = prefs.getString(_tokenKey);
      final oldPort = prefs.get(_portKey);
      try {
        if (!await prefs.setString(_tokenKey, token) ||
            !await prefs.setInt(_portKey, port)) {
          throw StateError('Could not persist the MCP port.');
        }
      } catch (_) {
        if (oldToken == null) {
          await prefs.remove(_tokenKey);
        } else {
          await prefs.setString(_tokenKey, oldToken);
        }
        if (oldPort is int) {
          await prefs.setInt(_portKey, oldPort);
        } else {
          await prefs.remove(_portKey);
        }
        rethrow;
      }
      if (_disposed) return;
      _port = port;
      _token = token;
      error = null;
      if (previous != null) {
        _server = listener;
        listener.listen(_handle);
        replacement = null;
        await previous.close(force: true);
      }
    } finally {
      await replacement?.close(force: true);
    }
    if (!_disposed) notifyListeners();
  });

  /// Gives the server a new secret path. The old address stops working at
  /// once and sessions opened through it are let go; the tabs stay open.
  Future<void> regenerateUrl() => _withListener(() async {
    final prefs = await SharedPreferences.getInstance();
    if (_disposed) return;
    _token = _newToken();
    gateway.close();
    await prefs.setString(_tokenKey, _token!);
    if (!_disposed) notifyListeners();
  });

  static String _newToken() {
    final random = Random.secure();
    return List<int>.generate(
      32,
      (_) => random.nextInt(256),
    ).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    response.headers.set('Cache-Control', 'no-store');
    response.headers.set('Connection', 'close');
    final host = request.headers.value(HttpHeaders.hostHeader);
    final validHost =
        host == '127.0.0.1:${_server?.port}' ||
        host == 'localhost:${_server?.port}';
    final origin = request.headers.value('Origin');
    final validOrigin =
        origin == null ||
        origin == 'http://127.0.0.1:${_server?.port}' ||
        origin == 'http://localhost:${_server?.port}';
    if (!validHost || !validOrigin || !_sameSecret(request.uri.path, '/mcp/$_token')) {
      response.statusCode = HttpStatus.forbidden;
      await response.close();
      return;
    }
    if (request.method != 'POST') {
      response.statusCode = HttpStatus.methodNotAllowed;
      await response.close();
      return;
    }
    if (request.headers.contentType?.mimeType != 'application/json') {
      response.statusCode = HttpStatus.unsupportedMediaType;
      await response.close();
      return;
    }
    try {
      final bytes = <int>[];
      await for (final chunk in request) {
        bytes.addAll(chunk);
        if (bytes.length > _maxBody) {
          response.statusCode = HttpStatus.requestEntityTooLarge;
          await response.close();
          return;
        }
      }
      final message = jsonDecode(utf8.decode(bytes));
      if (message is! Map<String, dynamic> ||
          message['jsonrpc'] != '2.0' ||
          message['method'] is! String) {
        _json(
          response,
          _rpcError(
            message is Map ? message['id'] : null,
            -32600,
            'Invalid request',
          ),
        );
        return;
      }
      final id = message['id'];
      if (id == null) {
        response.statusCode = HttpStatus.accepted;
        await response.close();
        return;
      }
      final method = message['method'] as String;
      final params = message['params'] is Map<String, dynamic>
          ? message['params'] as Map<String, dynamic>
          : <String, dynamic>{};
      Object? result;
      switch (method) {
        case 'initialize':
          final requested = params['protocolVersion'];
          result = {
            'protocolVersion':
                ['2025-11-25', '2025-06-18', '2025-03-26'].contains(requested)
                ? requested
                : '2025-11-25',
            'capabilities': {'tools': {}},
            'serverInfo': {'name': 'commands', 'version': appVersion},
            'instructions': 'Use only the connections listed, by their id. Each has its name, host address, port and username; the login itself is handled by CommandS, so no password is needed or given. '
                'Use device_type to choose device-specific commands. Unknown means inspect the banner and prompt before sending a command; do not assume a Unix shell. '
                'On network devices, show and display commands (and turning off paging for the session) run at once. Every other command, such as configuration changes or saving, is approved by the user in CommandS first and can be refused. '
                'Open a session, send a single command, then read output using the returned cursor. '
                'Session output is asynchronous; poll read_output until the expected prompt or result appears. '
                'Never assume a command has finished just because one read returned no text. '
                'To save catalog entries, use create_folder and create_connections with the destination folder path supplied by the user. '
                'CommandS asks for approval before saving new entries. Saving does not grant SSH session access.',
          };
          break;
        case 'ping':
          result = <String, Object>{};
          break;
        case 'tools/list':
          result = {'tools': _tools};
          break;
        case 'tools/call':
          result = await _call(params);
          break;
        default:
          _json(response, _rpcError(id, -32601, 'Method not found'));
          return;
      }
      _json(response, {'jsonrpc': '2.0', 'id': id, 'result': result});
    } on FormatException {
      _json(response, _rpcError(null, -32700, 'Parse error'));
    } catch (e) {
      _json(response, _rpcError(null, -32603, 'Internal error: $e'));
    }
  }

  Future<Map<String, Object?>> _call(Map<String, dynamic> params) async {
    final name = params['name'];
    final args = params['arguments'] ?? <String, dynamic>{};
    if (name is! String || args is! Map<String, dynamic>) {
      return _toolResult('Invalid tool call.', error: true);
    }
    try {
      Object? value;
      switch (name) {
        case 'list_connections':
          value = {'connections': gateway.listConnections()};
          break;
        case 'list_sessions':
          value = {'sessions': gateway.listSessions()};
          break;
        case 'create_folder':
          value = await gateway.createFolder(args);
          break;
        case 'create_connections':
          value = await gateway.createConnections(args);
          break;
        case 'open_connection':
          final newSession = args.containsKey('new_session')
              ? args['new_session']
              : false;
          if (newSession is! bool) {
            throw ArgumentError('new_session must be a boolean.');
          }
          value = {
            'session_id': await gateway.openConnection(
              _string(args, 'connection_id'),
              newSession: newSession,
            ),
          };
          break;
        case 'send_command':
          value = {
            'cursor': await gateway.sendCommand(
              _string(args, 'session_id'),
              _string(args, 'command'),
            ),
          };
          break;
        case 'read_output':
          final cursor = args['cursor'] ?? 0;
          if (cursor is! int) throw ArgumentError('cursor must be an integer.');
          value = gateway.readOutput(_string(args, 'session_id'), cursor);
          break;
        default:
          throw ArgumentError('Unknown tool.');
      }
      return _toolResult(jsonEncode(value));
    } catch (e) {
      return _toolResult('$e', error: true);
    }
  }

  static String _string(Map<String, dynamic> args, String key) {
    final value = args[key];
    if (value is! String || value.isEmpty) {
      throw ArgumentError('$key is required.');
    }
    return value;
  }

  static Map<String, Object?> _toolResult(String text, {bool error = false}) =>
      {
        'content': [
          {'type': 'text', 'text': text},
        ],
        if (error) 'isError': true,
      };

  static Map<String, Object?> _rpcError(Object? id, int code, String message) =>
      {
        'jsonrpc': '2.0',
        'id': id,
        'error': {'code': code, 'message': message},
      };

  static void _json(HttpResponse response, Object data) {
    response.headers.contentType = ContentType.json;
    final bytes = utf8.encode(jsonEncode(data));
    response.contentLength = bytes.length;
    response.add(bytes);
    unawaited(response.close());
  }

  static const _tools = [
    {
      'name': 'list_connections',
      'description': 'List the SSH connections the user allowed for this agent: id (use it to open the connection), name, host (hostname or IP address), port, username and device_type. Unknown means the type has not been identified. The password is never returned; CommandS logs in by itself.',
      'inputSchema': {'type': 'object', 'properties': <String, Object>{}},
    },
    {
      'name': 'list_sessions',
      'description': 'List open SSH sessions created through MCP for still-allowed connections. Returns session_id, connection_id and terminal status. Use session_id to resume. A running terminal may still be waiting for login or MFA; check read_output before sending commands.',
      'inputSchema': {'type': 'object', 'properties': <String, Object>{}},
    },
    {
      'name': 'create_folder',
      'description': 'Create a saved folder after local approval. Pass each name in order, e.g. ["CUSTOMER-A", "Switch"]. The parent must exist. Returns created: false if the folder already exists, without changing it.',
      'annotations': {'destructiveHint': false, 'idempotentHint': true, 'openWorldHint': false},
      'inputSchema': {
        'type': 'object',
        'additionalProperties': false,
        'properties': {
          'path': {
            'type': 'array', 'items': {'type': 'string'}, 'minItems': 1, 'maxItems': 16,
          },
          'kind': {'type': 'string', 'enum': ['network', 'firewall', 'system']},
        },
        'required': ['path'],
      },
    },
    {
      'name': 'create_connections',
      'description': 'Save one or more connections in CommandS with one local approval. Use hostname as name and the address as host when importing a table. Create any missing destination with create_folder first. Repeated host, port, protocol and username combinations are skipped across the catalog. Returns created and skipped counts.',
      'annotations': {'destructiveHint': false, 'idempotentHint': true, 'openWorldHint': false},
      'inputSchema': {
        'type': 'object',
        'additionalProperties': false,
        'properties': {
          'folder_path': {
            'type': 'array', 'items': {'type': 'string'}, 'maxItems': 16,
            'description': 'Folder names from root to leaf. Use [] for the top level.',
          },
          'connections': {
            'type': 'array', 'minItems': 1, 'maxItems': 100,
            'items': {
              'type': 'object',
              'additionalProperties': false,
              'properties': {
                'name': {'type': 'string'},
                'host': {'type': 'string'},
                'port': {'type': 'integer', 'minimum': 1, 'maximum': 65535},
                'protocol': {'type': 'string', 'enum': ['ssh', 'rdp'], 'default': 'ssh'},
                'username': {'type': 'string'},
                'device_type': {
                  'type': 'string',
                  'description': 'Optional known vendor or platform for SSH. Omit to detect automatically.',
                  'enum': ['linux', 'vmware', 'paloalto', 'fortinet', 'cisco', 'aruba', 'hpe', 'dell', 'huawei'],
                },
              },
              'required': ['name', 'host'],
            },
          },
        },
        'required': ['folder_path', 'connections'],
      },
    },
    {
      'name': 'open_connection',
      'description': 'Return a usable MCP session ID for a saved SSH connection. Reuses an open MCP tab for that connection, including one waiting for login, or opens a tab if needed. Use list_sessions to select a specific tab or new_session to open a separate one.',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'connection_id': {'type': 'string'},
          'new_session': {'type': 'boolean', 'default': false},
        },
        'required': ['connection_id'],
      },
    },
    {
      'name': 'send_command',
      'description': 'Send one line followed by Enter to an MCP-opened SSH session. On network devices, show and display commands run at once; for any other command the user is asked first, and a refusal is returned as an error. Returns the output cursor from before the send. Commands execute on the remote device with the saved connection privileges.',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'session_id': {'type': 'string'},
          'command': {'type': 'string'},
        },
        'required': ['session_id', 'command'],
      },
    },
    {
      'name': 'read_output',
      'description': 'Read up to 8192 characters of terminal output from cursor, including the current device_type. Use the returned cursor for the next read; output and device detection can arrive later.',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'session_id': {'type': 'string'},
          'cursor': {'type': 'integer', 'minimum': 0},
        },
        'required': ['session_id'],
      },
    },
  ];

  @override
  void dispose() {
    _disposed = true;
    final server = _server;
    _server = null;
    unawaited(server?.close(force: true));
    gateway.close();
    super.dispose();
  }
}

/// Compares without stopping at the first difference, so the time taken
/// does not tell how much of the address was right.
bool _sameSecret(String a, String b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
  }
  return diff == 0;
}
