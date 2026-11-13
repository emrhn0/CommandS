import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:xterm/xterm.dart';

import '../providers/app_state.dart';
import '../services/mac_rdp_session.dart';
import '../services/pane_layout.dart';
import '../services/pty_session.dart';
import '../services/rdp_session.dart';
import '../services/serial_session.dart';
import '../services/session_controller.dart';
import '../services/terminal_appearance.dart';
import '../theme/app_theme.dart';
import 'context_menu.dart';
import 'new_connection_dialog.dart';
import 'rdp_embed_view.dart';
import 'split_view_dialog.dart';
import 'terminal_clipboard.dart';
import 'terminal_drag_select.dart';
import 'terminal_hover_scrollbar.dart';
import 'sftp_browser.dart';
import 'sftp_window.dart';
import 'threshold_draggable.dart';
import '../l10n/strings.dart';

class TerminalTabsArea extends StatelessWidget {
  const TerminalTabsArea({super.key, this.sidebarVisible = true});

  final bool sidebarVisible;

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
              sidebarVisible
                  ? tr('Pick a saved connection on the left, use quick connect,\nor start a new one.')
                  : tr('Show the sidebar to pick a saved connection,\nor start a new one.'),
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
        Expanded(
          child: Stack(
            fit: StackFit.expand,
            children: [
              _PaneTreeView(node: layout),
              if (app.draggingTabId != null && app.tabs.length > 1)
                _LayoutPicker(tabId: app.draggingTabId!, tabCount: app.tabs.length),
            ],
          ),
        ),
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
            key: ValueKey('group-${group.id}'),
            tabIds: members.map((t) => t.id).toList(),
            isGroup: true,
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
        // Each session of the split too, so one can be dragged back out.
        for (final m in members) {
          final index = app.tabs.indexOf(m);
          chips.add(
            _TabChip(
              key: ValueKey('member-${m.id}'),
              tabIds: [m.id],
              isGroup: false,
              nested: true,
              title: _tabTitle(m),
              active: app.activeGroupId == group.id,
              icon: _tabIcon(m),
              status: m.controller.status,
              onTap: () => app.activateGroup(group.id),
              onClose: () => app.closeTab(index),
              onMenu: (at) => _showTabMenu(context, app, m, at),
            ),
          );
        }
        continue;
      }
      chips.add(
        _TabChip(
          key: ValueKey('tab-${tab.id}'),
          tabIds: [tab.id],
          isGroup: false,
          title: _tabTitle(tab),
          active:
              app.activeGroupId == null &&
              (visible.contains(tab.id) || (app.paneLayout == null && i == app.activeTabIndex)),
          icon: _tabIcon(tab),
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
            // Behind the chips, the rest of the strip: a drop there goes last.
            child: DragTarget<_TabDrag>(
              onAcceptWithDetails: (d) => _moveInStrip(app, d.data, null),
              builder: (context, _, _) => ListView(scrollDirection: Axis.horizontal, children: chips),
            ),
          ),
          if (app.activeGroupId != null) _SeparateButton(groupId: app.activeGroupId!),
          _SplitViewButton(active: app.activeGroupId != null, enabled: app.tabs.length > 1),
        ],
      ),
    );
  }
}

String _tabTitle(OpenTab tab) => tab.controller.tabTitle ?? tab.controller.host;

IconData _tabIcon(OpenTab tab) {
  final c = tab.controller;
  if (c is RdpSessionController || c is MacRdpSessionController) return Icons.desktop_windows_outlined;
  if (c is SerialSessionController) return Icons.cable;
  return Icons.terminal;
}

/// A tab dropped on the strip goes to that place. A session dragged out of a
/// split leaves the split first; a split's own chip moves it whole.
void _moveInStrip(AppState app, _TabDrag drag, String? beforeTabId) {
  if (!drag.isGroup) {
    for (final id in drag.tabIds) {
      app.takeOutOfSplit(id);
    }
  }
  app.moveTabs(drag.tabIds, beforeTabId);
}

/// Next to Split view while a split is on screen: back to separate tabs.
class _SeparateButton extends StatelessWidget {
  const _SeparateButton({required this.groupId});
  final String groupId;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tr('Separate into tabs'),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: TextButton.icon(
          key: const ValueKey('separate-split'),
          onPressed: () => context.read<AppState>().ungroup(groupId),
          style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            visualDensity: VisualDensity.compact,
          ),
          icon: const Icon(Icons.call_split, size: 16),
          label: Text(tr('Separate'), style: const TextStyle(fontSize: 12)),
        ),
      ),
    );
  }
}

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
  final remote = app.tabs.where((t) => group.tabIds.contains(t.id)).where(canSendCtrlAltDel).toList();
  final key = await showContextMenu(
    context,
    position: at,
    header: group.name ?? tr('Split View'),
    actions: [
      if (dropped.isNotEmpty) const MenuAction('reconnect', 'Reconnect dropped sessions', Icons.refresh),
      for (final t in remote)
        MenuAction('ctrlaltdel:${t.id}', '${tr('Send Ctrl+Alt+Del')}: ${_tabTitle(t)}', Icons.keyboard),
      MenuAction(
        'edit',
        'Edit split view…',
        Icons.vertical_split_outlined,
        separatorBefore: dropped.isNotEmpty || remote.isNotEmpty,
      ),
      MenuAction('ungroup', 'Separate into tabs', Icons.tab_outlined),
      MenuAction('close', 'Close all sessions', Icons.close, separatorBefore: true),
    ],
  );
  if (key == null || !context.mounted) return;
  if (key.startsWith('ctrlaltdel:')) {
    final id = key.substring('ctrlaltdel:'.length);
    for (final t in remote) {
      if (t.id == id) (t.controller as RdpSessionController).sendCtrlAltDelete();
    }
    return;
  }
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
  return c is TerminalSessionController || c is RdpSessionController || c is MacRdpSessionController;
}

void reconnectTab(OpenTab tab) {
  final c = tab.controller;
  if (c is TerminalSessionController) {
    c.reconnect();
  } else if (c is RdpSessionController) {
    // The pane reports its size on the next layout, as on first connect.
    c.reconnect(null, 1);
  } else if (c is MacRdpSessionController) {
    c.relaunch();
  }
}

/// A live embedded session: the real keys never reach it, as Windows keeps
/// them, so it is sent from the tab's menu.
bool canSendCtrlAltDel(OpenTab tab) {
  final c = tab.controller;
  return c is RdpSessionController && c.status == SessionStatus.running;
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
      if (canSendCtrlAltDel(tab)) const MenuAction('ctrlaltdel', 'Send Ctrl+Alt+Del', Icons.keyboard),
      if (tab.controller case final PtySessionController ssh)
        ssh.sftpOpen.value
            ? const MenuAction('sftp', 'Close SFTP files', Icons.folder_off_rounded)
            : const MenuAction('sftp', 'SFTP files', Icons.folder_rounded),
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
    case 'ctrlaltdel':
      (tab.controller as RdpSessionController).sendCtrlAltDelete();
    case 'sftp':
      final ssh = tab.controller as PtySessionController;
      ssh.sftpOpen.value = !ssh.sftpOpen.value;
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

/// What dragging a tab's chip carries.
class _TabDrag {
  const _TabDrag({required this.tabIds, required this.isGroup});

  /// The tab, or every session of a split, which moves as one.
  final List<String> tabIds;
  final bool isGroup;
}

/// A tab in the strip. It can be dragged along the strip to reorder it, like a
/// browser's, and a plain tab can also be dragged onto the panes to split them.
class _TabChip extends StatefulWidget {
  const _TabChip({
    super.key,
    required this.tabIds,
    required this.isGroup,
    required this.title,
    required this.active,
    required this.icon,
    required this.status,
    required this.onTap,
    required this.onClose,
    required this.onMenu,
    this.tooltip,
    this.nested = false,
  });

  /// A session inside a split, drawn under the split's own chip.
  final bool nested;

  /// The sessions behind this chip, in tab order.
  final List<String> tabIds;
  final bool isGroup;
  final String title;
  final bool active;
  final IconData icon;

  /// For a split: the sessions in it.
  final String? tooltip;
  final SessionStatus status;
  final VoidCallback onTap;
  final VoidCallback onClose;
  final ValueChanged<Offset> onMenu;

  @override
  State<_TabChip> createState() => _TabChipState();
}

class _TabChipState extends State<_TabChip> {
  /// Which side of this chip a dragged tab would land on; null when none.
  bool? _dropAfter;
  bool _dragging = false;

  /// Kept for a drag that ends after this chip has gone: dropped onto a pane,
  /// a tab's chip becomes the split's.
  AppState? _app;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _app = context.read<AppState>();
  }

  @override
  void dispose() {
    // A Draggable reports no end once it is unmounted, and sessions must not
    // stay hidden. Not during this frame: listeners would rebuild mid-build.
    if (_dragging) {
      final app = _app;
      WidgetsBinding.instance.addPostFrameCallback((_) => app?.setTabDrag(active: false));
    }
    super.dispose();
  }

  Widget _chip(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      constraints: BoxConstraints(minWidth: widget.nested ? 90 : 120, maxWidth: widget.nested ? 170 : 200),
      height: 36,
      margin: const EdgeInsets.only(right: 2),
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: widget.nested
            ? scheme.primary.withValues(alpha: widget.active ? 0.08 : 0.04)
            : widget.active
            ? scheme.surface
            : Colors.transparent,
        border: Border(
          bottom: BorderSide(
            color: widget.active ? scheme.primary.withValues(alpha: widget.nested ? 0.5 : 1) : Colors.transparent,
            width: 2,
          ),
        ),
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
              color: switch (widget.status) {
                SessionStatus.running => const Color(0xFF2EB85C),
                SessionStatus.starting => const Color(0xFFE0A526),
                SessionStatus.error || SessionStatus.closed => const Color(0xFFE5484D),
              },
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 6),
          Icon(widget.icon, size: 12),
          const SizedBox(width: 4),
          Expanded(
            child: Text(widget.title, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
          ),
          InkWell(
            onTap: widget.onClose,
            child: const Padding(padding: EdgeInsets.all(2), child: Icon(Icons.close, size: 14)),
          ),
        ],
      ),
    );
  }

  void _dragStarted() {
    setState(() => _dragging = true);
    _app?.setTabDrag(active: true, tabId: widget.isGroup ? null : widget.tabIds.single);
  }

  void _dragEnded() {
    if (mounted) setState(() => _dragging = false);
    _app?.setTabDrag(active: false);
  }

  void _setDropAfter(bool? after) {
    if (_dropAfter != after) setState(() => _dropAfter = after);
  }

  bool _isAfter(DragTargetDetails<_TabDrag> d) {
    final box = context.findRenderObject() as RenderBox;
    return box.globalToLocal(d.offset).dx > box.size.width / 2;
  }

  void _drop(DragTargetDetails<_TabDrag> d) {
    final app = context.read<AppState>();
    String? before = widget.tabIds.first;
    if (_isAfter(d)) {
      // The first tab past this chip that is not itself moving.
      final ids = app.tabs.map((t) => t.id).toList();
      final lastHere = widget.tabIds.map(ids.indexOf).reduce((a, b) => a > b ? a : b);
      before = ids.skip(lastHere + 1).where((id) => !d.data.tabIds.contains(id)).firstOrNull;
    }
    _setDropAfter(null);
    _moveInStrip(app, d.data, before);
  }

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final Widget chip = GestureDetector(
      onTap: widget.onTap,
      onSecondaryTapDown: (d) => widget.onMenu(d.globalPosition),
      child: _chip(context),
    );
    final content = widget.tooltip == null
        ? chip
        : Tooltip(message: widget.tooltip!, waitDuration: const Duration(milliseconds: 600), child: chip);
    return DragTarget<_TabDrag>(
      onWillAcceptWithDetails: (d) => !d.data.tabIds.any(widget.tabIds.contains),
      onMove: (d) => _setDropAfter(_isAfter(d)),
      onLeave: (_) => _setDropAfter(null),
      onAcceptWithDetails: _drop,
      builder: (context, _, _) => Stack(
        children: [
          ThresholdDraggable<_TabDrag>(
            data: _TabDrag(tabIds: widget.tabIds, isGroup: widget.isGroup),
            dragAnchorStrategy: pointerDragAnchorStrategy,
            onDragStarted: _dragStarted,
            onDragEnd: (_) => _dragEnded(),
            onDraggableCanceled: (_, _) => _dragEnded(),
            feedback: _TabDragFeedback(title: widget.title, icon: widget.icon),
            child: Opacity(opacity: _dragging ? 0.45 : 1, child: content),
          ),
          if (_dropAfter != null)
            Positioned(
              top: 4,
              bottom: 4,
              left: _dropAfter! ? null : 0,
              right: _dropAfter! ? 0 : null,
              child: IgnorePointer(child: Container(width: 2, color: accent)),
            ),
        ],
      ),
    );
  }
}

/// The chip under the pointer while a tab is being dragged.
class _TabDragFeedback extends StatelessWidget {
  const _TabDragFeedback({required this.title, required this.icon});
  final String title;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Material(
      elevation: 4,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 200),
        height: 30,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 12),
            const SizedBox(width: 6),
            Flexible(
              child: Text(title, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
            ),
          ],
        ),
      ),
    );
  }
}

/// Where a dragged tab would land: the frosted area Windows shows while
/// snapping a window. [fraction] is that area as a part of its parent.
class _SnapPreview extends StatelessWidget {
  const _SnapPreview({required this.fraction});
  final Rect fraction;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth, h = constraints.maxHeight;
        return Stack(
          children: [
            AnimatedPositioned(
              duration: const Duration(milliseconds: 120),
              curve: Curves.easeOut,
              left: fraction.left * w,
              top: fraction.top * h,
              width: fraction.width * w,
              height: fraction.height * h,
              child: IgnorePointer(
                child: Padding(
                  padding: const EdgeInsets.all(6),
                  child: ClipRRect(
                    key: const ValueKey('snap-preview'),
                    borderRadius: BorderRadius.circular(8),
                    child: BackdropFilter(
                      filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: accent.withValues(alpha: 0.22),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: accent.withValues(alpha: 0.75), width: 1.5),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// One pane as a target for a dragged tab: dropped near an edge, the tab takes
/// that half of the pane, with a preview of it while the drag is there.
class _PaneDropTarget extends StatefulWidget {
  const _PaneDropTarget({super.key, required this.tabId, required this.child});
  final String tabId;
  final Widget child;

  @override
  State<_PaneDropTarget> createState() => _PaneDropTargetState();
}

class _PaneDropTargetState extends State<_PaneDropTarget> {
  PaneSide? _side;

  PaneSide? _sideFor(DragTargetDetails<_TabDrag> d) {
    final box = context.findRenderObject() as RenderBox;
    return paneSideAt(box.size, box.globalToLocal(d.offset));
  }

  void _set(PaneSide? side) {
    if (_side != side) setState(() => _side = side);
  }

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    return DragTarget<_TabDrag>(
      onWillAcceptWithDetails: (d) => !d.data.isGroup && app.canDropTabBeside(d.data.tabIds.single, widget.tabId),
      onMove: (d) => _set(_sideFor(d)),
      onLeave: (_) => _set(null),
      onAcceptWithDetails: (d) {
        final side = _sideFor(d);
        _set(null);
        if (side != null) app.dropTabBeside(d.data.tabIds.single, widget.tabId, side);
      },
      builder: (context, _, _) => Stack(
        fit: StackFit.expand,
        children: [
          widget.child,
          if (_side != null) _SnapPreview(fraction: paneSideRect(_side!)),
        ],
      ),
    );
  }
}

/// Shown while a tab is being dragged, like Windows' Snap Layouts: drop the tab
/// on a pane of one of these and the tab area takes that arrangement.
class _LayoutPicker extends StatefulWidget {
  const _LayoutPicker({required this.tabId, required this.tabCount});
  final String tabId;
  final int tabCount;

  @override
  State<_LayoutPicker> createState() => _LayoutPickerState();
}

class _LayoutPickerState extends State<_LayoutPicker> {
  Rect? _hovered;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final presets = SplitPreset.values.where((p) => p.slots >= 2 && p.slots <= widget.tabCount).toList();
    return Stack(
      fit: StackFit.expand,
      children: [
        if (_hovered != null) _SnapPreview(fraction: _hovered!),
        Align(
          alignment: Alignment.topCenter,
          child: Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Material(
              elevation: 6,
              color: theme.colorScheme.surface,
              borderRadius: BorderRadius.circular(10),
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final preset in presets)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: _PresetTile(
                          preset: preset,
                          onHover: (rect) => setState(() => _hovered = rect),
                          onDrop: (slot) => context.read<AppState>().dropTabInPreset(widget.tabId, preset, slot),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// A small drawing of a layout, each pane of it a drop target.
class _PresetTile extends StatefulWidget {
  const _PresetTile({required this.preset, required this.onHover, required this.onDrop});
  final SplitPreset preset;
  final ValueChanged<Rect?> onHover;
  final ValueChanged<int> onDrop;

  @override
  State<_PresetTile> createState() => _PresetTileState();
}

class _PresetTileState extends State<_PresetTile> {
  static const double _width = 56, _height = 38;
  int? _hoveredSlot;

  void _hover(int? slot, Rect? rect) {
    setState(() => _hoveredSlot = slot);
    widget.onHover(rect);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final rects = presetSlotRects(widget.preset);
    return SizedBox(
      width: _width,
      height: _height,
      child: Stack(
        children: [
          for (var i = 0; i < rects.length; i++)
            Positioned(
              left: rects[i].left * _width,
              top: rects[i].top * _height,
              width: rects[i].width * _width,
              height: rects[i].height * _height,
              child: DragTarget<_TabDrag>(
                onWillAcceptWithDetails: (d) => !d.data.isGroup,
                onMove: (_) {
                  if (_hoveredSlot != i) _hover(i, rects[i]);
                },
                onLeave: (_) => _hover(null, null),
                onAcceptWithDetails: (_) {
                  _hover(null, null);
                  widget.onDrop(i);
                },
                builder: (context, _, _) => Container(
                  key: ValueKey('layout-${widget.preset.name}-$i'),
                  margin: const EdgeInsets.all(1),
                  decoration: BoxDecoration(
                    color: _hoveredSlot == i ? scheme.primary : scheme.onSurface.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              ),
            ),
        ],
      ),
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
      return _PaneDropTarget(
        key: ValueKey(tab.id),
        tabId: tab.id,
        child: _SessionPane(controller: tab.controller, active: true),
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

/// Picks the right view for whatever kind of session this tab holds.
class _SessionPane extends StatelessWidget {
  const _SessionPane({required this.controller, required this.active});
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
    return _TerminalPane(controller: controller as TerminalSessionController, active: active);
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
  final TerminalSessionController controller;
  final bool active;

  @override
  State<_TerminalPane> createState() => _TerminalPaneState();
}

class _TerminalPaneState extends State<_TerminalPane> {
  final _focusNode = FocusNode();
  final _terminalController = TerminalController();
  late final TerminalClipboard _clipboard;
  final _viewKey = GlobalKey<TerminalViewState>();
  final _scroll = ScrollController();

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
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final style = terminalStyle(family: app.terminalFontFamily, size: app.terminalFontSize);
    final terminal = TerminalHoverScrollbar(
      controller: _scroll,
      color: app.terminalForeground,
      child: GestureDetector(
        onTap: () => _focusNode.requestFocus(),
        child: TerminalViewport(style: style, background: app.terminalBackground, child: _view(app, style)),
      ),
    );
    final session = widget.controller;
    if (session is! PtySessionController) return terminal;
    final terminalWithOffer = Stack(children: [
      Positioned.fill(child: terminal),
      Positioned(
        left: 12,
        right: 12,
        bottom: 18,
        child: Center(child: ValueListenableBuilder<String?>(
          valueListenable: session.sudoPrompt,
          builder: (context, prompt, _) => prompt == null
              ? const SizedBox.shrink()
              : _SudoPasswordOffer(
                  onFill: () {
                    session.fillSudoPassword();
                    _focusNode.requestFocus();
                  },
                  onDismiss: session.dismissSudoPrompt,
                ),
        )),
      ),
    ]);
    return Column(
      children: [
        ValueListenableBuilder<String?>(
          valueListenable: session.loginQuestion,
          builder: (context, question, _) => question == null
              ? const SizedBox.shrink()
              : _LoginQuestionBar(
                  question: question,
                  hasPassword: session.hasSavedPassword,
                  onAnswer: (yes) {
                    session.answerLoginQuestion(yes: yes);
                    _focusNode.requestFocus();
                  },
                ),
        ),
        Expanded(child: ValueListenableBuilder<bool>(
            valueListenable: session.sftpOpen,
            builder: (context, open, _) => !open
            ? terminalWithOffer
            : LayoutBuilder(builder: (context, constraints) {
                final browser = SftpBrowser(
                  key: ValueKey(session),
                  createClient: (password) => session.createSftpClient(password: password),
                  transfers: session.sftpTransfers,
                  onClose: () => session.sftpOpen.value = false,
                  onExpand: () => openSftpWindow(
                    session,
                    dark: Theme.of(context).brightness == Brightness.dark,
                  ),
                );
                if (constraints.maxWidth < 600) {
                  return Column(children: [
                    Expanded(child: browser),
                    const Divider(height: 1),
                    Expanded(child: terminalWithOffer),
                  ]);
                }
                return Row(children: [
                  SizedBox(width: (constraints.maxWidth * 0.38).clamp(280.0, 360.0),
                      child: browser),
                  const VerticalDivider(width: 1),
                  Expanded(child: terminalWithOffer),
                ]);
              }))),
      ],
    );
  }

  Widget _view(AppState app, TerminalStyle style) {
    // Selecting with the mouse scrolls the view at its edges, as in PuTTY.
    return TerminalDragSelect(
      viewKey: _viewKey,
      scroll: _scroll,
      terminal: widget.controller.terminal,
      controller: _terminalController,
      child: _terminalView(app, style),
    );
  }

  Widget _terminalView(AppState app, TerminalStyle style) {
    return TerminalView(
      widget.controller.terminal,
      key: _viewKey,
      scrollController: _scroll,
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
      onKeyEvent: (node, event) {
        final session = widget.controller;
        final keyboard = HardwareKeyboard.instance;
        if (session is PtySessionController &&
            session.sudoPrompt.value != null &&
            event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.keyY &&
            keyboard.isControlPressed && keyboard.isShiftPressed &&
            !keyboard.isAltPressed) {
          session.fillSudoPassword();
          return KeyEventResult.handled;
        }
        return _clipboard.handleKey(node, event);
      },
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

class _SudoPasswordOffer extends StatelessWidget {
  const _SudoPasswordOffer({required this.onFill, required this.onDismiss});
  final VoidCallback onFill;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final background = dark ? AppColors.darkPanelAlt : AppColors.lightPanel;
    final foreground = dark ? AppColors.darkText : AppColors.lightText;
    final muted = dark ? AppColors.darkTextDim : AppColors.lightTextDim;
    final border = dark ? AppColors.darkBorder : AppColors.lightBorder;
    return Material(
      color: background,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(kControlRadius),
        side: BorderSide(color: border),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 325),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Row(children: [
              Icon(Icons.key_outlined, size: 14, color: muted),
              const SizedBox(width: 6),
              Expanded(child: Text(tr('Saved password for sudo'),
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, color: foreground))),
              Text('Ctrl+Shift+Y', style: TextStyle(fontSize: 10, color: muted)),
            ]),
            const SizedBox(height: 7),
            Row(children: [
              Expanded(child: InkWell(
                key: const ValueKey('sudo-fill-button'),
                onTap: onFill,
                borderRadius: BorderRadius.circular(4),
                child: Container(
                  height: 25,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(color: foreground,
                      borderRadius: BorderRadius.circular(4)),
                  child: Text(tr('Fill'), style: TextStyle(fontSize: 11,
                      fontWeight: FontWeight.w600, color: background)),
                ),
              )),
              const SizedBox(width: 6),
              Expanded(child: InkWell(
                key: const ValueKey('sudo-cancel-button'),
                onTap: onDismiss,
                borderRadius: BorderRadius.circular(4),
                child: Container(
                  height: 25,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    border: Border.all(color: border),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(tr('Cancel'), style: TextStyle(fontSize: 11,
                      color: foreground)),
                ),
              )),
            ]),
          ]),
        ),
      ),
    );
  }
}

/// A yes/no question the server asked at login, so it can be answered with a
/// click, with the saved password filled in after a yes.
class _LoginQuestionBar extends StatelessWidget {
  const _LoginQuestionBar({required this.question, required this.hasPassword, required this.onAnswer});

  final String question;
  final bool hasPassword;
  final ValueChanged<bool> onAnswer;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surface,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Row(
          children: [
            const Icon(Icons.help_outline, size: 16),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(question, style: const TextStyle(fontSize: 12), maxLines: 2, overflow: TextOverflow.ellipsis),
                  if (!hasPassword)
                    Text(
                      tr('No password is saved for this connection, so you will need to type it.'),
                      style: TextStyle(fontSize: 11, color: theme.textTheme.bodySmall?.color),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            TextButton(onPressed: () => onAnswer(false), child: Text(tr('No'))),
            const SizedBox(width: 4),
            FilledButton(onPressed: () => onAnswer(true), child: Text(tr('Yes'))),
          ],
        ),
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

  static const double margin = 2;

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
