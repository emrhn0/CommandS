import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../models/models.dart';
import '../providers/app_state.dart';
import '../theme/app_theme.dart';
import 'device_icon.dart';

/// One thing quick search can go to. [depth] is how far inside a found
/// folder it sits: 0 for a match of its own, 1 for what is directly in a
/// found folder, and so on.
class QuickSearchResult {
  const QuickSearchResult.connection(SavedConnection this.connection, {this.depth = 0}) : folder = null;
  const QuickSearchResult.folder(ConnectionFolder this.folder, {this.depth = 0}) : connection = null;

  final SavedConnection? connection;
  final ConnectionFolder? folder;
  final int depth;

  String get id => connection?.id ?? folder!.id;
}

/// What quick search lists for [query]: first the folders whose name has it,
/// each followed by what is inside it in the list's own order, then the
/// connections whose name, host or user name has it, favorites and recent
/// ones first. A connection inside a found folder is listed there, not twice.
/// With no query: the favorites, then the recent.
List<QuickSearchResult> quickSearch(AppState app, String query, {int limit = 40, int contentsLimit = 200}) {
  final q = query.trim().toLowerCase();
  final favorites = app.favoriteConnectionIds;
  final recent = app.recentConnectionIds;
  int rank(SavedConnection c) {
    final f = favorites.indexOf(c.id);
    if (f >= 0) return f;
    final r = recent.indexOf(c.id);
    if (r >= 0) return 1000 + r;
    return 100000;
  }

  if (q.isEmpty) {
    final seen = <String>{};
    return [
      for (final c in [...app.favoriteConnections, ...app.recentConnections])
        if (seen.add(c.id)) QuickSearchResult.connection(c),
    ].take(limit).toList();
  }
  bool has(String? s) => s != null && s.toLowerCase().contains(q);

  final parentOf = {for (final f in app.folders) f.id: f.parentId};
  final found = {for (final f in app.folders) if (has(f.name)) f.id};
  /// Whether [folderId] or a folder above it was found.
  bool inFound(String? folderId) {
    final seen = <String>{};
    for (var id = folderId; id != null && seen.add(id); id = parentOf[id]) {
      if (found.contains(id)) return true;
    }
    return false;
  }

  final connections = app.connections
      .where((c) => !inFound(c.folderId) && (has(c.name) || has(c.host) || has(app.resolved(c).username)))
      .toList()
    ..sort((a, b) {
      final byRank = rank(a).compareTo(rank(b));
      if (byRank != 0) return byRank;
      // A name that starts with the query before one that only contains it.
      final aStarts = a.name.toLowerCase().startsWith(q) ? 0 : 1;
      final bStarts = b.name.toLowerCase().startsWith(q) ? 0 : 1;
      if (aStarts != bStarts) return aStarts.compareTo(bStarts);
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
  // A found folder inside another found folder is shown in that one's block.
  final folders = app.folders.where((f) => found.contains(f.id) && !inFound(f.parentId)).toList()
    ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

  // Found folders come first, each with everything inside it; then the
  // connections found elsewhere.
  final out = <QuickSearchResult>[];
  void contents(String folderId, int depth, Set<String> seen) {
    if (!seen.add(folderId)) return;
    for (final f in app.sortFolders(app.folders.where((f) => f.parentId == folderId).toList())) {
      if (out.length >= contentsLimit) return;
      out.add(QuickSearchResult.folder(f, depth: depth));
      contents(f.id, depth + 1, seen);
    }
    for (final c in app.sortConnections(app.connections.where((c) => c.folderId == folderId).toList())) {
      if (out.length >= contentsLimit) return;
      out.add(QuickSearchResult.connection(c, depth: depth));
    }
  }

  for (final f in folders) {
    if (out.length >= contentsLimit) break;
    out.add(QuickSearchResult.folder(f));
    contents(f.id, 1, <String>{});
  }
  out.addAll([for (final c in connections.take(limit)) QuickSearchResult.connection(c)]);
  return out;
}

/// Where the mouse last was over the app window, in global coordinates, so
/// Ctrl+K can open quick search there. The home screen keeps it up to date.
Offset? lastPointerPosition;

/// Quick search over every connection and folder (Ctrl+K, or the search box
/// in the title bar). Enter connects to a connection, or shows a folder in
/// the connection list.
///
/// With [anchor] (the title bar's search box, in global coordinates) the box
/// itself becomes the field: same place, same size, and the results open
/// right under it. With [at] (Ctrl+K: the mouse) the search opens there,
/// kept on screen. Otherwise it sits high in the middle. It is a route either
/// way, so embedded Remote Desktop sessions step aside while it is open.
Future<void> showQuickSearch(BuildContext context, {Rect? anchor, Offset? at}) {
  return showDialog<void>(
    context: context,
    barrierColor: anchor != null || at != null ? Colors.transparent : Colors.black.withValues(alpha: 0.25),
    builder: (_) => _QuickSearchDialog(anchor: anchor, at: at),
  );
}

class _QuickSearchDialog extends StatefulWidget {
  const _QuickSearchDialog({this.anchor, this.at});

  final Rect? anchor;
  final Offset? at;

  @override
  State<_QuickSearchDialog> createState() => _QuickSearchDialogState();
}

class _QuickSearchDialogState extends State<_QuickSearchDialog> {
  final _field = TextEditingController();
  final _list = ScrollController();
  int _selected = 0;

  static const _rowHeight = 40.0;

  /// The full panel's width, and its tallest: field, nine rows and the hint.
  static const _panelWidth = 560.0;
  static const _panelHeight = 48 + _rowHeight * 9 + 8 + 30;

  /// Under the title bar's box the results are at least this wide, so a
  /// name, an address and a folder still fit on a row.
  static const _dropdownMinWidth = 460.0;

  @override
  void dispose() {
    _field.dispose();
    _list.dispose();
    super.dispose();
  }

  void _go(QuickSearchResult r) {
    final app = context.read<AppState>();
    Navigator.of(context).pop();
    final conn = r.connection;
    if (conn != null) {
      app.openConnection(conn);
    } else {
      app.reveal(r.folder!.id);
    }
  }

  void _moveSelection(int by, int count) {
    if (count == 0) return;
    setState(() => _selected = (_selected + by).clamp(0, count - 1));
    if (!_list.hasClients) return;
    final top = _selected * _rowHeight;
    final p = _list.position;
    if (top < p.pixels) {
      _list.jumpTo(top);
    } else if (top + _rowHeight > p.pixels + p.viewportDimension) {
      _list.jumpTo(top + _rowHeight - p.viewportDimension);
    }
  }

  /// The text field, with the arrow keys moving through [results].
  Widget _input(List<QuickSearchResult> results, AppPalette palette, {required double fontSize}) {
    return Focus(
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
        if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
          _moveSelection(1, results.length);
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
          _moveSelection(-1, results.length);
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: TextField(
        key: const Key('quick-search-field'),
        controller: _field,
        autofocus: true,
        style: TextStyle(fontSize: fontSize, color: palette.text),
        decoration: InputDecoration(
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
          filled: false,
          isDense: true,
          contentPadding: EdgeInsets.zero,
          hintText: tr('Search connections and folders'),
          hintStyle: TextStyle(fontSize: fontSize, color: palette.textDim),
        ),
        onChanged: (_) => setState(() => _selected = 0),
        onSubmitted: (_) {
          if (results.isNotEmpty) _go(results[_selected]);
        },
      ),
    );
  }

  /// The results (or what to type), and the keys' hint under them.
  List<Widget> _resultsAndHint(List<QuickSearchResult> results, AppPalette palette, Color accent) => [
        if (results.isEmpty)
          Padding(
            padding: const EdgeInsets.all(18),
            child: Text(
              _field.text.trim().isEmpty
                  ? tr('Type a name, an address or a folder.')
                  : tr('Nothing found for "{query}".', {'query': _field.text.trim()}),
              style: TextStyle(fontSize: 13, color: palette.textDim),
            ),
          )
        else
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: _rowHeight * 9),
            child: ListView.builder(
              controller: _list,
              shrinkWrap: true,
              padding: const EdgeInsets.symmetric(vertical: 4),
              itemCount: results.length,
              itemExtent: _rowHeight,
              itemBuilder: (context, i) => QuickSearchRow(
                result: results[i],
                selected: i == _selected,
                accent: accent,
                palette: palette,
                onTap: () => _go(results[i]),
                onHover: () => setState(() => _selected = i),
              ),
            ),
          ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
          decoration: BoxDecoration(border: Border(top: BorderSide(color: palette.border))),
          child: Text(
            tr('↑ ↓ to choose · Enter connects to a connection or shows a folder in the list'),
            style: TextStyle(fontSize: 11, color: palette.textDim),
          ),
        ),
      ];

  Widget _card(AppPalette palette, {required Widget child, Key? key, double? width}) => Material(
        color: palette.panel,
        elevation: 12,
        shadowColor: Colors.black54,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: palette.border)),
        clipBehavior: Clip.antiAlias,
        child: SizedBox(key: key, width: width, child: child),
      );

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final palette = AppPalette.of(context);
    final accent = Theme.of(context).colorScheme.primary;
    final results = quickSearch(app, _field.text);
    if (_selected >= results.length) _selected = results.isEmpty ? 0 : results.length - 1;
    final anchor = widget.anchor;
    if (anchor != null) return _inTitleBar(anchor, results, palette, accent);

    final panel = _card(
      palette,
      key: const Key('quick-search'),
      width: _panelWidth,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
            child: Row(
              children: [
                Icon(Icons.search, size: 18, color: palette.textDim),
                const SizedBox(width: 10),
                Expanded(child: _input(results, palette, fontSize: 15)),
                Text('Esc', style: TextStyle(fontSize: 11, color: palette.textDim)),
              ],
            ),
          ),
          Divider(height: 1, color: palette.border),
          ..._resultsAndHint(results, palette, accent),
        ],
      ),
    );
    final at = widget.at;
    if (at == null) return Align(alignment: const Alignment(0, -0.55), child: panel);
    // At the mouse: centred on it, just below, and moved in so it all shows.
    return LayoutBuilder(
      builder: (context, constraints) {
        final left = (at.dx - _panelWidth / 2)
            .clamp(8.0, (constraints.maxWidth - _panelWidth - 8).clamp(8.0, double.infinity));
        final top = (at.dy + 8).clamp(8.0, (constraints.maxHeight - _panelHeight - 8).clamp(8.0, double.infinity));
        return Stack(children: [
          Positioned(key: const Key('quick-search-at-pointer'), left: left, top: top, child: panel),
        ]);
      },
    );
  }

  /// The title bar's box turned into the field, where it was and as big as
  /// it was, with the results opening under it.
  Widget _inTitleBar(Rect anchor, List<QuickSearchResult> results, AppPalette palette, Color accent) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = anchor.width < _dropdownMinWidth ? _dropdownMinWidth : anchor.width;
        final left = (anchor.center.dx - width / 2)
            .clamp(8.0, (constraints.maxWidth - width - 8).clamp(8.0, double.infinity));
        return Stack(children: [
          Positioned.fromRect(
            key: const Key('quick-search-anchored'),
            rect: anchor,
            child: Material(
              type: MaterialType.transparency,
              child: Container(
                key: const Key('quick-search-box'),
                padding: const EdgeInsets.symmetric(horizontal: 9),
                decoration: BoxDecoration(
                  color: palette.panelAlt,
                  border: Border.all(color: accent.withValues(alpha: 0.7)),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Row(
                  children: [
                    Icon(Icons.search, size: 14, color: palette.textDim),
                    const SizedBox(width: 7),
                    Expanded(child: _input(results, palette, fontSize: 12)),
                    Text('Esc', style: TextStyle(fontSize: 10.5, color: palette.textDim)),
                  ],
                ),
              ),
            ),
          ),
          Positioned(
            left: left,
            top: anchor.bottom + 6,
            child: _card(
              palette,
              key: const Key('quick-search'),
              width: width,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: _resultsAndHint(results, palette, accent),
              ),
            ),
          ),
        ]);
      },
    );
  }
}

/// One result: its icon, name, address and where it is. Rows inside a found
/// folder are indented under it and leave the folder path out.
class QuickSearchRow extends StatelessWidget {
  const QuickSearchRow({
    super.key,
    required this.result,
    required this.selected,
    required this.accent,
    required this.palette,
    required this.onTap,
    required this.onHover,
    this.keyPrefix = 'quick-search-',
  });

  /// What the row's key starts with, before the id.
  final String keyPrefix;

  final QuickSearchResult result;
  final bool selected;
  final Color accent;
  final AppPalette palette;
  final VoidCallback onTap;
  final VoidCallback onHover;

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final conn = result.connection;
    final folder = result.folder;
    final path = result.depth > 0 ? '' : app.folderNamesOf(conn?.folderId ?? folder?.parentId).join(' › ');
    final kind = conn == null ? null : DeviceIcon.of(conn);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => onHover(),
      child: GestureDetector(
        key: Key('$keyPrefix${result.id}'),
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 6),
          padding: EdgeInsets.only(left: 10.0 + 18.0 * result.depth, right: 10),
          decoration: BoxDecoration(
            color: selected ? accent.withValues(alpha: 0.13) : Colors.transparent,
            borderRadius: BorderRadius.circular(7),
          ),
          child: Row(
            children: [
              SizedBox(
                width: 22,
                child: folder != null
                    ? Icon(Icons.folder_outlined, size: 17, color: palette.textDim)
                    : kind != null
                        ? DeviceIcon(kind)
                        : Icon(
                            conn!.protocol == ConnectionProtocol.rdp ? Icons.desktop_windows_outlined : Icons.terminal,
                            size: 16,
                            color: palette.textDim,
                          ),
              ),
              const SizedBox(width: 10),
              Flexible(
                child: Text(
                  conn?.name ?? folder!.name,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13.5, color: palette.text, fontWeight: selected ? FontWeight.w600 : FontWeight.w400),
                ),
              ),
              if (conn != null && app.isFavorite(conn.id)) ...[
                const SizedBox(width: 4),
                Icon(Icons.star_rounded, size: 12, color: accent),
              ],
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  [if (conn != null && !conn.name.contains(conn.host)) conn.host, if (path.isNotEmpty) path].join('  ·  '),
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11.5, color: palette.textDim),
                ),
              ),
              if (selected)
                Text(
                  conn != null ? tr('Connect') : tr('Show'),
                  style: TextStyle(fontSize: 11, color: accent, fontWeight: FontWeight.w600),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
