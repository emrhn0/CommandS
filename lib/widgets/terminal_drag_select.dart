import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:xterm/xterm.dart';

/// Mouse selection that can run past the edge of a terminal view, as in
/// PuTTY: drag below the bottom (or above the top) and the view scrolls,
/// the selection growing with it, faster the further out the pointer is.
///
/// xterm's own drag selection neither scrolls nor survives scrolling: it
/// remembers where the drag started as a point on the screen, so once the
/// text moves the start moves with it. Here the start is kept as a cell of
/// the buffer, and the selection is set from that cell to the one under the
/// pointer on every move and every scroll step.
class TerminalDragSelect extends StatefulWidget {
  const TerminalDragSelect({
    super.key,
    required this.viewKey,
    required this.scroll,
    required this.terminal,
    required this.controller,
    required this.child,
  });

  final GlobalKey<TerminalViewState> viewKey;
  final ScrollController scroll;
  final Terminal terminal;
  final TerminalController controller;
  final Widget child;

  @override
  State<TerminalDragSelect> createState() => _TerminalDragSelectState();
}

class _TerminalDragSelectState extends State<TerminalDragSelect> {
  CellOffset? _start;
  Offset? _pointer; // global
  bool _moved = false;
  Timer? _autoScroll;

  dynamic get _render => widget.viewKey.currentState?.renderTerminal;

  @override
  void dispose() {
    _autoScroll?.cancel();
    super.dispose();
  }

  void _down(PointerDownEvent e) {
    if (e.kind != PointerDeviceKind.mouse || e.buttons != kPrimaryMouseButton) return;
    final render = _render;
    if (render == null) return;
    _start = render.getCellOffset(render.globalToLocal(e.position)) as CellOffset;
    _pointer = e.position;
    _moved = false;
  }

  void _move(PointerMoveEvent e) {
    if (_start == null || e.buttons != kPrimaryMouseButton) return;
    _pointer = e.position;
    _moved = true;
    // After xterm's own handler for this move, which would otherwise win.
    scheduleMicrotask(_select);
    _updateAutoScroll();
  }

  void _up(PointerEvent e) {
    _autoScroll?.cancel();
    _autoScroll = null;
    if (_moved) _select();
    _start = null;
    _pointer = null;
  }

  /// How far outside the view the pointer is: negative above, positive
  /// below, 0 inside.
  double _overshoot() {
    final render = _render;
    final pointer = _pointer;
    if (render == null || pointer == null) return 0;
    final y = (render.globalToLocal(pointer) as Offset).dy;
    final h = (render.size as Size).height;
    if (y < 0) return y;
    if (y > h) return y - h;
    return 0;
  }

  void _updateAutoScroll() {
    if (_overshoot() == 0) {
      _autoScroll?.cancel();
      _autoScroll = null;
      return;
    }
    _autoScroll ??= Timer.periodic(const Duration(milliseconds: 50), (_) => _step());
  }

  void _step() {
    final render = _render;
    final out = _overshoot();
    if (render == null || out == 0 || !widget.scroll.hasClients) {
      _autoScroll?.cancel();
      _autoScroll = null;
      return;
    }
    final line = render.lineHeight as double;
    // One line per step at the edge, more the further out.
    final lines = 1 + (out.abs() / 24).floor();
    final p = widget.scroll.position;
    final to = (p.pixels + out.sign * lines * line).clamp(p.minScrollExtent, p.maxScrollExtent);
    if (to != p.pixels) widget.scroll.jumpTo(to);
    _select();
  }

  /// From the start cell to the cell under the pointer, the pointer held
  /// inside the view vertically (above it is the top row, below it the
  /// bottom one). The end cell is inclusive, as xterm's own selection.
  void _select() {
    final render = _render;
    final start = _start;
    final pointer = _pointer;
    if (render == null || start == null || pointer == null) return;
    final local = render.globalToLocal(pointer) as Offset;
    final h = (render.size as Size).height;
    final inside = Offset(local.dx, local.dy.clamp(0.0, h - 1));
    var end = render.getCellOffset(inside) as CellOffset;
    final after = end.y > start.y || (end.y == start.y && end.x >= start.x);
    if (after) end = CellOffset(end.x + 1, end.y);
    final buffer = widget.terminal.buffer;
    widget.controller.setSelection(buffer.createAnchorFromOffset(start), buffer.createAnchorFromOffset(end));
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: _down,
      onPointerMove: _move,
      onPointerUp: _up,
      onPointerCancel: _up,
      child: widget.child,
    );
  }
}
