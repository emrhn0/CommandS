import 'package:flutter/material.dart';
import '../widgets/connection_tree.dart';
import '../widgets/custom_title_bar.dart';
import '../widgets/new_connection_dialog.dart';
import '../widgets/quick_connect_bar.dart';
import '../widgets/terminal_tabs.dart';
import '../widgets/update_dialog.dart';
import 'settings_screen.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          const CustomTitleBar(),
          Expanded(
            child: Row(
              children: [
                SizedBox(
                  width: 260,
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
                            // Only appears once a newer release has been found.
                            const UpdateButton(),
                            const Spacer(),
                            // Theme, terminal colours, import/export and
                            // updates all live on the Settings page now,
                            // instead of four unlabelled icons here.
                            _HeaderIcon(
                              icon: Icons.settings_outlined,
                              tooltip: 'Settings',
                              onTap: () => showSettings(context),
                            ),
                          ],
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(8, 8, 8, 2),
                        child: SizedBox(
                          height: 30,
                          child: ElevatedButton.icon(
                            onPressed: () => showNewConnectionDialog(context),
                            icon: const Icon(Icons.add, size: 15),
                            label: const Text('New Connection', style: TextStyle(fontSize: 12)),
                          ),
                        ),
                      ),
                      const Expanded(child: ConnectionTree()),
                      const QuickConnectBar(),
                    ],
                  ),
                ),
                VerticalDivider(width: 1, color: Theme.of(context).dividerColor),
                const Expanded(child: TerminalTabsArea()),
              ],
            ),
          ),
        ],
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
        child: Padding(
          padding: const EdgeInsets.all(5),
          child: Icon(icon, size: 15),
        ),
      ),
    );
  }
}
