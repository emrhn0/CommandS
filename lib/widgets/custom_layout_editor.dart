import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/strings.dart';
import '../services/pane_layout.dart';

/// What the editor ended with: a layout to keep, or a request to delete the
/// one being edited.
sealed class CustomLayoutEdit {
  const CustomLayoutEdit();
}

class CustomLayoutSaved extends CustomLayoutEdit {
  const CustomLayoutSaved(this.layout);
  final CustomLayout layout;
}

class CustomLayoutDeleted extends CustomLayoutEdit {
  const CustomLayoutDeleted();
}

/// Draws a custom split layout, the way PowerToys FancyZones does: start from
/// one zone, click a zone to split it side by side (Shift+click: stacked),
/// drag a divider to resize, remove a zone with its x. Null when cancelled.
Future<CustomLayoutEdit?> showCustomLayoutEditor(
  BuildContext context, {
  CustomLayout? editing,
  required String Function() newId,
}) {
  return showDialog<CustomLayoutEdit>(
    context: context,
    builder: (_) => _CustomLayoutEditor(editing: editing, newId: newId),
  );
}

class _CustomLayoutEditor extends StatefulWidget {
  const _CustomLayoutEditor({required this.editing, required this.newId});
  final CustomLayout? editing;
  final String Function() newId;

  @override
  State<_CustomLayoutEditor> createState() => _CustomLayoutEditorState();
}

class _CustomLayoutEditorState extends State<_CustomLayoutEditor> {
  late ZoneNode _shape = widget.editing?.shape ??
      const ZoneSplit(axis: Axis.horizontal, first: ZoneLeaf(), second: ZoneLeaf());
  late final _name = TextEditingController(text: widget.editing?.name ?? '');

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  bool get _canSplit => zoneCount(_shape) < maxCustomZones;

  void _split(int zone, Axis axis) {
    if (!_canSplit) return;
    setState(() => _shape = splitZone(_shape, zone, axis));
  }

  void _remove(int zone) {
    if (zoneCount(_shape) < 2) return;
    setState(() => _shape = removeZone(_shape, zone));
  }

  void _save() {
    final name = _name.text.trim();
    if (name.isEmpty) return;
    Navigator.of(context).pop(
      CustomLayoutSaved(CustomLayout(id: widget.editing?.id ?? widget.newId(), name: name, shape: _shape)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final dim = Theme.of(context).textTheme.bodySmall?.color;
    final count = zoneCount(_shape);
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 22, 24, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                widget.editing == null ? tr('New custom layout') : tr('Edit custom layout'),
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 6),
              Text(
                tr('Click a zone to split it side by side, Shift+click to stack it. Drag a divider to resize.'),
                style: TextStyle(fontSize: 12, color: dim),
              ),
              const SizedBox(height: 14),
              AspectRatio(
                aspectRatio: 16 / 9,
                child: _ZoneCanvas(
                  key: const ValueKey('zone-canvas'),
                  shape: _shape,
                  canSplit: _canSplit,
                  canRemove: count > 1,
                  onSplit: _split,
                  onRemove: _remove,
                  onResize: (path, ratio) => setState(() => _shape = setZoneRatio(_shape, path, ratio)),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                tr('{n} of {max} panes', {'n': count, 'max': maxCustomZones}),
                style: TextStyle(fontSize: 11, color: dim),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('custom-layout-name'),
                controller: _name,
                autofocus: widget.editing == null,
                decoration: InputDecoration(labelText: tr('Name'), isDense: true),
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) => _save(),
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  if (widget.editing != null)
                    TextButton.icon(
                      key: const ValueKey('custom-layout-delete'),
                      onPressed: () => Navigator.of(context).pop(const CustomLayoutDeleted()),
                      icon: const Icon(Icons.delete_outline, size: 16),
                      label: Text(tr('Delete')),
                      style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
                    ),
                  const Spacer(),
                  TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(tr('Cancel'))),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    key: const ValueKey('custom-layout-save'),
                    onPressed: _name.text.trim().isEmpty ? null : _save,
                    child: Text(tr('Save')),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The editable drawing: zones with their number and buttons, dividers that
/// drag.
class _ZoneCanvas extends StatelessWidget {
  const _ZoneCanvas({
    super.key,
    required this.shape,
    required this.canSplit,
    required this.canRemove,
    required this.onSplit,
    required this.onRemove,
    required this.onResize,
  });

  final ZoneNode shape;
  final bool canSplit;
  final bool canRemove;
  final void Function(int zone, Axis axis) onSplit;
  final void Function(int zone) onRemove;
  final void Function(List<bool> path, double ratio) onResize;

  static const double _divider = 8;

  Widget _node(ZoneNode node, List<bool> path, int firstZone) {
    if (node is! ZoneSplit) {
      return _Zone(
        index: firstZone,
        canSplit: canSplit,
        canRemove: canRemove,
        onSplit: (axis) => onSplit(firstZone, axis),
        onRemove: () => onRemove(firstZone),
      );
    }
    final horizontal = node.axis == Axis.horizontal;
    return LayoutBuilder(
      builder: (context, constraints) {
        final total = (horizontal ? constraints.maxWidth : constraints.maxHeight) - _divider;
        return Flex(
          direction: node.axis,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              flex: (node.ratio * 1000).round(),
              child: _node(node.first, [...path, false], firstZone),
            ),
            MouseRegion(
              cursor: horizontal ? SystemMouseCursors.resizeColumn : SystemMouseCursors.resizeRow,
              child: GestureDetector(
                key: ValueKey('zone-divider-${path.map((p) => p ? 1 : 0).join()}'),
                behavior: HitTestBehavior.opaque,
                onPanUpdate: (d) {
                  if (total <= 0) return;
                  final delta = horizontal ? d.delta.dx : d.delta.dy;
                  onResize(path, node.ratio + delta / total);
                },
                child: SizedBox(
                  width: horizontal ? _divider : null,
                  height: horizontal ? null : _divider,
                  child: Center(
                    child: Container(
                      width: horizontal ? 2 : 24,
                      height: horizontal ? 24 : 2,
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.7),
                        borderRadius: BorderRadius.circular(1),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Expanded(
              flex: ((1 - node.ratio) * 1000).round(),
              child: _node(node.second, [...path, true], firstZone + zoneCount(node.first)),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) => _node(shape, const [], 0);
}

class _Zone extends StatefulWidget {
  const _Zone({
    required this.index,
    required this.canSplit,
    required this.canRemove,
    required this.onSplit,
    required this.onRemove,
  });

  final int index;
  final bool canSplit;
  final bool canRemove;
  final ValueChanged<Axis> onSplit;
  final VoidCallback onRemove;

  @override
  State<_Zone> createState() => _ZoneState();
}

class _ZoneState extends State<_Zone> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;
    Widget button(String key, IconData icon, String tip, VoidCallback? onPressed) => IconButton(
      key: ValueKey('zone-${widget.index}-$key'),
      tooltip: tip,
      visualDensity: VisualDensity.compact,
      iconSize: 16,
      onPressed: onPressed,
      icon: Icon(icon),
    );
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: widget.canSplit ? SystemMouseCursors.click : SystemMouseCursors.basic,
      child: GestureDetector(
        key: ValueKey('zone-${widget.index}'),
        onTap: widget.canSplit
            ? () => widget.onSplit(HardwareKeyboard.instance.isShiftPressed ? Axis.vertical : Axis.horizontal)
            : null,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 100),
          decoration: BoxDecoration(
            color: accent.withValues(alpha: _hover ? 0.22 : 0.12),
            border: Border.all(color: accent.withValues(alpha: _hover ? 0.9 : 0.4)),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Stack(
            children: [
              Center(
                child: Text(
                  '${widget.index + 1}',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: accent),
                ),
              ),
              if (_hover)
                Positioned(
                  top: 2,
                  right: 2,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      button('split-h', Icons.vertical_split_outlined, tr('Split side by side'),
                          widget.canSplit ? () => widget.onSplit(Axis.horizontal) : null),
                      button('split-v', Icons.horizontal_split_outlined, tr('Split stacked'),
                          widget.canSplit ? () => widget.onSplit(Axis.vertical) : null),
                      if (widget.canRemove) button('remove', Icons.close, tr('Remove pane'), widget.onRemove),
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
