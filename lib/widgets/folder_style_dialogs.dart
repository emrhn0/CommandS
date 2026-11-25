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

/// The colour dialog of a folder: the three kinds, named, then "no colour",
/// the plain colours (unnamed) and a colour of one's own. A click only
/// picks; Save pops the [FolderStyleChoice], and closing pops null.
class FolderColorDialog extends StatefulWidget {
  const FolderColorDialog({super.key, required this.name, this.current, this.currentKind});

  final String name;
  final int? current;
  final FolderKind? currentKind;

  @override
  State<FolderColorDialog> createState() => _FolderColorDialogState();
}

class _FolderColorDialogState extends State<FolderColorDialog> {
  late FolderStyleChoice _choice = widget.currentKind != null
      ? FolderStyleChoice.kind(widget.currentKind!)
      : widget.current != null
          ? FolderStyleChoice.color(widget.current!)
          : const FolderStyleChoice.none();

  /// A colour of one's own on show: the folder's, or one just picked.
  late int? _own = widget.currentKind == null &&
          widget.current != null &&
          !AppState.folderColors.contains(widget.current)
      ? widget.current
      : null;

  void _pick(FolderStyleChoice choice) => setState(() => _choice = choice);

  Future<void> _custom() async {
    final start = _choice.color ?? _own;
    final initial = start != null ? Color(start) : const Color(0xFFB57CF0);
    final picked = await showColorPicker(context, initial: initial, title: 'Folder color');
    if (picked == null || !mounted) return;
    final argb = picked.withAlpha(255).toARGB32();
    // A kind's own colour typed in picks that kind.
    final kind = FolderKind.ofColor(argb);
    setState(() {
      if (kind != null) {
        _choice = FolderStyleChoice.kind(kind);
      } else {
        if (!AppState.folderColors.contains(argb)) _own = argb;
        _choice = FolderStyleChoice.color(argb);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final noneChosen = _choice.kind == null && _choice.color == null;
    return AppDialog(
      title: tr('Color for "{name}"', {'name': widget.name}),
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
                  selected: _choice.kind == kind,
                  ring: Color(kind.color),
                  onTap: () => _pick(FolderStyleChoice.kind(kind)),
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
              Tooltip(
                message: tr('No color'),
                child: _NoColorSwatch(
                  key: const Key('folder-color-none'),
                  selected: noneChosen,
                  onTap: () => _pick(const FolderStyleChoice.none()),
                ),
              ),
              for (final color in AppState.folderColors)
                _Swatch(
                  key: ValueKey('folder-swatch-$color'),
                  color: Color(color),
                  selected: _choice.kind == null && _choice.color == color,
                  onTap: () => _pick(FolderStyleChoice.color(color)),
                ),
              if (_own case final own?)
                _Swatch(
                  key: const ValueKey('folder-swatch-own'),
                  color: Color(own),
                  selected: _choice.kind == null && _choice.color == own,
                  onTap: () => _pick(FolderStyleChoice.color(own)),
                ),
              TextButton.icon(
                key: const ValueKey('folder-color-custom'),
                onPressed: _custom,
                icon: const Icon(Icons.colorize_outlined, size: 16),
                label: Text(tr('Custom…')),
              ),
            ],
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(tr('Cancel'))),
        ElevatedButton(
          key: const Key('folder-color-save'),
          onPressed: () => Navigator.of(context).pop(_choice),
          child: Text(tr('Save')),
        ),
      ],
    );
  }
}

/// "No color": an empty ring crossed by a line, like a see-through swatch.
class _NoColorSwatch extends StatelessWidget {
  const _NoColorSwatch({super.key, required this.selected, required this.onTap});
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
          shape: BoxShape.circle,
          border: Border.all(color: selected ? palette.text : palette.textDim, width: selected ? 2 : 1.5),
        ),
        child: CustomPaint(painter: _SlashPainter(selected ? palette.text : palette.textDim)),
      ),
    );
  }
}

class _SlashPainter extends CustomPainter {
  const _SlashPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final inset = size.width * 0.22;
    canvas.drawLine(
      Offset(size.width - inset, inset),
      Offset(inset, size.height - inset),
      Paint()
        ..color = color
        ..strokeWidth = 1.5
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_SlashPainter old) => old.color != color;
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

  /// Picks [kind] and, while the name is empty or still the one filled in
  /// for the previous kind, names the folder after it ("Firewall").
  void _setKind(FolderKind? kind) {
    final text = _name.text.trim();
    final auto = text.isEmpty || FolderKind.values.any((k) => k.label == text);
    setState(() {
      _kind = kind;
      if (auto) {
        _name.text = kind?.label ?? '';
        _name.selection = TextSelection(baseOffset: 0, extentOffset: _name.text.length);
      }
    });
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
                onTap: () => _setKind(null),
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
                  onTap: () => _setKind(kind),
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
