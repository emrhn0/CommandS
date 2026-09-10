import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/models.dart';
import '../providers/app_state.dart';
import '../services/rdm_import.dart';
import '../services/storage_service.dart';
import 'selection_tree_dialog.dart';

Future<void> showExportDialog(BuildContext context) async {
  final app = context.read<AppState>();
  if (app.connections.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No connections to export yet.')));
    return;
  }

  final picked = await showSelectionTreeDialog(
    context,
    title: 'Export connections',
    folders: app.folders,
    connections: app.connections,
    showPasswordToggle: false,
  );
  if (picked == null) return;

  if (!context.mounted) return;
  final format = await showDialog<String>(
    context: context,
    builder: (ctx) => SimpleDialog(
      title: const Text('Export format'),
      children: [
        SimpleDialogOption(onPressed: () => Navigator.pop(ctx, 'json'), child: const Text('JSON')),
        SimpleDialogOption(onPressed: () => Navigator.pop(ctx, 'xml'), child: const Text('XML')),
        SimpleDialogOption(onPressed: () => Navigator.pop(ctx, 'csv'), child: const Text('CSV (Excel/Sheets)')),
      ],
    ),
  );
  if (format == null) return;

  final String content;
  if (format == 'xml') {
    content = app.exportAllXml(connectionIds: picked.connectionIds);
  } else if (format == 'csv') {
    content = app.exportAllCsv(connectionIds: picked.connectionIds);
  } else {
    content = app.exportAll(connectionIds: picked.connectionIds);
  }

  final path = await FilePicker.platform.saveFile(
    dialogTitle: 'Export CommandS connections',
    fileName: 'commands-export.$format',
    type: FileType.custom,
    allowedExtensions: [format],
  );
  if (path == null) return;
  final file = File(path.endsWith('.$format') ? path : '$path.$format');
  await file.writeAsString(content);
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Exported to ${file.path}')));
  }
}

Future<void> showImportDialog(BuildContext context) async {
  final app = context.read<AppState>();
  final result = await FilePicker.platform.pickFiles(
    dialogTitle: 'Import connections (CommandS JSON/XML/CSV or Remote Desktop Manager JSON)',
    type: FileType.custom,
    allowedExtensions: ['json', 'xml', 'csv'],
  );
  if (result == null || result.files.single.path == null) return;
  final file = File(result.files.single.path!);
  final storage = StorageService();

  try {
    final raw = await file.readAsString();
    final isXml = file.path.toLowerCase().endsWith('.xml');
    final isCsv = file.path.toLowerCase().endsWith('.csv');

    if (isCsv) {
      final parsed = storage.parseCsv(raw);
      if (!context.mounted) return;
      await _confirmAndImportParsed(context, app, parsed.folders, parsed.connections);
      return;
    }

    if (isXml) {
      final parsed = storage.parseXml(raw);
      if (parsed.folders.isEmpty && parsed.connections.isEmpty) {
        throw const FormatException(
            'This XML doesn\'t look like a CommandS export (no <Connection>/<Folder> elements found). '
            'CommandS\'s own XML import only round-trips its own export — for Remote Desktop Manager, '
            'export as JSON instead, or as CSV if you need passwords included.');
      }
      if (!context.mounted) return;
      await _confirmAndImportParsed(context, app, parsed.folders, parsed.connections);
      return;
    }

    final doc = jsonDecode(raw) as Map<String, dynamic>;
    if (looksLikeRdmExport(doc)) {
      final rdm = parseRdmExport(doc);
      if (!context.mounted) return;
      final picked = await showSelectionTreeDialog(
        context,
        title: 'Import from Remote Desktop Manager',
        folders: rdm.folders,
        connections: rdm.connections,
        showPasswordToggle: false,
      );
      if (picked == null) return;
      final chosen = RdmImportResult(
        folders: rdm.folders,
        connections: rdm.connections.where((c) => picked.connectionIds.contains(c.id)).toList(),
        skippedUnsupported: rdm.skippedUnsupported,
        passwordsNotImported: rdm.passwordsNotImported,
      );
      await app.importRdm(chosen);
      if (!context.mounted) return;
      final parts = <String>['Imported ${chosen.connections.length} connection(s)'];
      if (rdm.skippedUnsupported > 0) parts.add('${rdm.skippedUnsupported} skipped (unsupported type)');
      if (rdm.passwordsNotImported > 0) {
        parts.add(
          '${rdm.passwordsNotImported} password(s) are AES-encrypted by RDM\'s own vault and can\'t be '
          'decrypted from this file (true for JSON or XML alike) — re-enter them, or export from RDM as '
          'CSV/spreadsheet with credentials revealed and import that instead',
        );
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(parts.join('. ')), duration: const Duration(seconds: 6)),
      );
    } else {
      final parsed = storage.parseJson(raw);
      if (!context.mounted) return;
      await _confirmAndImportParsed(context, app, parsed.folders, parsed.connections);
    }
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Import failed: $e')));
    }
  }
}

Future<void> _confirmAndImportParsed(
  BuildContext context,
  AppState app,
  List<ConnectionFolder> folders,
  List<SavedConnection> connections,
) async {
  final picked = await showSelectionTreeDialog(
    context,
    title: 'Import connections',
    folders: folders,
    connections: connections,
    showPasswordToggle: true,
  );
  if (picked == null) return;
  final chosenConnections = connections.where((c) => picked.connectionIds.contains(c.id)).map((c) {
    if (!picked.passwordIds.contains(c.id)) {
      c.password = '';
      c.rememberPassword = false;
    }
    return c;
  }).toList();
  await app.importParsed(folders, chosenConnections);
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Imported ${chosenConnections.length} connection(s)')));
  }
}
