import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../models/models.dart';
import '../providers/app_state.dart';
import '../theme/app_theme.dart';
import 'new_connection_dialog.dart';

/// A row in the flattened, virtualized tree — either a folder header or a
/// connection leaf, at a given nesting depth.
class _Row {
  _Row.folder(this.folder, this.depth) : connection = null;
  _Row.connection(this.connection, this.depth) : folder = null;

  final ConnectionFolder? folder;
  final SavedConnection? connection;
  final int depth;
}

class ConnectionTree extends StatefulWidget {
  const ConnectionTree({super.key});

  @override
  State<ConnectionTree> createState() => _ConnectionTreeState();
}

class _ConnectionTreeState extends State<ConnectionTree> {
  final _search = TextEditingController();
  String _query = '';

  // Folders start collapsed — expansion state lives here (not per-tile) so
  // building the visible row list stays a single flat pass instead of a
  // fully-materialized nested widget tree (which crawled with 200+ entries).
  final Set<String> _expanded = {};

  // Ctrl/Shift+click multi-select, RDM-style — Ctrl+click.dart's not a typo,
  // it toggles individual rows; Shift+click extends from the last click.
  final Set<String> _selected = {};
  String? _lastClickedId;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _promptName(BuildContext context, String title, String initial, ValueChanged<String> onSubmit) async {
    final controller = TextEditingController(text: initial);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(controller: controller, autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, controller.text.trim()), child: const Text('OK')),
        ],
      ),
    );
    if (result != null && result.isNotEmpty) onSubmit(result);
  }

  List<_Row> _visibleRows(AppState app) {
    final rows = <_Row>[];

    List<ConnectionFolder> foldersUnder(String? parentId) =>
        app.folders.where((f) => f.parentId == parentId).toList()
          ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    List<SavedConnection> connectionsUnder(String? folderId) =>
        app.connections.where((c) => c.folderId == folderId).toList()
          ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

    void walk(String? parentId, int depth) {
      for (final folder in foldersUnder(parentId)) {
        rows.add(_Row.folder(folder, depth));
        if (_expanded.contains(folder.id)) {
          walk(folder.id, depth + 1);
          for (final conn in connectionsUnder(folder.id)) {
            rows.add(_Row.connection(conn, depth + 1));
          }
        }
      }
    }

    walk(null, 0);
    for (final conn in connectionsUnder(null)) {
      rows.add(_Row.connection(conn, 0));
    }
    return rows;
  }

  // Folders are selectable rows too (RDM treats them as first-class items
  // you can multi-select, move, and delete just like connections) so
  // selection is keyed by row id regardless of whether it's a folder or a
  // connection; only the "plain click, nothing selected" behavior differs
  // (open a session vs. toggle expand).
  String? _rowId(_Row r) => r.folder?.id ?? r.connection?.id;

  void _handleRowTap(_Row row, List<_Row> rows, VoidCallback onPlainClick) {
    final id = _rowId(row);
    if (id == null) return;
    final ctrl = HardwareKeyboard.instance.isControlPressed || HardwareKeyboard.instance.isMetaPressed;
    final shift = HardwareKeyboard.instance.isShiftPressed;

    if (ctrl) {
      setState(() {
        if (_selected.contains(id)) {
          _selected.remove(id);
        } else {
          _selected.add(id);
        }
        _lastClickedId = id;
      });
      return;
    }

    if (shift && _lastClickedId != null) {
      final ids = rows.map(_rowId).toList();
      final fromIdx = ids.indexOf(_lastClickedId);
      final toIdx = ids.indexOf(id);
      if (fromIdx != -1 && toIdx != -1) {
        final lo = fromIdx < toIdx ? fromIdx : toIdx;
        final hi = fromIdx < toIdx ? toIdx : fromIdx;
        setState(() {
          for (var i = lo; i <= hi; i++) {
            final rid = ids[i];
            if (rid != null) _selected.add(rid);
          }
        });
        return;
      }
    }

    if (_selected.isNotEmpty) {
      // A plain click while a selection is active just adjusts the
      // selection rather than opening/toggling — matches how Explorer/RDM
      // treat clicks once you're in "picking rows" mode.
      setState(() {
        _selected
          ..clear()
          ..add(id);
        _lastClickedId = id;
      });
      return;
    }

    onPlainClick();
  }

  Future<void> _connect(SavedConnection conn) async {
    final app = context.read<AppState>();
    final error = await app.openConnection(conn);
    if (error != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error)));
    }
  }

  void _clearSelection() => setState(() => _selected.clear());

  void _selectAll(AppState app) {
    setState(() {
      _selected
        ..clear()
        ..addAll(app.connections.map((c) => c.id))
        ..addAll(app.folders.map((f) => f.id));
    });
  }

  Future<void> _deleteSelected(AppState app) async {
    final folderIds = _selected.where((id) => app.folders.any((f) => f.id == id)).toList();
    final connIds = _selected.where((id) => app.connections.any((c) => c.id == id)).toList();
    final parts = <String>[
      if (connIds.isNotEmpty) '${connIds.length} connection${connIds.length == 1 ? '' : 's'}',
      if (folderIds.isNotEmpty) '${folderIds.length} folder${folderIds.length == 1 ? '' : 's'}',
    ];
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete ${parts.join(' and ')}?'),
        content: Text(
          folderIds.isEmpty
              ? 'This cannot be undone.'
              : 'This cannot be undone. Deleted folders\' contents are NOT deleted — they move to root, unfiled.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
        ],
      ),
    );
    if (confirmed != true) return;
    for (final id in connIds) {
      await app.deleteConnection(id);
    }
    for (final id in folderIds) {
      await app.deleteFolder(id);
    }
    _clearSelection();
  }

  Future<void> _moveSelected(AppState app) async {
    final folderIds = _selected.where((id) => app.folders.any((f) => f.id == id)).toList();
    final connIds = _selected.where((id) => app.connections.any((c) => c.id == id)).toList();
    final choice = await showDialog<String?>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text('Move ${_selected.length} item${_selected.length == 1 ? '' : 's'} to folder'),
        children: [
          SimpleDialogOption(onPressed: () => Navigator.pop(ctx, ''), child: const Text('(none)')),
          for (final f in app.folders)
            SimpleDialogOption(onPressed: () => Navigator.pop(ctx, f.id), child: Text(f.name)),
        ],
      ),
    );
    if (choice == null) return;
    final destination = choice.isEmpty ? null : choice;
    for (final id in connIds) {
      await app.moveConnectionToFolder(id, destination);
    }
    for (final id in folderIds) {
      await app.moveFolderToFolder(id, destination);
    }
    _clearSelection();
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();

    return Focus(
      autofocus: true,
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.keyA &&
            (HardwareKeyboard.instance.isControlPressed || HardwareKeyboard.instance.isMetaPressed)) {
          _selectAll(app);
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: _buildBody(context, app),
    );
  }

  Widget _buildBody(BuildContext context, AppState app) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 6, 8, 4),
          child: Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 30,
                  child: TextField(
                    controller: _search,
                    onChanged: (v) => setState(() => _query = v.trim().toLowerCase()),
                    style: const TextStyle(fontSize: 12),
                    decoration: InputDecoration(
                      hintText: 'Filter connections',
                      hintStyle: const TextStyle(fontSize: 12),
                      prefixIcon: const Icon(Icons.search, size: 14),
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(vertical: 4),
                      suffixIcon: _query.isEmpty
                          ? null
                          : IconButton(
                              icon: const Icon(Icons.close, size: 13),
                              onPressed: () => setState(() {
                                _search.clear();
                                _query = '';
                              }),
                            ),
                    ),
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.select_all, size: 16),
                tooltip: 'Select all',
                visualDensity: VisualDensity.compact,
                onPressed: app.connections.isEmpty ? null : () => _selectAll(app),
              ),
              IconButton(
                icon: const Icon(Icons.create_new_folder_outlined, size: 16),
                tooltip: 'New folder',
                visualDensity: VisualDensity.compact,
                onPressed: () => _promptName(context, 'New folder', '', (name) => app.addFolder(name)),
              ),
            ],
          ),
        ),
        if (_selected.isNotEmpty) _SelectionBar(
          count: _selected.length,
          total: app.connections.length + app.folders.length,
          onDelete: () => _deleteSelected(app),
          onMove: () => _moveSelected(app),
          onSelectAll: () => _selectAll(app),
          onCancel: _clearSelection,
        ),
        Expanded(
          child: _query.isEmpty ? _buildTree(app) : _buildFiltered(app),
        ),
      ],
    );
  }

  Widget _buildTree(AppState app) {
    final rows = _visibleRows(app);
    if (app.folders.isEmpty && app.connections.isEmpty) {
      return const _EmptyTreeHint();
    }
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 8),
      itemCount: rows.length,
      itemExtent: kTreeRowHeight,
      itemBuilder: (context, i) {
        final row = rows[i];
        if (row.folder != null) {
          final expanded = _expanded.contains(row.folder!.id);
          void toggle() => setState(() {
                if (expanded) {
                  _expanded.remove(row.folder!.id);
                } else {
                  _expanded.add(row.folder!.id);
                }
              });
          return _FolderRow(
            folder: row.folder!,
            depth: row.depth,
            expanded: expanded,
            selected: _selected.contains(row.folder!.id),
            onTap: () => _handleRowTap(row, rows, toggle),
            onToggle: toggle,
          );
        }
        return _ConnectionRow(
          conn: row.connection!,
          depth: row.depth,
          selected: _selected.contains(row.connection!.id),
          onTap: () => _handleRowTap(row, rows, () => _connect(row.connection!)),
        );
      },
    );
  }

  Widget _buildFiltered(AppState app) {
    final matches = app.connections.where((c) {
      return c.name.toLowerCase().contains(_query) || c.host.toLowerCase().contains(_query);
    }).toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

    if (matches.isEmpty) {
      return Center(
        child: Text('No matches', style: TextStyle(color: Theme.of(context).textTheme.bodySmall?.color, fontSize: 12)),
      );
    }
    final rows = [for (final c in matches) _Row.connection(c, 0)];
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 8),
      itemCount: matches.length,
      itemExtent: kTreeRowHeight,
      itemBuilder: (context, i) => _ConnectionRow(
        conn: matches[i],
        depth: 0,
        selected: _selected.contains(matches[i].id),
        onTap: () => _handleRowTap(rows[i], rows, () => _connect(matches[i])),
      ),
    );
  }
}

class _SelectionBar extends StatelessWidget {
  const _SelectionBar({
    required this.count,
    required this.total,
    required this.onDelete,
    required this.onMove,
    required this.onSelectAll,
    required this.onCancel,
  });
  final int count;
  final int total;
  final VoidCallback onDelete;
  final VoidCallback onMove;
  final VoidCallback onSelectAll;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.12),
      child: Row(
        children: [
          Expanded(
            child: Text('$count selected', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
          ),
          if (count < total)
            IconButton(
              icon: const Icon(Icons.select_all, size: 16),
              tooltip: 'Select all',
              visualDensity: VisualDensity.compact,
              onPressed: onSelectAll,
            ),
          IconButton(
            icon: const Icon(Icons.drive_file_move_outline, size: 16),
            tooltip: 'Move to folder',
            visualDensity: VisualDensity.compact,
            onPressed: onMove,
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline, size: 16),
            tooltip: 'Delete',
            visualDensity: VisualDensity.compact,
            onPressed: onDelete,
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 16),
            tooltip: 'Clear selection',
            visualDensity: VisualDensity.compact,
            onPressed: onCancel,
          ),
        ],
      ),
    );
  }
}

class _EmptyTreeHint extends StatelessWidget {
  const _EmptyTreeHint();

  @override
  Widget build(BuildContext context) {
    final dim = Theme.of(context).textTheme.bodySmall?.color;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 32),
      child: Column(
        children: [
          Icon(Icons.dns_outlined, size: 24, color: dim),
          const SizedBox(height: 8),
          Text(
            'No saved connections yet.\nUse "+ New Connection" above to add one,\nor import from a file.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 11, color: dim),
          ),
        ],
      ),
    );
  }
}

class _FolderRow extends StatefulWidget {
  const _FolderRow({
    required this.folder,
    required this.depth,
    required this.expanded,
    required this.selected,
    required this.onTap,
    required this.onToggle,
  });
  final ConnectionFolder folder;
  final int depth;
  final bool expanded;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onToggle;

  @override
  State<_FolderRow> createState() => _FolderRowState();
}

class _FolderRowState extends State<_FolderRow> {
  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final childCount = app.folders.where((f) => f.parentId == widget.folder.id).length +
        app.connections.where((c) => c.folderId == widget.folder.id).length;
    return _TreeRow(
      depth: widget.depth,
      selected: widget.selected,
      onTap: widget.onTap,
      // The chevron toggles without going through selection handling, so
      // opening a folder while rows are selected does not clear the selection.
      expanded: widget.expanded,
      onToggle: widget.onToggle,
      icon: widget.expanded ? Icons.folder_open : Icons.folder,
      title: widget.folder.name,
      trailingCount: childCount == 0 ? null : childCount,
      bold: true,
      menuItems: const {
        'new': 'New connection here',
        'rename': 'Rename',
        'delete': 'Delete folder',
      },
      onMenu: (key) {
        if (key == 'new') {
          showNewConnectionDialog(context, folderId: widget.folder.id);
        } else if (key == 'rename') {
          showDialog(
            context: context,
            builder: (ctx) {
              final c = TextEditingController(text: widget.folder.name);
              return AlertDialog(
                title: const Text('Rename folder'),
                content: TextField(controller: c, autofocus: true),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
                  FilledButton(
                    onPressed: () {
                      app.renameFolder(widget.folder.id, c.text.trim());
                      Navigator.pop(ctx);
                    },
                    child: const Text('OK'),
                  ),
                ],
              );
            },
          );
        } else if (key == 'delete') {
          _confirmDeleteFolder(context, app);
        }
      },
    );
  }

  Future<void> _confirmDeleteFolder(BuildContext context, AppState app) async {
    final childCount = app.connections.where((c) => c.folderId == widget.folder.id).length +
        app.folders.where((f) => f.parentId == widget.folder.id).length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete "${widget.folder.name}"?'),
        content: Text(
          childCount == 0
              ? 'This folder is empty.'
              : 'It contains $childCount item${childCount == 1 ? '' : 's'}. '
                  'They will NOT be deleted — they move to the root, unfiled.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete folder')),
        ],
      ),
    );
    if (confirmed == true) app.deleteFolder(widget.folder.id);
  }
}

/// The connection's name with a trailing copy of its host taken off.
///
/// People name connections after the box *and* the address ("DATOMON -
/// 192.168.237.215" is typical in real exports), and the row already shows the
/// host in its own column. Left alone, the address appears twice and squeezes
/// the name until it is ellipsised down to nothing useful. Only a trailing
/// occurrence is removed, so a name that genuinely is an address ("10.0.0.1")
/// survives untouched.
String _displayName(SavedConnection conn) {
  final name = conn.name.trim();
  final host = conn.host.trim();
  if (host.isEmpty || !name.toLowerCase().endsWith(host.toLowerCase())) {
    return name;
  }
  final stripped = name.substring(0, name.length - host.length);
  // Whatever the user put between the two: " - ", " | ", a bare space.
  final cleaned = stripped.replaceFirst(RegExp(r'[\s\-\u2013\u2014|:/]+$'), '').trim();
  return cleaned.isEmpty ? name : cleaned;
}

class _ConnectionRow extends StatelessWidget {
  const _ConnectionRow({required this.conn, required this.depth, required this.selected, required this.onTap});
  final SavedConnection conn;
  final int depth;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    return _TreeRow(
      depth: depth,
      selected: selected,
      onTap: onTap,
      icon: conn.protocol == ConnectionProtocol.rdp
          ? Icons.desktop_windows_outlined
          : Icons.dns_outlined,
      // Name and host were one run of identical text ("name - host"), which
      // made every row look the same at a glance. The name carries the
      // meaning, so it gets the weight and the host trails behind it, dimmer.
      title: _displayName(conn),
      subtitle: conn.host,
      menuItems: const {
        'edit': 'Edit…',
        'clone': 'Clone',
        'rename': 'Rename',
        'move': 'Move to folder',
        'delete': 'Delete',
      },
      onMenu: (key) async {
        if (key == 'edit') {
          await showEditConnectionDialog(context, conn);
        } else if (key == 'clone') {
          await app.cloneConnection(conn.id);
        } else if (key == 'rename') {
          final c = TextEditingController(text: conn.name);
          await showDialog(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('Rename connection'),
              content: TextField(controller: c, autofocus: true),
              actions: [
                TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
                FilledButton(
                  onPressed: () {
                    app.renameConnection(conn.id, c.text.trim());
                    Navigator.pop(ctx);
                  },
                  child: const Text('OK'),
                ),
              ],
            ),
          );
        } else if (key == 'move') {
          final app2 = context.read<AppState>();
          final choice = await showDialog<String?>(
            context: context,
            builder: (ctx) => SimpleDialog(
              title: const Text('Move to folder'),
              children: [
                SimpleDialogOption(onPressed: () => Navigator.pop(ctx, ''), child: const Text('(none)')),
                for (final f in app2.folders)
                  SimpleDialogOption(onPressed: () => Navigator.pop(ctx, f.id), child: Text(f.name)),
              ],
            ),
          );
          if (choice != null) {
            app.moveConnectionToFolder(conn.id, choice.isEmpty ? null : choice);
          }
        } else if (key == 'delete') {
          app.deleteConnection(conn.id);
        }
      },
    );
  }
}

/// One row of the tree.
///
/// The tree used to be a flat list of icon + label at a 12px indent per level,
/// with folders distinguished only by swapping the folder icon for an open
/// one. At a couple of hundred entries that reads as a list, not a tree: there
/// is no disclosure control to say a row opens, and nothing ties a child to
/// the parent it belongs to. This draws the two things that were missing -- a
/// chevron, and a guide line per ancestor level -- and separates a
/// connection's name from its host so the eye lands on the name first.
///
/// Height stays fixed ([kTreeRowHeight]) because the list is virtualized by
/// `itemExtent`; with 200+ connections, letting rows size themselves is the
/// difference between instant and visibly slow.
class _TreeRow extends StatefulWidget {
  const _TreeRow({
    required this.depth,
    required this.selected,
    required this.onTap,
    required this.icon,
    required this.title,
    required this.menuItems,
    required this.onMenu,
    this.subtitle,
    this.trailingCount,
    this.expanded,
    this.onToggle,
    this.bold = false,
  });

  final int depth;
  final bool selected;
  final VoidCallback onTap;
  final IconData icon;
  final String title;

  /// The host, for a connection. Drawn dimmer, after the name.
  final String? subtitle;

  /// How many items a folder holds directly.
  final int? trailingCount;

  /// Null for a row that cannot be expanded; the chevron column is still
  /// reserved either way so names stay aligned down a level.
  final bool? expanded;
  final VoidCallback? onToggle;

  final bool bold;
  final Map<String, String> menuItems;
  final ValueChanged<String> onMenu;

  @override
  State<_TreeRow> createState() => _TreeRowState();
}

/// Fixed, so the list can be virtualized with `itemExtent`.
const double kTreeRowHeight = 30;

/// Per nesting level. Wide enough that the guide line reads as structure
/// rather than as a stray pixel.
const double kTreeIndent = 16;

class _TreeRowState extends State<_TreeRow> {
  bool _hover = false;

  Future<void> _showContextMenu(Offset globalPosition) async {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final selected = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        globalPosition & Size.zero,
        Offset.zero & overlay.size,
      ),
      items: [
        for (final e in widget.menuItems.entries)
          PopupMenuItem(value: e.key, child: Text(e.value)),
      ],
    );
    if (selected != null) widget.onMenu(selected);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final text = isDark ? AppColors.darkText : AppColors.lightText;
    final dim = isDark ? AppColors.darkTextDim : AppColors.lightTextDim;
    final guide = isDark ? AppColors.darkBorder : AppColors.lightBorder;
    final accent = theme.colorScheme.primary;

    final Color background;
    if (widget.selected) {
      background = accent.withValues(alpha: isDark ? 0.16 : 0.12);
    } else if (_hover) {
      background = accent.withValues(alpha: isDark ? 0.07 : 0.05);
    } else {
      background = Colors.transparent;
    }

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onSecondaryTapDown: (d) => _showContextMenu(d.globalPosition),
        child: Container(
          height: kTreeRowHeight,
          color: background,
          child: Row(
            children: [
              // A selected row gets a solid edge, not only a wash, so it stays
              // obvious next to the hover tint on the row above it.
              Container(
                width: 2,
                color: widget.selected ? accent : Colors.transparent,
              ),
              // One guide line per ancestor level: the part that makes nesting
              // legible at a glance instead of having to count indents.
              for (var level = 0; level < widget.depth; level++)
                SizedBox(
                  width: kTreeIndent,
                  child: Center(
                    child: Container(width: 1, height: kTreeRowHeight, color: guide),
                  ),
                ),
              SizedBox(
                width: 18,
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
              Icon(widget.icon, size: 15, color: widget.bold ? text : dim),
              const SizedBox(width: 7),
              Expanded(
                child: InkWell(
                  onTap: widget.onTap,
                  child: SizedBox(
                    height: kTreeRowHeight,
                    child: Row(
                      children: [
                        // Expanded, with the host left at its natural width:
                        // a Row lays out its inflexible children first, so the
                        // name gets every pixel the host does not need. Making
                        // both flexible split the space proportionally
                        // instead, which ellipsised names like "WIN_DATNES_
                        // BACKUP" down to nothing while a short IP sat beside
                        // them with room to spare.
                        Expanded(
                          child: Text(
                            widget.title,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              height: 1.1,
                              color: text,
                              fontWeight:
                                  widget.bold ? FontWeight.w600 : FontWeight.w400,
                            ),
                          ),
                        ),
                        if (widget.subtitle != null && widget.subtitle!.isNotEmpty) ...[
                          const SizedBox(width: 8),
                          ConstrainedBox(
                            // A long hostname must not be allowed to squeeze
                            // the name out entirely.
                            constraints: const BoxConstraints(maxWidth: 124),
                            child: Text(
                              widget.subtitle!,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 11, height: 1.1, color: dim),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
              // Swapped for the "..." button on hover, so the row never has to
              // find room for both.
              if (widget.trailingCount != null && !_hover)
                Padding(
                  padding: const EdgeInsets.only(left: 6, right: 8),
                  child: Text(
                    '${widget.trailingCount}',
                    style: TextStyle(fontSize: 10, color: dim, height: 1.1),
                  ),
                ),
              // Kept mounted (not conditionally built) even when hidden:
              // hovering opens the menu, then the cursor moves onto the menu
              // overlay, MouseRegion sees that as "exited", and if this widget
              // were removed from the tree right then the open PopupMenuButton
              // got torn down mid-selection -- "Edit" (or anything else)
              // silently never fired. Opacity keeps it alive so a selection
              // always lands.
              SizedBox(
                width: 24,
                child: Opacity(
                  opacity: _hover ? 1 : 0,
                  child: IgnorePointer(
                    ignoring: !_hover,
                    child: PopupMenuButton<String>(
                      icon: Icon(Icons.more_horiz, size: 14, color: dim),
                      padding: EdgeInsets.zero,
                      tooltip: '',
                      itemBuilder: (ctx) => [
                        for (final e in widget.menuItems.entries)
                          PopupMenuItem(value: e.key, child: Text(e.value)),
                      ],
                      onSelected: widget.onMenu,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
