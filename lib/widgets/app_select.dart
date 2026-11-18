import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_theme.dart';

/// One row of an [AppSelect].
class AppSelectItem<T> {
  const AppSelectItem(
    this.value,
    this.label, {
    this.leading,
    this.style,
    this.dividerBefore = false,
    this.action = false,
  });

  final T value;
  final String label;

  /// An icon or logo before the label, also shown in the field when chosen.
  final Widget? leading;
  final TextStyle? style;

  /// A thin line above this row, to set a group apart.
  final bool dividerBefore;

  /// Does something rather than being a choice ("New profile…"): drawn in
  /// the accent colour, and never shown as the current value.
  final bool action;
}

/// The app's select field: looks like its text fields, and opens a compact
/// desktop menu just below, as wide as the field, with the current choice
/// ticked. Arrows, Enter and Esc work as in any desktop menu. Used in place
/// of Material's dropdown, whose tall sheet covered the field like a phone's.
class AppSelect<T> extends StatefulWidget {
  const AppSelect({
    super.key,
    required this.items,
    required this.value,
    required this.onChanged,
    this.label,
    this.maxMenuHeight = 360,
  });

  final List<AppSelectItem<T>> items;
  final T value;
  final ValueChanged<T> onChanged;

  /// Drawn inside the field's border, as a text field's label.
  final String? label;
  final double maxMenuHeight;

  @override
  State<AppSelect<T>> createState() => _AppSelectState<T>();
}

class _AppSelectState<T> extends State<AppSelect<T>> {
  final _controller = MenuController();
  final _fieldFocus = FocusNode(debugLabel: 'AppSelect');
  bool _open = false;
  bool _hover = false;

  @override
  void dispose() {
    _fieldFocus.dispose();
    super.dispose();
  }

  /// Opens or closes the menu, keeping the keyboard on the field so the
  /// arrows go into the menu and Esc closes it.
  void _toggle() {
    _fieldFocus.requestFocus();
    _controller.isOpen ? _controller.close() : _controller.open();
  }

  AppSelectItem<T>? get _current {
    for (final item in widget.items) {
      if (!item.action && item.value == widget.value) return item;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = AppPalette.of(context);
    final accent = theme.colorScheme.primary;
    final current = _current;
    return LayoutBuilder(
      builder: (context, constraints) => MenuAnchor(
        controller: _controller,
        childFocusNode: _fieldFocus,
        alignmentOffset: const Offset(0, 4),
        onOpen: () => setState(() => _open = true),
        onClose: () => setState(() => _open = false),
        style: MenuStyle(
          backgroundColor: WidgetStatePropertyAll(palette.panel),
          surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
          shadowColor: WidgetStatePropertyAll(Colors.black.withValues(alpha: 0.45)),
          elevation: const WidgetStatePropertyAll(10),
          padding: const WidgetStatePropertyAll(EdgeInsets.all(4)),
          minimumSize: WidgetStatePropertyAll(Size(constraints.maxWidth, 0)),
          maximumSize: WidgetStatePropertyAll(Size(constraints.maxWidth, widget.maxMenuHeight)),
          shape: WidgetStatePropertyAll(RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: BorderSide(color: palette.border),
          )),
        ),
        menuChildren: [
          for (final item in widget.items) ...[
            if (item.dividerBefore)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 6),
                child: Divider(height: 1, color: palette.border),
              ),
            _row(item, item.value == widget.value && !item.action, accent, palette, constraints.maxWidth),
          ],
        ],
        builder: (context, controller, _) => MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          child: Focus(
            focusNode: _fieldFocus,
            onKeyEvent: (node, event) {
              if (event is! KeyDownEvent) return KeyEventResult.ignored;
              final key = event.logicalKey;
              if (key == LogicalKeyboardKey.escape && controller.isOpen) {
                controller.close();
                return KeyEventResult.handled;
              }
              if (!controller.isOpen &&
                  (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.space || key == LogicalKeyboardKey.arrowDown)) {
                controller.open();
                return KeyEventResult.handled;
              }
              return KeyEventResult.ignored;
            },
            child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _toggle,
            child: InputDecorator(
              isFocused: _open,
              isHovering: _hover,
              decoration: InputDecoration(
                labelText: widget.label,
                isDense: true,
                suffixIcon: AnimatedRotation(
                  turns: _open ? 0.5 : 0,
                  duration: const Duration(milliseconds: 150),
                  child: Icon(Icons.expand_more, size: 18, color: _open ? accent : palette.textDim),
                ),
                suffixIconConstraints: const BoxConstraints(minWidth: 32, minHeight: 20),
              ),
              child: Row(
                children: [
                  if (current?.leading != null) ...[
                    SizedBox(width: 20, child: Center(child: current!.leading)),
                    const SizedBox(width: 8),
                  ],
                  Expanded(
                    child: Text(
                      current?.label ?? '',
                      overflow: TextOverflow.ellipsis,
                      style: (current?.style ?? const TextStyle(fontSize: 13)).copyWith(color: palette.text),
                    ),
                  ),
                ],
              ),
            ),
          ),
          ),
        ),
      ),
    );
  }

  Widget _row(AppSelectItem<T> item, bool selected, Color accent, AppPalette palette, double width) {
    final color = item.action ? accent : palette.text;
    return MenuItemButton(
      onPressed: () => widget.onChanged(item.value),
      style: ButtonStyle(
        // Desktop rows: no touch-sized padding around them.
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.standard,
        minimumSize: WidgetStatePropertyAll(Size(width - 8, 34)),
        maximumSize: WidgetStatePropertyAll(Size(width - 8, 34)),
        padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 10)),
        shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.circular(6))),
        backgroundColor: WidgetStatePropertyAll(selected ? accent.withValues(alpha: 0.12) : Colors.transparent),
        overlayColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.hovered) || states.contains(WidgetState.focused)
              ? accent.withValues(alpha: 0.10)
              : null,
        ),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 20,
            child: Center(
              child: item.leading == null
                  ? null
                  : IconTheme.merge(data: IconThemeData(color: item.action ? accent : palette.textDim), child: item.leading!),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              item.label,
              overflow: TextOverflow.ellipsis,
              style: (item.style ?? const TextStyle(fontSize: 13)).copyWith(
                color: color,
                fontWeight: selected || item.action ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ),
          SizedBox(
            width: 20,
            child: selected ? Icon(Icons.check_rounded, size: 16, color: accent) : null,
          ),
        ],
      ),
    );
  }
}
