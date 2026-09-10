import 'package:flutter/material.dart';
import '../models/models.dart';

class SelectionResult {
  SelectionResult({required this.connectionIds, required this.passwordIds});
  final Set<String> connectionIds;
  final Set<String> passwordIds; // subset of connectionIds whose password should travel too
}

/// RDM-style "pick what to bring over" screen — shown before both export
/// (which folders/connections go into the file) and import (which of the
/// parsed entries actually get added), instead of silently taking
/// everything. Every row starts checked; per-connection password toggles
/// only appear where a password actually exists to include.
Future<SelectionResult?> showSelectionTreeDialog(
  BuildContext context, {
  required String title,
  required List<ConnectionFolder> folders,
  required List<SavedConnection> connections,
  bool showPasswordToggle = false,
}) {
  return showDialog<SelectionResult>(
    context: context,
    builder: (_) => _SelectionTreeDialog(
      title: title,
      folders: folders,
      connections: connections,
      showPasswordToggle: showPasswordToggle,
    ),
  );
}

class _Row {
  _Row.folder(this.folder, this.depth) : connection = null;
  _Row.connection(this.connection, this.depth) : folder = null;
  final ConnectionFolder? folder;
  final SavedConnection? connection;
  final int depth;
}

class _SelectionTreeDialog extends StatefulWidget {
  const _SelectionTreeDialog({
    required this.title,
    required this.folders,
    required this.connections,
    required this.showPasswordToggle,
  });
  final String title;
  final List<ConnectionFolder> folders;
  final List<SavedConnection> connections;
  final bool showPasswordToggle;

  @override
  State<_SelectionTreeDialog> createState() => _SelectionTreeDialogState();
}

class _SelectionTreeDialogState extends State<_SelectionTreeDialog> {
  late Set<String> _checkedConnections;
  late Set<String> _checkedPasswords;

  @override
  void initState() {
    super.initState();
    _checkedConnections = widget.connections.map((c) => c.id).toSet();
    _checkedPasswords = widget.connections.where((c) => c.password.isNotEmpty).map((c) => c.id).toSet();
  }

  List<_Row> _rows() {
    final rows = <_Row>[];
    List<ConnectionFolder> foldersUnder(String? parentId) =>
        widget.folders.where((f) => f.parentId == parentId).toList()
          ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    List<SavedConnection> connectionsUnder(String? folderId) =>
        widget.connections.where((c) => c.folderId == folderId).toList()
          ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

    void walk(String? parentId, int depth) {
      for (final folder in foldersUnder(parentId)) {
        rows.add(_Row.folder(folder, depth));
        walk(folder.id, depth + 1);
        for (final c in connectionsUnder(folder.id)) {
          rows.add(_Row.connection(c, depth + 1));
        }
      }
    }

    walk(null, 0);
    for (final c in connectionsUnder(null)) {
      rows.add(_Row.connection(c, 0));
    }
    return rows;
  }

  List<String> _descendantConnectionIds(String folderId) {
    final childFolderIds = widget.folders.where((f) => f.parentId == folderId).map((f) => f.id).toList();
    final direct = widget.connections.where((c) => c.folderId == folderId).map((c) => c.id);
    return [...direct, for (final cf in childFolderIds) ..._descendantConnectionIds(cf)];
  }

  bool? _folderState(String folderId) {
    final ids = _descendantConnectionIds(folderId);
    if (ids.isEmpty) return true;
    final checkedCount = ids.where(_checkedConnections.contains).length;
    if (checkedCount == 0) return false;
    if (checkedCount == ids.length) return true;
    return null;
  }

  void _toggleFolder(String folderId, bool check) {
    setState(() {
      for (final id in _descendantConnectionIds(folderId)) {
        if (check) {
          _checkedConnections.add(id);
        } else {
          _checkedConnections.remove(id);
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows();
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460, maxHeight: 560),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(widget.title, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 4),
              Text(
                '${_checkedConnections.length} of ${widget.connections.length} selected',
                style: TextStyle(fontSize: 12, color: Theme.of(context).textTheme.bodySmall?.color),
              ),
              const SizedBox(height: 8),
              Flexible(
                child: rows.isEmpty
                    ? const Padding(
                        padding: EdgeInsets.symmetric(vertical: 24),
                        child: Center(child: Text('Nothing to show', style: TextStyle(fontSize: 12))),
                      )
                    : ListView.builder(
                        shrinkWrap: true,
                        itemCount: rows.length,
                        itemBuilder: (context, i) {
                          final row = rows[i];
                          if (row.folder != null) {
                            final state = _folderState(row.folder!.id);
                            return Padding(
                              padding: EdgeInsets.only(left: row.depth * 16),
                              child: CheckboxListTile(
                                value: state,
                                tristate: true,
                                dense: true,
                                controlAffinity: ListTileControlAffinity.leading,
                                title: Row(
                                  children: [
                                    Icon(Icons.folder, size: 15, color: Theme.of(context).colorScheme.primary),
                                    const SizedBox(width: 6),
                                    Text(row.folder!.name, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                                  ],
                                ),
                                onChanged: (v) => _toggleFolder(row.folder!.id, v ?? true),
                              ),
                            );
                          }
                          final conn = row.connection!;
                          final checked = _checkedConnections.contains(conn.id);
                          final hasPassword = conn.password.isNotEmpty;
                          return Padding(
                            padding: EdgeInsets.only(left: row.depth * 16),
                            child: CheckboxListTile(
                              value: checked,
                              dense: true,
                              controlAffinity: ListTileControlAffinity.leading,
                              title: Text(conn.label, style: const TextStyle(fontSize: 12)),
                              secondary: widget.showPasswordToggle && hasPassword
                                  ? IconButton(
                                      tooltip: _checkedPasswords.contains(conn.id)
                                          ? 'Password will be included'
                                          : 'Password will be excluded',
                                      icon: Icon(
                                        _checkedPasswords.contains(conn.id) ? Icons.lock : Icons.lock_open,
                                        size: 16,
                                      ),
                                      onPressed: () => setState(() {
                                        if (_checkedPasswords.contains(conn.id)) {
                                          _checkedPasswords.remove(conn.id);
                                        } else {
                                          _checkedPasswords.add(conn.id);
                                        }
                                      }),
                                    )
                                  : null,
                              onChanged: (v) => setState(() {
                                if (v ?? false) {
                                  _checkedConnections.add(conn.id);
                                } else {
                                  _checkedConnections.remove(conn.id);
                                }
                              }),
                            ),
                          );
                        },
                      ),
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: _checkedConnections.isEmpty
                        ? null
                        : () => Navigator.pop(
                              context,
                              SelectionResult(connectionIds: _checkedConnections, passwordIds: _checkedPasswords),
                            ),
                    child: Text('Confirm (${_checkedConnections.length})'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
