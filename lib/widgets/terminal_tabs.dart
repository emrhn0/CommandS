import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:xterm/xterm.dart';

import '../providers/app_state.dart';
import '../services/mac_rdp_session.dart';
import '../services/dead_keys.dart';
import '../services/mcp_server.dart';
import '../services/open_path.dart';
import '../services/pane_layout.dart';
import '../services/pty_session.dart';
import '../services/rdp_session.dart';
import '../services/serial_session.dart';
import '../services/session_controller.dart';
import '../services/session_log.dart';
import '../services/terminal_appearance.dart';
import '../theme/app_theme.dart';
import 'context_menu.dart';
import 'tree_drag.dart';
import 'welcome_panel.dart';
import 'new_connection_dialog.dart';
import 'mac_rdp_view.dart';
import 'rdp_embed_view.dart';
import 'split_view_dialog.dart';
import 'terminal_clipboard.dart';
import 'terminal_drag_select.dart';
import 'terminal_hover_scrollbar.dart';
import 'terminal_search.dart';
import 'quick_search.dart';
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

    if (app.tabs.isEmpty) return WelcomePanel(sidebarVisible: sidebarVisible);

    final layout = app.paneLayout ?? PaneLeaf(app.tabs[app.activeTabIndex.clamp(0, app.tabs.length - 1)].id);

    return Column(
      children: [
        _TabBarRow(app: app),
        const Divider(height: 1),
        // The welcome screen over the sessions, from the home button: they
        // keep running, and any tab brings them back. Embedded RDP windows
        // hide while their panes are not built.
        if (app.homeShown)
          Expanded(child: WelcomePanel(sidebarVisible: sidebarVisible))
        else ...[
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                _PaneTreeView(node: layout, headers: layout is PaneSplit),
                // Not over a split: its layout was set in Split View, and a tab
                // dragged there only fills an empty pane.
                if (app.draggingTabId != null && app.tabs.length > 1 && layout is! PaneSplit)
                  _LayoutPicker(tabId: app.draggingTabId!, tabCount: app.tabs.length),
              ],
            ),
          ),
          if (app.commandTab case final tab?) SessionStatusBar(tab: tab),
        ],
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
            active: !app.homeShown && app.activeGroupId == group.id,
            icon: Icons.space_dashboard_outlined,
            status: _groupStatus(members),
            onTap: () => app.activateGroup(group.id),
            onClose: () => app.closeGroup(group.id),
            onMenu: (at) => _showGroupMenu(context, app, group, at),
          ),
        );
        // Its sessions are not repeated here: each has a small tab bar of
        // its own above its pane (_PaneHeader), dragged from there to leave.
        continue;
      }
      chips.add(
        _TabChip(
          key: ValueKey('tab-${tab.id}'),
          tabIds: [tab.id],
          isGroup: false,
          title: _tabTitle(tab),
          active:
              !app.homeShown &&
              app.activeGroupId == null &&
              (visible.contains(tab.id) || (app.paneLayout == null && i == app.activeTabIndex)),
          icon: _tabIcon(tab),
          color: app.tabColorOf(tab),
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
    final activeIds = app.paneLayout == null
        ? {app.tabs[app.activeTabIndex.clamp(0, app.tabs.length - 1)].id}
        : tabIdsInLayout(app.paneLayout);
    final sshSessions = [
      for (final tab in app.tabs)
        if (activeIds.contains(tab.id) && tab.controller is PtySessionController)
          tab.controller as PtySessionController,
    ];
    return LayoutBuilder(builder: (context, constraints) => SizedBox(
      height: 36,
      child: Row(
        children: [
          _HomeButton(active: app.homeShown, onTap: app.showHome),
          Expanded(
            // Behind the chips, the rest of the strip: a drop there goes last.
            child: DragTarget<_TabDrag>(
              onAcceptWithDetails: (d) => _moveInStrip(app, d.data, null),
              builder: (context, _, _) => _ScrollingStrip(children: chips),
            ),
          ),
          if (app.activeGroupId != null) _SeparateButton(groupId: app.activeGroupId!),
          // Over a split each pane has its own record button on its bar.
          if (sshSessions.isNotEmpty && app.paneLayout is! PaneSplit)
            _SessionLogButton(sessions: sshSessions, compact: constraints.maxWidth < 1100),
          _SplitViewButton(active: app.activeGroupId != null,
              enabled: app.tabs.length > 1, compact: constraints.maxWidth < 1100),
        ],
      ),
    ));
  }
}

/// The tab chips in a row that scrolls sideways. When they do not all fit,
/// arrows at both ends move it along, and the mouse wheel does too.
class _ScrollingStrip extends StatefulWidget {
  const _ScrollingStrip({required this.children});
  final List<Widget> children;

  @override
  State<_ScrollingStrip> createState() => _ScrollingStripState();
}

class _ScrollingStripState extends State<_ScrollingStrip> {
  final _scroll = ScrollController();
  bool _canBack = false;
  bool _canForward = false;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _update(ScrollMetrics m) {
    final back = m.pixels > m.minScrollExtent + 0.5;
    final forward = m.pixels < m.maxScrollExtent - 0.5;
    if (back == _canBack && forward == _canForward) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() {
        _canBack = back;
        _canForward = forward;
      });
    });
  }

  void _by(double delta) {
    if (!_scroll.hasClients) return;
    final p = _scroll.position;
    final to = (p.pixels + delta).clamp(p.minScrollExtent, p.maxScrollExtent);
    _scroll.animateTo(to, duration: const Duration(milliseconds: 180), curve: Curves.easeOut);
  }

  Widget _arrow(String key, IconData icon, String tip, bool enabled, double delta) => SizedBox(
        width: 26,
        child: IconButton(
          key: ValueKey(key),
          tooltip: tip,
          padding: EdgeInsets.zero,
          iconSize: 18,
          onPressed: enabled ? () => _by(delta) : null,
          icon: Icon(icon),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final overflow = _canBack || _canForward;
    return Row(
      children: [
        if (overflow) _arrow('tabs-back', Icons.chevron_left, tr('Scroll tabs left'), _canBack, -240),
        Expanded(
          child: NotificationListener<ScrollMetricsNotification>(
            onNotification: (n) {
              _update(n.metrics);
              return false;
            },
            child: NotificationListener<ScrollNotification>(
              onNotification: (n) {
                _update(n.metrics);
                return false;
              },
              child: Listener(
                // The wheel moves the strip sideways.
                onPointerSignal: (e) {
                  if (e is PointerScrollEvent) {
                    final d = e.scrollDelta.dy != 0 ? e.scrollDelta.dy : e.scrollDelta.dx;
                    if (_scroll.hasClients) {
                      final p = _scroll.position;
                      _scroll.jumpTo((p.pixels + d).clamp(p.minScrollExtent, p.maxScrollExtent));
                    }
                  }
                },
                child: ListView(controller: _scroll, scrollDirection: Axis.horizontal, children: widget.children),
              ),
            ),
          ),
        ),
        if (overflow) _arrow('tabs-forward', Icons.chevron_right, tr('Scroll tabs right'), _canForward, 240),
      ],
    );
  }
}

/// A small box hanging from the button that was pressed, as wide as it:
/// "Include history" on top and the start button under it, so both read as
/// the button's own and not as part of the next one. Null when it is
/// dismissed without starting.
Future<bool?> _askIncludeHistory(BuildContext context) {
  final box = context.findRenderObject()! as RenderBox;
  final anchor = box.localToGlobal(Offset.zero);
  final width = box.size.width < _RecordOptionsEntry.minWidth ? _RecordOptionsEntry.minWidth : box.size.width;
  return showMenu<bool>(
    context: context,
    position: RelativeRect.fromLTRB(anchor.dx, anchor.dy + box.size.height + 4, anchor.dx + width, 0),
    constraints: BoxConstraints.tightFor(width: width + 16),
    items: [_RecordOptionsEntry(width: width)],
  );
}

/// "Include history" (always unticked when it opens) above a start button
/// that fills the box.
class _RecordOptionsEntry extends PopupMenuEntry<bool> {
  const _RecordOptionsEntry({required this.width});

  /// The box is never narrower than this, even under a small button.
  static const minWidth = 170.0;

  final double width;

  @override
  double get height => 76;

  @override
  bool represents(bool? value) => false;

  @override
  State<_RecordOptionsEntry> createState() => _RecordOptionsEntryState();
}

class _RecordOptionsEntryState extends State<_RecordOptionsEntry> {
  bool _includeHistory = false;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: SizedBox(
        key: const ValueKey('session-log-options'),
        width: widget.width,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          InkWell(
            key: const ValueKey('session-log-include-history'),
            borderRadius: BorderRadius.circular(4),
            onTap: () => setState(() => _includeHistory = !_includeHistory),
            child: Row(children: [
              Checkbox(
                value: _includeHistory,
                visualDensity: VisualDensity.compact,
                onChanged: (v) => setState(() => _includeHistory = v ?? false),
              ),
              Flexible(
                child: Text(tr('Include history'), overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
              ),
            ]),
          ),
          const SizedBox(height: 4),
          FilledButton(
            key: const ValueKey('session-log-start'),
            style: FilledButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 12),
            ),
            onPressed: () => Navigator.of(context).pop(_includeHistory),
            child: Text(tr('Start recording'), style: const TextStyle(fontSize: 12)),
          ),
        ]),
      ),
    );
  }
}

/// Starts recording [session], or stops it and says where the log is.
Future<void> _toggleRecording(BuildContext context, PtySessionController session) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    final current = session.recordingPath.value;
    if (current != null) {
      await session.stopRecording();
      messenger.showSnackBar(SnackBar(
        content: Text(tr('Session log saved to {path}', {'path': current})),
        // A SnackBar with an action stays until dismissed by default;
        // this one goes away on its own when it is not used.
        persist: false,
        duration: const Duration(seconds: 8),
        action: SnackBarAction(
          label: tr('Open file'),
          onPressed: () => OpenPath.open(current),
        ),
      ));
    } else {
      // Asked every time, unticked every time: the choice is never kept.
      final includeHistory = await _askIncludeHistory(context);
      if (includeHistory == null) return;
      final directory = await SessionLogSettings.directory();
      await session.startRecording(directory, includeHistory: includeHistory);
    }
  } catch (error) {
    messenger.showSnackBar(SnackBar(
      content: Text(tr('Could not record session: {error}', {'error': error.toString()})),
    ));
  }
}

/// The record button on a split pane's bar: a click starts recording that
/// session, another stops it. Red while it records.
class _PaneRecordButton extends StatefulWidget {
  const _PaneRecordButton({required this.session, required this.tabId});
  final PtySessionController session;
  final String tabId;

  @override
  State<_PaneRecordButton> createState() => _PaneRecordButtonState();
}

class _PaneRecordButtonState extends State<_PaneRecordButton> {
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    widget.session.recordingError.addListener(_onError);
  }

  @override
  void didUpdateWidget(_PaneRecordButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session != widget.session) {
      oldWidget.session.recordingError.removeListener(_onError);
      widget.session.recordingError.addListener(_onError);
    }
  }

  @override
  void dispose() {
    widget.session.recordingError.removeListener(_onError);
    super.dispose();
  }

  void _onError() {
    final error = widget.session.recordingError.value;
    if (error == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(tr('Session recording stopped: {error}', {'error': error})),
        ));
      }
    });
  }

  Future<void> _pressed() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await _toggleRecording(context, widget.session);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    return AnimatedBuilder(
      animation: Listenable.merge([session.recordingPath, session.recordingError]),
      builder: (context, _) {
        final on = session.recordingPath.value != null;
        final enabled = !_busy && (on || session.status == SessionStatus.running);
        final scheme = Theme.of(context).colorScheme;
        return Tooltip(
          message: tr(on ? 'Stop recording' : 'Record session'),
          child: InkWell(
            key: ValueKey('pane-record-${widget.tabId}'),
            onTap: enabled ? _pressed : null,
            child: Padding(
              padding: const EdgeInsets.all(2),
              child: Icon(
                on ? Icons.fiber_manual_record : Icons.radio_button_unchecked,
                size: 13,
                color: on ? Colors.red : enabled ? null : scheme.onSurface.withValues(alpha: 0.3),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _SessionLogButton extends StatefulWidget {
  const _SessionLogButton({required this.sessions, required this.compact});

  final List<PtySessionController> sessions;
  final bool compact;

  @override
  State<_SessionLogButton> createState() => _SessionLogButtonState();
}

class _SessionLogButtonState extends State<_SessionLogButton> {
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    for (final session in widget.sessions) {
      session.recordingError.addListener(_onRecordingError);
    }
  }

  @override
  void didUpdateWidget(_SessionLogButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    for (final session in oldWidget.sessions) {
      session.recordingError.removeListener(_onRecordingError);
    }
    for (final session in widget.sessions) {
      session.recordingError.addListener(_onRecordingError);
    }
  }

  @override
  void dispose() {
    for (final session in widget.sessions) {
      session.recordingError.removeListener(_onRecordingError);
    }
    super.dispose();
  }

  void _onRecordingError() {
    final errors = widget.sessions.map((s) => s.recordingError.value).whereType<String>();
    if (errors.isEmpty) return;
    final error = errors.first;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(tr('Session recording stopped: {error}', {'error': error})),
        ));
      }
    });
  }

  Future<void> _toggle(PtySessionController session) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await _toggleRecording(context, session);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pressed() async {
    if (_busy) return;
    if (widget.sessions.length == 1) {
      await _toggle(widget.sessions.single);
      return;
    }
    final box = context.findRenderObject()! as RenderBox;
    final anchor = box.localToGlobal(Offset.zero);
    final selected = await showMenu<PtySessionController>(
      context: context,
      position: RelativeRect.fromLTRB(anchor.dx, anchor.dy + box.size.height, 0, 0),
      items: [
        for (final session in widget.sessions)
          PopupMenuItem(
            value: session,
            child: Row(children: [
              Icon(Icons.circle, size: 9,
                  color: session.recordingPath.value == null ? Theme.of(context).disabledColor : Colors.red),
              const SizedBox(width: 8),
              Flexible(child: Text(
                '${session.tabTitle ?? session.host} — ${tr(session.recordingPath.value == null ? 'Record session' : 'Stop recording')}',
              )),
            ]),
          ),
      ],
    );
    if (selected != null && mounted) await _toggle(selected);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([
        for (final session in widget.sessions) ...[session.recordingPath, session.recordingError],
      ]),
      builder: (context, _) {
        final active = widget.sessions.any((s) => s.recordingPath.value != null);
        final failed = widget.sessions.any((s) => s.recordingError.value != null);
        final single = widget.sessions.length == 1;
        final enabled = !_busy && widget.sessions.any((s) => s.status == SessionStatus.running || s.recordingPath.value != null);
        final label = single ? tr(active ? 'Stop recording' : 'Record session') : tr('Session logs');
        final icon = Stack(clipBehavior: Clip.none, children: [
          Icon(failed ? Icons.error_outline : Icons.description_outlined, size: 16,
              color: failed ? Theme.of(context).colorScheme.error : null),
          if (active)
            const Positioned(
              right: -4, top: -3,
              child: Icon(Icons.circle, size: 8, color: Colors.red),
            ),
        ]);
        return Tooltip(
          message: failed ? tr('Session recording failed') : active ? tr('Session recording is on') : tr('Record SSH session'),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
            child: widget.compact
                ? IconButton(
                    key: const ValueKey('session-log-button'),
                    onPressed: enabled ? _pressed : null,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 32, minHeight: 28),
                    icon: icon,
                  )
                : TextButton.icon(
                    key: const ValueKey('session-log-button'),
                    onPressed: enabled ? _pressed : null,
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      visualDensity: VisualDensity.compact,
                    ),
                    icon: icon,
                    label: Text(label, style: const TextStyle(fontSize: 12)),
                  ),
          ),
        );
      },
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
      if (t.id != id) continue;
      final c = t.controller;
      if (c is RdpSessionController) c.sendCtrlAltDelete();
      if (c is MacRdpSessionController) c.sendCtrlAltDelete();
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
  if (c is MacRdpSessionController) return c.canSendCtrlAltDel;
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
      if (tab.controller is PtySessionController)
        const MenuAction('duplicate', 'Duplicate', Icons.copy_all_outlined),
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
    case 'duplicate':
      if (app.tabs.contains(tab)) {
        final ssh = tab.controller as PtySessionController;
        await app.openConnection(ssh.connectionForDuplicate(id: tab.connectionId));
      }
    case 'ctrlaltdel':
      final c = tab.controller;
      if (c is RdpSessionController) c.sendCtrlAltDelete();
      if (c is MacRdpSessionController) c.sendCtrlAltDelete();
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
  const _SplitViewButton({required this.active, required this.enabled, required this.compact});
  final bool active;
  final bool enabled;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Tooltip(
      message: enabled ? tr('Split View') : tr('Open a second tab to split the view'),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: compact
            ? IconButton(
                onPressed: enabled ? () => showSplitViewDialog(context) : null,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 28),
                style: IconButton.styleFrom(
                  backgroundColor: active ? theme.colorScheme.primary.withValues(alpha: 0.10) : null,
                ),
                icon: const Icon(Icons.vertical_split_outlined, size: 16),
              )
            : TextButton.icon(
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
/// Shown on the tab of a session an AI agent opened over MCP, so it is clear
/// which sessions the agent is working in. Nothing when no agent opened it.
class _AgentMark extends StatelessWidget {
  const _AgentMark({required this.tabIds});
  final List<String> tabIds;

  @override
  Widget build(BuildContext context) {
    final gateway = context.watch<McpServer?>()?.gateway;
    if (gateway is! AppMcpGateway) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: gateway,
      builder: (context, _) {
        if (!tabIds.any(gateway.isAgentTab)) return const SizedBox.shrink();
        final accent = Theme.of(context).colorScheme.primary;
        return Tooltip(
          message: tr('Opened by an AI agent over MCP'),
          child: Container(
            key: const ValueKey('tab-agent-mark'),
            margin: const EdgeInsets.only(left: 4, right: 4),
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: accent.withValues(alpha: 0.5)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.smart_toy_outlined, size: 11, color: accent),
                const SizedBox(width: 3),
                Text('AI', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: accent)),
              ],
            ),
          ),
        );
      },
    );
  }
}

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
    this.color,
  });

  /// The colour of the folder the connection is in, if it has one: the
  /// tab's icon takes it, so a customer's tabs are told apart at a glance.
  final Color? color;

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
    final palette = AppPalette.of(context);
    final active = widget.active;
    // On the accent fill of the tab in use, its own text and icons.
    final ink = active ? scheme.onPrimary : null;
    // Rounded pills with a gap between them; the one in use is filled with
    // the accent, so it stands out among many.
    return Container(
      key: ValueKey('tab-pill-${widget.tabIds.first}'),
      constraints: const BoxConstraints(minWidth: 110, maxWidth: 200),
      height: 28,
      margin: const EdgeInsets.only(right: 4, top: 4, bottom: 4),
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: active ? scheme.primary : palette.panelAlt,
        borderRadius: BorderRadius.circular(8),
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
            key: const ValueKey('tab-status'),
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: switch (widget.status) {
                SessionStatus.running => const Color(0xFF2EB85C),
                SessionStatus.starting => const Color(0xFFE0A526),
                SessionStatus.error || SessionStatus.closed => const Color(0xFFE5484D),
              },
              shape: BoxShape.circle,
              // A ring keeps the colour readable on the accent fill.
              border: active ? Border.all(color: scheme.onPrimary, width: 1.5) : null,
            ),
          ),
          const SizedBox(width: 6),
          Icon(
            widget.icon,
            size: 12,
            color: ink ?? widget.color,
            key: widget.color == null ? null : const ValueKey('tab-folder-color'),
          ),
          const SizedBox(width: 5),
          Expanded(
            child: Text(
              widget.title,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: ink, fontWeight: active ? FontWeight.w600 : null),
            ),
          ),
          _AgentMark(tabIds: widget.tabIds),
          InkWell(
            onTap: widget.onClose,
            child: Padding(padding: const EdgeInsets.all(2), child: Icon(Icons.close, size: 14, color: ink)),
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

  /// In a split: a session of the same split is over this pane, and would
  /// swap places with it.
  bool _swap = false;

  PaneSide? _sideFor(DragTargetDetails<_TabDrag> d) {
    final box = context.findRenderObject() as RenderBox;
    return paneSideAt(box.size, box.globalToLocal(d.offset));
  }

  void _set(PaneSide? side) {
    if (_side != side) setState(() => _side = side);
  }

  void _setSwap(bool swap) {
    if (_swap != swap) setState(() => _swap = swap);
  }

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    // A split keeps the panes it was given in Split View: nothing dropped on
    // a pane splits it. A session of the same split swaps places with it;
    // a tab from elsewhere goes into an empty pane only.
    bool inSplit() => app.paneLayout is PaneSplit;
    return DragTarget<_TabDrag>(
      onWillAcceptWithDetails: (d) {
        if (d.data.isGroup) return false;
        final id = d.data.tabIds.single;
        if (inSplit()) return app.canSwapPanes(id, widget.tabId);
        return app.canDropTabBeside(id, widget.tabId);
      },
      onMove: (d) => inSplit() ? _setSwap(true) : _set(_sideFor(d)),
      onLeave: (_) {
        _set(null);
        _setSwap(false);
      },
      onAcceptWithDetails: (d) {
        final id = d.data.tabIds.single;
        if (inSplit()) {
          _setSwap(false);
          app.swapPanes(id, widget.tabId);
          return;
        }
        final side = _sideFor(d);
        _set(null);
        if (side != null) app.dropTabBeside(id, widget.tabId, side);
      },
      builder: (context, _, _) => Stack(
        fit: StackFit.expand,
        children: [
          widget.child,
          if (_swap) const _SnapPreview(fraction: Rect.fromLTRB(0, 0, 1, 1)),
          if (!_swap && _side != null) _SnapPreview(fraction: paneSideRect(_side!)),
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
  const _PaneTreeView({required this.node, this.headers = false});
  final PaneNode node;

  /// Split: each pane gets its own small tab bar, as the strip at the top
  /// shows only the split's tab.
  final bool headers;

  @override
  Widget build(BuildContext context) {
    final n = node;
    if (n is PaneEmpty) return _EmptyPane(key: ValueKey(n.id), emptyId: n.id, header: headers);
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
      final pane = _PaneDropTarget(
        key: ValueKey(tab.id),
        tabId: tab.id,
        child: _SessionPane(controller: tab.controller, active: true),
      );
      if (!headers) return pane;
      return Column(
        children: [
          _PaneHeader(key: ValueKey('pane-header-${tab.id}'), tab: tab),
          Expanded(child: pane),
        ],
      );
    }
    final split = n as PaneSplit;
    return _ResizableSplit(split: split, headers: headers);
  }
}

/// A pane of a split with no session: drop a tab on it to fill it. It keeps
/// its place in the layout either way.
class _EmptyPane extends StatefulWidget {
  const _EmptyPane({super.key, required this.emptyId, required this.header});
  final String emptyId;
  final bool header;

  @override
  State<_EmptyPane> createState() => _EmptyPaneState();
}

class _EmptyPaneState extends State<_EmptyPane> {
  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;
    final dim = theme.textTheme.bodySmall?.color;
    // A connection dragged from the list opens here, as a tab of its own.
    return DragTarget<TreeDragItems>(
      onWillAcceptWithDetails: (d) =>
          d.data.singleConnection != null && app.connections.any((c) => c.id == d.data.singleConnection),
      onAcceptWithDetails: (d) {
        final id = d.data.singleConnection;
        final conn = app.connections.where((c) => c.id == id).firstOrNull;
        if (conn != null) app.openConnectionInEmptyPane(widget.emptyId, conn);
      },
      builder: (context, connections, _) => DragTarget<_TabDrag>(
      onWillAcceptWithDetails: (d) => !d.data.isGroup,
      onAcceptWithDetails: (d) => app.dropTabInEmptyPane(widget.emptyId, d.data.tabIds.single),
      builder: (context, candidates, _) {
        final hovering = candidates.isNotEmpty || connections.isNotEmpty;
        final body = Container(
          margin: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: hovering ? accent.withValues(alpha: 0.14) : Colors.transparent,
            border: Border.all(color: hovering ? accent : theme.dividerColor, width: hovering ? 2 : 1),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Center(
            child: Text(
              hovering ? tr('Drop here') : tr('Drop a tab here'),
              style: TextStyle(fontSize: 12, color: dim),
            ),
          ),
        );
        return Column(
          children: [
            if (widget.header)
              Container(
                height: 26,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.06),
                  border: Border(bottom: BorderSide(color: theme.dividerColor)),
                ),
                // No close button: an empty pane is part of the layout it
                // was given, and is filled by dropping a tab on it.
                alignment: Alignment.centerLeft,
                child: Text(tr('Empty pane'), style: TextStyle(fontSize: 11.5, color: dim)),
              ),
            Expanded(child: body),
          ],
        );
      },
      ),
    );
  }
}

/// The small tab bar above one pane of a split: the session's status, name
/// and close button. Right-click gives the tab's menu; dragging it to the
/// strip at the top takes the session out of the split, dragging it onto
/// another pane moves it there.
class _PaneHeader extends StatefulWidget {
  const _PaneHeader({super.key, required this.tab});
  final OpenTab tab;

  @override
  State<_PaneHeader> createState() => _PaneHeaderState();
}

class _PaneHeaderState extends State<_PaneHeader> {
  bool _dragging = false;
  AppState? _app;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _app = context.read<AppState>();
  }

  @override
  void dispose() {
    // Same as a chip: an unmounted Draggable reports no end.
    if (_dragging) {
      final app = _app;
      WidgetsBinding.instance.addPostFrameCallback((_) => app?.setTabDrag(active: false));
    }
    super.dispose();
  }

  void _dragEnded() {
    if (mounted) setState(() => _dragging = false);
    _app?.setTabDrag(active: false);
  }

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final scheme = Theme.of(context).colorScheme;
    final tab = widget.tab;
    final title = _tabTitle(tab);
    final broadcasting = context.select<AppState, bool>((a) => a.isBroadcasting(tab.id));
    final bar = Container(
      height: 26,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: scheme.primary.withValues(alpha: broadcasting ? 0.16 : 0.06),
        border: Border(bottom: BorderSide(color: Theme.of(context).dividerColor)),
      ),
      child: Row(
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(
              color: switch (tab.controller.status) {
                SessionStatus.running => const Color(0xFF2EB85C),
                SessionStatus.starting => const Color(0xFFE0A526),
                SessionStatus.error || SessionStatus.closed => const Color(0xFFE5484D),
              },
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 6),
          Icon(_tabIcon(tab), size: 12),
          const SizedBox(width: 4),
          Expanded(
            child: Text(title, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11.5)),
          ),
          _AgentMark(tabIds: [tab.id]),
          if (tab.controller is PtySessionController) ...[
            _BroadcastTick(tabId: tab.id, on: broadcasting),
            const SizedBox(width: 6),
            _PaneRecordButton(session: tab.controller as PtySessionController, tabId: tab.id),
            const SizedBox(width: 4),
          ],
          Tooltip(
            message: tr('Close tab'),
            child: InkWell(
              key: ValueKey('pane-close-${tab.id}'),
              onTap: () {
                final index = app.tabs.indexOf(tab);
                if (index >= 0) app.closeTab(index);
              },
              child: const Padding(padding: EdgeInsets.all(2), child: Icon(Icons.close, size: 13)),
            ),
          ),
        ],
      ),
    );
    return GestureDetector(
      onSecondaryTapDown: (d) => _showTabMenu(context, app, tab, d.globalPosition),
      child: ThresholdDraggable<_TabDrag>(
        data: _TabDrag(tabIds: [tab.id], isGroup: false),
        dragAnchorStrategy: pointerDragAnchorStrategy,
        onDragStarted: () {
          setState(() => _dragging = true);
          app.setTabDrag(active: true, tabId: tab.id);
        },
        onDragEnd: (_) => _dragEnded(),
        onDraggableCanceled: (_, _) => _dragEnded(),
        feedback: _TabDragFeedback(title: title, icon: _tabIcon(tab)),
        child: Opacity(opacity: _dragging ? 0.45 : 1, child: bar),
      ),
    );
  }
}

/// The tick on a split pane's bar for typing into several sessions at once:
/// what is typed into one ticked pane goes to every ticked pane. Unticked,
/// each pane is on its own again.
class _BroadcastTick extends StatelessWidget {
  const _BroadcastTick({required this.tabId, required this.on});

  final String tabId;
  final bool on;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final dim = Theme.of(context).textTheme.bodySmall?.color;
    return Tooltip(
      message: on
          ? tr('Typing here also goes to the other ticked panes. Click to stop.')
          : tr('Type into several sessions: tick the panes that should get what you type'),
      child: InkWell(
        key: ValueKey('pane-broadcast-$tabId'),
        borderRadius: BorderRadius.circular(4),
        onTap: () => context.read<AppState>().toggleBroadcast(tabId),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(on ? Icons.check_box : Icons.check_box_outline_blank, size: 13, color: on ? accent : dim),
              if (on) ...[
                const SizedBox(width: 3),
                Text(tr('Multi-type'), style: TextStyle(fontSize: 10.5, color: accent, fontWeight: FontWeight.w600)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _ResizableSplit extends StatefulWidget {
  const _ResizableSplit({required this.split, this.headers = false});
  final PaneSplit split;
  final bool headers;

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
              child: _PaneTreeView(node: widget.split.first, headers: widget.headers),
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
              child: _PaneTreeView(node: widget.split.second, headers: widget.headers),
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
      final mac = controller as MacRdpSessionController;
      // Drawn in the tab unless this build has no engine and an external
      // client was started instead.
      return ListenableBuilder(
        listenable: mac,
        builder: (context, _) => mac.embedded || mac.backend == null
            ? MacRdpEmbedView(controller: mac, active: active)
            : _MacRdpPane(controller: mac),
      );
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
                        label: Text(tr(_copied ? 'Copied, cleared in 30 seconds' : 'Copy password')),
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

  /// The search field over the terminal is open (magnifier or Ctrl+Shift+F).
  final _searchOpen = ValueNotifier<bool>(false);

  @override
  void initState() {
    super.initState();
    _clipboard = TerminalClipboard(terminal: widget.controller.terminal, controller: _terminalController);
    _focusNode.addListener(() {
      if (!_focusNode.hasFocus || !mounted) return;
      final app = context.read<AppState>();
      for (final tab in app.tabs) {
        if (identical(tab.controller, widget.controller)) app.focusCommandTab(tab.id);
      }
    });
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
    _searchOpen.dispose();
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
      // Focus moves on pointer-down, outside the gesture arena. A tap
      // recognizer here competed with TerminalView's own tap, double-tap and
      // the drag-select recognizers, so switching panes of a split by
      // clicking took several clicks.
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (_) {
          if (!_focusNode.hasFocus) _focusNode.requestFocus();
        },
        child: TerminalViewport(style: style, background: app.terminalBackground, child: _view(app, style)),
      ),
    );
    final searchable = Stack(children: [
      Positioned.fill(child: terminal),
      Positioned(
        top: 8,
        right: 22,
        child: TerminalSearch(
          terminal: widget.controller.terminal,
          controller: _terminalController,
          scroll: _scroll,
          lineHeight: TerminalViewport.cellHeight(style, MediaQuery.textScalerOf(context)),
          open: _searchOpen,
          onClosed: _focusNode.requestFocus,
        ),
      ),
    ]);
    final session = widget.controller;
    if (session is! PtySessionController) return searchable;
    final terminalWithOffer = Stack(children: [
      Positioned.fill(child: searchable),
      Positioned(
        left: 12,
        right: 12,
        bottom: 18,
        child: Center(child: ListenableBuilder(
          listenable: Listenable.merge([session.sudoPrompt, session.enablePrompt]),
          builder: (context, _) {
            final enable = session.enablePrompt.value != null;
            if (!enable && session.sudoPrompt.value == null) return const SizedBox.shrink();
            return _PasswordOffer(
              title: enable ? tr('Saved enable password') : tr('Saved password for sudo'),
              keyPrefix: enable ? 'enable' : 'sudo',
              onFill: () {
                if (enable) {
                  session.fillEnablePassword();
                } else {
                  session.fillSudoPassword();
                }
                _focusNode.requestFocus();
              },
              onDismiss: enable ? session.dismissEnablePrompt : session.dismissSudoPrompt,
            );
          },
        )),
      ),
    ]);
    return Column(
      children: [
        ValueListenableBuilder<bool>(
          valueListenable: session.hostKeyChanged,
          builder: (context, changed, _) => !changed
              ? const SizedBox.shrink()
              : _HostKeyChangedBar(
                  host: session.host,
                  onForget: () async {
                    final error = await session.forgetHostKeyAndReconnect();
                    if (error != null && context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                        content: Text(tr('The old key could not be removed: {error}', {'error': error})),
                      ));
                    }
                    _focusNode.requestFocus();
                  },
                  onDismiss: () => session.hostKeyChanged.value = false,
                ),
        ),
        ValueListenableBuilder<String?>(
          valueListenable: session.loginQuestion,
          builder: (context, question, _) => question == null
              ? const SizedBox.shrink()
              : _LoginQuestionBar(
                  question: question,
                  hasPassword: session.hasSavedPassword,
                  canRemember: session.canRememberLoginAnswer,
                  onAnswer: (yes, remember) {
                    session.answerLoginQuestion(yes: yes, remember: remember);
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
        // A dead key (AltGr+Ü for ~ on a Turkish keyboard) arrives with its
        // plain letter as the character, and Windows would compose the
        // accent into the next key. The terminal types the accent at once
        // and the next key plain (see DeadKeys).
        if (event is! KeyUpEvent) {
          final text = DeadKeys.translate(event);
          if (text != null) {
            if (text.isNotEmpty) widget.controller.terminal.textInput(text);
            return KeyEventResult.handled;
          }
        }
        final session = widget.controller;
        final keyboard = HardwareKeyboard.instance;
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.keyF &&
            keyboard.isControlPressed && keyboard.isShiftPressed &&
            !keyboard.isAltPressed) {
          _searchOpen.value = true;
          return KeyEventResult.handled;
        }
        // Ctrl+K stays the session's (delete to end of line); with Shift it
        // opens quick search, as Ctrl+K does outside a terminal.
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.keyK &&
            keyboard.isControlPressed && keyboard.isShiftPressed &&
            !keyboard.isAltPressed) {
          showQuickSearch(context);
          return KeyEventResult.handled;
        }
        if (session is PtySessionController &&
            (session.sudoPrompt.value != null || session.enablePrompt.value != null) &&
            event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.keyY &&
            keyboard.isControlPressed && keyboard.isShiftPressed &&
            !keyboard.isAltPressed) {
          if (session.enablePrompt.value != null) {
            session.fillEnablePassword();
          } else {
            session.fillSudoPassword();
          }
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
        ansi: app.terminalAnsi,
      ),
    );
  }
}

class _PasswordOffer extends StatelessWidget {
  const _PasswordOffer({required this.title, required this.keyPrefix, required this.onFill, required this.onDismiss});
  final String title;
  final String keyPrefix;
  final VoidCallback onFill;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final background = dark ? AppPalette.of(context).panelAlt : AppPalette.of(context).panel;
    final foreground = AppPalette.of(context).text;
    final muted = AppPalette.of(context).textDim;
    final border = AppPalette.of(context).border;
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
              Expanded(child: Text(title,
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, color: foreground))),
              Text('Ctrl+Shift+Y', style: TextStyle(fontSize: 10, color: muted)),
            ]),
            const SizedBox(height: 7),
            Row(children: [
              Expanded(child: InkWell(
                key: ValueKey('$keyPrefix-fill-button'),
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
                key: ValueKey('$keyPrefix-cancel-button'),
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
/// Shown when a device's SSH host key no longer matches the one remembered
/// for it, in place of reading the warning from OpenSSH in the terminal.
class _HostKeyChangedBar extends StatefulWidget {
  const _HostKeyChangedBar({required this.host, required this.onForget, required this.onDismiss});

  final String host;
  final Future<void> Function() onForget;
  final VoidCallback onDismiss;

  @override
  State<_HostKeyChangedBar> createState() => _HostKeyChangedBarState();
}

class _HostKeyChangedBarState extends State<_HostKeyChangedBar> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final warn = theme.colorScheme.error;
    return Material(
      key: const Key('host-key-changed-bar'),
      color: Color.alphaBlend(warn.withValues(alpha: 0.10), theme.colorScheme.surface),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Row(
          children: [
            Icon(Icons.gpp_maybe_outlined, size: 18, color: warn),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    tr("{host}'s identity has changed, so the connection was refused.", {'host': widget.host}),
                    style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    tr('If you replaced, reset or reinstalled this device, forget its old key and connect again. '
                        'If not, someone may be in between: do not connect.'),
                    style: TextStyle(fontSize: 11.5, color: theme.textTheme.bodySmall?.color),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            TextButton(onPressed: widget.onDismiss, child: Text(tr('Close'))),
            const SizedBox(width: 4),
            FilledButton(
              key: const Key('host-key-forget'),
              onPressed: _busy
                  ? null
                  : () async {
                      setState(() => _busy = true);
                      await widget.onForget();
                      if (mounted) setState(() => _busy = false);
                    },
              child: Text(tr('Forget old key and connect')),
            ),
          ],
        ),
      ),
    );
  }
}

class _LoginQuestionBar extends StatefulWidget {
  const _LoginQuestionBar({
    required this.question,
    required this.hasPassword,
    required this.canRemember,
    required this.onAnswer,
  });

  final String question;
  final bool hasPassword;

  /// A saved connection: "Remember" is offered, ticked, so the next login
  /// answers yes by itself.
  final bool canRemember;
  final void Function(bool yes, bool remember) onAnswer;

  @override
  State<_LoginQuestionBar> createState() => _LoginQuestionBarState();
}

class _LoginQuestionBarState extends State<_LoginQuestionBar> {
  bool _remember = true;

  @override
  Widget build(BuildContext context) {
    final question = widget.question;
    final hasPassword = widget.hasPassword;
    void onAnswer(bool yes) => widget.onAnswer(yes, widget.canRemember && _remember);
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
            if (widget.canRemember)
              Tooltip(
                message: tr('Next time, answer yes and log in by itself'),
                child: InkWell(
                  key: const Key('login-question-remember'),
                  borderRadius: BorderRadius.circular(4),
                  onTap: () => setState(() => _remember = !_remember),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          _remember ? Icons.check_box : Icons.check_box_outline_blank,
                          size: 15,
                          color: _remember ? theme.colorScheme.primary : theme.textTheme.bodySmall?.color,
                        ),
                        const SizedBox(width: 4),
                        Text(tr('Remember'), style: const TextStyle(fontSize: 12)),
                      ],
                    ),
                  ),
                ),
              ),
            const SizedBox(width: 6),
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

  /// [ansi] is a theme's 16 colours (see ThemePreset.ansi); without it the
  /// CommandS defaults are used, with white following the foreground.
  static TerminalTheme withColors({
    required Color background,
    required Color foreground,
    List<Color>? ansi,
  }) {
    final a = ansi != null && ansi.length == 16 ? ansi : null;
    return TerminalTheme(
      cursor: a == null ? dark.cursor : foreground,
      selection: a == null ? dark.selection : foreground.withValues(alpha: 0.3),
      foreground: foreground,
      background: background,
      black: a?[0] ?? dark.black,
      red: a?[1] ?? dark.red,
      green: a?[2] ?? dark.green,
      yellow: a?[3] ?? dark.yellow,
      blue: a?[4] ?? dark.blue,
      magenta: a?[5] ?? dark.magenta,
      cyan: a?[6] ?? dark.cyan,
      white: a?[7] ?? foreground,
      brightBlack: a?[8] ?? dark.brightBlack,
      brightRed: a?[9] ?? dark.brightRed,
      brightGreen: a?[10] ?? dark.brightGreen,
      brightYellow: a?[11] ?? dark.brightYellow,
      brightBlue: a?[12] ?? dark.brightBlue,
      brightMagenta: a?[13] ?? dark.brightMagenta,
      brightCyan: a?[14] ?? dark.brightCyan,
      brightWhite: a?[15] ?? Colors.white,
      searchHitBackground: a?[8] ?? dark.searchHitBackground,
      searchHitBackgroundCurrent: a == null ? dark.searchHitBackgroundCurrent : foreground,
      searchHitForeground: background,
    );
  }
}

/// The house at the start of the tab bar: the welcome screen, with the open
/// sessions listed, while they keep running.
class _HomeButton extends StatelessWidget {
  const _HomeButton({required this.active, required this.onTap});

  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final palette = AppPalette.of(context);
    return Tooltip(
      message: tr('Home'),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(6, 4, 4, 4),
        child: Material(
          key: const Key('tab-home'),
          // Filled like a tab in use while the welcome screen shows.
          color: active ? scheme.primary : palette.panelAlt,
          borderRadius: BorderRadius.circular(8),
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: onTap,
            child: SizedBox(
              width: 32,
              height: 28,
              child: Icon(Icons.home_outlined, size: 17, color: active ? scheme.onPrimary : palette.textDim),
            ),
          ),
        ),
      ),
    );
  }
}

/// A thin line under the sessions about the one in use: its protocol, its
/// address (a click copies it) and how long it has been open.
class SessionStatusBar extends StatefulWidget {
  const SessionStatusBar({super.key, required this.tab, this.now});

  final OpenTab tab;

  /// The time the duration is counted to; tests pass one in.
  final DateTime Function()? now;

  /// "42 min", or "2 h 5 min" from an hour on.
  static String durationLabel(Duration d) {
    final minutes = d.inMinutes;
    if (minutes < 60) return tr('{n} min', {'n': minutes});
    return tr('{h} h {m} min', {'h': minutes ~/ 60, 'm': minutes % 60});
  }

  @override
  State<SessionStatusBar> createState() => _SessionStatusBarState();
}

class _SessionStatusBarState extends State<SessionStatusBar> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    // The minutes move on by themselves.
    _tick = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final palette = AppPalette.of(context);
    final accent = Theme.of(context).colorScheme.primary;
    final c = widget.tab.controller;
    final protocol = switch (c) {
      RdpSessionController() || MacRdpSessionController() => 'RDP',
      SerialSessionController() => 'Serial',
      _ => 'SSH',
    };
    final conn = app.connections.where((x) => x.id == widget.tab.connectionId).firstOrNull;
    final defaultPort = protocol == 'RDP' ? 3389 : 22;
    final address = switch (conn) {
      final conn? when conn.port != defaultPort && protocol != 'Serial' => '${conn.host}:${conn.port}',
      final conn? => conn.host,
      null => c.host,
    };
    final now = widget.now?.call() ?? DateTime.now();
    final style = TextStyle(fontSize: 11, color: palette.textDim);
    return Container(
      key: const Key('session-status-bar'),
      height: 24,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(border: Border(top: BorderSide(color: Theme.of(context).dividerColor))),
      child: Row(
        children: [
          Text(protocol, style: style.copyWith(color: accent, fontWeight: FontWeight.w600)),
          const SizedBox(width: 8),
          // The address takes the room up to the time, which sits at the end.
          Expanded(
            child: Align(
              alignment: Alignment.centerLeft,
              child: Tooltip(
              message: tr('Copy address'),
              child: InkWell(
                key: const Key('session-status-address'),
                onTap: () async {
                  await Clipboard.setData(ClipboardData(text: address));
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Host address copied'))));
                  }
                },
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(address, overflow: TextOverflow.ellipsis, style: style.copyWith(color: palette.text)),
                    ),
                    const SizedBox(width: 5),
                    Icon(Icons.copy_rounded, size: 11, color: palette.textDim),
                  ],
                ),
              ),
            ),
            ),
          ),
          const SizedBox(width: 12),
          Text(
            SessionStatusBar.durationLabel(now.difference(widget.tab.openedAt)),
            key: const Key('session-status-duration'),
            style: style,
          ),
        ],
      ),
    );
  }
}
