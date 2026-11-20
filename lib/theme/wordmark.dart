import 'package:flutter/material.dart';

/// The face the "CommandS" wordmark is set in, in the title bar and on the
/// welcome panel. Bundled (`assets/fonts/GeistMono`), so it looks the same on
/// every machine. The rest of the interface keeps the system font.
const String wordmarkFontFamily = 'Geist Mono';

/// The text cursor after the wordmark on the welcome panel: an accent "_"
/// that blinks like a terminal's, or stays lit when [animate] is off.
class WordmarkCursor extends StatefulWidget {
  const WordmarkCursor({super.key, required this.style, this.animate = true});

  final TextStyle style;
  final bool animate;

  @override
  State<WordmarkCursor> createState() => _WordmarkCursorState();
}

class _WordmarkCursorState extends State<WordmarkCursor> with SingleTickerProviderStateMixin {
  late final AnimationController _blink =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1060), value: 0);

  @override
  void initState() {
    super.initState();
    if (widget.animate) _blink.repeat();
  }

  @override
  void dispose() {
    _blink.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _blink,
        // On for the first half of each beat, off for the second: a hard
        // blink, as a terminal does, not a fade.
        builder: (context, child) => Opacity(opacity: _blink.value < 0.5 ? 1 : 0, child: child),
        child: Text('_', key: const Key('wordmark-cursor'), style: widget.style),
      );
}
