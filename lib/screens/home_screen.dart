import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/app_state.dart';
import '../widgets/connection_tree.dart';
import '../widgets/custom_title_bar.dart';
import '../widgets/import_export_dialog.dart';
import '../widgets/new_connection_dialog.dart';
import '../widgets/quick_connect_bar.dart';
import '../widgets/terminal_appearance_dialog.dart';
import '../widgets/terminal_tabs.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
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
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            _HeaderIcon(icon: Icons.file_upload_outlined, tooltip: 'Export', onTap: () => showExportDialog(context)),
                            _HeaderIcon(icon: Icons.file_download_outlined, tooltip: 'Import', onTap: () => showImportDialog(context)),
                            _HeaderIcon(
                              icon: Icons.palette_outlined,
                              tooltip: 'Terminal appearance',
                              onTap: () => showTerminalAppearanceDialog(context),
                            ),
                            _HeaderIcon(
                              icon: app.themeMode == ThemeMode.dark ? Icons.dark_mode_outlined : Icons.light_mode_outlined,
                              tooltip: 'Toggle theme',
                              onTap: app.toggleTheme,
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
