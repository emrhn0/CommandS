import 'package:flutter/gestures.dart' show DragStartBehavior;
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
/// one zone; over a zone a line follows the mouse, and a click splits the
/// zone right there. The line is horizontal or vertical, picked at the top
/// (Shift switches it while held). Dividers drag, a zone goes with its x.
/// Null when cancelled.
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
  late ZoneNode _shape = widget.editing?.shape ?? const ZoneLeaf();

  /// The direction of the line a click splits along: a horizontal line
  /// stacks two zones, a vertical one puts them side by side.
  Axis _line = Axis.horizontal;
  late final _name = TextEditingController(text: widget.editing?.name ?? '');

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  bool get _canSplit => zoneCount(_shape) < maxCustomZones;

  /// A split along a [line] at [at] (0..1 across the zone).
  void _split(int zone, Axis line, double at) {
    if (!_canSplit) return;
    final axis = line == Axis.horizontal ? Axis.vertical : Axis.horizontal;
    setState(() => _shape = splitZone(_shape, zone, axis, ratio: at));
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
              Row(
                children: [
                  Expanded(
                    child: Text(
                      tr('Click where the line is to split a zone; Shift switches the line. Drag a divider to resize: it snaps to halves, thirds and quarters (Alt: no snapping). Double-click it to make the panes even.'),
                      style: TextStyle(fontSize: 12, color: dim),
                    ),
                  ),
                  const SizedBox(width: 12),
                  SegmentedButton<Axis>(
                    key: const ValueKey('split-line'),
                    showSelectedIcon: false,
                    style: const ButtonStyle(visualDensity: VisualDensity.compact),
                    segments: [
                      ButtonSegment(
                        value: Axis.horizontal,
                        icon: const Icon(Icons.horizontal_split_outlined, size: 16),
                        label: Text(tr('Horizontal split')),
                      ),
                      ButtonSegment(
                        value: Axis.vertical,
                        icon: const Icon(Icons.vertical_split_outlined, size: 16),
                        label: Text(tr('Vertical split')),
                      ),
                    ],
                    selected: {_line},
                    onSelectionChanged: (v) => setState(() => _line = v.single),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              // Shrinks with the window instead of pushing the buttons off it.
              Flexible(
                child: AspectRatio(
                aspectRatio: 16 / 9,
                child: _ZoneCanvas(
                  key: const ValueKey('zone-canvas'),
                  shape: _shape,
                  line: _line,
                  canSplit: _canSplit,
                  canRemove: count > 1,
                  onSplit: _split,
                  onRemove: _remove,
                  onResize: (path, ratio) => setState(() => _shape = setZoneRatio(_shape, path, ratio)),
                  onEqualize: (path) => setState(() => _shape = equalizeZones(_shape, path)),
                ),
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

/// The editable drawing: zones with their number, a line that follows the
/// mouse to split along, and dividers that drag. A dragged divider shows the
/// two shares and snaps to halves, thirds and quarters (Alt: no snapping);
/// a double click on it makes its row or column even.
class _ZoneCanvas extends StatefulWidget {
  const _ZoneCanvas({
    super.key,
    required this.shape,
    required this.line,
    required this.canSplit,
    required this.canRemove,
    required this.onSplit,
    required this.onRemove,
    required this.onResize,
    required this.onEqualize,
  });

  final ZoneNode shape;
  final Axis line;
  final bool canSplit;
  final bool canRemove;
  final void Function(int zone, Axis line, double at) onSplit;
  final void Function(int zone) onRemove;
  final void Function(List<bool> path, double ratio) onResize;
  final void Function(List<bool> path) onEqualize;

  @override
  State<_ZoneCanvas> createState() => _ZoneCanvasState();
}

class _ZoneCanvasState extends State<_ZoneCanvas> {
  static const double _divider = 8;

  /// The divider being dragged, by its path, and whether it sits on a snap
  /// ratio right now.
  String? _dragging;
  bool _snapped = false;

  static String _key(List<bool> path) => path.map((p) => p ? 1 : 0).join();

  Widget _node(ZoneNode node, List<bool> path, int firstZone) {
    if (node is! ZoneSplit) {
      return _Zone(
        index: firstZone,
        line: widget.line,
        canSplit: widget.canSplit,
        canRemove: widget.canRemove,
        onSplit: (line, at) => widget.onSplit(firstZone, line, at),
        onRemove: () => widget.onRemove(firstZone),
      );
    }
    final horizontal = node.axis == Axis.horizontal;
    final key = _key(path);
    return LayoutBuilder(
      builder: (context, constraints) {
        final total = (horizontal ? constraints.maxWidth : constraints.maxHeight) - _divider;
        // The divider sits under the mouse: the ratio is read from where the
        // pointer is in this split, not added up from movement, which lagged
        // behind by the distance a drag needs before it starts.
        void follow(Offset global) {
          final box = context.findRenderObject() as RenderBox?;
          if (box == null || total <= 0) return;
          final local = box.globalToLocal(global);
          final free = (((horizontal ? local.dx : local.dy) - _divider / 2) / total)
              .clamp(minZoneRatio, 1 - minZoneRatio);
          final ratio = HardwareKeyboard.instance.isAltPressed ? free : snapZoneRatio(free);
          setState(() {
            _dragging = key;
            _snapped = ratio != free || zoneSnapRatios.contains(ratio);
          });
          widget.onResize(path, ratio);
        }

        void end() => setState(() => _dragging = null);

        final theme = Theme.of(context);
        final accent = theme.colorScheme.primary;
        final dragging = _dragging == key;
        final at = node.ratio * total + _divider / 2;
        final first = (node.ratio * 100).round();
        return Stack(
          clipBehavior: Clip.none,
          children: [
            Flex(
              direction: node.axis,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  flex: (node.ratio * 1000).round(),
                  child: _node(node.first, [...path, false], firstZone),
                ),
                MouseRegion(
                  cursor: horizontal ? SystemMouseCursors.resizeColumn : SystemMouseCursors.resizeRow,
                  child: Tooltip(
                    message: tr('Double-click to make the panes even'),
                    waitDuration: const Duration(milliseconds: 800),
                    child: GestureDetector(
                      key: ValueKey('zone-divider-$key'),
                      behavior: HitTestBehavior.opaque,
                      dragStartBehavior: DragStartBehavior.down,
                      onPanDown: (d) => follow(d.globalPosition),
                      onPanUpdate: (d) => follow(d.globalPosition),
                      onPanEnd: (_) => end(),
                      onPanCancel: end,
                      onDoubleTap: () => widget.onEqualize(path),
                      child: SizedBox(
                        width: horizontal ? _divider : null,
                        height: horizontal ? null : _divider,
                        child: Center(
                          child: Container(
                            width: horizontal ? 2 : 24,
                            height: horizontal ? 24 : 2,
                            decoration: BoxDecoration(
                              color: accent.withValues(alpha: dragging ? 1 : 0.7),
                              borderRadius: BorderRadius.circular(1),
                            ),
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
            ),
            // The two shares, next to the divider while it is dragged; lit
            // when it sits on a half, third or quarter.
            if (dragging)
              Positioned(
                left: horizontal ? at - 48 : null,
                top: horizontal ? null : at - 13,
                right: horizontal ? null : 0,
                bottom: horizontal ? 0 : null,
                width: horizontal ? 96 : null,
                child: IgnorePointer(
                  child: Center(
                    child: Container(
                      key: const ValueKey('zone-share'),
                      margin: const EdgeInsets.all(6),
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: _snapped ? accent : theme.colorScheme.surface,
                        border: Border.all(color: accent),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        tr('{a}% | {b}%', {'a': first, 'b': 100 - first}),
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: _snapped ? theme.colorScheme.onPrimary : accent,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) => _node(widget.shape, const [], 0);
}

class _Zone extends StatefulWidget {
  const _Zone({
    required this.index,
    required this.line,
    required this.canSplit,
    required this.canRemove,
    required this.onSplit,
    required this.onRemove,
  });

  final int index;
  final Axis line;
  final bool canSplit;
  final bool canRemove;
  final void Function(Axis line, double at) onSplit;
  final VoidCallback onRemove;

  @override
  State<_Zone> createState() => _ZoneState();
}

class _ZoneState extends State<_Zone> {
  /// Where the mouse is over this zone, null when it is elsewhere.
  Offset? _pointer;
  bool _overButton = false;

  /// The line in use: the picked one, the other while Shift is held.
  Axis get _line {
    final shift = HardwareKeyboard.instance.isShiftPressed;
    if (!shift) return widget.line;
    return widget.line == Axis.horizontal ? Axis.vertical : Axis.horizontal;
  }

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    super.dispose();
  }

  /// Shift pressed or let go while the mouse is still: the line turns.
  bool _onKey(KeyEvent event) {
    if (_pointer != null &&
        (event.logicalKey == LogicalKeyboardKey.shiftLeft || event.logicalKey == LogicalKeyboardKey.shiftRight)) {
      setState(() {});
    }
    return false;
  }

  double _at(Offset local, Size size, Axis line) =>
      line == Axis.horizontal ? local.dy / size.height : local.dx / size.width;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;
    final pointer = _pointer;
    final line = _line;
    final showLine = pointer != null && widget.canSplit && !_overButton;
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        return MouseRegion(
          onHover: (e) => setState(() => _pointer = e.localPosition),
          onExit: (_) => setState(() => _pointer = null),
          cursor: widget.canSplit ? SystemMouseCursors.precise : SystemMouseCursors.basic,
          child: GestureDetector(
            key: ValueKey('zone-${widget.index}'),
            onTapUp: widget.canSplit
                ? (d) => widget.onSplit(line, _at(d.localPosition, size, line))
                : null,
            child: Container(
              decoration: BoxDecoration(
                color: accent.withValues(alpha: pointer != null ? 0.18 : 0.10),
                border: Border.all(color: accent.withValues(alpha: pointer != null ? 0.8 : 0.4)),
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
                  // The split to come: a faint line under the mouse.
                  if (showLine)
                    line == Axis.horizontal
                        ? Positioned(
                            key: const ValueKey('split-preview'),
                            left: 0,
                            right: 0,
                            top: pointer.dy.clamp(0, size.height) - 1,
                            child: IgnorePointer(child: Container(height: 2, color: accent.withValues(alpha: 0.55))),
                          )
                        : Positioned(
                            key: const ValueKey('split-preview'),
                            top: 0,
                            bottom: 0,
                            left: pointer.dx.clamp(0, size.width) - 1,
                            child: IgnorePointer(child: Container(width: 2, color: accent.withValues(alpha: 0.55))),
                          ),
                  if (pointer != null && widget.canRemove)
                    Positioned(
                      top: 2,
                      right: 2,
                      child: MouseRegion(
                        onEnter: (_) => setState(() => _overButton = true),
                        onExit: (_) => setState(() => _overButton = false),
                        child: IconButton(
                          key: ValueKey('zone-${widget.index}-remove'),
                          tooltip: tr('Remove pane'),
                          visualDensity: VisualDensity.compact,
                          iconSize: 16,
                          onPressed: widget.onRemove,
                          icon: const Icon(Icons.close),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
