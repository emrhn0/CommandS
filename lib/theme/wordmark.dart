import 'package:flutter/material.dart';

import '../services/app_activity.dart';

/// The text cursor after the wordmark on the welcome panel: an accent "_"
/// that blinks like a terminal's, or stays lit when [animate] is off.
///
/// It blinks only while the window is in front (`AppActivity`); behind
/// another window, minimized, or when the system asks for no animations it
/// rests lit, and nothing is drawn for it.
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
  bool _systemStill = false;

  @override
  void initState() {
    super.initState();
    AppActivity.foreground.addListener(_sync);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _systemStill = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    _sync();
  }

  @override
  void didUpdateWidget(WordmarkCursor oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  void _sync() {
    final run = widget.animate && !_systemStill && AppActivity.foreground.value;
    if (run) {
      if (!_blink.isAnimating) _blink.repeat();
    } else if (_blink.isAnimating || _blink.value != 0) {
      _blink
        ..stop()
        ..value = 0;
    }
  }

  @override
  void dispose() {
    AppActivity.foreground.removeListener(_sync);
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
