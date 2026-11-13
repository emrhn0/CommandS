import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/app_state.dart';

import '../widgets/connection_tree.dart';
import '../widgets/custom_title_bar.dart';
import '../widgets/new_connection_dialog.dart';
import '../widgets/quick_connect_bar.dart';
import '../widgets/terminal_tabs.dart';
import '../widgets/update_dialog.dart';
import 'settings_screen.dart';
import '../l10n/strings.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  @override
  Widget build(BuildContext context) {
    final width = context.select<AppState, double>((a) => a.sidebarWidth);
    final sidebarVisible = context.select<AppState, bool>((a) => a.sidebarVisible);
    return Scaffold(
      body: Column(
        children: [
          CustomTitleBar(
            leading: Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Tooltip(
                message: tr(sidebarVisible ? 'Hide Sidebar' : 'Show Sidebar'),
                child: IconButton(
                  key: const Key('sidebar-toggle'),
                  onPressed: () => context.read<AppState>().setSidebarVisible(!sidebarVisible),
                  icon: Icon(sidebarVisible ? Icons.menu_open : Icons.menu, size: 18),
                  constraints: const BoxConstraints.tightFor(width: 32, height: 32),
                  padding: EdgeInsets.zero,
                ),
              ),
            ),
          ),
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
                            SizedBox(
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
                            const Spacer(),
                            // Only appears once a newer release has been found.
                            const UpdateButton(compact: true),
                            const SizedBox(width: 8),
                            // Theme, terminal colours, import/export and
                            // updates all live on the Settings page now,
                            // instead of four unlabelled icons here.
                            _HeaderIcon(
                              icon: Icons.settings_outlined,
                              tooltip: tr('Settings'),
                              onTap: () => showSettings(context),
                            ),
                          ],
                        ),
                      ),
                      const Expanded(child: ConnectionTree()),
                      const QuickConnectBar(),
                    ],
                  ),
                ),
                if (sidebarVisible) const _SidebarResizer(),
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
  const _HeaderIcon({required this.icon, required this.tooltip, required this.onTap});
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
