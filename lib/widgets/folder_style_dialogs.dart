import 'package:flutter/material.dart';

import '../l10n/strings.dart';
import '../models/models.dart';
import '../providers/app_state.dart';
import '../theme/app_theme.dart';
import 'app_dialog.dart';
import 'color_picker_dialog.dart';

/// What the colour dialog decided: a kind, a plain colour, or neither.
class FolderStyleChoice {
  const FolderStyleChoice.kind(FolderKind this.kind) : color = null;
  const FolderStyleChoice.color(int this.color) : kind = null;
  const FolderStyleChoice.none() : kind = null, color = null;

  final FolderKind? kind;
  final int? color;
}

/// A kind's colour dot and its name, as the kind choices show it.
class FolderKindLabel extends StatelessWidget {
  const FolderKindLabel({super.key, required this.kind});
  final FolderKind kind;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.folder, size: 16, color: Color(kind.color)),
        const SizedBox(width: 6),
        Text(tr(kind.label)),
      ],
    );
  }
}

/// A rounded, outlined choice: ringed in [ring] when picked.
class _Choice extends StatelessWidget {
  const _Choice({super.key, required this.child, required this.selected, required this.onTap, this.ring});
  final Widget child;
  final bool selected;
  final VoidCallback onTap;
  final Color? ring;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: selected ? (ring ?? scheme.primary).withAlpha(0x26) : palette.panelAlt,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: selected ? (ring ?? scheme.primary) : palette.border, width: selected ? 1.5 : 1),
        ),
        child: child,
      ),
    );
  }
}

/// The colour dialog of a folder: the three kinds, named, then the plain
/// colours (unnamed) and a colour of one's own. Pops a [FolderStyleChoice],
/// or null when closed without one.
class FolderColorDialog extends StatelessWidget {
  const FolderColorDialog({super.key, required this.name, this.current, this.currentKind});

  final String name;
  final int? current;
  final FolderKind? currentKind;

  Future<void> _custom(BuildContext context) async {
    final initial = current != null ? Color(current!) : const Color(0xFFB57CF0);
    final picked = await showColorPicker(context, initial: initial, title: 'Folder color');
    if (picked == null || !context.mounted) return;
    final argb = picked.withAlpha(255).toARGB32();
    // A kind's own colour typed in makes the folder that kind.
    final kind = FolderKind.ofColor(argb);
    Navigator.of(context).pop(kind != null ? FolderStyleChoice.kind(kind) : FolderStyleChoice.color(argb));
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final ownColor = current != null && currentKind == null && !AppState.folderColors.contains(current);
    return AppDialog(
      title: tr('Color for "{name}"', {'name': name}),
      icon: Icons.palette_outlined,
      width: 420,
      body: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            tr('Shown on the folder, the folders inside it and the tabs of its connections.'),
            style: TextStyle(fontSize: 12, color: palette.textDim),
          ),
          const SizedBox(height: 14),
          Text(tr('Folder type'), style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final kind in FolderKind.values)
                _Choice(
                  key: ValueKey('folder-kind-${kind.name}'),
                  selected: currentKind == kind,
                  ring: Color(kind.color),
                  onTap: () => Navigator.of(context).pop(FolderStyleChoice.kind(kind)),
                  child: FolderKindLabel(kind: kind),
                ),
            ],
          ),
          const SizedBox(height: 16),
          Text(tr('Other colors'), style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              for (final color in AppState.folderColors)
                _Swatch(
                  key: ValueKey('folder-swatch-$color'),
                  color: Color(color),
                  selected: currentKind == null && color == current,
                  onTap: () => Navigator.of(context).pop(FolderStyleChoice.color(color)),
                ),
              if (ownColor)
                _Swatch(
                  key: const ValueKey('folder-swatch-own'),
                  color: Color(current!),
                  selected: true,
                  onTap: () => Navigator.of(context).pop(FolderStyleChoice.color(current!)),
                ),
              TextButton.icon(
                key: const ValueKey('folder-color-custom'),
                onPressed: () => _custom(context),
                icon: const Icon(Icons.colorize_outlined, size: 16),
                label: Text(tr('Custom…')),
              ),
            ],
          ),
        ],
      ),
      actions: [
        TextButton(
          key: const Key('folder-color-none'),
          onPressed: () => Navigator.of(context).pop(const FolderStyleChoice.none()),
          child: Text(tr('No color')),
        ),
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(tr('Cancel'))),
      ],
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch({super.key, required this.color, required this.selected, required this.onTap});
  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return InkWell(
      customBorder: const CircleBorder(),
      onTap: onTap,
      child: Container(
        width: 28,
        height: 28,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(color: selected ? palette.text : Colors.transparent, width: 2),
        ),
        child: selected ? const Icon(Icons.check, size: 16, color: Colors.white) : null,
      ),
    );
  }
}

/// What the new folder dialog returns: the name, and the kind if one was
/// picked.
typedef NewFolder = ({String name, FolderKind? kind});

/// Asks for a new folder's name and what it holds: an ordinary folder, or a
/// network, firewall or system one in that kind's colour.
Future<NewFolder?> showNewFolderDialog(BuildContext context) {
  return showDialog<NewFolder>(context: context, builder: (_) => const _NewFolderDialog());
}

class _NewFolderDialog extends StatefulWidget {
  const _NewFolderDialog();

  @override
  State<_NewFolderDialog> createState() => _NewFolderDialogState();
}

class _NewFolderDialogState extends State<_NewFolderDialog> {
  final _name = TextEditingController();
  FolderKind? _kind;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _name.text.trim();
    if (name.isEmpty) return;
    Navigator.pop<NewFolder>(context, (name: name, kind: _kind));
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return AppDialog(
      title: tr('New folder'),
      icon: Icons.create_new_folder_outlined,
      width: 440,
      body: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LabeledField(
            label: 'Name',
            child: TextField(
              key: const ValueKey('new-folder-name'),
              controller: _name,
              autofocus: true,
              onSubmitted: (_) => _submit(),
            ),
          ),
          const SizedBox(height: 4),
          Text(tr('Folder type'), style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _Choice(
                key: const ValueKey('new-folder-kind-none'),
                selected: _kind == null,
                onTap: () => setState(() => _kind = null),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.folder, size: 16, color: palette.textDim),
                    const SizedBox(width: 6),
                    Text(tr('Normal')),
                  ],
                ),
              ),
              for (final kind in FolderKind.values)
                _Choice(
                  key: ValueKey('new-folder-kind-${kind.name}'),
                  selected: _kind == kind,
                  ring: Color(kind.color),
                  onTap: () => setState(() => _kind = kind),
                  child: FolderKindLabel(kind: kind),
                ),
            ],
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('Cancel'))),
        ElevatedButton(key: const ValueKey('new-folder-create'), onPressed: _submit, child: Text(tr('Create'))),
      ],
    );
  }
}
