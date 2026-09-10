import 'dart:convert';
import '../models/models.dart';

class RdmImportResult {
  final List<ConnectionFolder> folders;
  final List<SavedConnection> connections;
  final int skippedUnsupported; // serial / unsupported connection types
  final int passwordsNotImported;

  RdmImportResult({
    required this.folders,
    required this.connections,
    required this.skippedUnsupported,
    required this.passwordsNotImported,
  });
}

/// True if [doc] looks like a Remote Desktop Manager / mRemoteNG-style export
/// (top-level "Connections" array with PascalCase fields) rather than
/// CommandS's own export format (lowercase "connections").
bool looksLikeRdmExport(Map<String, dynamic> doc) => doc['Connections'] is List;

/// Stable, non-random id for a folder path that has no explicit RDM group
/// marker of its own — deterministic so re-importing the same file always
/// resolves to the same folder instead of minting a duplicate.
String _fallbackFolderId(String path) => 'rdmpath:${base64Url.encode(utf8.encode(path))}';

/// Parses an RDM-style export. Group hierarchy ("A\\B\\C") becomes nested
/// folders. Every id here is derived from the source export (RDM's own
/// "ID" field for connections and group-marker entries, or a deterministic
/// hash of the group path as a fallback) rather than randomly generated, so
/// importing the same file twice reconciles instead of duplicating —
/// [AppState.importRdm] matches on these ids.
///
/// SafePassword is RDM's own AES blob — we have no way to decrypt it
/// without RDM's key material, so passwords are dropped and the caller is
/// told how many were skipped so it can warn the user.
RdmImportResult parseRdmExport(Map<String, dynamic> doc) {
  final rawConnections = (doc['Connections'] as List).cast<Map<String, dynamic>>();

  // First pass: find the stable RDM id for every group-marker entry (Name
  // == last segment of Group, no Terminal/RDP payload), keyed by full path.
  final markerIdByPath = <String, String>{};
  for (final entry in rawConnections) {
    final group = entry['Group'] as String?;
    final id = entry['ID'] as String?;
    final hasPayload = entry['Terminal'] != null || entry['RDP'] != null;
    if (group != null && group.isNotEmpty && id != null && !hasPayload) {
      markerIdByPath[group] = id;
    }
  }

  final folders = <ConnectionFolder>[];
  final folderIdByPath = <String, String>{};

  String folderIdFor(String groupPath) {
    if (folderIdByPath.containsKey(groupPath)) return folderIdByPath[groupPath]!;
    final segments = groupPath.split('\\');
    String? parentId;
    var pathSoFar = '';
    for (final segment in segments) {
      pathSoFar = pathSoFar.isEmpty ? segment : '$pathSoFar\\$segment';
      final existing = folderIdByPath[pathSoFar];
      if (existing != null) {
        parentId = existing;
        continue;
      }
      final id = markerIdByPath[pathSoFar] ?? _fallbackFolderId(pathSoFar);
      folders.add(ConnectionFolder(id: id, name: segment, parentId: parentId));
      folderIdByPath[pathSoFar] = id;
      parentId = id;
    }
    return folderIdByPath[groupPath]!;
  }

  final connections = <SavedConnection>[];
  var skipped = 0;
  var passwordsNotImported = 0;

  for (final entry in rawConnections) {
    final group = entry['Group'] as String?;
    final folderId = (group != null && group.isNotEmpty) ? folderIdFor(group) : null;
    final name = entry['Name'] as String? ?? 'Unnamed';
    final id = entry['ID'] as String?;

    final terminal = entry['Terminal'] as Map<String, dynamic>?;
    final rdp = entry['RDP'] as Map<String, dynamic>?;

    if (terminal != null && terminal['Host'] != null) {
      final hasPassword = terminal['SafePassword'] != null;
      if (hasPassword) passwordsNotImported++;
      connections.add(SavedConnection(
        id: id,
        name: name,
        host: terminal['Host'] as String,
        port: (terminal['HostPort'] as num?)?.toInt() ?? 22,
        username: terminal['Username'] as String? ?? '',
        folderId: folderId,
        protocol: ConnectionProtocol.ssh,
      ));
    } else if (rdp != null && entry['Url'] != null) {
      final hasPassword = rdp['SafePassword'] != null;
      if (hasPassword) passwordsNotImported++;
      connections.add(SavedConnection(
        id: id,
        name: name,
        host: entry['Url'] as String,
        port: 3389,
        username: rdp['UserName'] as String? ?? '',
        domain: rdp['Domain'] as String?,
        folderId: folderId,
        protocol: ConnectionProtocol.rdp,
      ));
    } else {
      // Group-only marker (ConnectionType 25) or an unsupported type
      // (serial, VNC, web, ...) with no host payload to import.
      skipped++;
    }
  }

  return RdmImportResult(
    folders: folders,
    connections: connections,
    skippedUnsupported: skipped,
    passwordsNotImported: passwordsNotImported,
  );
}
