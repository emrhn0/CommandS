import 'package:flutter/material.dart';

import '../models/models.dart';
import '../theme/app_theme.dart';
import 'app_dialog.dart';
import '../l10n/strings.dart';

/// The answer from [showFolderPicker]: [folderId] is the chosen folder, or
/// null for "no folder" (top level). The picker returns null itself when it
/// was dismissed without a choice, which is why this wrapper exists.
class FolderChoice {
  const FolderChoice(this.folderId);
  final String? folderId;
}

/// "CUSTOMER-D › Core switches" for a folder, or null when [folderId] is null.
String? folderPath(List<ConnectionFolder> folders, String? folderId) {
  if (folderId == null) return null;
  final byId = {for (final f in folders) f.id: f};
  final parts = <String>[];
  var cursor = byId[folderId];
  final seen = <String>{};
  while (cursor != null && seen.add(cursor.id)) {
    parts.add(cursor.name);
    cursor = cursor.parentId == null ? null : byId[cursor.parentId];
  }
  return parts.reversed.join('  ›  ');
}

/// Picks a folder from the same tree the sidebar shows -- nested folders under
/// their parents, expandable, with a guide line per level -- instead of the
/// flat dropdown it replaced, where a sub-folder like CUSTOMER-D's "Core switches" was
/// just another entry in one long list, indistinguishable from a top-level
/// folder of the same name.
Future<FolderChoice?> showFolderPicker(
  BuildContext context, {
  required List<ConnectionFolder> folders,
  required List<SavedConnection> connections,
  required String? selected,
  String title = 'Choose a folder',
}) {
  return showDialog<FolderChoice>(
    context: context,
    builder: (_) =>
        _FolderPickerDialog(folders: folders, connections: connections, selected: selected, title: title),
  );
}

/// A form field that shows the chosen folder as a path and opens
/// [showFolderPicker] when clicked.
class FolderField extends StatelessWidget {
  const FolderField({
    super.key,
    required this.folders,
    required this.connections,
    required this.value,
    required this.onChanged,
    this.label = 'Folder',
  });

  final List<ConnectionFolder> folders;
  final List<SavedConnection> connections;
  final String? value;
  final ValueChanged<String?> onChanged;

  /// Drawn inside the field; null when the form puts its labels above.
  final String? label;

  @override
  Widget build(BuildContext context) {
    final path = folderPath(folders, value);
    final dim = Theme.of(context).textTheme.bodySmall?.color;
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: () async {
        final choice = await showFolderPicker(
          context,
          folders: folders,
          connections: connections,
          selected: value,
        );
        if (choice != null) onChanged(choice.folderId);
      },
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label == null ? null : tr(label!),
          suffixIcon: const Icon(Icons.unfold_more, size: 18),
        ),
        child: Row(
          children: [
            Icon(
              path == null ? Icons.folder_off_outlined : Icons.folder,
              size: 16,
              color: path == null ? dim : null,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                path ?? tr('No folder (top level)'),
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: path == null ? dim : null),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FolderPickerDialog extends StatefulWidget {
  const _FolderPickerDialog({
    required this.folders,
    required this.connections,
    required this.selected,
    required this.title,
  });

  final List<ConnectionFolder> folders;
  final List<SavedConnection> connections;
  final String? selected;
  final String title;

  @override
  State<_FolderPickerDialog> createState() => _FolderPickerDialogState();
}

class _Row {
  const _Row(this.folder, this.depth, this.hasChildren);
  final ConnectionFolder folder;
  final int depth;
  final bool hasChildren;
}

class _FolderPickerDialogState extends State<_FolderPickerDialog> {
  final _expanded = <String>{};
  final _scroll = ScrollController();

  /// Fixed so the current choice can be scrolled to by index.
  static const _rowHeight = 32.0;
  String _query = '';

  late final Map<String?, List<ConnectionFolder>> _children;
  late final Map<String, int> _counts;

  @override
  void initState() {
    super.initState();
    _children = {};
    for (final f in widget.folders) {
      _children.putIfAbsent(f.parentId, () => []).add(f);
    }
    for (final list in _children.values) {
      list.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    }
    _counts = {};
    for (final f in widget.folders) {
      if (f.parentId != null) _counts[f.parentId!] = (_counts[f.parentId!] ?? 0) + 1;
    }
    for (final c in widget.connections) {
      if (c.folderId != null) _counts[c.folderId!] = (_counts[c.folderId!] ?? 0) + 1;
    }
    // Open the way down to the current choice, so it is visible straight away.
    final byId = {for (final f in widget.folders) f.id: f};
    var cursor = widget.selected == null ? null : byId[widget.selected]?.parentId;
    while (cursor != null && _expanded.add(cursor)) {
      cursor = byId[cursor]?.parentId;
    }
    // Then bring it on screen: with a long folder list the revealed choice
    // could otherwise sit far below the visible part.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || widget.selected == null || !_scroll.hasClients) return;
      final index = _rows().indexWhere((r) => r.folder.id == widget.selected);
      if (index == -1) return;
      // Row index + 1 for the "No folder" row above the tree, less one row
      // so its parent stays in view as context.
      final target = index * _rowHeight;
      _scroll.jumpTo(target.clamp(0, _scroll.position.maxScrollExtent));
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  List<_Row> _rows() {
    final rows = <_Row>[];
    if (_query.isNotEmpty) {
      // Searching shows every matching folder at any depth, each with its
      // path so two folders with the same name can be told apart.
      for (final f in widget.folders) {
        if (f.name.toLowerCase().contains(_query)) {
          rows.add(_Row(f, 0, false));
        }
      }
      rows.sort(
        (a, b) => (folderPath(widget.folders, a.folder.id) ?? '').toLowerCase().compareTo(
          (folderPath(widget.folders, b.folder.id) ?? '').toLowerCase(),
        ),
      );
      return rows;
    }
    void walk(String? parent, int depth) {
      for (final f in _children[parent] ?? const <ConnectionFolder>[]) {
        final kids = _children[f.id]?.isNotEmpty ?? false;
        rows.add(_Row(f, depth, kids));
        if (kids && _expanded.contains(f.id)) walk(f.id, depth + 1);
      }
    }

    walk(null, 0);
    return rows;
  }

  void _pick(String? id) => Navigator.of(context).pop(FolderChoice(id));

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rows = _rows();
    return AppDialog(
      title: tr(widget.title),
      icon: Icons.drive_file_move_outlined,
      width: 440,
      maxHeight: 620,
      scrollable: false,
      body: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            autofocus: true,
            onChanged: (v) => setState(() => _query = v.trim().toLowerCase()),
            decoration: InputDecoration(
              hintText: tr('Search folders'),
              prefixIcon: const Icon(Icons.search, size: 18),
              isDense: true,
            ),
          ),
          const SizedBox(height: 10),
          Flexible(
            child: Container(
              decoration: BoxDecoration(
                border: Border.all(color: theme.dividerColor),
                borderRadius: BorderRadius.circular(6),
              ),
              child: ListView(
                controller: _scroll,
                shrinkWrap: true,
                padding: const EdgeInsets.symmetric(vertical: 4),
                children: [
                  if (_query.isEmpty)
                    _PickerRow(
                      depth: 0,
                      icon: Icons.folder_off_outlined,
                      title: tr('No folder (top level)'),
                      selected: widget.selected == null,
                      expanded: null,
                      onTap: () => _pick(null),
                    ),
                  for (final r in rows)
                    _PickerRow(
                      depth: r.depth,
                      icon: _expanded.contains(r.folder.id) ? Icons.folder_open : Icons.folder,
                      title: r.folder.name,
                      subtitle: _query.isEmpty ? null : folderPath(widget.folders, r.folder.parentId),
                      count: _counts[r.folder.id],
                      selected: widget.selected == r.folder.id,
                      expanded: r.hasChildren ? _expanded.contains(r.folder.id) : null,
                      onToggle: () => setState(() {
                        if (!_expanded.remove(r.folder.id)) _expanded.add(r.folder.id);
                      }),
                      onTap: () => _pick(r.folder.id),
                    ),
                  if (_query.isNotEmpty && rows.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        tr('No folder matches.'),
                        textAlign: TextAlign.center,
                        style: TextStyle(color: theme.textTheme.bodySmall?.color),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
      actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(tr('Cancel')))],
    );
  }
}

/// Styled like the sidebar's tree rows, so the folder structure looks the
/// same in both places.
class _PickerRow extends StatefulWidget {
  const _PickerRow({
    required this.depth,
    required this.icon,
    required this.title,
    required this.selected,
    required this.expanded,
    required this.onTap,
    this.subtitle,
    this.count,
    this.onToggle,
  });

  final int depth;
  final IconData icon;
  final String title;
  final String? subtitle;
  final int? count;
  final bool selected;
  final bool? expanded;
  final VoidCallback onTap;
  final VoidCallback? onToggle;

  @override
  State<_PickerRow> createState() => _PickerRowState();
}

class _PickerRowState extends State<_PickerRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final text = isDark ? AppColors.darkText : AppColors.lightText;
    final dim = isDark ? AppColors.darkTextDim : AppColors.lightTextDim;
    final guide = isDark ? AppColors.darkBorder : AppColors.lightBorder;
    final accent = theme.colorScheme.primary;
    final bg = widget.selected
        ? accent.withValues(alpha: isDark ? 0.16 : 0.12)
        : _hover
        ? accent.withValues(alpha: isDark ? 0.07 : 0.05)
        : Colors.transparent;

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          height: _FolderPickerDialogState._rowHeight,
          color: bg,
          child: Row(
            children: [
              Container(width: 2, color: widget.selected ? accent : Colors.transparent),
              const SizedBox(width: 4),
              for (var i = 0; i < widget.depth; i++)
                SizedBox(
                  width: 16,
                  child: Center(child: Container(width: 1, height: 32, color: guide)),
                ),
              SizedBox(
                width: 20,
                child: widget.expanded == null
                    ? null
                    : InkWell(
                        onTap: widget.onToggle,
                        child: AnimatedRotation(
                          turns: widget.expanded! ? 0.25 : 0,
                          duration: const Duration(milliseconds: 120),
                          child: Icon(Icons.chevron_right, size: 16, color: dim),
                        ),
                      ),
              ),
              Icon(widget.icon, size: 16, color: text),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  widget.title,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    color: text,
                    fontWeight: widget.selected ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
              ),
              if (widget.subtitle != null) ...[
                const SizedBox(width: 8),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 160),
                  child: Text(
                    'in ${widget.subtitle}',
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, color: dim),
                  ),
                ),
              ],
              if (widget.selected)
                Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: Icon(Icons.check, size: 16, color: accent),
                )
              else if (widget.count != null)
                Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: Text('${widget.count}', style: TextStyle(fontSize: 10, color: dim)),
                ),
              const SizedBox(width: 10),
            ],
          ),
        ),
      ),
    );
  }
}
