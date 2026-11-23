import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../models/models.dart';
import '../providers/app_state.dart';
import '../services/app_commands.dart';
import '../theme/app_theme.dart';

/// Returns the chosen command; the caller runs it after this route closes.
Future<AppCommandId?> showCommandPalette(BuildContext context) =>
    showDialog<AppCommandId>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.30),
      builder: (_) => const _CommandPalette(),
    );

class _CommandPalette extends StatefulWidget {
  const _CommandPalette();

  @override
  State<_CommandPalette> createState() => _CommandPaletteState();
}

class _CommandPaletteState extends State<_CommandPalette> {
  final _search = TextEditingController();
  final _scroll = ScrollController();
  int _selected = 0;

  @override
  void dispose() {
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _move(int delta, int count) {
    if (count == 0) return;
    setState(() => _selected = (_selected + delta).clamp(0, count - 1));
    if (_scroll.hasClients)
      _scroll.animateTo(
        (_selected * 46.0).clamp(0, _scroll.position.maxScrollExtent),
        duration: const Duration(milliseconds: 100),
        curve: Curves.easeOut,
      );
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final palette = AppPalette.of(context);
    final accent = Theme.of(context).colorScheme.primary;
    final raw = _search.text.trim();
    // "@" turns the palette to the saved connections: one opens on Enter.
    final connectionMode = raw.startsWith('@');
    final query = (connectionMode ? raw.substring(1).trim() : raw).toLowerCase();
    final commands = connectionMode
        ? const <AppCommand>[]
        : AppCommand.all
            .where(
              (command) =>
                  query.isEmpty ||
                  tr(command.title).toLowerCase().contains(query) ||
                  command.title.toLowerCase().contains(query),
            )
            .toList();
    final connections = connectionMode ? paletteConnections(app, query) : const <SavedConnection>[];
    final count = connectionMode ? connections.length : commands.length;
    if (_selected >= count) _selected = count == 0 ? 0 : count - 1;
    void choose(int index) {
      if (connectionMode) {
        final connection = connections[index];
        Navigator.of(context).pop();
        app.openConnection(connection);
        return;
      }
      final command = commands[index];
      if (app.canRunCommand(command.id)) Navigator.of(context).pop(command.id);
    }

    return Align(
      alignment: const Alignment(0, -0.55),
      child: Material(
        color: palette.panel,
        elevation: 12,
        shadowColor: Colors.black54,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: palette.border),
        ),
        clipBehavior: Clip.antiAlias,
        child: SizedBox(
          key: const Key('command-palette-dialog'),
          width: 580,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 14, 2),
                child: Text(
                  tr('Command palette'),
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: palette.textDim,
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 2, 14, 6),
                child: Focus(
                  onKeyEvent: (_, event) {
                    if (event is! KeyDownEvent && event is! KeyRepeatEvent)
                      return KeyEventResult.ignored;
                    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
                      _move(1, count);
                      return KeyEventResult.handled;
                    }
                    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
                      _move(-1, count);
                      return KeyEventResult.handled;
                    }
                    if (event.logicalKey == LogicalKeyboardKey.enter) {
                      if (count > 0) choose(_selected);
                      return KeyEventResult.handled;
                    }
                    return KeyEventResult.ignored;
                  },
                  child: TextField(
                    key: const Key('command-palette-search'),
                    controller: _search,
                    autofocus: true,
                    style: TextStyle(fontSize: 15, color: palette.text),
                    decoration: InputDecoration(
                      prefixIcon: Icon(
                        Icons.search,
                        size: 18,
                        color: palette.textDim,
                      ),
                      hintText: tr('Find a command, or type @ for a connection'),
                      hintStyle: TextStyle(color: palette.textDim),
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      filled: false,
                    ),
                    onChanged: (_) => setState(() => _selected = 0),
                    onSubmitted: (_) {
                      if (count > 0) choose(_selected);
                    },
                  ),
                ),
              ),
              Divider(height: 1, color: palette.border),
              if (count == 0)
                Padding(
                  padding: const EdgeInsets.all(18),
                  child: Text(
                    connectionMode ? tr('No matching connections') : tr('No matching commands'),
                    style: TextStyle(color: palette.textDim),
                  ),
                )
              else if (connectionMode)
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 46 * 8),
                  child: ListView.builder(
                    controller: _scroll,
                    shrinkWrap: true,
                    padding: const EdgeInsets.symmetric(vertical: 5),
                    itemExtent: 46,
                    itemCount: connections.length,
                    itemBuilder: (context, index) {
                      final connection = connections[index];
                      return Material(
                        color: index == _selected ? accent.withValues(alpha: 0.12) : Colors.transparent,
                        child: InkWell(
                          key: ValueKey('palette-connection-${connection.id}'),
                          onHover: (hover) {
                            if (hover) setState(() => _selected = index);
                          },
                          onTap: () => choose(index),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 17),
                            child: Row(
                              children: [
                                Icon(
                                  connection.protocol == ConnectionProtocol.rdp
                                      ? Icons.desktop_windows_outlined
                                      : Icons.terminal,
                                  size: 17,
                                  color: palette.textDim,
                                ),
                                const SizedBox(width: 13),
                                Expanded(
                                  child: Row(
                                    children: [
                                      Flexible(
                                        child: Text(
                                          connection.name,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(fontSize: 13, color: palette.text),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Flexible(
                                        child: Text(
                                          connection.host,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(fontSize: 12, color: palette.textDim),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                Text(tr('Open'), style: TextStyle(fontSize: 11, color: palette.textDim)),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                )
              else
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 46 * 8),
                  child: ListView.builder(
                    controller: _scroll,
                    shrinkWrap: true,
                    padding: const EdgeInsets.symmetric(vertical: 5),
                    itemExtent: 46,
                    itemCount: commands.length,
                    itemBuilder: (context, index) {
                      final command = commands[index];
                      final enabled = app.canRunCommand(command.id);
                      final selected = index == _selected;
                      final color = enabled
                          ? palette.text
                          : palette.textDim.withValues(alpha: 0.55);
                      final hotkey = app.hotkeyFor(command.id);
                      return Material(
                        color: selected
                            ? accent.withValues(alpha: 0.12)
                            : Colors.transparent,
                        child: InkWell(
                          key: ValueKey('command-${command.id.name}'),
                          onHover: (hover) {
                            if (hover) setState(() => _selected = index);
                          },
                          onTap: enabled ? () => choose(index) : null,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 17),
                            child: Row(
                              children: [
                                Icon(command.icon, size: 17, color: color),
                                const SizedBox(width: 13),
                                Expanded(
                                  child: Text(
                                    tr(command.title),
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 13,
                                      color: color,
                                    ),
                                  ),
                                ),
                                if (hotkey != null)
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 7,
                                      vertical: 3,
                                    ),
                                    decoration: BoxDecoration(
                                      color: palette.panelAlt,
                                      borderRadius: BorderRadius.circular(5),
                                    ),
                                    child: Text(
                                      hotkey.label,
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: palette.textDim,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 17,
                  vertical: 8,
                ),
                child: Text(
                  tr('↑ ↓ to choose · Enter to run · Esc to close'),
                  style: TextStyle(fontSize: 11, color: palette.textDim),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The saved connections the palette offers after "@": name or address
/// containing [query], favorites and recent ones first, at most 30.
List<SavedConnection> paletteConnections(AppState app, String query) {
  final q = query.toLowerCase();
  final matching = app.connections
      .where((c) => q.isEmpty || c.name.toLowerCase().contains(q) || c.host.toLowerCase().contains(q))
      .toList();
  int rank(SavedConnection c) {
    final recent = app.recentConnectionIds.indexOf(c.id);
    if (recent >= 0) return recent;
    return app.isFavorite(c.id) ? 100 : 1000;
  }
  // Stable: equal ranks keep the list's own order.
  final order = {for (var i = 0; i < matching.length; i++) matching[i].id: i};
  matching.sort((a, b) {
    final byRank = rank(a).compareTo(rank(b));
    return byRank != 0 ? byRank : order[a.id]!.compareTo(order[b.id]!);
  });
  return matching.take(30).toList();
}
