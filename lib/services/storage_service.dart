import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xml/xml.dart';
import '../models/models.dart';

class ParsedImport {
  ParsedImport({required this.folders, required this.connections});
  final List<ConnectionFolder> folders;
  final List<SavedConnection> connections;
}

/// Everything (folders, connections, remembered passwords) lives in one JSON
/// blob in shared_preferences — mRemoteNG-style single-store simplicity,
/// stored in roaming app data outside the install dir so it survives upgrades.
class StorageService {
  static const _kFolders = 'commands.folders';
  static const _kConnections = 'commands.connections';

  Future<List<ConnectionFolder>> loadFolders() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kFolders);
    if (raw == null) return [];
    final list = jsonDecode(raw) as List;
    return list.map((e) => ConnectionFolder.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<void> saveFolders(List<ConnectionFolder> folders) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kFolders, jsonEncode(folders.map((f) => f.toJson()).toList()));
  }

  Future<List<SavedConnection>> loadConnections() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kConnections);
    if (raw == null) return [];
    final list = jsonDecode(raw) as List;
    return list.map((e) => SavedConnection.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<void> saveConnections(List<SavedConnection> connections) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kConnections, jsonEncode(connections.map((c) => c.toJson()).toList()));
  }

  // ---- JSON export/import ----

  /// Export folders + connections as a single JSON document (mRemoteNG-style).
  String exportJson({
    required List<ConnectionFolder> folders,
    required List<SavedConnection> connections,
  }) {
    final doc = {
      'app': 'CommandS',
      'version': 1,
      'folders': folders.map((f) => f.toJson()).toList(),
      'connections': connections.map((c) => c.toJson()).toList(),
    };
    return const JsonEncoder.withIndent('  ').convert(doc);
  }

  /// Parses a JSON document produced by [exportJson] without touching any
  /// existing state — the caller decides what to do with the result (e.g.
  /// let the user pick a subset before merging).
  ParsedImport parseJson(String jsonStr) {
    final doc = jsonDecode(jsonStr) as Map<String, dynamic>;
    final folders =
        (doc['folders'] as List? ?? []).map((e) => ConnectionFolder.fromJson(e as Map<String, dynamic>)).toList();
    final connections =
        (doc['connections'] as List? ?? []).map((e) => SavedConnection.fromJson(e as Map<String, dynamic>)).toList();
    return ParsedImport(folders: folders, connections: connections);
  }

  // ---- XML export/import (same schema, XML-shaped) ----

  String exportXml({
    required List<ConnectionFolder> folders,
    required List<SavedConnection> connections,
  }) {
    final builder = XmlBuilder();
    builder.processing('xml', 'version="1.0" encoding="UTF-8"');
    builder.element('CommandS', attributes: {'version': '1'}, nest: () {
      builder.element('Folders', nest: () {
        for (final f in folders) {
          builder.element('Folder', attributes: {
            'id': f.id,
            'name': f.name,
            if (f.parentId != null) 'parentId': f.parentId!,
          });
        }
      });
      builder.element('Connections', nest: () {
        for (final c in connections) {
          builder.element('Connection', attributes: {
            'id': c.id,
            'name': c.name,
            'host': c.host,
            'port': '${c.port}',
            'username': c.username,
            'password': c.rememberPassword ? c.password : '',
            'protocol': c.protocol.name,
            if (c.folderId != null) 'folderId': c.folderId!,
            if (c.domain != null) 'domain': c.domain!,
            'rdpClipboard': '${c.rdpClipboard}',
            'rdpWallpaper': '${c.rdpWallpaper}',
          });
        }
      });
    });
    return builder.buildDocument().toXmlString(pretty: true, indent: '  ');
  }

  ParsedImport parseXml(String xmlStr) {
    final doc = XmlDocument.parse(xmlStr);
    final folders = doc.findAllElements('Folder').map((e) {
      return ConnectionFolder(
        id: e.getAttribute('id'),
        name: e.getAttribute('name') ?? 'Unnamed',
        parentId: e.getAttribute('parentId'),
      );
    }).toList();
    final connections = doc.findAllElements('Connection').map((e) {
      return SavedConnection(
        id: e.getAttribute('id'),
        name: e.getAttribute('name') ?? 'Unnamed',
        host: e.getAttribute('host') ?? '',
        port: int.tryParse(e.getAttribute('port') ?? '') ?? 22,
        username: e.getAttribute('username') ?? '',
        password: e.getAttribute('password') ?? '',
        rememberPassword: (e.getAttribute('password') ?? '').isNotEmpty,
        folderId: e.getAttribute('folderId'),
        protocol: e.getAttribute('protocol') == 'rdp' ? ConnectionProtocol.rdp : ConnectionProtocol.ssh,
        domain: e.getAttribute('domain'),
        rdpClipboard: e.getAttribute('rdpClipboard') != 'false',
        rdpWallpaper: e.getAttribute('rdpWallpaper') == 'true',
      );
    }).toList();
    return ParsedImport(folders: folders, connections: connections);
  }

  // ---- CSV export/import ----
  //
  // The one format every credential manager (RDM included) can produce with
  // passwords actually visible: RDM's "SafePassword" field in its own
  // JSON/XML export is AES-encrypted against a vault key we never have
  // access to (not a JSON-vs-XML difference — same ciphertext either way),
  // but RDM can show/copy the decrypted password once its vault is
  // unlocked, and its grid can be copy-pasted or exported to a spreadsheet.
  // A plain CSV closes that gap.

  static const _csvColumns = [
    'name',
    'folder',
    'protocol',
    'host',
    'port',
    'username',
    'password',
    'domain',
  ];

  String exportCsv({
    required List<ConnectionFolder> folders,
    required List<SavedConnection> connections,
  }) {
    String folderPath(String? id) {
      final parts = <String>[];
      var cursor = id;
      while (cursor != null) {
        final matches = folders.where((f) => f.id == cursor);
        if (matches.isEmpty) break;
        final f = matches.first;
        parts.insert(0, f.name);
        cursor = f.parentId;
      }
      return parts.join('/');
    }

    final buf = StringBuffer()..writeln(_csvColumns.map(_csvField).join(','));
    for (final c in connections) {
      buf.writeln([
        c.name,
        folderPath(c.folderId),
        c.protocol.name,
        c.host,
        '${c.port}',
        c.username,
        c.rememberPassword ? c.password : '',
        c.domain ?? '',
      ].map(_csvField).join(','));
    }
    return buf.toString();
  }

  String _csvField(String v) {
    if (v.contains(',') || v.contains('"') || v.contains('\n') || v.contains('\r')) {
      return '"${v.replaceAll('"', '""')}"';
    }
    return v;
  }

  List<String> _parseCsvLine(String line, String delimiter) {
    final fields = <String>[];
    final cur = StringBuffer();
    var inQuotes = false;
    for (var i = 0; i < line.length; i++) {
      final ch = line[i];
      if (inQuotes) {
        if (ch == '"') {
          if (i + 1 < line.length && line[i + 1] == '"') {
            cur.write('"');
            i++;
          } else {
            inQuotes = false;
          }
        } else {
          cur.write(ch);
        }
      } else if (ch == '"') {
        inQuotes = true;
      } else if (ch == delimiter) {
        fields.add(cur.toString());
        cur.clear();
      } else {
        cur.write(ch);
      }
    }
    fields.add(cur.toString());
    return fields;
  }

  /// Parses a CSV with a header row. Column order and delimiter are
  /// flexible: recognizes CommandS's own export, plain spreadsheets, and --
  /// because these are the files that actually carry real passwords --
  /// RDM's own CSV export (`Group`, `ConnectionType`, `CredentialUserName`/
  /// `CredentialPassword`, comma-delimited) and mRemoteNG's CSV export
  /// (`;`-delimited, GUID `Id`/`Parent` folder hierarchy instead of a path
  /// column, `Username`/`Password`/`Protocol`).
  ParsedImport parseCsv(String csvStr) {
    final lines = csvStr.split(RegExp(r'\r\n|\r|\n')).where((l) => l.trim().isNotEmpty).toList();
    if (lines.isEmpty) return ParsedImport(folders: [], connections: []);

    // A BOM (common in Excel-exported CSVs) would otherwise end up glued to
    // the first header name.
    var headerLine = lines.first;
    if (headerLine.isNotEmpty && headerLine.codeUnitAt(0) == 0xFEFF) {
      headerLine = headerLine.substring(1);
    }
    final delimiter = ';'.allMatches(headerLine).length > ','.allMatches(headerLine).length ? ';' : ',';

    final header = _parseCsvLine(headerLine, delimiter).map((h) => h.trim().toLowerCase()).toList();
    int colIndex(List<String> names) {
      for (final n in names) {
        final i = header.indexOf(n);
        if (i != -1) return i;
      }
      return -1;
    }

    final iName = colIndex(['name', 'ad', 'title']);
    final iFolder = colIndex(['folder', 'group', 'klasör', 'klasor']);
    final iId = colIndex(['id']);
    final iParentId = colIndex(['parent']);
    final iNodeType = colIndex(['nodetype']);
    final iConnType = colIndex(['connectiontype']);
    final iProtocol = colIndex(['protocol', 'type']);
    final iHost = colIndex(['host', 'anamakine', 'ip', 'address', 'hostname']);
    final iPort = colIndex(['port']);
    final iUser = colIndex(['username', 'user', 'kullanıcı adı', 'kullanici adi', 'credentialusername']);
    final iPass = colIndex(['password', 'parola', 'şifre', 'sifre', 'credentialpassword']);
    final iDomain = colIndex(['domain', 'credentialdomain']);

    if (iHost == -1) {
      throw const FormatException(
          'No "host" column found. Expected a header row with at least a host/IP column '
          '(name, folder, protocol, host, port, username, password, domain).');
    }

    final rows = lines.skip(1).map((l) => _parseCsvLine(l, delimiter)).toList();
    String field(List<String> fields, int i) => (i != -1 && i < fields.length) ? fields[i] : '';

    ConnectionProtocol protocolOf(List<String> fields) {
      if (iProtocol != -1) {
        return field(fields, iProtocol).trim().toUpperCase().contains('RDP') ? ConnectionProtocol.rdp : ConnectionProtocol.ssh;
      }
      if (iConnType != -1) {
        final t = field(fields, iConnType).trim().toLowerCase();
        if (t.contains('rdp') || t.contains('masaüstü') || t.contains('masaustu') || t.contains('desktop')) {
          return ConnectionProtocol.rdp;
        }
      }
      return ConnectionProtocol.ssh;
    }

    final folders = <ConnectionFolder>[];

    // mRemoteNG-style: folders are separate "Container" rows addressed by a
    // GUID, connections point at their parent folder's GUID via "Parent"
    // rather than carrying a path string.
    if (iNodeType != -1 && iId != -1 && iParentId != -1) {
      final folderIdsSeen = <String>{};
      for (final fields in rows) {
        if (field(fields, iNodeType).trim().toLowerCase() != 'container') continue;
        final id = field(fields, iId).trim();
        if (id.isEmpty || !folderIdsSeen.add(id)) continue;
        folders.add(ConnectionFolder(id: id, name: field(fields, iName).trim(), parentId: null));
      }
      // Second pass: point each folder at its parent container, if that
      // parent is one we created (the export's own top-level root GUID
      // isn't itself a row, so it naturally falls through to null/top-level).
      final folderById = {for (final f in folders) f.id: f};
      for (final fields in rows) {
        if (field(fields, iNodeType).trim().toLowerCase() != 'container') continue;
        final id = field(fields, iId).trim();
        final parent = field(fields, iParentId).trim();
        if (folderById.containsKey(id) && folderById.containsKey(parent)) {
          folderById[id]!.parentId = parent;
        }
      }

      final connections = <SavedConnection>[];
      for (final fields in rows) {
        if (field(fields, iNodeType).trim().toLowerCase() != 'connection') continue;
        final host = field(fields, iHost).trim();
        if (host.isEmpty) continue;
        final protocol = protocolOf(fields);
        final password = field(fields, iPass);
        final parent = field(fields, iParentId).trim();
        connections.add(SavedConnection(
          name: field(fields, iName).trim().isEmpty ? host : field(fields, iName).trim(),
          host: host,
          port: int.tryParse(field(fields, iPort).trim()) ?? (protocol == ConnectionProtocol.rdp ? 3389 : 22),
          username: field(fields, iUser).trim(),
          rememberPassword: password.isNotEmpty,
          password: password,
          folderId: folderById.containsKey(parent) ? parent : null,
          protocol: protocol,
          domain: field(fields, iDomain).trim().isEmpty ? null : field(fields, iDomain).trim(),
        ));
      }
      return ParsedImport(folders: folders, connections: connections);
    }

    // Path-based folders (our own CSV, or RDM's "Group" column, which uses
    // backslashes like "Parent\Child" the same way its JSON export does).
    final folderIdByPath = <String, String>{};
    String? ensureFolderPath(String path) {
      final normalized = path.replaceAll('\\', '/');
      if (normalized.trim().isEmpty) return null;
      final segments = normalized.split('/').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
      String? parentId;
      var acc = '';
      for (final seg in segments) {
        acc = acc.isEmpty ? seg : '$acc/$seg';
        var id = folderIdByPath[acc];
        if (id == null) {
          final f = ConnectionFolder(name: seg, parentId: parentId);
          folders.add(f);
          id = f.id;
          folderIdByPath[acc] = id;
        }
        parentId = id;
      }
      return parentId;
    }

    final connections = <SavedConnection>[];
    for (final fields in rows) {
      final host = field(fields, iHost).trim();
      if (host.isEmpty) continue; // folder-marker / group rows carry no host
      final protocol = protocolOf(fields);
      final password = field(fields, iPass);
      connections.add(SavedConnection(
        name: field(fields, iName).trim().isEmpty ? host : field(fields, iName).trim(),
        host: host,
        port: int.tryParse(field(fields, iPort).trim()) ?? (protocol == ConnectionProtocol.rdp ? 3389 : 22),
        username: field(fields, iUser).trim(),
        rememberPassword: password.isNotEmpty,
        password: password,
        folderId: ensureFolderPath(field(fields, iFolder)),
        protocol: protocol,
        domain: field(fields, iDomain).trim().isEmpty ? null : field(fields, iDomain).trim(),
      ));
    }
    return ParsedImport(folders: folders, connections: connections);
  }
}
