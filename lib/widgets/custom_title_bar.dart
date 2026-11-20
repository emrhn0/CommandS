import 'dart:io';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../theme/app_mark.dart';
import '../theme/app_theme.dart';
import '../app_version.dart';
import '../l10n/strings.dart';

const double kTitleBarHeight = 32;

/// Replaces the native Windows caption (which just shows the OS accent
/// color — orange, in this case — behind plain system buttons) with one
/// that matches CommandS's own theme. Spans the full window width, above
/// the sidebar/terminal split.
///
/// On macOS the same bar keeps the system traffic lights (restored in
/// `main`) instead of drawing its own buttons: it indents the title past
/// them and leaves the right side empty. Minimise/maximise/close belong to
/// the OS there, and a Windows-shaped close button on the wrong side of a
/// Mac window is worse than no button.
class CustomTitleBar extends StatefulWidget {
  const CustomTitleBar({super.key, this.title, this.leading, this.center, this.actions = const []});

  /// What the bar says in its middle; the app's name by default.
  final String? title;

  /// Something for the middle of the bar instead of the name, such as the
  /// search box. The name then moves to the start of the bar.
  final Widget? center;

  /// An optional button at the start of the bar, outside the drag area.
  final Widget? leading;

  /// Buttons of the window's own, before the minimise button.
  final List<Widget> actions;

  @override
  State<CustomTitleBar> createState() => _CustomTitleBarState();
}

class _CustomTitleBarState extends State<CustomTitleBar> with WindowListener {
  bool _isMaximized = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    windowManager.isMaximized().then((v) {
      if (mounted) setState(() => _isMaximized = v);
    });
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowMaximize() => setState(() => _isMaximized = true);

  @override
  void onWindowUnmaximize() => setState(() => _isMaximized = false);

  /// The mark and the name, with a "Beta" tag on a beta build.
  Widget _name(BuildContext context) {
    final palette = AppPalette.of(context);
    final accent = Theme.of(context).colorScheme.primary;
    final custom = widget.title;
    return Row(
      key: const ValueKey('title-bar-name'),
      mainAxisSize: MainAxisSize.min,
      children: [
        const AppMark(size: 16),
        const SizedBox(width: 7),
        Text(
          custom ?? appBaseName,
          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, letterSpacing: 0.3, color: palette.text),
        ),
        if (custom == null && buildChannel == ReleaseChannel.beta) ...[
          const SizedBox(width: 6),
          Container(
            key: const ValueKey('title-bar-beta'),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(5),
            ),
            child: Text(
              'Beta',
              style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w600, color: accent),
            ),
          ),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final isMac = Platform.isMacOS;
    final center = widget.center;
    // The middle piece sits in the middle of the window whatever its size,
    // over the drag area rather than in it, so the caption buttons do not
    // push it off centre. The name alone lets the pointer through, so the
    // whole bar still drags; a search box takes its clicks.
    final middle = center != null
        ? Center(child: center)
        : IgnorePointer(child: Center(child: _name(context)));
    return Container(
      height: kTitleBarHeight,
      color: AppPalette.of(context).bg,
      child: Stack(
        children: [
          _buttons(isMac),
          Positioned.fill(child: middle),
        ],
      ),
    );
  }

  Widget _buttons(bool isMac) {
    return Row(
        children: [
          if (isMac && (widget.leading != null || widget.center != null)) const SizedBox(width: 78),
          if (widget.leading != null) widget.leading!,
          // With something else in the middle, the name starts the bar.
          if (widget.center != null)
            IgnorePointer(
              child: Padding(
                padding: EdgeInsets.only(left: widget.leading != null ? 4 : 10),
                child: _name(context),
              ),
            ),
          const Expanded(
            child: DragToMoveArea(child: SizedBox(height: double.infinity)),
          ),
          ...widget.actions,
          if (!isMac) ...[
            _CaptionButton(
              icon: Icons.remove,
              tooltip: tr('Minimize'),
              onTap: () => windowManager.minimize(),
            ),
            _CaptionButton(
              icon: _isMaximized ? Icons.filter_none : Icons.crop_square,
              iconSize: _isMaximized ? 12 : 13,
              tooltip: _isMaximized ? tr('Restore') : tr('Maximize'),
              onTap: () async {
                if (await windowManager.isMaximized()) {
                  windowManager.unmaximize();
                } else {
                  windowManager.maximize();
                }
              },
            ),
            _CaptionButton(
              icon: Icons.close,
              tooltip: tr('Close'),
              hoverColor: const Color(0xFFE81123),
              hoverIconColor: Colors.white,
              onTap: () => windowManager.close(),
            ),
          ],
        ],
    );
  }
}

class _CaptionButton extends StatefulWidget {
  const _CaptionButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.iconSize = 15,
    this.hoverColor,
    this.hoverIconColor,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final double iconSize;
  final Color? hoverColor;
  final Color? hoverIconColor;

  @override
  State<_CaptionButton> createState() => _CaptionButtonState();
}

class _CaptionButtonState extends State<_CaptionButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final dim = Theme.of(context).textTheme.bodySmall?.color;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Tooltip(
          message: widget.tooltip,
          waitDuration: const Duration(milliseconds: 600),
          child: Container(
            width: 44,
            height: kTitleBarHeight,
            color: _hover ? (widget.hoverColor ?? AppColors.darkPanelAlt) : Colors.transparent,
            alignment: Alignment.center,
            child: Icon(
              widget.icon,
              size: widget.iconSize,
              color: _hover ? (widget.hoverIconColor ?? Theme.of(context).colorScheme.primary) : dim,
            ),
          ),
        ),
      ),
    );
  }
}
