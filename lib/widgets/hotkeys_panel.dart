import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../providers/app_state.dart';
import '../services/app_commands.dart';
import '../theme/app_theme.dart';

class HotkeysPanel extends StatefulWidget {
  const HotkeysPanel({super.key});

  @override
  State<HotkeysPanel> createState() => _HotkeysPanelState();
}

class _HotkeysPanelState extends State<HotkeysPanel> {
  final _filter = TextEditingController();

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  Future<void> _record(AppCommand command) async {
    final hotkey = await showDialog<Hotkey>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(
          tr('Set shortcut for {command}', {'command': tr(command.title)}),
        ),
        content: Focus(
          autofocus: true,
          onKeyEvent: (_, event) {
            if (event is! KeyDownEvent) return KeyEventResult.ignored;
            if (event.logicalKey == LogicalKeyboardKey.escape) {
              Navigator.of(dialogContext).pop();
              return KeyEventResult.handled;
            }
            final hotkey = Hotkey.fromEvent(event, HardwareKeyboard.instance);
            if (hotkey != null) {
              Navigator.of(dialogContext).pop(hotkey);
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: Text(
            tr('Press a shortcut with Ctrl, Alt or Meta. Esc cancels.'),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(tr('Cancel')),
          ),
        ],
      ),
    );
    if (hotkey == null || !mounted) return;
    final applied = await context.read<AppState>().setCommandHotkey(
      command.id,
      hotkey,
    );
    if (!applied && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr('This shortcut is already in use.'))),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final palette = AppPalette.of(context);
    final query = _filter.text.trim().toLowerCase();
    final commands = AppCommand.all
        .where(
          (command) =>
              query.isEmpty ||
              tr(command.title).toLowerCase().contains(query) ||
              command.title.toLowerCase().contains(query),
        )
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          key: const Key('hotkeys-filter'),
          controller: _filter,
          decoration: InputDecoration(
            prefixIcon: const Icon(Icons.search, size: 18),
            hintText: tr('Filter commands'),
          ),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 10),
        Text(
          tr(
            'Click a shortcut to change it. The same commands appear in the command palette.',
          ),
          style: TextStyle(fontSize: 12, color: palette.textDim),
        ),
        const SizedBox(height: 14),
        for (final command in commands)
          Container(
            key: ValueKey('hotkey-${command.id.name}'),
            padding: const EdgeInsets.symmetric(vertical: 7),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: palette.border)),
            ),
            child: Row(
              children: [
                Icon(command.icon, size: 17, color: palette.textDim),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    tr(command.title),
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
                OutlinedButton(
                  key: ValueKey('hotkey-edit-${command.id.name}'),
                  onPressed: () => _record(command),
                  child: Text(
                    app.hotkeyFor(command.id)?.label ?? tr('Unassigned'),
                  ),
                ),
                IconButton(
                  tooltip: tr('Remove shortcut'),
                  onPressed: app.hotkeyFor(command.id) == null
                      ? null
                      : () => app.setCommandHotkey(command.id, null),
                  icon: const Icon(Icons.close, size: 16),
                ),
                IconButton(
                  tooltip: tr('Reset to default'),
                  onPressed: () => app.resetCommandHotkey(command.id),
                  icon: const Icon(Icons.restart_alt, size: 17),
                ),
              ],
            ),
          ),
        if (commands.isEmpty)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(tr('No matching commands')),
          ),
      ],
    );
  }
}
