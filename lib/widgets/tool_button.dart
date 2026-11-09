import 'package:flutter/material.dart';

/// The square icon button of the connection panel and the SFTP panel: a
/// tile beside a field, or flat inside a bar until the mouse is over it.
class ToolButton extends StatefulWidget {
  const ToolButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.size = 30,
    this.danger = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  /// 30 = a tile beside the search field; smaller ones sit inside a bar,
  /// drawn flat until the mouse is over them.
  final double size;

  /// Lights up red (delete).
  final bool danger;

  @override
  State<ToolButton> createState() => ToolButtonState();
}

class ToolButtonState extends State<ToolButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final enabled = widget.onPressed != null;
    final lit = enabled && _hover;
    final flat = widget.size < 30;
    final tint = widget.danger ? scheme.error : scheme.primary;
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onPressed,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            width: widget.size,
            height: widget.size,
            decoration: BoxDecoration(
              color: lit
                  ? tint.withValues(alpha: 0.14)
                  : flat
                      ? Colors.transparent
                      : scheme.onSurface.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(flat ? 6 : 8),
              border: Border.all(
                color: lit
                    ? tint.withValues(alpha: 0.45)
                    : flat
                        ? Colors.transparent
                        : scheme.onSurface.withValues(alpha: 0.10),
              ),
            ),
            child: AnimatedScale(
              duration: const Duration(milliseconds: 140),
              scale: lit ? 1.08 : 1,
              child: Icon(
                widget.icon,
                size: flat ? 15 : 16,
                color: lit && widget.danger
                    ? scheme.error
                    : scheme.onSurface.withValues(alpha: enabled ? (lit ? 1 : 0.8) : 0.3),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
