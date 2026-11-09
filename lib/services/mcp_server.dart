import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app_version.dart';
import '../models/models.dart';
import '../providers/app_state.dart';
import 'pty_session.dart';

/// What the user is asked before a command reaches a device. The real
/// connection name is shown only here, on this computer.
class McpApproval {
  const McpApproval({required this.connectionName, required this.alias, required this.command});
  final String connectionName;
  final String alias;
  final String command;
}

/// Only saved SSH connections the user allowed one by one are exposed, under
/// anonymous names (`DEVICE-01`...). Credentials, hosts and real names are
/// never in the tool results, and every command waits for the user's yes.
abstract class McpGateway {
  List<Map<String, String>> listConnections();
  Future<String> openConnection(String connectionId);
  Future<int> sendCommand(String sessionId, String command);
  Map<String, Object?> readOutput(String sessionId, int cursor);
  void close();
}

class AppMcpGateway extends ChangeNotifier implements McpGateway {
  AppMcpGateway(this.app, {this.approve});

  final AppState app;

  /// Asks the user about one command. No answer, or no way to ask, is a no.
  final Future<bool> Function(McpApproval approval)? approve;

  final _sessions = <String, _CapturedSession>{};

  /// Allowed connection ids, each with the number of its anonymous name. The
  /// number stays with a connection, so a name the agent saw keeps meaning
  /// the same device.
  final Map<String, int> _allowed = {};
  static const _allowedKey = 'commands.mcp.allowed';

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_allowedKey);
    _allowed.clear();
    if (raw != null) {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        decoded.forEach((k, v) {
          if (k is String && v is int) _allowed[k] = v;
        });
      }
    }
    notifyListeners();
  }

  bool isAllowed(String connectionId) => _allowed.containsKey(connectionId);

  /// The anonymous name an allowed connection is shown to the agent under.
  String? aliasOf(String connectionId) {
    final n = _allowed[connectionId];
    return n == null ? null : 'DEVICE-${n.toString().padLeft(2, '0')}';
  }

  Future<void> setAllowed(String connectionId, bool allowed) async {
    if (allowed) {
      final next = _allowed.values.fold(0, max) + 1;
      _allowed.putIfAbsent(connectionId, () => next);
    } else {
      _allowed.remove(connectionId);
    }
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_allowedKey, jsonEncode(_allowed));
  }

  /// Allowed SSH connections that still exist, by anonymous name.
  Iterable<SavedConnection> get allowedConnections => app.connections.where(
    (c) => c.protocol == ConnectionProtocol.ssh && isAllowed(c.id),
  );

  SavedConnection _byAlias(String alias) {
    for (final c in allowedConnections) {
      if (aliasOf(c.id) == alias) return c;
    }
    throw ArgumentError('Connection not found, or not allowed for this agent.');
  }

  @override
  List<Map<String, String>> listConnections() => [
    for (final c in allowedConnections) {'id': aliasOf(c.id)!, 'name': aliasOf(c.id)!},
  ];

  @override
  Future<String> openConnection(String connectionId) async {
    final connection = _byAlias(connectionId);
    final before = app.tabs.length;
    final error = await app.openConnection(connection);
    if (error != null) throw StateError(error);
    if (app.tabs.length <= before) throw StateError('Session was not opened.');
    final tab = app.tabs.last;
    final controller = tab.controller;
    if (controller is! PtySessionController) {
      throw StateError('Not an SSH session.');
    }
    _sessions[tab.id] = _CapturedSession(controller, connection.id);
    return tab.id;
  }

  _CapturedSession _session(String id) {
    final session = _sessions[id];
    if (session == null ||
        !app.tabs.any(
          (t) => t.id == id && identical(t.controller, session.controller),
        )) {
      session?.close();
      _sessions.remove(id);
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
    final session = _session(sessionId);
    if (session.controller.status == SessionStatus.closed ||
        session.controller.status == SessionStatus.error) {
      throw StateError('Session is closed.');
    }
    final connection = app.connections.firstWhere((c) => c.id == session.connectionId);
    final ask = approve;
    final yes = ask != null &&
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
  Map<String, Object?> readOutput(String sessionId, int cursor) =>
      _session(sessionId).read(cursor);

  @override
  void close() {
    for (final session in _sessions.values) {
      session.close();
    }
    _sessions.clear();
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
  McpServer(this.gateway, {this.port = 8765});

  final McpGateway gateway;
  final int port;
  HttpServer? _server;
  Future<void>? _starting;
  bool _disposed = false;
  String? _token;
  String? error;
  static const _enabledKey = 'commands.mcp.enabled';
  static const _tokenKey = 'commands.mcp.token';
  static const _maxBody = 1024 * 1024;

  bool get enabled => _server != null;
  String? get url =>
      enabled ? 'http://127.0.0.1:${_server!.port}/mcp/$_token' : null;

  Future<void> restore() async {
    final prefs = await SharedPreferences.getInstance();
    if (!_disposed && prefs.getBool(_enabledKey) == true) await start();
  }

  Future<void> start({String? testToken}) {
    if (enabled || _disposed) return Future<void>.value();
    return _starting ??= _start(testToken).whenComplete(() => _starting = null);
  }

  Future<void> _start(String? testToken) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (_disposed) return;
      final saved = prefs.getString(_tokenKey);
      _token =
          testToken ??
          (saved != null && saved.length >= 32 ? saved : _newToken());
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
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

  Future<void> stop() async {
    await _starting;
    final server = _server;
    _server = null;
    await server?.close(force: true);
    gateway.close();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_enabledKey, false);
    if (!_disposed) notifyListeners();
  }

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
    if (!validHost || !validOrigin || request.uri.path != '/mcp/$_token') {
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
            'instructions': 'Use only the connections listed; they have anonymous names. The user approves every command in CommandS before it runs, so a command can be refused. Open a session, send a single command, then read output using the returned cursor. Session output is asynchronous; poll read_output until the expected prompt or result appears. Never assume a command has finished just because one read returned no text.',
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
        case 'open_connection':
          value = {
            'session_id': await gateway.openConnection(
              _string(args, 'connection_id'),
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
      'description': 'List the SSH connections the user allowed for this agent, by anonymous ID. No real names, hostnames or credentials are returned.',
      'inputSchema': {'type': 'object', 'properties': <String, Object>{}},
    },
    {
      'name': 'open_connection',
      'description': 'Open a saved SSH connection in a CommandS tab and return its MCP session ID.',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'connection_id': {'type': 'string'},
        },
        'required': ['connection_id'],
      },
    },
    {
      'name': 'send_command',
      'description': 'Send one line followed by Enter to an MCP-opened SSH session. The user is asked to allow each command first; a refusal is returned as an error. Returns the output cursor from before the send. Commands execute on the remote device with the saved connection privileges.',
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
      'description': 'Read up to 8192 characters of terminal output from cursor. Use the returned cursor for the next read; output can arrive later.',
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
