import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../providers/app_state.dart';
import '../services/backup_service.dart';
import '../services/open_path.dart';
import 'app_dialog.dart';

/// Settings > Connections > Backups: the copies on disk, newest first, each
/// one click from being restored.
class BackupsPanel extends StatefulWidget {
  const BackupsPanel({super.key});

  @override
  State<BackupsPanel> createState() => _BackupsPanelState();
}

class _BackupsPanelState extends State<BackupsPanel> {
  static const _shown = 8;

  List<BackupEntry>? _entries;
  bool _all = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final entries = await context.read<AppState>().backups.list();
    if (mounted) setState(() => _entries = entries);
  }

  static String reasonLabel(BackupReason reason) => switch (reason) {
        BackupReason.daily => tr('Daily'),
        BackupReason.manual => tr('Backed up by hand'),
        BackupReason.beforeImport => tr('Before an import'),
        BackupReason.beforeDelete => tr('Before a delete'),
        BackupReason.beforeRestore => tr('Before a restore'),
      };

  static String _two(int n) => n.toString().padLeft(2, '0');
  static String dateLabel(DateTime t) =>
      '${_two(t.day)}.${_two(t.month)}.${t.year}  ${_two(t.hour)}:${_two(t.minute)}';

  Future<void> _backUpNow() async {
    setState(() => _busy = true);
    final file = await context.read<AppState>().backups.backUp(BackupReason.manual);
    await _reload();
    if (!mounted) return;
    setState(() => _busy = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(file == null ? tr('There is nothing to back up yet.') : tr('Backup saved.'))),
    );
  }

  Future<void> _restore(BackupEntry entry) async {
    final app = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AppDialog(
        title: tr('Restore this backup?'),
        icon: Icons.settings_backup_restore,
        width: 440,
        body: Text(
          tr(
            'Your folders, connections and layouts go back to how they were on {date}. '
            'What you have now is backed up first, so this can be undone. Open tabs stay open.',
            {'date': dateLabel(entry.created)},
          ),
          style: const TextStyle(fontSize: 13, height: 1.45),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: Text(tr('Cancel'))),
          ElevatedButton(
            key: const Key('backup-restore-confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(tr('Restore')),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    final restored = await app.restoreBackup(entry);
    await _reload();
    if (!mounted) return;
    setState(() => _busy = false);
    messenger.showSnackBar(SnackBar(
      content: Text(restored ? tr('Backup restored.') : tr('This backup could not be read. Nothing was changed.')),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final dim = Theme.of(context).textTheme.bodySmall?.color;
    final entries = _entries;
    final visible = entries == null ? const <BackupEntry>[] : (_all ? entries : entries.take(_shown).toList());
    return Column(
      key: const Key('backups-panel'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (app.storageLoadFailed) ...[
          Container(
            key: const Key('backups-load-failed'),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.error.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              tr('Your saved connections could not be read. Nothing is saved over them until you restore a backup.'),
              style: TextStyle(fontSize: 12.5, color: Theme.of(context).colorScheme.error),
            ),
          ),
          const SizedBox(height: 14),
        ],
        Text(
          tr('A copy is kept every day, and before an import, a delete or a restore. Passwords stay encrypted in it.'),
          style: TextStyle(fontSize: 12.5, color: dim, height: 1.45),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 10,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              key: const Key('backup-now'),
              onPressed: _busy ? null : _backUpNow,
              icon: const Icon(Icons.save_outlined, size: 16),
              label: Text(tr('Back up now')),
            ),
            TextButton.icon(
              onPressed: () async {
                await app.backups.directory.create(recursive: true);
                await OpenPath.open(app.backups.directory.path);
              },
              icon: const Icon(Icons.folder_open_outlined, size: 16),
              label: Text(tr('Open folder')),
            ),
          ],
        ),
        const SizedBox(height: 14),
        if (entries == null)
          const SizedBox(height: 24)
        else if (entries.isEmpty)
          Text(tr('No backups yet. The first one is taken today.'), style: TextStyle(fontSize: 12.5, color: dim))
        else ...[
          for (final e in visible)
            Padding(
              key: Key('backup-row-${e.file.uri.pathSegments.last}'),
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                children: [
                  SizedBox(
                    width: 150,
                    child: Text(dateLabel(e.created), style: const TextStyle(fontSize: 13, fontFeatures: [FontFeature.tabularFigures()])),
                  ),
                  Expanded(child: Text(reasonLabel(e.reason), style: TextStyle(fontSize: 12.5, color: dim))),
                  if (e.connections != null)
                    Padding(
                      padding: const EdgeInsets.only(right: 12),
                      child: Text(
                        tr('{count} connections', {'count': e.connections}),
                        style: TextStyle(fontSize: 12.5, color: dim),
                      ),
                    ),
                  TextButton(
                    onPressed: _busy ? null : () => _restore(e),
                    child: Text(tr('Restore')),
                  ),
                ],
              ),
            ),
          if (!_all && entries.length > _shown)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: () => setState(() => _all = true),
                child: Text(tr('Show all {count}', {'count': entries.length})),
              ),
            ),
        ],
      ],
    );
  }
}
