import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xml/xml.dart';
import '../models/models.dart';
import 'password_vault.dart';

class ParsedImport {
  ParsedImport({required this.folders, required this.connections, this.layouts = const []});
  final List<ConnectionFolder> folders;
  final List<SavedConnection> connections;
  final List<SavedLayout> layouts;
}

/// Everything (folders, connections, remembered passwords) lives in one JSON
/// blob in shared_preferences — mRemoteNG-style single-store simplicity,
/// stored in roaming app data outside the install dir so it survives upgrades.
///
/// Remembered passwords are encrypted in that blob, under `passwordEnc`, with
/// a key held by the OS (see [PasswordVault]); they are plain only in memory.
class StorageService {
  static const _kFolders = 'commands.folders';
  static const _kConnections = 'commands.connections';
  static const _kLayouts = 'commands.layouts';

  /// A stored list could not be read. Until it is restored, nothing is saved:
  /// writing the empty list the app started with would overwrite the
  /// connections that are still there, only unreadable.
  bool loadFailed = false;

  /// [raw] as a JSON list, or null after marking [loadFailed].
  List? _decodeList(String raw) {
    try {
      return jsonDecode(raw) as List;
    } catch (_) {
      loadFailed = true;
      return null;
    }
  }

  Future<List<SavedLayout>> loadLayouts() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kLayouts);
    if (raw == null) return [];
    final list = _decodeList(raw);
    if (list == null) return [];
    try {
      return list.map((e) => SavedLayout.fromJson(e as Map<String, dynamic>)).toList();
    } catch (_) {
      loadFailed = true;
      return [];
    }
  }

  Future<void> saveLayouts(List<SavedLayout> layouts) async {
    if (loadFailed) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kLayouts, jsonEncode(layouts.map((l) => l.toJson()).toList()));
  }

  Future<List<ConnectionFolder>> loadFolders() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kFolders);
    if (raw == null) return [];
    final list = _decodeList(raw);
    if (list == null) return [];
    try {
      return list.map((e) => ConnectionFolder.fromJson(e as Map<String, dynamic>)).toList();
    } catch (_) {
      loadFailed = true;
      return [];
    }
  }

  Future<void> saveFolders(List<ConnectionFolder> folders) async {
    if (loadFailed) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kFolders, jsonEncode(folders.map((f) => f.toJson()).toList()));
  }

  static const _kPasswordEnc = 'passwordEnc';
  static const _kEnablePasswordEnc = 'enablePasswordEnc';

  PasswordVault? _vaultInstance;
  PasswordVault get _vault => _vaultInstance ??= PasswordVault(PasswordVault.platformStore());

  /// Encrypted values that could not be opened (say the key cannot be read
  /// right now), by connection id. Saved back as they were, so a passing
  /// problem does not wipe them on the next save.
  final Map<String, String> _unopened = {};
  final Map<String, String> _unopenedEnable = {};

  /// A password was found in plain text, as older versions saved it, and the
  /// next save will encrypt it.
  bool needsPasswordMigration = false;

  static const _kProfiles = 'commands.credentialProfiles';

  /// Encrypted profile passwords that could not be opened, kept as they were.
  final Map<String, String> _unopenedProfiles = {};

  Future<List<CredentialProfile>> loadProfiles() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kProfiles);
    _unopenedProfiles.clear();
    if (raw == null) return [];
    final list = _decodeList(raw);
    if (list == null) return [];
    final profiles = <CredentialProfile>[];
    for (final e in list) {
      final Map<String, dynamic> json;
      final CredentialProfile profile;
      try {
        json = e as Map<String, dynamic>;
        profile = CredentialProfile.fromJson(json);
      } catch (_) {
        loadFailed = true;
        return [];
      }
      final sealed = json[_kPasswordEnc] as String?;
      if (sealed != null) {
        try {
          profile.password = await _vault.decrypt(sealed, profile.id);
        } catch (error) {
          debugPrint('A profile password could not be decrypted: ${error.runtimeType}');
          _unopenedProfiles[profile.id] = sealed;
        }
      }
      profiles.add(profile);
    }
    return profiles;
  }

  Future<void> saveProfiles(List<CredentialProfile> profiles) async {
    if (loadFailed) return;
    final prefs = await SharedPreferences.getInstance();
    final encoded = <Map<String, dynamic>>[];
    for (final p in profiles) {
      final json = p.toJson();
      final password = json['password'] as String? ?? '';
      json['password'] = '';
      if (password.isNotEmpty) {
        try {
          json[_kPasswordEnc] = await _vault.encrypt(password, p.id);
        } catch (error) {
          // Never lose it: kept as it was until encryption works again.
          debugPrint('A profile password could not be encrypted: ${error.runtimeType}');
          json['password'] = password;
        }
      } else if (_unopenedProfiles.containsKey(p.id)) {
        json[_kPasswordEnc] = _unopenedProfiles[p.id];
      }
      encoded.add(json);
    }
    await prefs.setString(_kProfiles, jsonEncode(encoded));
  }

  Future<List<SavedConnection>> loadConnections() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kConnections);
    needsPasswordMigration = false;
    _unopened.clear();
    _unopenedEnable.clear();
    if (raw == null) return [];
    final list = _decodeList(raw);
    if (list == null) return [];
    final connections = <SavedConnection>[];
    for (final e in list) {
      final Map<String, dynamic> json;
      final SavedConnection connection;
      try {
        json = e as Map<String, dynamic>;
        connection = SavedConnection.fromJson(json);
      } catch (_) {
        loadFailed = true;
        return [];
      }
      final sealed = json[_kPasswordEnc] as String?;
      if (sealed != null) {
        try {
          connection.password = await _vault.decrypt(sealed, connection.id);
        } catch (error) {
          debugPrint('A saved password could not be decrypted: ${error.runtimeType}');
          _unopened[connection.id] = sealed;
        }
      } else if (connection.password.isNotEmpty) {
        needsPasswordMigration = true;
      }
      final sealedEnable = json[_kEnablePasswordEnc] as String?;
      if (sealedEnable != null) {
        try {
          connection.enablePassword = await _vault.decrypt(sealedEnable, '${connection.id}:enable');
        } catch (error) {
          debugPrint('A saved enable password could not be decrypted: ${error.runtimeType}');
          _unopenedEnable[connection.id] = sealedEnable;
        }
      } else if (connection.enablePassword.isNotEmpty) {
        needsPasswordMigration = true;
      }
      connections.add(connection);
    }
    return connections;
  }

  Future<void> saveConnections(List<SavedConnection> connections) async {
    if (loadFailed) return;
    final prefs = await SharedPreferences.getInstance();
    final encoded = <Map<String, dynamic>>[];
    var migrated = true;
    for (final c in connections) {
      final json = c.toJson();
      final password = json['password'] as String? ?? '';
      if (password.isNotEmpty) {
        try {
          json[_kPasswordEnc] = await _vault.encrypt(password, c.id);
          json['password'] = '';
        } catch (error) {
          // Losing the password would be worse than keeping it as it was:
          // left as is, and tried again on the next save or start.
          debugPrint('A password could not be encrypted: ${error.runtimeType}');
          migrated = false;
        }
      } else if (c.rememberPassword && _unopened.containsKey(c.id)) {
        json[_kPasswordEnc] = _unopened[c.id];
      }
      final enablePassword = json['enablePassword'] as String? ?? '';
      if (enablePassword.isNotEmpty) {
        try {
          json[_kEnablePasswordEnc] = await _vault.encrypt(enablePassword, '${c.id}:enable');
          json.remove('enablePassword');
        } catch (error) {
          debugPrint('An enable password could not be encrypted: ${error.runtimeType}');
          migrated = false;
        }
      } else if (_unopenedEnable.containsKey(c.id)) {
        json[_kEnablePasswordEnc] = _unopenedEnable[c.id];
      }
      encoded.add(json);
    }
    await prefs.setString(_kConnections, jsonEncode(encoded));
    needsPasswordMigration = !migrated;
  }

  // ---- JSON export/import ----

  /// Export folders + connections as a single JSON document (mRemoteNG-style).
  String exportJson({
    required List<ConnectionFolder> folders,
    required List<SavedConnection> connections,
    List<SavedLayout> layouts = const [],
  }) {
    final doc = {
      'app': 'CommandS',
      'version': 1,
      'folders': folders.map((f) => f.toJson()).toList(),
      'connections': connections.map((c) => c.toJson()).toList(),
      if (layouts.isNotEmpty) 'layouts': layouts.map((l) => l.toJson()).toList(),
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
    final layouts =
        (doc['layouts'] as List? ?? []).map((e) => SavedLayout.fromJson(e as Map<String, dynamic>)).toList();
    return ParsedImport(folders: folders, connections: connections, layouts: layouts);
  }

  // ---- XML export/import (same schema, XML-shaped) ----

  String exportXml({
    required List<ConnectionFolder> folders,
    required List<SavedConnection> connections,
    List<SavedLayout> layouts = const [],
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
            if (f.color != null) 'color': '${f.color}',
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
            if (c.enablePassword.isNotEmpty) 'enablePassword': c.enablePassword,
            'protocol': c.protocol.name,
            if (c.folderId != null) 'folderId': c.folderId!,
            if (c.domain != null) 'domain': c.domain!,
            'rdpClipboard': '${c.rdpClipboard}',
            'rdpWallpaper': '${c.rdpWallpaper}',
            'recordSessionByDefault': '${c.recordSessionByDefault}',
            if (c.device != null) 'device': c.device!.name,
            if (c.deviceManual) 'deviceManual': 'true',
            if (c.credentialProfileId != null) 'credentialProfileId': c.credentialProfileId!,
            if (c.answerLoginQuestionYes) 'answerLoginQuestionYes': 'true',
          });
        }
      });
      if (layouts.isNotEmpty) {
        builder.element('Layouts', nest: () {
          for (final l in layouts) {
            builder.element('Layout', attributes: {
              'id': l.id,
              'name': l.name,
              if (l.folderId != null) 'folderId': l.folderId!,
              'preset': l.preset,
              // A pane can be empty (null), so the list goes as JSON.
              'connectionIds': jsonEncode(l.connectionIds),
              if (l.shape != null) 'shape': jsonEncode(l.shape),
            });
          }
        });
      }
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
        color: int.tryParse(e.getAttribute('color') ?? ''),
      );
    }).toList();
    final connections = doc.findAllElements('Connection').map((e) {
      final protocol = ConnectionProtocol.fromName(e.getAttribute('protocol'));
      return SavedConnection(
        id: e.getAttribute('id'),
        name: e.getAttribute('name') ?? 'Unnamed',
        host: e.getAttribute('host') ?? '',
        port: int.tryParse(e.getAttribute('port') ?? ''),
        username: e.getAttribute('username') ?? '',
        password: e.getAttribute('password') ?? '',
        enablePassword: e.getAttribute('enablePassword') ?? '',
        rememberPassword: (e.getAttribute('password') ?? '').isNotEmpty,
        folderId: e.getAttribute('folderId'),
        protocol: protocol,
        domain: e.getAttribute('domain'),
        rdpClipboard: e.getAttribute('rdpClipboard') != 'false',
        rdpWallpaper: e.getAttribute('rdpWallpaper') == 'true',
        recordSessionByDefault: e.getAttribute('recordSessionByDefault') == 'true',
        device: DeviceKind.byName(e.getAttribute('device')),
        deviceManual: e.getAttribute('deviceManual') == 'true',
        credentialProfileId: e.getAttribute('credentialProfileId'),
        answerLoginQuestionYes: e.getAttribute('answerLoginQuestionYes') == 'true',
      );
    }).toList();
    final layouts = <SavedLayout>[];
    for (final e in doc.findAllElements('Layout')) {
      // A layout that cannot be read is left out; the connections still come.
      try {
        final shape = e.getAttribute('shape');
        layouts.add(SavedLayout.fromJson({
          'id': e.getAttribute('id'),
          'name': e.getAttribute('name'),
          'folderId': e.getAttribute('folderId'),
          'preset': e.getAttribute('preset'),
          'connectionIds': jsonDecode(e.getAttribute('connectionIds') ?? '[]'),
          if (shape != null) 'shape': jsonDecode(shape),
        }));
      } catch (_) {}
    }
    return ParsedImport(folders: folders, connections: connections, layouts: layouts);
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
    'enablePassword',
    'domain',
    'recordSessionByDefault',
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
        c.enablePassword,
        c.domain ?? '',
        '${c.recordSessionByDefault}',
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

  List<String> _csvRecords(String csv) {
    final records = <String>[];
    final record = StringBuffer();
    var inQuotes = false;
    for (var i = 0; i < csv.length; i++) {
      final ch = csv[i];
      if (ch == '"') inQuotes = !inQuotes;
      if (!inQuotes && (ch == '\r' || ch == '\n')) {
        if (record.toString().trim().isNotEmpty) records.add(record.toString());
        record.clear();
        if (ch == '\r' && i + 1 < csv.length && csv[i + 1] == '\n') i++;
      } else {
        record.write(ch);
      }
    }
    if (record.toString().trim().isNotEmpty) records.add(record.toString());
    return records;
  }

  /// Parses a CSV with a header row. Column order and delimiter are
  /// flexible: recognizes CommandS's own export, plain spreadsheets, and --
  /// because these are the files that actually carry real passwords --
  /// RDM's own CSV export (`Group`, `ConnectionType`, `CredentialUserName`/
  /// `CredentialPassword`, comma-delimited) and mRemoteNG's CSV export
  /// (`;`-delimited, GUID `Id`/`Parent` folder hierarchy instead of a path
  /// column, `Username`/`Password`/`Protocol`).
  ParsedImport parseCsv(String csvStr) {
    final lines = _csvRecords(csvStr);
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
    final iEnablePass = colIndex(['enablepassword']);
    final iDomain = colIndex(['domain', 'credentialdomain']);
    final iRecordSession = colIndex(['recordsessionbydefault']);

    if (iHost == -1) {
      throw const FormatException(
          'No "host" column found. Expected a header row with at least a host/IP column '
          '(name, folder, protocol, host, port, username, password, domain).');
    }

    final rows = lines.skip(1).map((l) => _parseCsvLine(l, delimiter)).toList();
    String field(List<String> fields, int i) => (i != -1 && i < fields.length) ? fields[i] : '';

    ConnectionProtocol protocolOf(List<String> fields) {
      if (iProtocol != -1) {
        final protocol = field(fields, iProtocol).trim().toLowerCase();
        if (protocol.contains('rdp')) return ConnectionProtocol.rdp;
        if (protocol.contains('telnet')) return ConnectionProtocol.telnet;
        return ConnectionProtocol.ssh;
      }
      if (iConnType != -1) {
        final t = field(fields, iConnType).trim().toLowerCase();
        if (t.contains('telnet')) return ConnectionProtocol.telnet;
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
          port: int.tryParse(field(fields, iPort).trim()),
          username: field(fields, iUser).trim(),
          rememberPassword: password.isNotEmpty,
          password: password,
          enablePassword: field(fields, iEnablePass),
          folderId: folderById.containsKey(parent) ? parent : null,
          protocol: protocol,
          domain: field(fields, iDomain).trim().isEmpty ? null : field(fields, iDomain).trim(),
          recordSessionByDefault: field(fields, iRecordSession).trim().toLowerCase() == 'true',
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
        port: int.tryParse(field(fields, iPort).trim()),
        username: field(fields, iUser).trim(),
        rememberPassword: password.isNotEmpty,
        password: password,
        enablePassword: field(fields, iEnablePass),
        folderId: ensureFolderPath(field(fields, iFolder)),
        protocol: protocol,
        domain: field(fields, iDomain).trim().isEmpty ? null : field(fields, iDomain).trim(),
        recordSessionByDefault: field(fields, iRecordSession).trim().toLowerCase() == 'true',
      ));
    }
    return ParsedImport(folders: folders, connections: connections);
  }
}
