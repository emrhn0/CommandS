import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:xterm/xterm.dart' show TerminalView;

import '../providers/app_state.dart';
import '../theme/app_theme.dart';

import '../widgets/connection_tree.dart';
import '../widgets/custom_title_bar.dart';
import '../widgets/new_connection_dialog.dart';
import '../widgets/quick_connect_bar.dart';
import '../widgets/terminal_tabs.dart';
import '../widgets/update_dialog.dart';
import 'settings_screen.dart';
import '../widgets/app_dialog.dart';
import '../widgets/quick_search.dart';
import '../l10n/strings.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  @override
  void initState() {
    super.initState();
    // Saved connections that could not be read are not saved over (see
    // StorageService.loadFailed); say so once, and offer the backups.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && context.read<AppState>().storageLoadFailed) _offerRestore();
    });
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    super.dispose();
  }

  /// Ctrl+K opens quick search, anywhere but in a terminal: there Ctrl+K
  /// belongs to the session (it deletes to the end of the line on Cisco and
  /// in bash), and Ctrl+Shift+K opens it instead.
  bool _onKey(KeyEvent event) {
    if (event is! KeyDownEvent || event.logicalKey != LogicalKeyboardKey.keyK) return false;
    final keyboard = HardwareKeyboard.instance;
    if (!(keyboard.isControlPressed || keyboard.isMetaPressed) || keyboard.isShiftPressed || keyboard.isAltPressed) {
      return false;
    }
    if (!mounted || !(ModalRoute.of(context)?.isCurrent ?? true)) return false;
    final focused = FocusManager.instance.primaryFocus?.context;
    if (focused != null && focused.findAncestorWidgetOfExactType<TerminalView>() != null) return false;
    showQuickSearch(context);
    return true;
  }

  Future<void> _offerRestore() async {
    final open = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AppDialog(
        title: tr('Your connections could not be read'),
        icon: Icons.warning_amber_rounded,
        width: 460,
        body: Text(
          tr('The saved connections are still there but could not be read, so nothing is saved over them. '
              'Restore the latest backup from Settings > Connections.'),
          style: const TextStyle(fontSize: 13, height: 1.45),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: Text(tr('Later'))),
          ElevatedButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(tr('Open backups')),
          ),
        ],
      ),
    );
    if (open == true && mounted) await showSettings(context, page: SettingsPage.connections);
  }

  @override
  Widget build(BuildContext context) {
    final width = context.select<AppState, double>((a) => a.sidebarWidth);
    final sidebarVisible = context.select<AppState, bool>((a) => a.sidebarVisible);
    return Scaffold(
      body: Column(
        children: [
          // The name on the left, the search box in the middle, always.
          const CustomTitleBar(center: _TitleSearchBox()),
          Expanded(
            child: Row(
              children: [
                if (sidebarVisible) SizedBox(
                  width: width,
                  child: Column(
                    children: [
                      Container(
                        height: 32,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        decoration: BoxDecoration(
                          border: Border(bottom: BorderSide(color: Theme.of(context).dividerColor)),
                        ),
                        child: Row(
                          children: [
                            // The panel's main action fills its first row.
                            Expanded(
                              child: SizedBox(
                                height: 26,
                                child: width < 230
                                    ? Tooltip(
                                        message: tr('New Connection'),
                                        child: ElevatedButton(
                                          key: const Key('sidebar-new-connection'),
                                          style: ElevatedButton.styleFrom(
                                            padding: const EdgeInsets.symmetric(horizontal: 8),
                                            minimumSize: const Size(0, 26),
                                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                          ),
                                          onPressed: () => showNewConnectionDialog(context),
                                          child: const Icon(Icons.add, size: 15),
                                        ),
                                      )
                                    : ElevatedButton.icon(
                                        key: const Key('sidebar-new-connection'),
                                        style: ElevatedButton.styleFrom(
                                          padding: const EdgeInsets.symmetric(horizontal: 8),
                                          minimumSize: const Size(0, 26),
                                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                        ),
                                        onPressed: () => showNewConnectionDialog(context),
                                        icon: const Icon(Icons.add, size: 15),
                                        label: Text(tr('New Connection'), style: const TextStyle(fontSize: 12)),
                                      ),
                              ),
                            ),
                            // Only appears once a newer release has been found.
                            const UpdateButton(compact: true),
                          ],
                        ),
                      ),
                      const Expanded(child: ConnectionTree()),
                      const QuickConnectBar(),
                      // Hiding the panel and Settings sit at its foot, out
                      // of the title bar.
                      Container(
                        key: const Key('sidebar-footer'),
                        height: 30,
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        decoration: BoxDecoration(
                          border: Border(top: BorderSide(color: Theme.of(context).dividerColor)),
                        ),
                        child: Row(
                          children: [
                            _HeaderIcon(
                              key: const Key('sidebar-toggle'),
                              icon: Icons.keyboard_double_arrow_left_rounded,
                              tooltip: tr('Hide Sidebar'),
                              onTap: () => context.read<AppState>().setSidebarVisible(false),
                            ),
                            const Spacer(),
                            // Theme, terminal colours, import/export and
                            // updates all live on the Settings page.
                            _HeaderIcon(
                              key: const Key('sidebar-settings'),
                              icon: Icons.settings_outlined,
                              tooltip: tr('Settings'),
                              onTap: () => showSettings(context),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                if (sidebarVisible) const _SidebarResizer(),
                // A hidden panel leaves a thin strip with the button that
                // brings it back, where the hide button was: at the foot.
                if (!sidebarVisible) const _CollapsedSidebarRail(),
                // Sessions take whatever the panel leaves: terminals re-wrap
                // and RDP sessions resize to the new pane.
                Expanded(child: TerminalTabsArea(sidebarVisible: sidebarVisible)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The connections panel's right edge: drag to make it wider or narrower
/// (long names stop being cut off), double-click to go back to the default.
class _SidebarResizer extends StatefulWidget {
  const _SidebarResizer();

  @override
  State<_SidebarResizer> createState() => _SidebarResizerState();
}

class _SidebarResizerState extends State<_SidebarResizer> {
  bool _hover = false;
  bool _dragging = false;

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final theme = Theme.of(context);
    final active = _hover || _dragging;
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: (_) => setState(() => _dragging = true),
        onHorizontalDragUpdate: (d) => app.setSidebarWidth(app.sidebarWidth + d.delta.dx),
        onHorizontalDragEnd: (_) {
          setState(() => _dragging = false);
          app.setSidebarWidth(app.sidebarWidth, save: true);
        },
        onDoubleTap: () => app.setSidebarWidth(AppState.defaultSidebarWidth, save: true),
        // A wider grip than the 1px line it draws, so it is easy to catch.
        child: SizedBox(
          width: 7,
          child: Center(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              width: active ? 3 : 1,
              color: active ? theme.colorScheme.primary.withValues(alpha: 0.5) : theme.dividerColor,
            ),
          ),
        ),
      ),
    );
  }
}

/// Small fixed-size icon button that never claims Material's 48px tap
/// target — keeps the 32px header row from overflowing.
class _HeaderIcon extends StatelessWidget {
  const _HeaderIcon({super.key, required this.icon, required this.tooltip, required this.onTap});
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        child: Padding(padding: const EdgeInsets.all(5), child: Icon(icon, size: 15)),
      ),
    );
  }
}

/// The search box in the middle of the title bar: a click (or Ctrl+K) opens
/// quick search.
class _TitleSearchBox extends StatefulWidget {
  const _TitleSearchBox();

  @override
  State<_TitleSearchBox> createState() => _TitleSearchBoxState();
}

class _TitleSearchBoxState extends State<_TitleSearchBox> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final accent = Theme.of(context).colorScheme.primary;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        key: const Key('quick-search-button'),
        onTap: () => showQuickSearch(context),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          width: 300,
          height: 23,
          padding: const EdgeInsets.symmetric(horizontal: 9),
          decoration: BoxDecoration(
            color: _hover ? palette.panelAlt : palette.panel,
            border: Border.all(color: _hover ? accent.withValues(alpha: 0.45) : palette.border),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            children: [
              Icon(Icons.search, size: 14, color: palette.textDim),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  tr('Search connections and folders'),
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: palette.textDim),
                ),
              ),
              Text(Platform.isMacOS ? '⌘K' : 'Ctrl K', style: TextStyle(fontSize: 10.5, color: palette.textDim.withValues(alpha: 0.8))),
            ],
          ),
        ),
      ),
    );
  }
}

/// What a hidden connections panel leaves: a thin strip on the left with the
/// show button at its foot, in the same spot as the hide button.
class _CollapsedSidebarRail extends StatelessWidget {
  const _CollapsedSidebarRail();

  @override
  Widget build(BuildContext context) {
    final divider = Theme.of(context).dividerColor;
    return Container(
      key: const Key('sidebar-rail'),
      width: 30,
      decoration: BoxDecoration(border: Border(right: BorderSide(color: divider))),
      child: Column(
        children: [
          const Spacer(),
          Container(
            height: 30,
            alignment: Alignment.centerLeft,
            padding: const EdgeInsets.only(left: 4),
            decoration: BoxDecoration(border: Border(top: BorderSide(color: divider))),
            child: _HeaderIcon(
              key: const Key('sidebar-toggle'),
              icon: Icons.keyboard_double_arrow_right_rounded,
              tooltip: tr('Show Sidebar'),
              onTap: () => context.read<AppState>().setSidebarVisible(true),
            ),
          ),
        ],
      ),
    );
  }
}
