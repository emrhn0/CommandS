import 'dart:async';

import 'package:flutter/material.dart';

import '../services/app_activity.dart';

/// The text cursor after the wordmark on the welcome panel: an accent "_"
/// that blinks like a terminal's, or stays lit when [animate] is off.
///
/// A hard on/off blink needs a frame only when it flips, so it runs on a
/// timer (two frames a second) instead of an animation drawing sixty. It
/// stops, lit, while the window is not in front (`AppActivity`) or the
/// system asks for no animations.
class WordmarkCursor extends StatefulWidget {
  const WordmarkCursor({super.key, required this.style, this.animate = true});

  final TextStyle style;
  final bool animate;

  /// Half a beat: as long on as off, the way a terminal blinks.
  static const halfBeat = Duration(milliseconds: 530);

  @override
  State<WordmarkCursor> createState() => _WordmarkCursorState();
}

class _WordmarkCursorState extends State<WordmarkCursor> {
  Timer? _timer;
  bool _lit = true;
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
      _timer ??= Timer.periodic(WordmarkCursor.halfBeat, (_) => setState(() => _lit = !_lit));
    } else {
      _timer?.cancel();
      _timer = null;
      if (!_lit && mounted) setState(() => _lit = true);
    }
  }

  @override
  void dispose() {
    AppActivity.foreground.removeListener(_sync);
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
        child: Opacity(
          opacity: _lit ? 1 : 0,
          child: Text('_', key: const Key('wordmark-cursor'), style: widget.style),
        ),
      );
}
