import 'dart:io';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';
import '../theme/app_mark.dart';
import '../theme/app_theme.dart';

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
  const CustomTitleBar({super.key});

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

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isMac = Platform.isMacOS;
    return Container(
      height: kTitleBarHeight,
      color: isDark ? AppColors.darkBg : AppColors.lightPanel,
      child: Row(
        children: [
          Expanded(
            child: DragToMoveArea(
              child: SizedBox(
                height: double.infinity,
                child: Row(
                  children: [
                    // Clear of the traffic lights on macOS.
                    SizedBox(width: isMac ? 78 : 10),
                    const AppMark(size: 16),
                    const SizedBox(width: 7),
                    Text(
                      'CommandS',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.3,
                        color: isDark ? AppColors.darkText : AppColors.lightText,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (!isMac) ...[
            _CaptionButton(
              icon: Icons.remove,
              tooltip: 'Minimize',
              onTap: () => windowManager.minimize(),
            ),
            _CaptionButton(
              icon: _isMaximized ? Icons.filter_none : Icons.crop_square,
              iconSize: _isMaximized ? 12 : 13,
              tooltip: _isMaximized ? 'Restore' : 'Maximize',
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
              tooltip: 'Close',
              hoverColor: const Color(0xFFE81123),
              hoverIconColor: Colors.white,
              onTap: () => windowManager.close(),
            ),
          ],
        ],
      ),
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
