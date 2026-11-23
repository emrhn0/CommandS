import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../providers/app_state.dart';
import '../services/pane_layout.dart';
import '../services/session_controller.dart';
import '../theme/app_theme.dart';
import 'app_dialog.dart';
import 'context_menu.dart';
import 'device_icon.dart';
import 'folder_picker.dart';
import 'new_connection_dialog.dart';
import 'threshold_draggable.dart';
import 'tool_button.dart';
import '../services/mcp_server.dart';
import '../l10n/strings.dart';
import 'tree_drag.dart';

/// A row in the flattened, virtualized tree — a folder header, a connection
/// leaf, or a saved split layout, at a given nesting depth.
class _Row {
  _Row.folder(this.folder, this.depth) : connection = null, layout = null;
  _Row.connection(this.connection, this.depth) : folder = null, layout = null;
  _Row.layout(this.layout, this.depth) : folder = null, connection = null;

  final ConnectionFolder? folder;
  final SavedConnection? connection;
  final SavedLayout? layout;
  final int depth;
}

Future<void> _promptName(
  BuildContext context,
  String title,
  String initial,
  ValueChanged<String> onSubmit,
) async {
  final result = await showTextInputDialog(
    context,
    title: title,
    initial: initial,
    okLabel: initial.isEmpty ? 'Create' : 'Rename',
    icon: initial.isEmpty ? Icons.create_new_folder_outlined : Icons.edit_outlined,
  );
  if (result != null) onSubmit(result);
}

class ConnectionTree extends StatefulWidget {
  const ConnectionTree({super.key});

  @override
  State<ConnectionTree> createState() => _ConnectionTreeState();
}

class _ConnectionTreeState extends State<ConnectionTree> with WidgetsBindingObserver {
  final _search = TextEditingController();
  String _query = '';

  // Folders start collapsed — expansion state lives here (not per-tile) so
  // building the visible row list stays a single flat pass instead of a
  // fully-materialized nested widget tree (which crawled with 200+ entries).
  final Set<String> _expanded = {};

  // Ctrl/Shift+click multi-select, RDM-style — Ctrl+click.dart's not a typo,
  // it toggles individual rows; Shift+click extends from the last click.
  final Set<String> _selected = {};

  /// Select mode (the Select button): every row has a box, a click ticks it,
  /// and the selection bar stays until the mode is turned off.
  bool _selectMode = false;
  String? _lastClickedId;

  final _scroll = ScrollController();

  /// Rows in the tree as last built, and whether a drag is over the empty
  /// space below them (the top-level drop area).
  int _rowCount = 0;
  bool _overEmpty = false;

  /// The row being dragged, drawn faded where it was.
  final Set<String> _draggingIds = {};

  bool _belowRows(Offset global) {
    final box = _listKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return false;
    final y = box.globalToLocal(global).dy + (_scroll.hasClients ? _scroll.offset : 0);
    return y >= _rowCount * kTreeRowHeight;
  }

  /// Set while something is being dragged; drives edge auto-scroll.
  bool _dragging = false;
  Timer? _autoScroll;
  double _autoScrollStep = 0;
  final _listKey = GlobalKey();

  /// The collapsed folder a drag is resting on, and the timer that opens it
  /// -- Explorer opens a folder you hold something over.
  String? _hoverFolderId;
  Timer? _hoverExpand;

  /// What a drag starting on [row] carries: the whole selection when the
  /// row is part of a multi-selection, otherwise just the row.
  TreeDragItems _dragItemsFor(_Row row, AppState app) {
    final id = _rowId(row)!;
    final ids = _selected.length > 1 && _selected.contains(id) ? _selected.toSet() : {id};
    return TreeDragItems(
      folderIds: ids.where((i) => app.folders.any((f) => f.id == i)).toList(),
      connectionIds: ids.where((i) => app.connections.any((c) => c.id == i)).toList(),
      layoutIds: ids.where((i) => app.layouts.any((l) => l.id == i)).toList(),
    );
  }

  /// Whether [items] may go into [target] (null: the top level). A folder
  /// cannot go into itself or anything under it, and a drop that would move
  /// nothing is not offered.
  bool _canDrop(TreeDragItems items, String? target, AppState app) {
    final parentOf = {for (final f in app.folders) f.id: f.parentId};
    for (final id in items.folderIds) {
      var cursor = target;
      final seen = <String>{};
      while (cursor != null && seen.add(cursor)) {
        if (cursor == id) return false;
        cursor = parentOf[cursor];
      }
    }
    final moves =
        items.folderIds.any((id) => parentOf[id] != target) ||
        items.connectionIds.any((id) => app.connections.firstWhere((c) => c.id == id).folderId != target) ||
        items.layoutIds.any((id) => app.layouts.firstWhere((l) => l.id == id).folderId != target);
    return moves;
  }

  Future<void> _drop(TreeDragItems items, String? target, AppState app) async {
    _stopHoverExpand();
    for (final id in items.folderIds) {
      await app.moveFolderToFolder(id, target);
    }
    for (final id in items.connectionIds) {
      await app.moveConnectionToFolder(id, target);
    }
    for (final id in items.layoutIds) {
      await app.moveLayoutToFolder(id, target);
    }
    if (!mounted) return;
    setState(() {
      // Show where they went, still selected, as Explorer does.
      if (target != null) _expanded.add(target);
      _selected
        ..clear()
        ..addAll([...items.folderIds, ...items.connectionIds, ...items.layoutIds]);
    });
  }

  void _startHoverExpand(String folderId) {
    if (_hoverFolderId == folderId) return;
    _stopHoverExpand();
    if (_expanded.contains(folderId)) return;
    _hoverFolderId = folderId;
    _hoverExpand = Timer(const Duration(milliseconds: 700), () {
      if (mounted && _hoverFolderId == folderId) setState(() => _expanded.add(folderId));
    });
  }

  void _stopHoverExpand() {
    _hoverExpand?.cancel();
    _hoverExpand = null;
    _hoverFolderId = null;
  }

  /// Near the top or bottom edge of the list while dragging, scroll that way.
  void _onDragPointerMove(PointerMoveEvent e) {
    if (!_dragging) return;
    final box = _listKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final y = box.globalToLocal(e.position).dy;
    const edge = 36.0;
    _autoScrollStep = y < edge
        ? -(edge - y) / 3 - 2
        : (y > box.size.height - edge ? (y - box.size.height + edge) / 3 + 2 : 0);
    if (_autoScrollStep == 0) {
      _autoScroll?.cancel();
      _autoScroll = null;
    } else {
      _autoScroll ??= Timer.periodic(const Duration(milliseconds: 16), (_) {
        if (!_scroll.hasClients || _autoScrollStep == 0) return;
        final p = _scroll.position;
        _scroll.jumpTo((p.pixels + _autoScrollStep).clamp(p.minScrollExtent, p.maxScrollExtent));
      });
    }
  }

  void _dragEnded() {
    _dragging = false;
    if (_draggingIds.isNotEmpty && mounted) setState(_draggingIds.clear);
    _autoScroll?.cancel();
    _autoScroll = null;
    _autoScrollStep = 0;
    _stopHoverExpand();
  }

  /// Rows that just moved, lit up briefly so the eye finds where they went.
  final Set<String> _flash = {};
  Timer? _flashTimer;

  void _flashRows(Iterable<String> ids) {
    _flashTimer?.cancel();
    setState(
      () => _flash
        ..clear()
        ..addAll(ids),
    );
    _flashTimer = Timer(const Duration(milliseconds: 900), () {
      if (mounted) setState(_flash.clear);
    });
  }

  /// Folders only, and none of them [target] or above it: they may be
  /// placed next to [target], in its parent.
  bool _canPlaceBeside(TreeDragItems items, ConnectionFolder target, AppState app) {
    if (items.folderIds.isEmpty || items.connectionIds.isNotEmpty || items.layoutIds.isNotEmpty) return false;
    if (items.folderIds.contains(target.id)) return false;
    final parentOf = {for (final f in app.folders) f.id: f.parentId};
    var cursor = target.parentId;
    final seen = <String>{};
    while (cursor != null && seen.add(cursor)) {
      if (items.folderIds.contains(cursor)) return false;
      cursor = parentOf[cursor];
    }
    return true;
  }

  Future<void> _placeBeside(TreeDragItems items, ConnectionFolder target, bool after, AppState app) async {
    _stopHoverExpand();
    String? before = target.id;
    if (after) {
      final siblings = app
          .sortFolders(app.folders.where((f) => f.parentId == target.parentId).toList())
          .map((f) => f.id)
          .where((id) => !items.folderIds.contains(id))
          .toList();
      final i = siblings.indexOf(target.id);
      before = i + 1 < siblings.length ? siblings[i + 1] : null;
    }
    await app.placeFolders(items.folderIds, target.parentId, before: before);
    if (!mounted) return;
    setState(() {
      if (target.parentId != null) _expanded.add(target.parentId!);
      _selected
        ..clear()
        ..addAll(items.folderIds);
    });
    _flashRows(items.folderIds);
  }

  /// Connections only, and not [target] itself: they may be placed next to
  /// it, in its folder.
  bool _canPlaceConnectionsBeside(TreeDragItems items, SavedConnection target) =>
      items.connectionIds.isNotEmpty &&
      items.folderIds.isEmpty &&
      items.layoutIds.isEmpty &&
      !items.connectionIds.contains(target.id);

  Future<void> _placeConnectionsBeside(TreeDragItems items, SavedConnection target, bool after, AppState app) async {
    _stopHoverExpand();
    String? before = target.id;
    if (after) {
      final siblings = app
          .sortConnections(app.connections.where((c) => c.folderId == target.folderId).toList())
          .map((c) => c.id)
          .where((id) => !items.connectionIds.contains(id))
          .toList();
      final i = siblings.indexOf(target.id);
      before = i + 1 < siblings.length ? siblings[i + 1] : null;
    }
    await app.placeConnections(items.connectionIds, target.folderId, before: before);
    if (!mounted) return;
    setState(() {
      if (target.folderId != null) _expanded.add(target.folderId!);
      _selected
        ..clear()
        ..addAll(items.connectionIds);
    });
    _flashRows(items.connectionIds);
  }

  /// Makes [child] draggable and a drop target. A folder row takes items
  /// into itself, or -- for folders dropped on its top or bottom third --
  /// places them above or below it; a connection or layout row takes items
  /// into the folder it is in ([dropFolderId]), or -- for connections dropped
  /// on its top or bottom edge -- places them above or below it.
  Widget _dragAndDrop(_Row row, AppState app, Widget child, {required String? dropFolderId}) {
    final title = row.folder?.name ?? row.layout?.name ?? row.connection?.name ?? '';
    final icon = row.folder != null
        ? Icons.folder
        : row.layout != null
        ? Icons.space_dashboard_outlined
        : (row.connection!.protocol == ConnectionProtocol.rdp
              ? Icons.desktop_windows_outlined
              : Icons.terminal);
    final folder = row.folder;
    final connection = row.connection;
    final id = _rowId(row)!;
    return _DropZone(
      depth: row.depth,
      flash: _flash.contains(id),
      canInto: (items) => _canDrop(items, dropFolderId, app),
      canReorder: (items) =>
          (folder != null && _canPlaceBeside(items, folder, app)) ||
          (connection != null && _canPlaceConnectionsBeside(items, connection)),
      onInto: () {
        if (folder != null) _startHoverExpand(folder.id);
      },
      onLeave: () {
        if (folder != null && _hoverFolderId == folder.id) _stopHoverExpand();
      },
      onDrop: (items, zone) {
        if (zone == _Zone.into) {
          _drop(
            items,
            dropFolderId,
            app,
          ).then((_) => _flashRows([...items.folderIds, ...items.connectionIds, ...items.layoutIds]));
        } else if (folder != null) {
          _placeBeside(items, folder, zone == _Zone.after, app);
        } else if (connection != null) {
          _placeConnectionsBeside(items, connection, zone == _Zone.after, app);
        }
      },
      child: ThresholdDraggable<TreeDragItems>(
        data: _dragItemsFor(row, app),
        dragAnchorStrategy: pointerDragAnchorStrategy,
        onDragStarted: () {
          _handleRowSecondary(row); // the dragged row joins (or is) the selection
          _dragging = true;
          setState(() => _draggingIds.add(id));
        },
        onDragEnd: (_) => _dragEnded(),
        onDraggableCanceled: (_, _) => _dragEnded(),
        feedback: _DragFeedback(
          icon: icon,
          label: _selected.length > 1 && _selected.contains(id)
              ? trCount(_selected.length, '{n} item', '{n} items')
              : title,
        ),
        child: Opacity(opacity: _draggingIds.contains(id) ? 0.45 : 1, child: child),
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  AppState? _revealSource;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final app = context.read<AppState>();
    if (!identical(app, _revealSource)) {
      _revealSource?.revealRequest.removeListener(_onReveal);
      _revealSource = app..revealRequest.addListener(_onReveal);
    }
  }

  /// Quick search asked to show a folder or connection: its folders open,
  /// the search box clears, and the row is selected, flashed and scrolled to.
  void _onReveal() {
    final app = _revealSource;
    final id = app?.revealRequest.value;
    if (app == null || id == null || !mounted) return;
    final folder = app.folders.where((f) => f.id == id).firstOrNull;
    final conn = app.connections.where((c) => c.id == id).firstOrNull;
    if (folder == null && conn == null) return;
    final parentOf = {for (final f in app.folders) f.id: f.parentId};
    var cursor = folder?.parentId ?? conn?.folderId;
    final seen = <String>{};
    setState(() {
      _search.clear();
      _query = '';
      while (cursor != null && seen.add(cursor!)) {
        _expanded.add(cursor!);
        cursor = parentOf[cursor];
      }
      if (folder != null) _expanded.add(folder.id);
      _selected
        ..clear()
        ..add(id);
    });
    _flashRows([id]);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final index = _visibleRows(app).indexWhere((r) => _rowId(r) == id);
      if (index < 0) return;
      final p = _scroll.position;
      final to = (index * kTreeRowHeight - p.viewportDimension / 3).clamp(p.minScrollExtent, p.maxScrollExtent);
      _scroll.animateTo(to, duration: const Duration(milliseconds: 220), curve: Curves.easeOutCubic);
    });
  }

  /// A click anywhere else in the app drops the selection, as in Explorer. Not
  /// while a menu or dialog is open: those act on the selection.
  void _clearIfNothingOnTop() {
    if (_selected.isEmpty || !mounted || _selectMode) return;
    if (ModalRoute.of(context)?.isCurrent ?? true) _clearSelection();
  }

  /// A click in an embedded RDP session never reaches Flutter: it shows here as
  /// the app window losing the keyboard.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive) _clearIfNothingOnTop();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _revealSource?.revealRequest.removeListener(_onReveal);
    _search.dispose();
    _scroll.dispose();
    _autoScroll?.cancel();
    _hoverExpand?.cancel();
    _flashTimer?.cancel();
    super.dispose();
  }

  List<_Row> _visibleRows(AppState app) {
    final rows = <_Row>[];

    // In the order the user dragged them into; untouched ones by name.
    List<ConnectionFolder> foldersUnder(String? parentId) =>
        app.sortFolders(app.folders.where((f) => f.parentId == parentId).toList());
    List<SavedConnection> connectionsUnder(String? folderId) =>
        app.sortConnections(app.connections.where((c) => c.folderId == folderId).toList());
    // Saved layouts sit above a folder's connections: there are few of them
    // and each opens several of the connections below.
    List<SavedLayout> layoutsUnder(String? folderId) =>
        app.layouts.where((l) => l.folderId == folderId).toList()
          ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

    void walk(String? parentId, int depth) {
      for (final folder in foldersUnder(parentId)) {
        rows.add(_Row.folder(folder, depth));
        if (_expanded.contains(folder.id)) {
          walk(folder.id, depth + 1);
          for (final layout in layoutsUnder(folder.id)) {
            rows.add(_Row.layout(layout, depth + 1));
          }
          for (final conn in connectionsUnder(folder.id)) {
            rows.add(_Row.connection(conn, depth + 1));
          }
        }
      }
    }

    walk(null, 0);
    for (final layout in layoutsUnder(null)) {
      rows.add(_Row.layout(layout, 0));
    }
    for (final conn in connectionsUnder(null)) {
      rows.add(_Row.connection(conn, 0));
    }
    return rows;
  }

  // Folders, connections and layouts are all selectable rows, keyed by id.
  // Windows Explorer's model: a click selects (and only selects), a double
  // click opens -- a connection connects, a folder opens or closes, a layout
  // opens. Ctrl and Shift extend the selection.
  String? _rowId(_Row r) => r.folder?.id ?? r.connection?.id ?? r.layout?.id;

  void _handleRowSelect(_Row row, List<_Row> rows) {
    final id = _rowId(row);
    if (id == null) return;
    if (_selectMode) {
      _toggleTick(id, context.read<AppState>());
      return;
    }
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

    setState(() {
      _selected
        ..clear()
        ..add(id);
      _lastClickedId = id;
    });
  }

  /// Right-click selects the row first, as in Explorer -- unless it is part
  /// of a multi-selection, which the menu should not break up.
  void _handleRowSecondary(_Row row) {
    final id = _rowId(row);
    if (id == null || _selected.contains(id)) return;
    setState(() {
      _selected
        ..clear()
        ..add(id);
      _lastClickedId = id;
    });
  }

  Future<void> _connect(SavedConnection conn) async {
    final app = context.read<AppState>();
    final error = await app.openConnection(conn);
    if (error != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error)));
    }
  }

  void _clearSelection() => setState(() => _selected.clear());

  /// Every folder, connection and layout.
  Set<String> _allIds(AppState app) => {
    ...app.folders.map((f) => f.id),
    ...app.connections.map((c) => c.id),
    ...app.layouts.map((l) => l.id),
  };

  void _selectAll(AppState app) => setState(() => _selected..clear()..addAll(_allIds(app)));

  /// The bar's button: everything, or nothing once everything is ticked.
  void _toggleAll(AppState app) {
    if (_selected.containsAll(_allIds(app))) {
      _clearSelection();
    } else {
      _selectAll(app);
    }
  }

  /// Which connections the list shows (the chips under the search box).
  TreeFilter _filter = TreeFilter.all;

  /// The view menu next to the search box: sort the whole list, open or
  /// close every folder, and the select mode.
  Future<void> _showViewMenu(BuildContext anchor, AppState app) async {
    final box = anchor.findRenderObject() as RenderBox?;
    if (box == null || !box.attached) return;
    final empty = app.connections.isEmpty && app.folders.isEmpty;
    final actions = <MenuAction>[
      if (!empty) ...treeSortActions(names: true, connections: app.connections.length > 1),
      MenuAction('collapseAll', 'Collapse all folders', Icons.unfold_less_rounded, separatorBefore: !empty),
      const MenuAction('expandAll', 'Expand all folders', Icons.unfold_more_rounded),
      MenuAction('select', 'Select', Icons.checklist_rounded, separatorBefore: true, checked: _selectMode),
    ];
    final key = await showContextMenu(
      anchor,
      actions: actions,
      anchor: box.localToGlobal(Offset.zero) & box.size,
      header: tr('Sort the whole list'),
      minWidth: 210,
    );
    if (key == null || !mounted) return;
    switch (key) {
      case 'collapseAll':
        setState(_expanded.clear);
      case 'expandAll':
        setState(() => _expanded.addAll(app.folders.map((f) => f.id)));
      case 'select':
        _toggleSelectMode();
      default:
        final order = TreeSort.values.byName(key);
        final confirmed = await showConfirmDialog(
          context,
          title: tr('Sort the whole list?'),
          message: tr('Every folder and connection is put in this order, at every level. '
              'The order you arranged by dragging is replaced.'),
          confirmLabel: 'Sort',
          icon: Icons.sort_rounded,
        );
        if (confirmed) await app.sortWholeList(order);
    }
  }

  /// The Select button: on with every box empty, off again with nothing
  /// selected.
  void _toggleSelectMode() => setState(() {
    _selectMode = !_selectMode;
    _selected.clear();
  });

  /// The folder [id] and what is inside it, at any depth.
  Set<String> _withContents(String id, AppState app) {
    if (!app.folders.any((f) => f.id == id)) return {id};
    final tree = app.folderTree(id);
    return {
      ...tree,
      for (final c in app.connections) if (c.folderId != null && tree.contains(c.folderId)) c.id,
      for (final l in app.layouts) if (l.folderId != null && tree.contains(l.folderId)) l.id,
    };
  }

  /// The folders that hold [id], up to the top level.
  Iterable<String> _ancestors(String id, AppState app) sync* {
    final parentOf = {for (final f in app.folders) f.id: f.parentId};
    var parent = parentOf.containsKey(id)
        ? parentOf[id]
        : app.connections.where((c) => c.id == id).firstOrNull?.folderId ??
            app.layouts.where((l) => l.id == id).firstOrNull?.folderId;
    final seen = <String>{};
    while (parent != null && seen.add(parent)) {
      yield parent;
      parent = parentOf[parent];
    }
  }

  /// A box: a folder takes everything inside it along; unticking something
  /// also unticks the folders around it, which are no longer whole.
  void _toggleTick(String id, AppState app) {
    setState(() {
      final group = _withContents(id, app);
      if (_selected.contains(id)) {
        _selected.removeAll(group);
        _selected.removeAll(_ancestors(id, app));
      } else {
        _selected.addAll(group);
      }
      _lastClickedId = id;
    });
  }

  /// The selected items that are not already inside a selected folder: what
  /// a move or a delete acts on, so a folder's contents go along with it
  /// instead of being moved or deleted one by one.
  ({List<String> folders, List<String> connections, List<String> layouts}) _topSelected(AppState app) {
    final folderIds = _selected.where((id) => app.folders.any((f) => f.id == id)).toSet();
    bool covered(String id) => _ancestors(id, app).any(folderIds.contains);
    return (
      folders: folderIds.where((id) => !covered(id)).toList(),
      connections: [for (final c in app.connections) if (_selected.contains(c.id) && !covered(c.id)) c.id],
      layouts: [for (final l in app.layouts) if (_selected.contains(l.id) && !covered(l.id)) l.id],
    );
  }

  Future<void> _deleteSelected(AppState app) async {
    final top = _topSelected(app);
    // Everything that goes, the contents of the folders included.
    final gone = <String>{
      for (final id in [...top.folders, ...top.connections, ...top.layouts]) ..._withContents(id, app),
    };
    final folders = app.folders.where((f) => gone.contains(f.id)).length;
    final conns = app.connections.where((c) => gone.contains(c.id)).length;
    final layouts = app.layouts.where((l) => gone.contains(l.id)).length;
    if (folders + conns + layouts == 0) return;
    final parts = <String>[
      if (folders > 0) trCount(folders, '{n} folder', '{n} folders'),
      if (conns > 0) trCount(conns, '{n} connection', '{n} connections'),
      if (layouts > 0) trCount(layouts, '{n} layout', '{n} layouts'),
    ];
    final confirmed = await showConfirmDialog(
      context,
      title: tr('Delete {what}?', {'what': parts.join(tr(' and '))}),
      message: top.folders.isEmpty
          ? tr('This cannot be undone.')
          : tr('This cannot be undone. Folders are deleted with everything in them.'),
      confirmLabel: 'Delete',
      destructive: true,
    );
    if (!confirmed) return;
    await app.deleteItems(folderIds: top.folders, connectionIds: top.connections, layoutIds: top.layouts);
    _clearSelection();
  }

  /// Sorts the selected items within their own levels: folders by name (for
  /// the name orders), connections by [order].
  Future<void> _sortSelected(AppState app, TreeSort order) async {
    if (order == TreeSort.nameAscending || order == TreeSort.nameDescending) {
      await app.sortFoldersByName(
        _selected.where((id) => app.folders.any((f) => f.id == id)),
        descending: order == TreeSort.nameDescending,
      );
    }
    await app.sortConnectionsBy(_selected.where((id) => app.connections.any((c) => c.id == id)), order);
  }

  /// At least two selected connections share a folder.
  bool _canSortSelectedConnections(AppState app) {
    final folderIds = <String?>{};
    for (final connection in app.connections) {
      if (_selected.contains(connection.id) && !folderIds.add(connection.folderId)) return true;
    }
    return false;
  }

  bool _canSortSelected(AppState app) {
    final parents = <String?>{};
    for (final folder in app.folders) {
      if (_selected.contains(folder.id) && !parents.add(folder.parentId)) return true;
    }
    final folderIds = <String?>{};
    for (final connection in app.connections) {
      if (_selected.contains(connection.id) && !folderIds.add(connection.folderId)) return true;
    }
    return false;
  }

  Future<void> _moveSelected(AppState app) async {
    final top = _topSelected(app);
    final folderIds = top.folders;
    final connIds = top.connections;
    final choice = await showFolderPicker(
      context,
      folders: app.folders,
      connections: app.connections,
      selected: null,
      title: trCount(_selected.length, 'Move {n} item to folder', 'Move {n} items to folder'),
    );
    if (choice == null) return;
    final destination = choice.folderId;
    for (final id in connIds) {
      await app.moveConnectionToFolder(id, destination);
    }
    for (final id in folderIds) {
      await app.moveFolderToFolder(id, destination);
    }
    for (final id in top.layouts) {
      await app.moveLayoutToFolder(id, destination);
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
                      hintText: tr('Filter connections'),
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
              const SizedBox(width: 6),
              Builder(
                builder: (anchor) => ToolButton(
                  key: const ValueKey('tree-view-menu'),
                  icon: Icons.tune_rounded,
                  tooltip: tr('View'),
                  active: _selectMode,
                  onPressed: () => _showViewMenu(anchor, app),
                ),
              ),
              const SizedBox(width: 4),
              ToolButton(
                icon: Icons.create_new_folder_rounded,
                tooltip: tr('New folder'),
                onPressed: () => _promptName(context, 'New folder', '', (name) => app.addFolder(name)),
              ),
            ],
          ),
        ),
        _FilterChips(
          value: _filter,
          counts: {
            for (final f in TreeFilter.values) f: app.connections.where((c) => f.matches(c, app)).length,
          },
          onChanged: (f) => setState(() => _filter = f),
        ),
        Expanded(
          child: TapRegion(
            onTapOutside: (_) => _clearIfNothingOnTop(),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // One selected row is just the cursor, as in Explorer; the bulk
                // actions are for picking several.
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 160),
                  transitionBuilder: (child, anim) => SizeTransition(
                    sizeFactor: anim,
                    alignment: Alignment.topCenter,
                    child: FadeTransition(opacity: anim, child: child),
                  ),
                  child: _selectMode || _selected.length > 1
                      ? _SelectionBar(
                          count: _selected.length,
                          allSelected: _selected.isNotEmpty && _selected.containsAll(_allIds(app)),
                          sortActions: treeSortActions(
                            names: _canSortSelected(app),
                            connections: _canSortSelectedConnections(app),
                          ),
                          onDelete: () => _deleteSelected(app),
                          onMove: () => _moveSelected(app),
                          onSort: (order) => _sortSelected(app, order),
                          onToggleAll: () => _toggleAll(app),
                          onCancel: () => _selectMode ? _toggleSelectMode() : _clearSelection(),
                        )
                      : const SizedBox(width: double.infinity),
                ),
                Expanded(
                  child: _query.isEmpty && _filter == TreeFilter.all ? _buildTree(app) : _buildFiltered(app),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// The best state of any open session inside each folder, at any depth, so
  /// a collapsed folder still shows that something in it is connected.
  Map<String, SessionStatus> _openByFolder(AppState app) {
    int rank(SessionStatus s) => switch (s) {
      SessionStatus.running => 3,
      SessionStatus.starting => 2,
      SessionStatus.error => 1,
      SessionStatus.closed => 0,
    };
    final folderOf = {for (final c in app.connections) c.id: c.folderId};
    final parentOf = {for (final f in app.folders) f.id: f.parentId};
    final out = <String, SessionStatus>{};
    for (final t in app.tabs) {
      final s = t.controller.status;
      var folder = t.connectionId == null ? null : folderOf[t.connectionId];
      final seen = <String>{};
      while (folder != null && seen.add(folder)) {
        final current = out[folder];
        if (current == null || rank(s) > rank(current)) out[folder] = s;
        folder = parentOf[folder];
      }
    }
    return out;
  }

  Widget _buildTree(AppState app) {
    final rows = _visibleRows(app);
    _rowCount = rows.length;
    final openByFolder = _openByFolder(app);
    if (app.folders.isEmpty && app.connections.isEmpty) {
      return const _EmptyTreeHint();
    }
    // The list itself is the top level: something dropped on empty space
    // below the rows goes out of every folder.
    return Listener(
      onPointerMove: _onDragPointerMove,
      // The empty space below the rows is "elsewhere" too.
      onPointerDown: (e) {
        if (e.buttons == kPrimaryButton && _belowRows(e.position) && !_selectMode) _clearSelection();
      },
      child: DragTarget<TreeDragItems>(
        key: _listKey,
        onWillAcceptWithDetails: (d) => _canDrop(d.data, null, app),
        onMove: (d) {
          final below = _belowRows(d.offset);
          if (below != _overEmpty) setState(() => _overEmpty = below);
        },
        onLeave: (_) {
          if (_overEmpty) setState(() => _overEmpty = false);
        },
        // Only on the empty space below the rows. A drop on a row that the
        // row turned down (a connection onto itself, say) used to fall
        // through to here and send the item to the top level.
        onAcceptWithDetails: (d) {
          final below = _belowRows(d.offset);
          setState(() => _overEmpty = false);
          if (below) _drop(d.data, null, app);
        },
        builder: (context, candidates, _) => DecoratedBox(
          decoration: BoxDecoration(
            color: candidates.isEmpty || !_overEmpty
                ? Colors.transparent
                : Theme.of(context).colorScheme.primary.withValues(alpha: 0.04),
          ),
          child: ListView.builder(
            controller: _scroll,
            padding: const EdgeInsets.only(bottom: 48),
            itemCount: rows.length,
            itemExtent: kTreeRowHeight,
            itemBuilder: (context, i) {
              final row = rows[i];
              return _dragAndDrop(
                row,
                app,
                _buildRow(row, rows, openByFolder),
                dropFolderId: row.folder?.id ?? row.connection?.folderId ?? row.layout?.folderId,
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildRow(_Row row, List<_Row> rows, Map<String, SessionStatus> openByFolder) {
    if (row.folder != null) {
      final expanded = _expanded.contains(row.folder!.id);
      void toggle() => setState(() {
        if (!_selectMode) _selected.clear();
        if (expanded) {
          _expanded.remove(row.folder!.id);
        } else {
          _expanded.add(row.folder!.id);
        }
      });
      return _FolderRow(
        folder: row.folder!,
        depth: row.depth,
        openStatus: openByFolder[row.folder!.id],
        expanded: expanded,
        selected: _selected.contains(row.folder!.id),
        ticked: _selectMode ? _selected.contains(row.folder!.id) : null,
        onSelect: () => _handleRowSelect(row, rows),
        onSecondary: () => _handleRowSecondary(row),
        onOpen: _selectMode ? () {} : toggle,
        onToggle: toggle,
      );
    }
    if (row.layout != null) {
      return _LayoutRow(
        layout: row.layout!,
        depth: row.depth,
        selected: _selected.contains(row.layout!.id),
        ticked: _selectMode ? _selected.contains(row.layout!.id) : null,
        onSelect: () => _handleRowSelect(row, rows),
        onSecondary: () => _handleRowSecondary(row),
      );
    }
    return _ConnectionRow(
      conn: row.connection!,
      depth: row.depth,
      selected: _selected.contains(row.connection!.id),
      ticked: _selectMode ? _selected.contains(row.connection!.id) : null,
      onSelect: () => _handleRowSelect(row, rows),
      onSecondary: () => _handleRowSecondary(row),
      onOpen: _selectMode ? () {} : () => _connect(row.connection!),
    );
  }

  Widget _buildFiltered(AppState app) {
    final matches = app.connections.where((c) {
      if (!_filter.matches(c, app)) return false;
      return c.name.toLowerCase().contains(_query) || c.host.toLowerCase().contains(_query);
    }).toList()..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

    // Layouts are not of one kind: they show only without a filter.
    final layoutMatches = app.layouts
        .where((l) => _filter == TreeFilter.all && l.name.toLowerCase().contains(_query))
        .toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    if (matches.isEmpty && layoutMatches.isEmpty) {
      return Center(
        child: Text(
          tr('No matches'),
          style: TextStyle(color: Theme.of(context).textTheme.bodySmall?.color, fontSize: 12),
        ),
      );
    }
    final rows = [
      for (final l in layoutMatches) _Row.layout(l, 0),
      for (final c in matches) _Row.connection(c, 0),
    ];
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 8),
      itemCount: layoutMatches.length + matches.length,
      itemExtent: kTreeRowHeight,
      itemBuilder: (context, i) {
        if (i < layoutMatches.length) {
          return _LayoutRow(
            layout: layoutMatches[i],
            depth: 0,
            selected: _selected.contains(layoutMatches[i].id),
            ticked: _selectMode ? _selected.contains(layoutMatches[i].id) : null,
            onSelect: () => _handleRowSelect(rows[i], rows),
            onSecondary: () => _handleRowSecondary(rows[i]),
          );
        }
        final j = i - layoutMatches.length;
        return _ConnectionRow(
          conn: matches[j],
          depth: 0,
          selected: _selected.contains(matches[j].id),
          ticked: _selectMode ? _selected.contains(matches[j].id) : null,
          onSelect: () => _handleRowSelect(rows[i], rows),
          onSecondary: () => _handleRowSecondary(rows[i]),
          onOpen: _selectMode ? () {} : () => _connect(matches[j]),
        );
      },
    );
  }
}

enum _Zone { none, before, into, after }

/// One row as a drop target, drawing where a drop would land: an outline
/// for "into", a line with a knob above or below for "place here" -- both
/// fading in and out, so the target is easy to follow while dragging.
class _DropZone extends StatefulWidget {
  const _DropZone({
    required this.depth,
    required this.flash,
    required this.canInto,
    required this.canReorder,
    required this.onInto,
    required this.onLeave,
    required this.onDrop,
    required this.child,
  });

  final int depth;
  final bool flash;
  final bool Function(TreeDragItems) canInto;
  final bool Function(TreeDragItems) canReorder;
  final VoidCallback onInto;
  final VoidCallback onLeave;
  final void Function(TreeDragItems, _Zone) onDrop;
  final Widget child;

  @override
  State<_DropZone> createState() => _DropZoneState();
}

class _DropZoneState extends State<_DropZone> {
  _Zone _zone = _Zone.none;

  _Zone _zoneFor(DragTargetDetails<TreeDragItems> d) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return _Zone.none;
    final y = box.globalToLocal(d.offset).dy;
    final h = box.size.height;
    final reorder = widget.canReorder(d.data);
    final into = widget.canInto(d.data);
    if (reorder && y < h * 0.3) return _Zone.before;
    if (reorder && y > h * 0.7) return _Zone.after;
    if (into) return _Zone.into;
    if (reorder) return y < h / 2 ? _Zone.before : _Zone.after;
    return _Zone.none;
  }

  void _set(_Zone z) {
    if (z == _zone) return;
    setState(() => _zone = z);
    if (z == _Zone.into) {
      widget.onInto();
    } else {
      widget.onLeave();
    }
  }

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final lineLeft = 8.0 + widget.depth * kTreeIndent + 18;
    Widget line(bool top) => Positioned(
      left: lineLeft - 4,
      right: 6,
      top: top ? -1 : null,
      bottom: top ? null : -1,
      child: IgnorePointer(
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 120),
          opacity: _zone == (top ? _Zone.before : _Zone.after) ? 1 : 0,
          child: Row(
            children: [
              Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: accent, width: 1.6),
                  color: Theme.of(context).colorScheme.surface,
                ),
              ),
              Expanded(child: Container(height: 2, color: accent)),
            ],
          ),
        ),
      ),
    );
    return DragTarget<TreeDragItems>(
      onWillAcceptWithDetails: (d) => widget.canInto(d.data) || widget.canReorder(d.data),
      onMove: (d) => _set(_zoneFor(d)),
      onLeave: (_) => _set(_Zone.none),
      onAcceptWithDetails: (d) {
        final z = _zoneFor(d);
        _set(_Zone.none);
        if (z != _Zone.none) widget.onDrop(d.data, z);
      },
      builder: (context, candidates, rejected) => Stack(
        clipBehavior: Clip.none,
        children: [
          // A moved row glows for a moment where it landed, then fades.
          AnimatedContainer(
            duration: const Duration(milliseconds: 450),
            curve: Curves.easeOut,
            margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
            decoration: BoxDecoration(
              color: widget.flash ? accent.withValues(alpha: 0.14) : accent.withValues(alpha: 0),
              borderRadius: BorderRadius.circular(4),
            ),
          ),
          widget.child,
          Positioned.fill(
            child: IgnorePointer(
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 120),
                opacity: _zone == _Zone.into ? 1 : 0,
                child: Container(
                  margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.06),
                    border: Border.all(color: accent, width: 1.4),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
            ),
          ),
          line(true),
          line(false),
        ],
      ),
    );
  }
}

/// What a drag in the tree carries.
/// The chip that follows the pointer while dragging.
class _DragFeedback extends StatelessWidget {
  const _DragFeedback({required this.icon, required this.label});
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Transform.translate(
      offset: const Offset(12, 10),
      child: Material(
        elevation: 6,
        borderRadius: BorderRadius.circular(6),
        color: theme.colorScheme.surface,
        child: Container(
          constraints: const BoxConstraints(maxWidth: 240),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: theme.dividerColor),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 15),
              const SizedBox(width: 8),
              Flexible(
                child: Text(label, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The orders the tree can sort by, as menu items keyed by [TreeSort] name.
/// [names]: folders or connections sorted by name; [connections]: at least
/// two connections, which can also go by address and device type.
List<MenuAction> treeSortActions({required bool names, required bool connections}) => [
      if (names) const MenuAction('nameAscending', 'Name (A–Z)', Icons.arrow_downward_rounded),
      if (names) const MenuAction('nameDescending', 'Name (Z–A)', Icons.arrow_upward_rounded),
      if (connections)
        MenuAction('ipAddress', 'IP address', Icons.lan_outlined, separatorBefore: names),
      if (connections) const MenuAction('deviceType', 'Device type', Icons.devices_other_outlined),
    ];

/// Shows [actions] as a menu under [anchorContext]'s widget and returns the
/// order picked, if any.
Future<TreeSort?> showTreeSortMenu(
  BuildContext anchorContext, {
  required List<MenuAction> actions,
  required String header,
}) async {
  final box = anchorContext.findRenderObject() as RenderBox?;
  if (box == null || !box.attached) return null;
  final key = await showContextMenu(
    anchorContext,
    actions: actions,
    anchor: box.localToGlobal(Offset.zero) & box.size,
    header: header,
    minWidth: 180,
  );
  return key == null ? null : TreeSort.values.byName(key);
}

/// The bar over the tree while several items are selected: a box that
/// selects or clears everything, the count, a Sort menu that names its
/// orders, and Move, Delete and Close.
class _SelectionBar extends StatelessWidget {
  const _SelectionBar({
    required this.count,
    required this.allSelected,
    required this.sortActions,
    required this.onDelete,
    required this.onMove,
    required this.onSort,
    required this.onToggleAll,
    required this.onCancel,
  });
  final int count;
  final bool allSelected;

  /// Empty when nothing selected can be sorted (fewer than two items at one level).
  final List<MenuAction> sortActions;
  final VoidCallback onDelete;
  final VoidCallback onMove;
  final ValueChanged<TreeSort> onSort;
  final VoidCallback onToggleAll;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      key: const ValueKey('selection-bar'),
      height: 30,
      margin: const EdgeInsets.fromLTRB(8, 0, 8, 4),
      padding: const EdgeInsets.only(left: 2, right: 3),
      decoration: BoxDecoration(
        color: scheme.onSurface.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: scheme.onSurface.withValues(alpha: 0.10)),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final actionSize = constraints.maxWidth < 190
              ? 18.0
              : constraints.maxWidth < 210
                  ? 20.0
                  : 24.0;
          // "Sort" is spelled out when there is room; the icon alone otherwise.
          final sortLabel = constraints.maxWidth >= 250;
          return Row(
            // Remount animated buttons at their new width during a resize.
            key: ValueKey(actionSize),
            children: [
              Tooltip(
                message: allSelected ? tr('Deselect all') : tr('Select all'),
                child: SizedBox(
                  width: 24,
                  height: 24,
                  child: Checkbox(
                    key: const ValueKey('select-all'),
                    tristate: true,
                    value: allSelected ? true : (count == 0 ? false : null),
                    onChanged: (_) => onToggleAll(),
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
              ),
              const SizedBox(width: 4),
              Container(
                height: 20,
                constraints: const BoxConstraints(minWidth: 20),
                padding: const EdgeInsets.symmetric(horizontal: 6),
                alignment: Alignment.center,
                decoration: BoxDecoration(color: scheme.primary, borderRadius: BorderRadius.circular(6)),
                child: Text(
                  '$count',
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: scheme.onPrimary),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  tr('selected'),
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11.5, color: scheme.onSurface.withValues(alpha: 0.7)),
                ),
              ),
              if (sortActions.isNotEmpty) ...[
                _SortMenuButton(
                  key: const ValueKey('sort-selected'),
                  actions: sortActions,
                  header: tr('Sort selected'),
                  showLabel: sortLabel,
                  height: actionSize,
                  onSort: onSort,
                ),
                const SizedBox(width: 2),
              ],
              ToolButton(
                key: const ValueKey('move-selected'),
                icon: Icons.drive_file_move_rounded,
                tooltip: tr('Move to folder'),
                onPressed: count == 0 ? null : onMove,
                size: actionSize,
              ),
              const SizedBox(width: 2),
              ToolButton(
                key: const ValueKey('delete-selected'),
                icon: Icons.delete_rounded,
                tooltip: tr('Delete'),
                onPressed: count == 0 ? null : onDelete,
                size: actionSize,
                danger: true,
              ),
              const SizedBox(width: 2),
              ToolButton(icon: Icons.close_rounded, tooltip: tr('Clear selection'), onPressed: onCancel, size: actionSize),
            ],
          );
        },
      ),
    );
  }
}

/// "Sort ▾": opens the list of orders, each with its name, instead of one
/// unlabeled button per order.
class _SortMenuButton extends StatefulWidget {
  const _SortMenuButton({
    super.key,
    required this.actions,
    required this.header,
    required this.showLabel,
    required this.height,
    required this.onSort,
  });
  final List<MenuAction> actions;
  final String header;
  final bool showLabel;
  final double height;
  final ValueChanged<TreeSort> onSort;

  @override
  State<_SortMenuButton> createState() => _SortMenuButtonState();
}

class _SortMenuButtonState extends State<_SortMenuButton> {
  bool _hover = false;
  bool _open = false;

  Future<void> _openMenu() async {
    setState(() => _open = true);
    final order = await showTreeSortMenu(context, actions: widget.actions, header: widget.header);
    if (!mounted) return;
    setState(() => _open = false);
    if (order != null) widget.onSort(order);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final lit = _hover || _open;
    final color = lit ? scheme.primary : scheme.onSurface.withValues(alpha: 0.75);
    return Tooltip(
      message: tr('Sort selected'),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _openMenu,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            height: widget.height,
            padding: EdgeInsets.symmetric(horizontal: widget.showLabel ? 6 : 2),
            decoration: BoxDecoration(
              color: lit ? scheme.primary.withValues(alpha: 0.12) : Colors.transparent,
              borderRadius: BorderRadius.circular(5),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.sort_rounded, size: widget.height * 0.7, color: color),
                if (widget.showLabel) ...[
                  const SizedBox(width: 3),
                  Text(tr('Sort'), style: TextStyle(fontSize: 11.5, color: color)),
                ],
                Icon(Icons.expand_more_rounded, size: widget.height * 0.6, color: color),
              ],
            ),
          ),
        ),
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
            // The button at the top of the panel says "+ New".
            tr('No saved connections yet.\nUse "+ New" above to add one,\nor import from a file.'),
            key: const Key('tree-empty-hint'),
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
    required this.onSelect,
    required this.onSecondary,
    required this.onOpen,
    required this.onToggle,
    this.openStatus,
    this.ticked,
  });
  final bool? ticked;
  final ConnectionFolder folder;
  final int depth;
  final bool expanded;
  final bool selected;
  final VoidCallback onSelect;
  final VoidCallback onSecondary;
  final VoidCallback onOpen;
  final VoidCallback onToggle;

  /// Set when a connection somewhere inside this folder has a tab open.
  final SessionStatus? openStatus;

  @override
  State<_FolderRow> createState() => _FolderRowState();
}

class _FolderRowState extends State<_FolderRow> {
  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final childCount =
        app.folders.where((f) => f.parentId == widget.folder.id).length +
        app.connections.where((c) => c.folderId == widget.folder.id).length +
        app.layouts.where((l) => l.folderId == widget.folder.id).length;
    return _TreeRow(
      rowId: widget.folder.id,
      depth: widget.depth,
      selected: widget.selected,
      ticked: widget.ticked,
      onSelect: widget.onSelect,
      onSecondary: widget.onSecondary,
      onOpen: widget.onOpen,
      // The chevron toggles with a single click, as in Explorer, without
      // going through selection.
      expanded: widget.expanded,
      onToggle: widget.onToggle,
      openStatus: widget.openStatus,
      // One filled folder icon, open or not, as in Remote Desktop Manager: the
      // chevron already says which.
      icon: Icons.folder,
      // A coloured folder, or one inside a coloured folder, shows its colour.
      leading: switch (app.folderColorOf(widget.folder.id)) {
        final color? => Icon(Icons.folder, size: 16, color: color, key: ValueKey('folder-color-${widget.folder.id}')),
        null => null,
      },
      title: widget.folder.name,
      trailingCount: childCount == 0 ? null : childCount,
      bold: true,
      menuItems: const [
        MenuAction('openAll', 'Open all connections', Icons.play_arrow_outlined),
        MenuAction('new', 'New connection here', Icons.add, separatorBefore: true),
        MenuAction('newFolder', 'New folder here', Icons.create_new_folder_outlined),
        MenuAction('rename', 'Rename', Icons.edit_outlined),
        MenuAction('color', 'Color…', Icons.palette_outlined),
        MenuAction('sort', 'Sort contents', Icons.sort_rounded, separatorBefore: true),
        MenuAction('delete', 'Delete folder', Icons.delete_outline, destructive: true, separatorBefore: true),
      ],
      onMenu: (key) async {
        if (key == 'openAll') {
          await _openAll(context, app);
        } else if (key == 'new') {
          showNewConnectionDialog(context, folderId: widget.folder.id);
        } else if (key == 'newFolder') {
          await _promptName(
            context,
            'New folder',
            '',
            (name) => app.addFolder(name, parentId: widget.folder.id),
          );
        } else if (key == 'rename') {
          final name = await showTextInputDialog(
            context,
            title: 'Rename folder',
            initial: widget.folder.name,
          );
          if (name != null) app.renameFolder(widget.folder.id, name);
        } else if (key == 'color') {
          await _pickColor(context, app);
        } else if (key == 'sort') {
          await _sortContents(context, app);
        } else if (key == 'delete') {
          _confirmDeleteFolder(context, app);
        }
      },
    );
  }

  /// Gives the folder a colour, or takes it away.
  Future<void> _pickColor(BuildContext context, AppState app) async {
    final folder = widget.folder;
    final picked = await showDialog<int>(
      context: context,
      builder: (context) => FolderColorDialog(name: folder.name, current: folder.color),
    );
    // -1 is "No color"; null is a dialog closed without a choice.
    if (picked != null) await app.setFolderColor(folder.id, picked < 0 ? null : picked);
  }

  /// Sorts what is directly inside this folder, from a menu that names each
  /// order: no need to select the items first.
  Future<void> _sortContents(BuildContext context, AppState app) async {
    final id = widget.folder.id;
    final order = await showTreeSortMenu(
      context,
      actions: treeSortActions(
        names: true,
        connections: app.connections.where((c) => c.folderId == id).length > 1,
      ),
      header: tr('Sort "{name}"', {'name': widget.folder.name}),
    );
    if (order != null) await app.sortFolderContents(id, order);
  }

  /// Opens every connection in this folder and the folders inside it. Many
  /// at once are asked about first: each one is a login to a device.
  Future<void> _openAll(BuildContext context, AppState app) async {
    final count = app.connectionsUnder(widget.folder.id).length;
    if (count == 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr('There are no connections in "{name}".', {'name': widget.folder.name}))),
      );
      return;
    }
    if (count > 10) {
      final ok = await showConfirmDialog(
        context,
        title: tr('Open {n} connections?', {'n': count}),
        message: tr('Every connection in "{name}" and the folders inside it opens in a tab of its own.',
            {'name': widget.folder.name}),
        confirmLabel: 'Open',
        icon: Icons.play_arrow_outlined,
      );
      if (!ok) return;
    }
    await app.openFolder(widget.folder.id);
  }

  Future<void> _confirmDeleteFolder(BuildContext context, AppState app) async {
    // Everything inside, at any depth: it goes with the folder.
    final tree = app.folderTree(widget.folder.id);
    final childCount =
        tree.length - 1 +
        app.connections.where((c) => c.folderId != null && tree.contains(c.folderId)).length +
        app.layouts.where((l) => l.folderId != null && tree.contains(l.folderId)).length;
    final confirmed = await showConfirmDialog(
      context,
      title: tr('Delete "{name}"?', {'name': widget.folder.name}),
      message: childCount == 0
          ? tr('This folder is empty.')
          : trCount(
              childCount,
              'It contains {n} item. It will be deleted too. This cannot be undone.',
              'It contains {n} items. They will be deleted too. This cannot be undone.',
            ),
      confirmLabel: 'Delete folder',
      destructive: true,
    );
    if (confirmed) await app.deleteItems(folderIds: [widget.folder.id]);
  }
}

/// The connection's name with a trailing copy of its host taken off.
///
/// People name connections after the box *and* the address ("CORE-SW -
/// 192.0.2.15" is typical in real exports), and the row already shows the
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
  const _ConnectionRow({
    required this.conn,
    required this.depth,
    required this.selected,
    required this.onSelect,
    required this.onSecondary,
    required this.onOpen,
    this.ticked,
  });
  final bool? ticked;
  final SavedConnection conn;
  final int depth;
  final bool selected;
  final VoidCallback onSelect;
  final VoidCallback onSecondary;
  final VoidCallback onOpen;

  /// The state of this connection's open tab, if it has one -- the best of
  /// them when it is open more than once, so one live session shows as live.
  SessionStatus? _openStatus(AppState app) {
    SessionStatus? best;
    int rank(SessionStatus s) => switch (s) {
      SessionStatus.running => 3,
      SessionStatus.starting => 2,
      SessionStatus.error => 1,
      SessionStatus.closed => 0,
    };
    for (final t in app.tabs) {
      if (t.connectionId != conn.id) continue;
      final s = t.controller.status;
      if (best == null || rank(s) > rank(best)) best = s;
    }
    return best;
  }

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    return _TreeRow(
      rowId: conn.id,
      depth: depth,
      selected: selected,
      ticked: ticked,
      onSelect: onSelect,
      onSecondary: onSecondary,
      onOpen: onOpen,
      openStatus: _openStatus(app),
      icon: conn.protocol == ConnectionProtocol.rdp ? Icons.desktop_windows_outlined : Icons.terminal,
      leading: switch (DeviceIcon.of(conn)) {
        final kind? => DeviceIcon(kind),
        null => null,
      },
      // Name and host were one run of identical text ("name - host"), which
      // made every row look the same at a glance. The name carries the
      // meaning, so it gets the weight and the host trails behind it, dimmer.
      title: _displayName(conn),
      subtitle: conn.host,
      favorite: app.isFavorite(conn.id),
      menuItems: [
        const MenuAction('connect', 'Connect', Icons.play_arrow_outlined),
        app.isFavorite(conn.id)
            ? const MenuAction('favorite', 'Remove from favorites', Icons.star_rounded)
            : const MenuAction('favorite', 'Add to favorites', Icons.star_border_rounded),
        if (_mcpGateway(context) case final gateway? when conn.protocol == ConnectionProtocol.ssh)
          gateway.isAllowed(conn.id)
              ? const MenuAction('mcp', 'Remove agent access', Icons.smart_toy_outlined)
              : const MenuAction('mcp', 'Allow agent access', Icons.smart_toy_outlined),
        const MenuAction('edit', 'Edit…', Icons.tune, separatorBefore: true),
        const MenuAction('rename', 'Rename', Icons.edit_outlined),
        const MenuAction('clone', 'Clone', Icons.copy_outlined),
        const MenuAction('move', 'Move to folder…', Icons.drive_file_move_outlined),
        const MenuAction('delete', 'Delete', Icons.delete_outline, destructive: true, separatorBefore: true),
      ],
      onMenu: (key) async {
        if (key == 'connect') {
          await app.openConnection(conn);
        } else if (key == 'favorite') {
          await app.toggleFavorite(conn.id);
        } else if (key == 'mcp') {
          final gateway = _mcpGateway(context);
          if (gateway != null) await gateway.setAllowed(conn.id, !gateway.isAllowed(conn.id));
        } else if (key == 'edit') {
          await showEditConnectionDialog(context, conn);
        } else if (key == 'clone') {
          await app.cloneConnection(conn.id);
        } else if (key == 'rename') {
          final name = await showTextInputDialog(context, title: 'Rename connection', initial: conn.name);
          if (name != null) app.renameConnection(conn.id, name);
        } else if (key == 'move') {
          final choice = await showFolderPicker(
            context,
            folders: app.folders,
            connections: app.connections,
            selected: conn.folderId,
            title: 'Move to folder',
          );
          if (choice != null) {
            app.moveConnectionToFolder(conn.id, choice.folderId);
          }
        } else if (key == 'delete') {
          app.deleteConnection(conn.id);
        }
      },
    );
  }
}

/// A saved split layout. Clicking it opens its connections in their saved
/// arrangement.
class _LayoutRow extends StatelessWidget {
  const _LayoutRow({
    required this.layout,
    required this.depth,
    required this.selected,
    required this.onSelect,
    required this.onSecondary,
    this.ticked,
  });
  final bool? ticked;
  final SavedLayout layout;
  final int depth;
  final bool selected;
  final VoidCallback onSelect;
  final VoidCallback onSecondary;

  void _open(BuildContext context) {
    final app = context.read<AppState>();
    final opened = app.openLayout(layout);
    if (opened == 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(tr('None of the connections in "{name}" exist any more.', {'name': layout.name})),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final preset = SplitPreset.values.where((p) => p.name == layout.preset).firstOrNull;
    final panes = layout.connectionIds.where((id) => id != null).length;
    return _TreeRow(
      rowId: layout.id,
      depth: depth,
      selected: selected,
      ticked: ticked,
      onSelect: onSelect,
      onSecondary: onSecondary,
      onOpen: () => _open(context),
      icon: Icons.space_dashboard_outlined,
      title: layout.name,
      subtitle: '${tr(layout.shape != null ? 'Custom' : preset?.label ?? 'Layout')} · $panes',
      menuItems: const [
        MenuAction('open', 'Open layout', Icons.play_arrow_outlined),
        MenuAction('rename', 'Rename', Icons.edit_outlined, separatorBefore: true),
        MenuAction('move', 'Move to folder…', Icons.drive_file_move_outlined),
        MenuAction('delete', 'Delete layout', Icons.delete_outline, destructive: true, separatorBefore: true),
      ],
      onMenu: (key) async {
        if (key == 'open') {
          _open(context);
        } else if (key == 'rename') {
          final name = await showTextInputDialog(context, title: 'Rename layout', initial: layout.name);
          if (name != null) await app.renameLayout(layout.id, name);
        } else if (key == 'move') {
          if (!context.mounted) return;
          final choice = await showFolderPicker(
            context,
            folders: app.folders,
            connections: app.connections,
            selected: layout.folderId,
            title: 'Move layout to folder',
          );
          if (choice != null) await app.moveLayoutToFolder(layout.id, choice.folderId);
        } else if (key == 'delete') {
          // Only the saved arrangement goes; its connections stay.
          await app.deleteLayout(layout.id);
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
    required this.rowId,
    required this.depth,
    required this.selected,
    required this.onSelect,
    required this.onSecondary,
    required this.onOpen,
    required this.icon,
    this.ticked,
    this.leading,
    required this.title,
    required this.menuItems,
    required this.onMenu,
    this.subtitle,
    this.trailingCount,
    this.expanded,
    this.onToggle,
    this.openStatus,
    this.bold = false,
    this.favorite = false,
  });

  /// The folder, connection or layout this row shows.
  final String rowId;
  final int depth;
  final bool selected;

  /// In select mode, the row's box: ticked or not. Null outside it.
  final bool? ticked;

  /// Mouse button down anywhere on the row: select it (Ctrl/Shift extend).
  final VoidCallback onSelect;

  /// Right button: select before the menu opens.
  final VoidCallback onSecondary;

  /// Double click: connect / open or close the folder / open the layout.
  final VoidCallback onOpen;
  final IconData icon;

  /// Drawn instead of [icon] when set: a device's logo.
  final Widget? leading;
  final String title;

  /// The host, for a connection. Drawn dimmer, after the name.
  final String? subtitle;

  /// How many items a folder holds directly.
  final int? trailingCount;

  /// Null for a row that cannot be expanded; the chevron column is still
  /// reserved either way so names stay aligned down a level.
  final bool? expanded;
  final VoidCallback? onToggle;

  /// Set when this connection has a tab open; drawn as a dot on its icon.
  final SessionStatus? openStatus;

  final bool bold;

  /// A starred connection: a small star after its name.
  final bool favorite;
  final List<MenuAction> menuItems;
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

  final _moreKey = GlobalKey();

  /// The last press, kept for the whole tree rather than per row widget: a
  /// row can be rebuilt between the two clicks of a double click (selection
  /// changes it), and a per-row memory was lost with it.
  static String? _lastDownRow;
  static Duration? _lastDown;
  static Offset? _lastDownAt;

  /// How far the pointer may wander between the two clicks: Windows' own
  /// double-click rectangle is 4x4 px. Flutter's touch default (100 px)
  /// would have made two quick clicks on two different rows a double click.
  static const double _doubleClickSlop = 6;

  /// Two presses of the left button on the same row, close together in time
  /// and place, make a double click: open.
  void _onNameDown(PointerDownEvent e) {
    if (e.buttons != kPrimaryMouseButton) return;
    final last = _lastDown;
    final at = _lastDownAt;
    if (_lastDownRow == widget.rowId &&
        last != null &&
        at != null &&
        e.timeStamp - last >= Duration.zero &&
        e.timeStamp - last <= kDoubleTapTimeout &&
        (e.position - at).distance <= _doubleClickSlop) {
      _lastDownRow = null;
      _lastDown = null;
      _lastDownAt = null;
      widget.onOpen();
      return;
    }
    _lastDownRow = widget.rowId;
    _lastDown = e.timeStamp;
    _lastDownAt = e.position;
  }

  /// Right-click and the "..." button open the same menu: at the pointer, or
  /// anchored under the button.
  Future<void> _showContextMenu({Offset? at}) async {
    Rect? anchor;
    if (at == null) {
      final box = _moreKey.currentContext?.findRenderObject() as RenderBox?;
      if (box == null) return;
      anchor = box.localToGlobal(Offset.zero) & box.size;
    }
    final selected = await showContextMenu(
      context,
      actions: widget.menuItems,
      position: at,
      anchor: anchor,
      header: widget.title,
    );
    if (selected != null) widget.onMenu(selected);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final text = AppPalette.of(context).text;
    final dim = AppPalette.of(context).textDim;
    final overlay = isDark ? Colors.white : Colors.black;

    // Windows 11's navigation pane: a rounded, neutral highlight inset from
    // the panel's edges -- lighter on hover, stronger when selected -- rather
    // than a full-width tinted band.
    final Color background;
    if (widget.selected) {
      background = overlay.withValues(alpha: isDark ? 0.11 : 0.075);
    } else if (_hover) {
      background = overlay.withValues(alpha: isDark ? 0.06 : 0.04);
    } else {
      background = Colors.transparent;
    }

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      // Selected the moment the button goes down, as in Explorer. A tap
      // recognizer would wait out the double-click timeout before reporting
      // a single click, which made selection feel late.
      child: Listener(
        onPointerDown: (e) {
          if (e.buttons == kPrimaryMouseButton) widget.onSelect();
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onSecondaryTapDown: (d) {
            widget.onSecondary();
            _showContextMenu(at: d.globalPosition);
          },
          child: SizedBox(
            height: kTreeRowHeight,
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
              decoration: BoxDecoration(color: background, borderRadius: BorderRadius.circular(4)),
              child: Row(
                children: [
                  // The selection pill, as in Remote Desktop Manager and Windows
                  // 11's own navigation panes.
                  Container(
                    width: 3,
                    height: 14,
                    margin: const EdgeInsets.only(right: 3),
                    decoration: BoxDecoration(
                      color: widget.selected ? text : Colors.transparent,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  // Select mode's box. The row takes the click, so the box
                  // only shows it; one column for every depth, so they line up.
                  if (widget.ticked != null)
                    IgnorePointer(
                      child: SizedBox(
                        width: 22,
                        height: 22,
                        child: Checkbox(
                          key: ValueKey('tick-${widget.rowId}'),
                          value: widget.ticked,
                          onChanged: (_) {},
                          visualDensity: VisualDensity.compact,
                          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                      ),
                    ),
                  // Indentation alone shows nesting, as in Explorer; guide lines
                  // made the panel busy without saying anything the indent and
                  // the chevrons do not.
                  SizedBox(width: widget.depth * kTreeIndent),
                  SizedBox(
                    width: 18,
                    child: widget.expanded == null
                        ? null
                        : InkWell(
                            borderRadius: BorderRadius.circular(3),
                            onTap: widget.onToggle,
                            child: AnimatedRotation(
                              turns: widget.expanded! ? 0.25 : 0,
                              duration: const Duration(milliseconds: 120),
                              child: Icon(Icons.chevron_right, size: 16, color: dim),
                            ),
                          ),
                  ),
                  // Icon and name: the part a double click opens. Detected by
                  // hand from the button presses rather than with a
                  // double-tap recognizer, which would have held every
                  // single click in the row -- the chevron and the "..."
                  // button included -- until the double-click time ran out.
                  Expanded(
                    child: Listener(
                      behavior: HitTestBehavior.opaque,
                      onPointerDown: _onNameDown,
                      child: Row(
                        children: [
                          _OpenBadge(
                            status: widget.openStatus,
                            cutout: AppPalette.of(context).panel,
                            child: widget.leading ?? Icon(widget.icon, size: 16, color: text),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: SizedBox(
                              height: kTreeRowHeight,
                              child: Row(
                                children: [
                                  // Expanded, with the host left at its natural width:
                                  // a Row lays out its inflexible children first, so
                                  // the name gets every pixel the host does not need.
                                  Expanded(
                                    child: Text(
                                      widget.title,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 13,
                                        height: 1.1,
                                        color: text,
                                        fontWeight: widget.bold ? FontWeight.w500 : FontWeight.w400,
                                      ),
                                    ),
                                  ),
                                  if (widget.favorite) ...[
                                    const SizedBox(width: 4),
                                    Icon(
                                      Icons.star_rounded,
                                      key: ValueKey('favorite-star-${widget.rowId}'),
                                      size: 12,
                                      color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.85),
                                    ),
                                  ],
                                  if (widget.subtitle != null && widget.subtitle!.isNotEmpty) ...[
                                    const SizedBox(width: 8),
                                    ConstrainedBox(
                                      // A long hostname must not squeeze the name out.
                                      constraints: const BoxConstraints(maxWidth: 120),
                                      child: Text(
                                        widget.subtitle!,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(fontSize: 11.5, height: 1.1, color: dim),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  // Swapped for the "..." button on hover, so the row never has to
                  // find room for both.
                  if (widget.trailingCount != null && !_hover)
                    Container(
                      margin: const EdgeInsets.only(left: 6, right: 6),
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                      decoration: BoxDecoration(
                        color: overlay.withValues(alpha: isDark ? 0.08 : 0.05),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        '${widget.trailingCount}',
                        style: TextStyle(fontSize: 10.5, color: dim, height: 1.2),
                      ),
                    ),
                  // Kept mounted (not conditionally built) even when hidden:
                  // opening the menu moves the cursor onto its overlay, the
                  // MouseRegion sees that as "exited", and a button removed from
                  // the tree right then lost the anchor the menu was opened from.
                  SizedBox(
                    key: _moreKey,
                    width: 24,
                    child: Opacity(
                      opacity: _hover ? 1 : 0,
                      child: IgnorePointer(
                        ignoring: !_hover,
                        child: InkWell(
                          borderRadius: BorderRadius.circular(4),
                          onTap: () => _showContextMenu(),
                          child: SizedBox(
                            height: kTreeRowHeight,
                            child: Icon(Icons.more_horiz, size: 15, color: dim),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A dot on the corner of a connection's icon while it has a tab open: green
/// once connected, amber while connecting, red if the session dropped. The
/// ring in the panel's colour keeps it legible where it overlaps the icon.
class _OpenBadge extends StatelessWidget {
  const _OpenBadge({required this.status, required this.cutout, required this.child});
  final SessionStatus? status;
  final Color cutout;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final s = status;
    if (s == null) return child;
    final color = switch (s) {
      SessionStatus.running => const Color(0xFF2EB85C),
      SessionStatus.starting => const Color(0xFFE0A526),
      SessionStatus.error || SessionStatus.closed => const Color(0xFFE5484D),
    };
    final label = switch (s) {
      SessionStatus.running => 'Connected',
      SessionStatus.starting => 'Connecting',
      SessionStatus.error => 'Disconnected',
      SessionStatus.closed => 'Session ended',
    };
    return Tooltip(
      message: tr(label),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          child,
          Positioned(
            right: -3,
            bottom: -2,
            child: Container(
              width: 9,
              height: 9,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
                border: Border.all(color: cutout, width: 1.5),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A square tool button the height of the search field: a soft tile that
/// lights up under the mouse.

/// The agent gateway, while MCP access is on; null otherwise.
AppMcpGateway? _mcpGateway(BuildContext context) {
  final server = Provider.of<McpServer?>(context, listen: false);
  final gateway = server?.gateway;
  return server != null && server.enabled && gateway is AppMcpGateway ? gateway : null;
}

/// Which connections the list shows.
enum TreeFilter {
  all('All', null),
  ssh('SSH', Icons.terminal_rounded),
  rdp('RDP', Icons.desktop_windows_outlined),
  favorites('Favorites', Icons.star_rounded);

  const TreeFilter(this.label, this.icon);
  final String label;
  final IconData? icon;

  bool matches(SavedConnection c, AppState app) => switch (this) {
        TreeFilter.all => true,
        TreeFilter.ssh => c.protocol == ConnectionProtocol.ssh,
        TreeFilter.rdp => c.protocol == ConnectionProtocol.rdp,
        TreeFilter.favorites => app.isFavorite(c.id),
      };
}

/// The chips under the search box: all connections, only SSH, only RDP, or
/// only the favorites. A chip with nothing behind it is left out, "All" aside.
class _FilterChips extends StatelessWidget {
  const _FilterChips({required this.value, required this.counts, required this.onChanged});

  final TreeFilter value;
  final Map<TreeFilter, int> counts;
  final ValueChanged<TreeFilter> onChanged;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final accent = Theme.of(context).colorScheme.primary;
    final shown = [
      for (final f in TreeFilter.values)
        if (f == TreeFilter.all || f == value || (counts[f] ?? 0) > 0) f,
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
      child: SizedBox(
        height: 24,
        child: ListView(
          scrollDirection: Axis.horizontal,
          children: [
            for (final f in shown)
              Padding(
                padding: const EdgeInsets.only(right: 10),
                child: _chip(f, palette, accent),
              ),
          ],
        ),
      ),
    );
  }

  Widget _chip(TreeFilter f, AppPalette palette, Color accent) {
    final on = f == value;
    // Plain words, the one that is on underlined: three framed chips in a
    // row made the head of the list heavy.
    final color = on ? palette.text : palette.textDim;
    // Favorites is a star alone; the others say what they are.
    final label = f == TreeFilter.favorites ? null : (f == TreeFilter.all ? tr(f.label) : f.label);
    return Tooltip(
      message: f == TreeFilter.favorites ? tr('Favorites') : '',
      child: InkWell(
        key: ValueKey('tree-filter-${f.name}'),
        // A second click on the one that is on goes back to everything.
        onTap: () => onChanged(on ? TreeFilter.all : f),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: on ? accent : Colors.transparent, width: 2)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (f.icon != null && label == null) Icon(f.icon, size: 13, color: on ? accent : color),
              if (label != null)
                Text(label, style: TextStyle(fontSize: 11.5, color: color, fontWeight: on ? FontWeight.w600 : null)),
              const SizedBox(width: 4),
              Text('${counts[f] ?? 0}', style: TextStyle(fontSize: 10.5, color: palette.textDim.withValues(alpha: 0.8))),
            ],
          ),
        ),
      ),
    );
  }
}

/// The colours a folder can take, and "No color". Pops the picked ARGB value,
/// or -1 for none.
class FolderColorDialog extends StatelessWidget {
  const FolderColorDialog({super.key, required this.name, this.current});

  final String name;
  final int? current;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return AlertDialog(
      title: Text(tr('Color for "{name}"', {'name': name})),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            tr('Shown on the folder, the folders inside it and the tabs of its connections.'),
            style: TextStyle(fontSize: 12, color: palette.textDim),
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final color in AppState.folderColors)
                InkWell(
                  key: ValueKey('folder-swatch-$color'),
                  customBorder: const CircleBorder(),
                  onTap: () => Navigator.of(context).pop(color),
                  child: Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      color: Color(color),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: color == current ? palette.text : Colors.transparent,
                        width: 2,
                      ),
                    ),
                    child: color == current ? const Icon(Icons.check, size: 16, color: Colors.white) : null,
                  ),
                ),
            ],
          ),
        ],
      ),
      actions: [
        TextButton(
          key: const Key('folder-color-none'),
          onPressed: () => Navigator.of(context).pop(-1),
          child: Text(tr('No color')),
        ),
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(tr('Cancel'))),
      ],
    );
  }
}
