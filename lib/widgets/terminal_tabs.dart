import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:xterm/xterm.dart';
import '../providers/app_state.dart';
import '../services/pane_layout.dart';
import '../services/pty_session.dart';
import '../services/rdp_session.dart';
import '../services/session_controller.dart';
import 'new_connection_dialog.dart';
import 'rdp_embed_view.dart';

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
            Icon(Icons.terminal, size: 40, color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.35)),
            const SizedBox(height: 14),
            Text('No active session', style: TextStyle(color: dim, fontSize: 15, fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            Text(
              'Pick a saved connection on the left, use quick connect,\nor start a new one.',
              textAlign: TextAlign.center,
              style: TextStyle(color: dim, fontSize: 12),
            ),
            const SizedBox(height: 18),
            OutlinedButton.icon(
              onPressed: () => showNewConnectionDialog(context),
              icon: const Icon(Icons.add, size: 16),
              label: const Text('New Connection'),
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

  @override
  Widget build(BuildContext context) {
    final visible = tabIdsInLayout(app.paneLayout);
    return SizedBox(
      height: 36,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: app.tabs.length,
        itemBuilder: (ctx, i) {
          final tab = app.tabs[i];
          final active = visible.contains(tab.id) || (app.paneLayout == null && i == app.activeTabIndex);
          return _TabChip(
            tabId: tab.id,
            title: tab.controller.tabTitle ?? tab.controller.host,
            active: active,
            isRdp: tab.controller is RdpSessionController,
            statusStream: tab.controller.statusStream,
            onTap: () => app.setActiveTab(i),
            onClose: () => app.closeTab(i),
          );
        },
      ),
    );
  }
}

class _TabChip extends StatelessWidget {
  const _TabChip({
    required this.tabId,
    required this.title,
    required this.active,
    required this.isRdp,
    required this.statusStream,
    required this.onTap,
    required this.onClose,
  });

  final String tabId;
  final String title;
  final bool active;
  final bool isRdp;
  final Stream<SessionStatus> statusStream;
  final VoidCallback onTap;
  final VoidCallback onClose;

  Widget _chip(BuildContext context, {bool dragging = false}) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      constraints: const BoxConstraints(minWidth: 120, maxWidth: 200),
      margin: const EdgeInsets.only(right: 2),
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: active ? scheme.surface : Colors.transparent,
        border: Border(
          bottom: BorderSide(color: active && !dragging ? scheme.primary : Colors.transparent, width: 2),
        ),
      ),
      child: Row(
        mainAxisSize: dragging ? MainAxisSize.min : MainAxisSize.max,
        children: [
          StreamBuilder<SessionStatus>(
            stream: statusStream,
            builder: (ctx, snap) {
              final s = snap.data;
              Color color = Colors.grey;
              if (s == SessionStatus.running) color = Colors.greenAccent;
              if (s == SessionStatus.error || s == SessionStatus.closed) color = Colors.redAccent;
              return Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              );
            },
          ),
          const SizedBox(width: 6),
          Icon(isRdp ? Icons.desktop_windows_outlined : Icons.terminal, size: 12),
          const SizedBox(width: 4),
          if (dragging)
            Text(title, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12))
          else ...[
            Expanded(
              child: Text(title, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
            ),
            InkWell(
              onTap: onClose,
              child: const Padding(
                padding: EdgeInsets.all(2),
                child: Icon(Icons.close, size: 14),
              ),
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Drag a tab onto the terminal area (Termius/Windows-Snap style) to tile
    // it alongside whatever pane it's dropped on.
    return Draggable<String>(
      data: tabId,
      feedback: Material(
        color: Colors.transparent,
        elevation: 4,
        child: Opacity(opacity: 0.9, child: _chip(context, dragging: true)),
      ),
      childWhenDragging: Opacity(opacity: 0.35, child: _chip(context)),
      child: GestureDetector(onTap: onTap, child: _chip(context)),
    );
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
      return _DropZone(
        tabId: n.tabId,
        child: _SessionPane(key: ValueKey(tab.id), controller: tab.controller, active: true),
      );
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

/// Wraps one pane so dragging a tab chip over it previews and, on drop,
/// commits a split on whichever edge (left/right/top/bottom) the cursor is
/// nearest — a center drop is ignored (no split, matches "just switch tabs"
/// expectations instead of tiling by accident).
class _DropZone extends StatefulWidget {
  const _DropZone({required this.tabId, required this.child});
  final String tabId;
  final Widget child;

  @override
  State<_DropZone> createState() => _DropZoneState();
}

class _DropZoneState extends State<_DropZone> {
  final _key = GlobalKey();
  SplitEdge? _hoverEdge;

  SplitEdge? _edgeFor(Offset globalPosition) {
    final box = _key.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;
    final local = box.globalToLocal(globalPosition);
    final size = box.size;
    if (local.dx < 0 || local.dy < 0 || local.dx > size.width || local.dy > size.height) return null;

    final left = local.dx;
    final right = size.width - local.dx;
    final top = local.dy;
    final bottom = size.height - local.dy;
    final minDist = math.min(math.min(left, right), math.min(top, bottom));

    // Middle 44% of the pane in both axes is a dead zone — drop there to
    // just cancel (no accidental splits from an imprecise drop).
    if (minDist > size.width * 0.28 && minDist > size.height * 0.28) return null;

    if (minDist == left) return SplitEdge.left;
    if (minDist == right) return SplitEdge.right;
    if (minDist == top) return SplitEdge.top;
    return SplitEdge.bottom;
  }

  @override
  Widget build(BuildContext context) {
    return DragTarget<String>(
      onWillAcceptWithDetails: (details) => details.data != widget.tabId,
      onMove: (details) => setState(() => _hoverEdge = _edgeFor(details.offset)),
      onLeave: (_) => setState(() => _hoverEdge = null),
      onAcceptWithDetails: (details) {
        final edge = _edgeFor(details.offset);
        setState(() => _hoverEdge = null);
        if (edge != null) {
          context.read<AppState>().splitPane(draggedTabId: details.data, targetTabId: widget.tabId, edge: edge);
        }
      },
      builder: (context, candidateData, rejectedData) {
        return Stack(
          key: _key,
          fit: StackFit.expand,
          children: [
            widget.child,
            if (_hoverEdge != null) _EdgePreview(edge: _hoverEdge!),
          ],
        );
      },
    );
  }
}

class _EdgePreview extends StatelessWidget {
  const _EdgePreview({required this.edge});
  final SplitEdge edge;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    Alignment align;
    double widthFactor = 1, heightFactor = 1;
    switch (edge) {
      case SplitEdge.left:
        align = Alignment.centerLeft;
        widthFactor = 0.5;
      case SplitEdge.right:
        align = Alignment.centerRight;
        widthFactor = 0.5;
      case SplitEdge.top:
        align = Alignment.topCenter;
        heightFactor = 0.5;
      case SplitEdge.bottom:
        align = Alignment.bottomCenter;
        heightFactor = 0.5;
    }
    return IgnorePointer(
      child: Align(
        alignment: align,
        child: FractionallySizedBox(
          widthFactor: widthFactor,
          heightFactor: heightFactor,
          child: Container(
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.22),
              border: Border.all(color: accent, width: 2),
            ),
          ),
        ),
      ),
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
    return _TerminalPane(controller: controller as PtySessionController, active: active);
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

  @override
  void initState() {
    super.initState();
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
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return GestureDetector(
      onTap: () => _focusNode.requestFocus(),
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: TerminalView(
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
          theme: TerminalThemes.withColors(background: app.terminalBackground, foreground: app.terminalForeground),
        ),
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
