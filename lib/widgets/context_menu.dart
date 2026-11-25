import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/strings.dart';

/// One entry in a [showContextMenu] menu.
class MenuAction {
  const MenuAction(
    this.key,
    this.label,
    this.icon, {
    this.destructive = false,
    this.separatorBefore = false,
    this.checked = false,
    this.children = const [],
  });

  final String key;
  final String label;
  final IconData icon;

  /// Drawn in the error colour, the way desktop apps mark "Delete".
  final bool destructive;

  /// Starts a new group with a thin rule above it.
  final bool separatorBefore;

  /// Marks the current choice in a menu that picks one value.
  final bool checked;

  /// When present, this row opens a menu instead of returning its own key.
  final List<MenuAction> children;
}

/// Row height for menu items. Material's default is 48, a touch target --
/// which is what made the tree's menu look like a phone's. Desktop menus
/// (Windows Explorer, VS Code, Remote Desktop Manager) sit around 28-32.
const double _itemHeight = 30;

/// A compact, desktop-style context menu: icons, grouped with separators,
/// destructive actions in red, an optional dimmed [header] naming what the
/// menu acts on. Opens at [position] (global), or anchored under [anchor]
/// (a widget's global rect, for "..." buttons). Returns the chosen key.
Future<String?> showContextMenu(
  BuildContext context, {
  required List<MenuAction> actions,
  Offset? position,
  Rect? anchor,
  String? header,
  double minWidth = 200,
}) {
  assert(position != null || anchor != null);
  final theme = Theme.of(context);
  final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
  final rect = anchor ?? (position! & Size.zero);
  final dim = theme.textTheme.bodySmall?.color;

  final entries = <PopupMenuEntry<String>>[
    if (header != null) ...[
      PopupMenuItem<String>(
        enabled: false,
        height: 26,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Text(
          header,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: dim, letterSpacing: 0.2),
        ),
      ),
      const PopupMenuDivider(height: 7),
    ],
    for (final a in actions) ...[
      if (a.separatorBefore) const PopupMenuDivider(height: 7),
      if (a.children.isNotEmpty)
        _SubmenuEntry(action: a)
      else
        PopupMenuItem<String>(
          value: a.key,
          height: _itemHeight,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: _ActionLabel(a),
        ),
    ],
  ];

  return showMenu<String>(
    context: context,
    position: RelativeRect.fromRect(rect, Offset.zero & overlay.size),
    items: entries,
    elevation: 8,
    shadowColor: Colors.black.withValues(alpha: 0.35),
    color: theme.colorScheme.surface,
    surfaceTintColor: Colors.transparent,
    constraints: BoxConstraints(minWidth: minWidth, maxWidth: 280),
    menuPadding: const EdgeInsets.symmetric(vertical: 4),
    shape: _menuShape(theme),
  );
}

RoundedRectangleBorder _menuShape(ThemeData theme) => RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(6),
      side: BorderSide(color: theme.dividerColor),
    );

class _ActionLabel extends StatelessWidget {
  const _ActionLabel(this.action);

  final MenuAction action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final danger = action.destructive ? theme.colorScheme.error : null;
    return Row(children: [
      Icon(action.icon, size: 16, color: danger ?? theme.iconTheme.color?.withValues(alpha: 0.8)),
      const SizedBox(width: 10),
      Expanded(
        child: Text(
          tr(action.label),
          style: TextStyle(fontSize: 13, color: danger, fontWeight: action.checked ? FontWeight.w600 : null),
        ),
      ),
      if (action.children.isNotEmpty) const Icon(Icons.chevron_right, size: 16),
      if (action.checked) const Icon(Icons.check, size: 16),
    ]);
  }
}

/// A popup row that leaves the popup route open while its child panel is up.
class _SubmenuEntry extends PopupMenuEntry<String> {
  const _SubmenuEntry({required this.action});

  final MenuAction action;

  @override
  double get height => _itemHeight;

  @override
  bool represents(String? value) => false;

  @override
  State<_SubmenuEntry> createState() => _SubmenuEntryState();
}

class _SubmenuEntryState extends State<_SubmenuEntry> {
  final _menu = MenuController();
  final _trigger = FocusNode();
  final _firstItem = FocusNode();

  void _open() {
    if (_menu.isOpen) return;
    _menu.open();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _menu.isOpen) _firstItem.requestFocus();
    });
  }

  @override
  void dispose() {
    _trigger.dispose();
    _firstItem.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final action = widget.action;
    return RawMenuAnchor(
      controller: _menu,
      childFocusNode: _trigger,
      overlayBuilder: (overlayContext, info) {
        final theme = Theme.of(overlayContext);
        return CustomSingleChildLayout(
          delegate: _SubmenuPosition(info.anchorRect),
          child: TapRegion(
            groupId: info.tapRegionGroupId,
            child: Focus(
              onKeyEvent: (_, event) {
                if (event is KeyDownEvent &&
                    (event.logicalKey == LogicalKeyboardKey.escape || event.logicalKey == LogicalKeyboardKey.arrowLeft)) {
                  _menu.close();
                  _trigger.requestFocus();
                  return KeyEventResult.handled;
                }
                return KeyEventResult.ignored;
              },
              child: Material(
                key: ValueKey('context-submenu-${action.key}'),
                color: theme.colorScheme.surface,
                elevation: 8,
                shadowColor: Colors.black.withValues(alpha: 0.35),
                surfaceTintColor: Colors.transparent,
                shape: _menuShape(theme),
                clipBehavior: Clip.antiAlias,
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final (index, child) in action.children.indexed) ...[
                        if (child.separatorBefore) const Divider(height: 7, indent: 0, endIndent: 0),
                        InkWell(
                          focusNode: index == 0 ? _firstItem : null,
                          onTap: () => Navigator.of(context).pop(child.key),
                          child: _SubmenuRow(action: child),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
      builder: (context, controller, _) => Focus(
        canRequestFocus: false,
        onKeyEvent: (_, event) {
          if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.arrowRight) {
            _open();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: InkWell(
          key: ValueKey('context-submenu-trigger-${action.key}'),
          focusNode: _trigger,
          onHover: (hovered) {
            if (hovered) _open();
          },
          onTap: _open,
          child: Ink(
            color: controller.isOpen ? Theme.of(context).hoverColor : null,
            child: _SubmenuRow(action: action),
          ),
        ),
      ),
    );
  }
}

class _SubmenuRow extends StatelessWidget {
  const _SubmenuRow({required this.action});

  final MenuAction action;

  @override
  Widget build(BuildContext context) => SizedBox(
        height: _itemHeight,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: DefaultTextStyle.merge(
            style: TextStyle(color: Theme.of(context).colorScheme.onSurface),
            child: _ActionLabel(action),
          ),
        ),
      );
}

class _SubmenuPosition extends SingleChildLayoutDelegate {
  const _SubmenuPosition(this.anchor);

  final Rect anchor;
  static const double _margin = 8;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    final available = constraints.deflate(const EdgeInsets.all(_margin)).loosen();
    return available.tighten(width: available.maxWidth.clamp(0.0, 190.0));
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final rightLimit = size.width - _margin - childSize.width;
    // Flip to the left edge of the opening row when the right side is full.
    final x = anchor.right <= rightLimit ? anchor.right : anchor.left - childSize.width;
    return Offset(
      x.clamp(_margin, rightLimit),
      anchor.top.clamp(_margin, size.height - _margin - childSize.height),
    );
  }

  @override
  bool shouldRelayout(_SubmenuPosition oldDelegate) => anchor != oldDelegate.anchor;
}
