import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../models/models.dart';
import '../providers/app_state.dart';
import '../theme/app_mark.dart';
import '../theme/app_theme.dart';
import 'import_export_dialog.dart';
import 'new_connection_dialog.dart';

/// What the session area shows while no tab is open: the mark and a
/// greeting, the two ways to add a connection, and the saved connections
/// opened most recently, each one click away.
class WelcomePanel extends StatelessWidget {
  const WelcomePanel({super.key, this.sidebarVisible = true, this.now});

  final bool sidebarVisible;

  /// The time the greeting is picked for; tests pass one in.
  final DateTime? now;

  /// Morning before noon, afternoon until six, evening after.
  static String greetingFor(DateTime time) => time.hour >= 5 && time.hour < 12
      ? tr('Good morning')
      : time.hour >= 12 && time.hour < 18
          ? tr('Good afternoon')
          : tr('Good evening');

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final palette = AppPalette.of(context);
    final accent = Theme.of(context).colorScheme.primary;
    final recent = app.recentConnections.take(5).toList();
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Column(
            key: const Key('welcome-panel'),
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  SvgPicture.asset(AppMark.darkAsset, width: 60, height: 60),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          greetingFor(now ?? DateTime.now()),
                          style: TextStyle(
                            fontSize: 26,
                            fontWeight: FontWeight.w600,
                            letterSpacing: -0.4,
                            color: palette.text,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          tr('{connections} connections, {folders} folders', {
                            'connections': app.connections.length,
                            'folders': app.folders.length,
                          }),
                          style: TextStyle(fontSize: 13, color: palette.textDim),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 22),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  FilledButton.icon(
                    key: const Key('welcome-new-connection'),
                    onPressed: () => showNewConnectionDialog(context),
                    icon: const Icon(Icons.add, size: 16),
                    label: Text(tr('New Connection')),
                  ),
                  OutlinedButton.icon(
                    key: const Key('welcome-import'),
                    onPressed: () => showImportDialog(context),
                    icon: const Icon(Icons.file_download_outlined, size: 16),
                    label: Text(tr('Import…')),
                  ),
                ],
              ),
              const SizedBox(height: 22),
              Container(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
                decoration: BoxDecoration(
                  color: palette.panel,
                  border: Border.all(color: palette.border),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      tr('Recently opened').toUpperCase(),
                      style: TextStyle(fontSize: 11, letterSpacing: 0.8, color: palette.textDim, fontWeight: FontWeight.w500),
                    ),
                    const SizedBox(height: 6),
                    if (recent.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Text(
                          sidebarVisible
                              ? tr('Pick a saved connection on the left, use quick connect,\nor start a new one.')
                              : tr('Show the sidebar to pick a saved connection,\nor start a new one.'),
                          style: TextStyle(fontSize: 12.5, color: palette.textDim, height: 1.5),
                        ),
                      )
                    else
                      for (final conn in recent) _RecentRow(conn: conn, accent: accent, palette: palette),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RecentRow extends StatelessWidget {
  const _RecentRow({required this.conn, required this.accent, required this.palette});

  final SavedConnection conn;
  final Color accent;
  final AppPalette palette;

  @override
  Widget build(BuildContext context) {
    final defaultPort = conn.protocol == ConnectionProtocol.rdp ? 3389 : 22;
    final address = conn.port == defaultPort ? conn.host : '${conn.host}:${conn.port}';
    return InkWell(
      key: Key('welcome-recent-${conn.id}'),
      borderRadius: BorderRadius.circular(6),
      onTap: () => context.read<AppState>().openConnection(conn),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 7),
        child: Row(
          children: [
            Container(
              width: 36,
              padding: const EdgeInsets.symmetric(vertical: 2),
              alignment: Alignment.center,
              decoration: BoxDecoration(color: palette.panelAlt, borderRadius: BorderRadius.circular(4)),
              child: Text(
                conn.protocol == ConnectionProtocol.rdp ? 'RDP' : 'SSH',
                style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w600, color: palette.textDim),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(conn.name, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: palette.text)),
            ),
            const SizedBox(width: 10),
            Text(address, style: TextStyle(fontSize: 11.5, color: palette.textDim, fontFamily: 'Consolas')),
          ],
        ),
      ),
    );
  }
}
