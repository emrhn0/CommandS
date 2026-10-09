import 'package:flutter/material.dart';

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
  final danger = theme.colorScheme.error;

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
      PopupMenuItem<String>(
        value: a.key,
        height: _itemHeight,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            Icon(
              a.icon,
              size: 16,
              color: a.destructive ? danger : theme.iconTheme.color?.withValues(alpha: 0.8),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                tr(a.label),
                style: TextStyle(
                  fontSize: 13,
                  color: a.destructive ? danger : null,
                  fontWeight: a.checked ? FontWeight.w600 : null,
                ),
              ),
            ),
            if (a.checked) const Icon(Icons.check, size: 16),
          ],
        ),
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
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(6),
      side: BorderSide(color: theme.dividerColor),
    ),
  );
}
