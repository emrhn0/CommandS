import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:xterm/xterm.dart';

import '../providers/app_state.dart';
import '../services/mac_rdp_session.dart';
import '../services/pane_layout.dart';
import '../services/pty_session.dart';
import '../services/rdp_session.dart';
import '../services/session_controller.dart';
import '../services/terminal_appearance.dart';
import 'context_menu.dart';
import 'new_connection_dialog.dart';
import 'rdp_embed_view.dart';
import 'split_view_dialog.dart';
import 'terminal_clipboard.dart';
import '../l10n/strings.dart';

class TerminalTabsArea extends StatelessWidget {
  const TerminalTabsArea({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();

    if (app.tabs.isEmpty) {
      final dim = Theme.of(context).textTheme.bodySmall?.color;
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.terminal,
              size: 40,
              color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.35),
            ),
            const SizedBox(height: 14),
            Text(
              tr('No active session'),
              style: TextStyle(color: dim, fontSize: 15, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            Text(
              tr('Pick a saved connection on the left, use quick connect,\nor start a new one.'),
              textAlign: TextAlign.center,
              style: TextStyle(color: dim, fontSize: 12),
            ),
            const SizedBox(height: 18),
            OutlinedButton.icon(
              onPressed: () => showNewConnectionDialog(context),
              icon: const Icon(Icons.add, size: 16),
              label: Text(tr('New Connection')),
            ),
          ],
        ),
      );
    }

    final layout = app.paneLayout ?? PaneLeaf(app.tabs[app.activeTabIndex.clamp(0, app.tabs.length - 1)].id);

    return Column(
      children: [
        _TabBarRow(app: app),
        const Divider(height: 1),
        Expanded(child: _PaneTreeView(node: layout)),
      ],
    );
  }
}

class _TabBarRow extends StatelessWidget {
  const _TabBarRow({required this.app});
  final AppState app;

  /// One chip per plain tab, and one per split group -- in the place of the
  /// group's first session -- so a split is a tab like any other.
  List<Widget> _chips(BuildContext context) {
    final visible = tabIdsInLayout(app.paneLayout);
    final shownGroups = <String>{};
    final chips = <Widget>[];
    for (var i = 0; i < app.tabs.length; i++) {
      final tab = app.tabs[i];
      final group = app.groupOf(tab.id);
      if (group != null) {
        if (!shownGroups.add(group.id)) continue;
        final members = app.tabs.where((t) => group.tabIds.contains(t.id)).toList();
        chips.add(
          _TabChip(
            title: group.name ?? tr('Split View'),
            tooltip: members.map(_tabTitle).join('\n'),
            active: app.activeGroupId == group.id,
            icon: Icons.space_dashboard_outlined,
            status: _groupStatus(members),
            onTap: () => app.activateGroup(group.id),
            onClose: () => app.closeGroup(group.id),
            onMenu: (at) => _showGroupMenu(context, app, group, at),
          ),
        );
        continue;
      }
      final isRdp = tab.controller is RdpSessionController || tab.controller is MacRdpSessionController;
      chips.add(
        _TabChip(
          title: _tabTitle(tab),
          active:
              app.activeGroupId == null &&
              (visible.contains(tab.id) || (app.paneLayout == null && i == app.activeTabIndex)),
          icon: isRdp ? Icons.desktop_windows_outlined : Icons.terminal,
          status: tab.controller.status,
          onTap: () => app.setActiveTab(i),
          onClose: () => app.closeTab(i),
          onMenu: (at) => _showTabMenu(context, app, tab, at),
        ),
      );
    }
    return chips;
  }

  @override
  Widget build(BuildContext context) {
    final chips = _chips(context);
    return SizedBox(
      height: 36,
      child: Row(
        children: [
          Expanded(
            child: ListView(scrollDirection: Axis.horizontal, children: chips),
          ),
          _SplitViewButton(active: app.activeGroupId != null, enabled: app.tabs.length > 1),
        ],
      ),
    );
  }
}

String _tabTitle(OpenTab tab) => tab.controller.tabTitle ?? tab.controller.host;

/// A split's dot: green only when every session in it is up.
SessionStatus _groupStatus(List<OpenTab> members) {
  final all = members.map((t) => t.controller.status).toSet();
  if (all.contains(SessionStatus.error) || all.contains(SessionStatus.closed)) return SessionStatus.error;
  if (all.contains(SessionStatus.starting)) return SessionStatus.starting;
  return SessionStatus.running;
}

/// Right-click on a split's tab.
Future<void> _showGroupMenu(BuildContext context, AppState app, TabGroup group, Offset at) async {
  final dropped = app.tabs
      .where((t) => group.tabIds.contains(t.id))
      .where((t) => t.controller.status == SessionStatus.error || t.controller.status == SessionStatus.closed)
      .where(canReconnect)
      .toList();
  final key = await showContextMenu(
    context,
    position: at,
    header: group.name ?? tr('Split View'),
    actions: [
      if (dropped.isNotEmpty) const MenuAction('reconnect', 'Reconnect dropped sessions', Icons.refresh),
      MenuAction(
        'edit',
        'Edit split view…',
        Icons.vertical_split_outlined,
        separatorBefore: dropped.isNotEmpty,
      ),
      MenuAction('ungroup', 'Separate into tabs', Icons.tab_outlined),
      MenuAction('close', 'Close all sessions', Icons.close, separatorBefore: true),
    ],
  );
  if (key == null || !context.mounted) return;
  switch (key) {
    case 'reconnect':
      dropped.forEach(reconnectTab);
    case 'edit':
      app.activateGroup(group.id);
      await showSplitViewDialog(context);
    case 'ungroup':
      app.ungroup(group.id);
    case 'close':
      app.closeGroup(group.id);
  }
}

/// Every session can be started again from its tab -- a quick connection
/// included, which otherwise meant typing its address in again.
bool canReconnect(OpenTab tab) {
  final c = tab.controller;
  return c is PtySessionController || c is RdpSessionController || c is MacRdpSessionController;
}

void reconnectTab(OpenTab tab) {
  final c = tab.controller;
  if (c is PtySessionController) {
    c.reconnect();
  } else if (c is RdpSessionController) {
    // The pane reports its size on the next layout, as on first connect.
    c.reconnect(null, 1);
  } else if (c is MacRdpSessionController) {
    c.relaunch();
  }
}

/// Right-click on a tab. A quick connection can be saved from here, with
/// what it is connected to already filled in; a saved one can be edited.
Future<void> _showTabMenu(BuildContext context, AppState app, OpenTab tab, Offset at) async {
  final unsaved = app.unsavedConnectionOf(tab);
  final saved = unsaved == null ? app.connections.where((c) => c.id == tab.connectionId).firstOrNull : null;
  final key = await showContextMenu(
    context,
    position: at,
    header: tab.controller.tabTitle ?? tab.controller.host,
    actions: [
      // First when the session has dropped: that is what the menu is for then.
      if (canReconnect(tab)) const MenuAction('reconnect', 'Reconnect', Icons.refresh),
      if (unsaved != null)
        MenuAction(
          'save',
          'Save connection…',
          Icons.bookmark_add_outlined,
          separatorBefore: canReconnect(tab),
        ),
      if (saved != null)
        MenuAction('edit', 'Edit connection…', Icons.tune, separatorBefore: canReconnect(tab)),
      const MenuAction('close', 'Close tab', Icons.close, separatorBefore: true),
    ],
  );
  if (key == null || !context.mounted) return;
  switch (key) {
    case 'reconnect':
      reconnectTab(tab);
    case 'save':
      final conn = await showSaveQuickConnectionDialog(context, unsaved!);
      if (conn != null) app.linkTabToConnection(tab.id, conn);
    case 'edit':
      await showEditConnectionDialog(context, saved!);
    case 'close':
      final index = app.tabs.indexOf(tab);
      if (index >= 0) app.closeTab(index);
  }
}

/// Opens Split view. Highlighted while the tab area is split, so it is also
/// where to look to undo one.
class _SplitViewButton extends StatelessWidget {
  const _SplitViewButton({required this.active, required this.enabled});
  final bool active;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Tooltip(
      message: enabled ? tr('Split View') : tr('Open a second tab to split the view'),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: TextButton.icon(
          onPressed: enabled ? () => showSplitViewDialog(context) : null,
          style: TextButton.styleFrom(
            backgroundColor: active ? theme.colorScheme.primary.withValues(alpha: 0.10) : null,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            visualDensity: VisualDensity.compact,
          ),
          icon: const Icon(Icons.vertical_split_outlined, size: 16),
          label: Text(tr('Split View'), style: const TextStyle(fontSize: 12)),
        ),
      ),
    );
  }
}

class _TabChip extends StatelessWidget {
  const _TabChip({
    required this.title,
    required this.active,
    required this.icon,
    required this.status,
    required this.onTap,
    required this.onClose,
    required this.onMenu,
    this.tooltip,
  });

  final String title;
  final bool active;
  final IconData icon;

  /// For a split: the sessions in it.
  final String? tooltip;
  final SessionStatus status;
  final VoidCallback onTap;
  final VoidCallback onClose;
  final ValueChanged<Offset> onMenu;

  Widget _chip(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      constraints: const BoxConstraints(minWidth: 120, maxWidth: 200),
      margin: const EdgeInsets.only(right: 2),
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: active ? scheme.surface : Colors.transparent,
        border: Border(bottom: BorderSide(color: active ? scheme.primary : Colors.transparent, width: 2)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.max,
        children: [
          // The session's current status, read directly. It used to come from
          // a StreamBuilder with no initial value, which only learns of the
          // *next* change: a chip rebuilt after its session had connected
          // (applying a split does that) sat grey until something else
          // happened. The tab bar rebuilds on every status change anyway.
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(
              color: switch (status) {
                SessionStatus.running => const Color(0xFF2EB85C),
                SessionStatus.starting => const Color(0xFFE0A526),
                SessionStatus.error || SessionStatus.closed => const Color(0xFFE5484D),
              },
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 6),
          Icon(icon, size: 12),
          const SizedBox(width: 4),
          Expanded(
            child: Text(title, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
          ),
          InkWell(
            onTap: onClose,
            child: const Padding(padding: EdgeInsets.all(2), child: Icon(Icons.close, size: 14)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final chip = GestureDetector(
      onTap: onTap,
      onSecondaryTapDown: (d) => onMenu(d.globalPosition),
      child: _chip(context),
    );
    return tooltip == null
        ? chip
        : Tooltip(message: tooltip!, waitDuration: const Duration(milliseconds: 600), child: chip);
  }
}

/// Renders the tiling tree: a single pane, or a resizable split of two
/// sub-trees. Every leaf currently in the tree is mounted and visible at
/// once (there is no hidden IndexedStack sibling anymore — a tab not in the
/// tree just isn't rendered here at all).
class _PaneTreeView extends StatelessWidget {
  const _PaneTreeView({required this.node});
  final PaneNode node;

  @override
  Widget build(BuildContext context) {
    final n = node;
    if (n is PaneLeaf) {
      final app = context.watch<AppState>();
      OpenTab? tab;
      for (final t in app.tabs) {
        if (t.id == n.tabId) {
          tab = t;
          break;
        }
      }
      if (tab == null) return const SizedBox.shrink();
      return _SessionPane(key: ValueKey(tab.id), controller: tab.controller, active: true);
    }
    final split = n as PaneSplit;
    return _ResizableSplit(split: split);
  }
}

class _ResizableSplit extends StatefulWidget {
  const _ResizableSplit({required this.split});
  final PaneSplit split;

  @override
  State<_ResizableSplit> createState() => _ResizableSplitState();
}

class _ResizableSplitState extends State<_ResizableSplit> {
  @override
  Widget build(BuildContext context) {
    final isRow = widget.split.axis == Axis.horizontal;
    return LayoutBuilder(
      builder: (context, constraints) {
        final total = isRow ? constraints.maxWidth : constraints.maxHeight;
        return Flex(
          direction: widget.split.axis,
          children: [
            Expanded(
              flex: (widget.split.ratio * 1000).round(),
              child: _PaneTreeView(node: widget.split.first),
            ),
            MouseRegion(
              cursor: isRow ? SystemMouseCursors.resizeColumn : SystemMouseCursors.resizeRow,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onPanUpdate: (details) {
                  final delta = isRow ? details.delta.dx : details.delta.dy;
                  setState(() {
                    widget.split.ratio = (widget.split.ratio + delta / total).clamp(0.12, 0.88);
                  });
                },
                child: Container(
                  width: isRow ? 6 : null,
                  height: isRow ? null : 6,
                  color: Theme.of(context).dividerColor,
                ),
              ),
            ),
            Expanded(
              flex: ((1 - widget.split.ratio) * 1000).round(),
              child: _PaneTreeView(node: widget.split.second),
            ),
          ],
        );
      },
    );
  }
}

/// Picks the right view for whatever kind of session this tab holds.
class _SessionPane extends StatelessWidget {
  const _SessionPane({super.key, required this.controller, required this.active});
  final SessionController controller;
  final bool active;

  @override
  Widget build(BuildContext context) {
    if (controller is RdpSessionController) {
      return RdpEmbedView(controller: controller as RdpSessionController, active: active);
    }
    if (controller is MacRdpSessionController) {
      return _MacRdpPane(controller: controller as MacRdpSessionController);
    }
    return _TerminalPane(controller: controller as PtySessionController, active: active);
  }
}

/// macOS RDP tab. The session itself is a window of the Microsoft client
/// (see [MacRdpSessionController] for why it cannot be drawn in here yet),
/// so the pane reports what happened and offers to open it again.
class _MacRdpPane extends StatefulWidget {
  const _MacRdpPane({required this.controller});
  final MacRdpSessionController controller;

  @override
  State<_MacRdpPane> createState() => _MacRdpPaneState();
}

class _MacRdpPaneState extends State<_MacRdpPane> {
  bool _copied = false;

  Future<void> _copyPassword() async {
    final ok = await widget.controller.copyPasswordToClipboard();
    if (!mounted || !ok) return;
    setState(() => _copied = true);
    // Long enough to read, short enough that the pane doesn't keep claiming
    // the clipboard still holds the password after the user has moved on.
    Timer(const Duration(seconds: 12), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  /// What is actually left for the user to do, which is the only thing this
  /// pane can usefully say — it has no session to show.
  String _detail(SessionStatus status) {
    final controller = widget.controller;
    if (status == SessionStatus.error) {
      return controller.lastError ?? tr('Unknown error.');
    }
    if (status == SessionStatus.closed) {
      return tr('The {client} window for {host} has closed. Open it again to reconnect.', {
        'client': controller.backendName ?? 'RDP',
        'host': controller.host,
      });
    }
    final args = {'host': controller.host, 'client': controller.backendName ?? tr('the RDP client')};
    if (controller.credentialsHandedOver) {
      return tr(
        '{host} is open in {client}, in its own window, signed in with your saved credentials. '
        'macOS has no embeddable RDP component and does not let one app place another app’s window '
        'inside a tab, so the session cannot be drawn in here.',
        args,
      );
    }
    if (controller.freerdpWouldHelp) {
      return tr(
        '{host} is open in {client}, in its own window, with the host and username filled in — '
        '{client} keeps its own credential store, so the password is the one thing CommandS cannot '
        'hand it. Copy it below, or run "brew install freerdp" and CommandS will sign you in with '
        'no prompt at all.',
        args,
      );
    }
    return tr('{host} is open in {client}, in its own window, with the host and username filled in.', args);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dim = Theme.of(context).textTheme.bodySmall?.color;
    final controller = widget.controller;
    return StreamBuilder<SessionStatus>(
      stream: controller.statusStream,
      initialData: controller.status,
      builder: (context, snapshot) {
        final status = snapshot.data ?? SessionStatus.starting;
        final failed = status == SessionStatus.error;
        return Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 430),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  failed ? Icons.error_outline : Icons.desktop_windows_outlined,
                  size: 38,
                  color: failed ? scheme.error : scheme.primary.withValues(alpha: 0.5),
                ),
                const SizedBox(height: 14),
                Text(
                  tr(switch (status) {
                    SessionStatus.error => 'RDP session could not start',
                    SessionStatus.closed => 'RDP session closed',
                    _ => 'RDP session opened',
                  }),
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  _detail(status),
                  textAlign: TextAlign.center,
                  style: TextStyle(color: dim, fontSize: 12, height: 1.45),
                ),
                const SizedBox(height: 18),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    OutlinedButton.icon(
                      onPressed: controller.relaunch,
                      icon: const Icon(Icons.open_in_new, size: 16),
                      label: Text(tr(failed ? 'Try again' : 'Open again')),
                    ),
                    if (controller.freerdpWouldHelp) ...[
                      const SizedBox(width: 10),
                      OutlinedButton.icon(
                        onPressed: _copied ? null : _copyPassword,
                        icon: Icon(_copied ? Icons.check : Icons.copy, size: 16),
                        label: Text(tr(_copied ? 'Copied' : 'Copy password')),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _TerminalPane extends StatefulWidget {
  const _TerminalPane({required this.controller, required this.active});
  final PtySessionController controller;
  final bool active;

  @override
  State<_TerminalPane> createState() => _TerminalPaneState();
}

class _TerminalPaneState extends State<_TerminalPane> {
  final _focusNode = FocusNode();
  final _terminalController = TerminalController();
  late final TerminalClipboard _clipboard;

  @override
  void initState() {
    super.initState();
    _clipboard = TerminalClipboard(terminal: widget.controller.terminal, controller: _terminalController);
    if (widget.active) _focusAfterFrame();
  }

  @override
  void didUpdateWidget(_TerminalPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active) _focusAfterFrame();
  }

  void _focusAfterFrame() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.active) _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _clipboard.dispose();
    _terminalController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final style = terminalStyle(family: app.terminalFontFamily, size: app.terminalFontSize);
    return GestureDetector(
      onTap: () => _focusNode.requestFocus(),
      child: TerminalViewport(style: style, background: app.terminalBackground, child: _view(app, style)),
    );
  }

  Widget _view(AppState app, TerminalStyle style) {
    return TerminalView(
      widget.controller.terminal,
      controller: _terminalController,
      focusNode: _focusNode,
      autofocus: widget.active,
      // Desktop: take characters straight from hardware key events. The
      // default path routes printable characters through Flutter's IME
      // TextInput connection, which is only opened by TerminalView's own tap
      // handler -- so typing silently vanished while Enter and Backspace
      // (which travel the key-event path) still worked. That is what made
      // every password look wrong.
      hardwareKeyboardOnly: true,
      // PuTTY's keys: Ctrl+A/V/C go to the session, Shift+Insert pastes,
      // Ctrl+Insert copies (TerminalClipboard).
      shortcuts: TerminalClipboard.shortcuts,
      onKeyEvent: _clipboard.handleKey,
      // PuTTY: right-click pastes, selecting copies (TerminalClipboard).
      onSecondaryTapDown: (_, _) {
        _clipboard.paste();
        _focusNode.requestFocus();
      },
      textStyle: style,
      theme: TerminalThemes.withColors(
        background: app.terminalBackground,
        foreground: app.terminalForeground,
      ),
    );
  }
}

/// Frames a [TerminalView] so it stays inside its pane.
///
/// xterm scrolls its last line to the bottom edge and draws the line above
/// the first full one wherever it lands -- with no clipping, so in a pane
/// whose height was not a whole number of lines that half line was painted
/// over whatever sat above (the tab strip, or the pane above in a split).
/// The view is sized to whole lines, so there is no partial line at all, the
/// spare pixels go to the bottom margin, and it is clipped regardless.
class TerminalViewport extends StatelessWidget {
  const TerminalViewport({super.key, required this.style, required this.background, required this.child});

  final TerminalStyle style;
  final Color background;
  final Widget child;

  static const double margin = 6;

  /// The line height xterm itself uses: one laid-out line of the terminal's
  /// font, measured the way its painter measures it.
  static double cellHeight(TerminalStyle style, TextScaler scaler) {
    final painter = TextPainter(
      text: TextSpan(text: 'mmmmmmmmmm', style: style.toTextStyle()),
      textDirection: TextDirection.ltr,
      textScaler: scaler,
    )..layout();
    final h = painter.height;
    painter.dispose();
    return h;
  }

  @override
  Widget build(BuildContext context) {
    final line = cellHeight(style, MediaQuery.textScalerOf(context));
    return Container(
      // The terminal's own colour behind the margin too, so the gap reads as
      // part of the terminal rather than a frame around it.
      color: background,
      padding: const EdgeInsets.fromLTRB(8, margin, 6, 0),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // The container's top padding is already taken off.
          final available = constraints.maxHeight;
          final rows = line > 0 ? (available / line).floor() : 0;
          return Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              height: rows > 0 ? rows * line : available,
              child: ClipRect(
                // xterm offsets its first line by MediaQuery's padding (meant
                // for phone notches); a pane inside a window has none.
                child: MediaQuery.removePadding(
                  context: context,
                  removeTop: true,
                  removeBottom: true,
                  removeLeft: true,
                  removeRight: true,
                  child: child,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class TerminalThemes {
  static const dark = TerminalTheme(
    cursor: Color(0xFFF2F2F2),
    selection: Color(0x55F2F2F2),
    foreground: Color(0xFFE8E6E1),
    background: Color(0xFF14161A),
    black: Color(0xFF1B1E24),
    red: Color(0xFFE06C75),
    green: Color(0xFF98C379),
    yellow: Color(0xFFE5C07B),
    blue: Color(0xFF61AFEF),
    magenta: Color(0xFFC678DD),
    cyan: Color(0xFF56B6C2),
    white: Color(0xFFE8E6E1),
    brightBlack: Color(0xFF5C6370),
    brightRed: Color(0xFFE06C75),
    brightGreen: Color(0xFF98C379),
    brightYellow: Color(0xFFE5C07B),
    brightBlue: Color(0xFF61AFEF),
    brightMagenta: Color(0xFFC678DD),
    brightCyan: Color(0xFF56B6C2),
    brightWhite: Color(0xFFFFFFFF),
    searchHitBackground: Color(0xFF5C6370),
    searchHitBackgroundCurrent: Color(0xFFF2F2F2),
    searchHitForeground: Color(0xFF14161A),
  );

  static TerminalTheme withColors({required Color background, required Color foreground}) {
    return TerminalTheme(
      cursor: dark.cursor,
      selection: dark.selection,
      foreground: foreground,
      background: background,
      black: dark.black,
      red: dark.red,
      green: dark.green,
      yellow: dark.yellow,
      blue: dark.blue,
      magenta: dark.magenta,
      cyan: dark.cyan,
      white: foreground,
      brightBlack: dark.brightBlack,
      brightRed: dark.brightRed,
      brightGreen: dark.brightGreen,
      brightYellow: dark.brightYellow,
      brightBlue: dark.brightBlue,
      brightMagenta: dark.brightMagenta,
      brightCyan: dark.brightCyan,
      brightWhite: Colors.white,
      searchHitBackground: dark.searchHitBackground,
      searchHitBackgroundCurrent: dark.searchHitBackgroundCurrent,
      searchHitForeground: background,
    );
  }
}
