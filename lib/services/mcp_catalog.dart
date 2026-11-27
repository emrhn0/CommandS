import 'dart:io';

import '../models/models.dart';
import '../providers/app_state.dart';
import 'mcp_command_policy.dart' show hasHiddenCharacters;

/// A preview of the local records an agent wants to add.
class McpCatalogApproval {
  const McpCatalogApproval({required this.path, this.connections = const [], this.kind});
  final List<String> path;
  final List<String> connections;
  final FolderKind? kind;
}

/// Saves catalog entries without opening sessions or granting MCP access.
class McpCatalog {
  McpCatalog(this.app, this.approve);

  final AppState app;
  final Future<bool> Function(McpCatalogApproval)? approve;
  bool _asking = false;
  int _generation = 0;

  void revokePendingRequests() => _generation++;

  Future<Map<String, Object>> createFolder(Map<String, dynamic> args) async {
    final generation = _generation;
    _checkKeys(args, const {'path', 'kind'});
    final path = _path(args['path'], allowRoot: false);
    final kind = FolderKind.fromName(args['kind']);
    if (args.containsKey('kind') && kind == null) {
      throw ArgumentError('kind must be network, firewall, or system.');
    }
    await _checkStorage();
    final parentPath = path.sublist(0, path.length - 1);
    final parent = _resolve(parentPath);
    final name = path.last;
    final existing = _findFolder(parent, name);
    if (existing != null) return {'created': false};
    await _confirm(McpCatalogApproval(path: path, kind: kind));
    _checkGeneration(generation);
    if (_resolve(parentPath) != parent) throw StateError('The parent folder changed. Retry the request.');
    if (_findFolder(parent, name) != null) return {'created': false};
    await app.addFolder(name, parentId: parent, kind: kind);
    return {'created': true};
  }

  Future<Map<String, Object>> createConnections(Map<String, dynamic> args) async {
    final generation = _generation;
    _checkKeys(args, const {'folder_path', 'connections'});
    final path = _path(args['folder_path'], allowRoot: true);
    final rows = args['connections'];
    if (rows is! List || rows.isEmpty || rows.length > 100) {
      throw ArgumentError('connections must contain 1 to 100 entries.');
    }
    // Validate all rows before asking for approval or saving anything.
    final connections = [for (var i = 0; i < rows.length; i++) _connection(rows[i], i + 1)];
    await _checkStorage();
    final folderId = _resolve(path);
    final pending = _newConnections(connections);
    if (pending.isEmpty) return {'created': 0, 'skipped': rows.length};

    await _confirm(
      McpCatalogApproval(
        path: path,
        connections: List.unmodifiable([
          for (final c in pending)
            '${c.name} — ${c.protocol.name.toUpperCase()} ${c.host} (port ${c.port})'
                '${c.username.isEmpty ? '' : ' — ${c.username}'}'
                '${c.device == null ? '' : ' — ${c.device!.label}'}',
        ]),
      ),
    );
    _checkGeneration(generation);
    if (_resolve(path) != folderId) throw StateError('The destination folder changed. Retry the request.');
    final additions = _newConnections(pending);
    for (final entry in additions) {
      entry.folderId = folderId;
    }
    if (additions.isNotEmpty) await app.addConnections(additions);
    return {'created': additions.length, 'skipped': rows.length - additions.length};
  }

  List<SavedConnection> _newConnections(List<SavedConnection> entries) {
    final seen = app.connections.map(AppState.connectionIdentity).toSet();
    return entries.where((c) => seen.add(AppState.connectionIdentity(c))).toList();
  }

  Future<void> _checkStorage() async {
    await app.ready;
    if (app.storageLoadFailed) throw StateError('The saved catalog could not be loaded.');
  }

  Future<void> _confirm(McpCatalogApproval request) async {
    if (_asking) throw StateError('Another catalog request is awaiting approval.');
    _asking = true;
    try {
      if (await approve?.call(request) != true) {
        throw StateError('The user did not allow this catalog request.');
      }
    } finally {
      _asking = false;
    }
  }

  void _checkGeneration(int generation) {
    if (generation != _generation) throw StateError('MCP access changed. Retry the request.');
    if (app.storageLoadFailed) throw StateError('The saved catalog could not be loaded.');
  }

  String? _resolve(List<String> path) {
    String? parent;
    for (final part in path) {
      final folder = _findFolder(parent, part);
      if (folder == null) {
        throw StateError('Folder path not found. Create the missing folder first.');
      }
      parent = folder.id;
    }
    return parent;
  }

  ConnectionFolder? _findFolder(String? parent, String name) {
    final matches = app.folders.where(
      (f) => f.parentId == parent && f.name.trim().toLowerCase() == name.toLowerCase(),
    );
    if (matches.length > 1) throw StateError('The folder path is ambiguous.');
    return matches.firstOrNull;
  }

  static List<String> _path(Object? value, {required bool allowRoot}) {
    if (value is! List || (!allowRoot && value.isEmpty) || value.length > 16) {
      throw ArgumentError('Use a folder path with ${allowRoot ? '0' : '1'} to 16 names.');
    }
    return List.unmodifiable([for (final part in value) _text(part, 'Folder name')]);
  }

  static SavedConnection _connection(Object? row, int number) {
    try {
      if (row is! Map<String, dynamic>) throw ArgumentError('Expected a connection object.');
      _checkKeys(row, const {'name', 'host', 'port', 'protocol', 'username', 'device_type'});
      final name = _text(row['name'], 'name');
      final host = _text(row['host'], 'host', max: 253);
      if (!_validHost(host)) throw ArgumentError('host must be a hostname or IP address.');
      final protocolName = row.containsKey('protocol') ? row['protocol'] : 'ssh';
      // Only what the tool schema offers; Telnet is not saved through MCP.
      final protocol = const [ConnectionProtocol.ssh, ConnectionProtocol.rdp]
          .where((p) => p.name == protocolName)
          .firstOrNull;
      if (protocol == null) throw ArgumentError('protocol must be ssh or rdp.');
      final port = row.containsKey('port') ? row['port'] : protocol.defaultPort;
      if (port is! int || port < 1 || port > 65535) {
        throw ArgumentError('port must be an integer from 1 to 65535.');
      }
      final username = row.containsKey('username') ? _text(row['username'], 'username') : '';
      if (username.isNotEmpty && protocol == ConnectionProtocol.ssh && !_sshUser.hasMatch(username)) {
        throw ArgumentError('username contains characters unsupported by SSH.');
      }
      final deviceValue = row['device_type'];
      final device = deviceValue is String ? DeviceKind.byName(deviceValue) : null;
      if (row.containsKey('device_type') &&
          (protocol != ConnectionProtocol.ssh || device == null || device == DeviceKind.windows)) {
        throw ArgumentError('device_type must be a supported SSH device type.');
      }
      return SavedConnection(
        name: name,
        host: host,
        port: port,
        protocol: protocol,
        username: username,
        device: device,
        deviceManual: device != null,
      );
    } on ArgumentError catch (error) {
      throw ArgumentError('Connection $number: ${error.message}');
    }
  }

  static final _hostname = RegExp(r'^[A-Za-z0-9_][A-Za-z0-9._-]*$');
  static final _sshUser = RegExp(r'^[A-Za-z0-9._@\\$-]+$');

  static bool _validHost(String host) {
    if (_hostname.hasMatch(host)) return true;
    if (!host.contains(':') || !RegExp(r'^[0-9A-Fa-f:.\[\]]+$').hasMatch(host)) return false;
    final address = host.startsWith('[') && host.endsWith(']') ? host.substring(1, host.length - 1) : host;
    return InternetAddress.tryParse(address)?.type == InternetAddressType.IPv6;
  }

  static String _text(Object? value, String field, {int max = 128}) {
    if (value is! String || hasHiddenCharacters(value) || value.trim().isEmpty || value.trim().length > max) {
      throw ArgumentError('$field must be 1 to $max visible characters.');
    }
    return value.trim();
  }

  static void _checkKeys(Map<String, dynamic> args, Set<String> allowed) {
    if (args.keys.any((key) => !allowed.contains(key))) {
      throw ArgumentError('Unsupported fields. Use the fields in the tool schema.');
    }
  }
}
