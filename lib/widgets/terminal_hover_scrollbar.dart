import 'package:flutter/material.dart';

/// A thin terminal scroll thumb that appears only near the pane's right edge.
class TerminalHoverScrollbar extends StatefulWidget {
  const TerminalHoverScrollbar({
    super.key,
    required this.controller,
    required this.color,
    required this.child,
  });

  final ScrollController controller;
  final Color color;
  final Widget child;

  @override
  State<TerminalHoverScrollbar> createState() => _TerminalHoverScrollbarState();
}

class _TerminalHoverScrollbarState extends State<TerminalHoverScrollbar> {
  static const double _edgeWidth = 24;
  bool _nearEdge = false;

  void _setNearEdge(bool value) {
    if (_nearEdge == value) return;
    setState(() => _nearEdge = value);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        void checkEdge(PointerEvent event) {
          _setNearEdge(
            event.localPosition.dx >= constraints.maxWidth - _edgeWidth,
          );
        }

        return MouseRegion(
          onEnter: checkEdge,
          onHover: checkEdge,
          onExit: (_) => _setNearEdge(false),
          child: RawScrollbar(
            controller: widget.controller,
            thumbVisibility: true,
            interactive: _nearEdge,
            thumbColor: _nearEdge
                ? widget.color.withValues(alpha: 0.58)
                : Colors.transparent,
            thickness: 4,
            radius: const Radius.circular(2),
            minThumbLength: 24,
            mainAxisMargin: 4,
            crossAxisMargin: 3,
            child: widget.child,
          ),
        );
      },
    );
  }
}
