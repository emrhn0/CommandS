import 'dart:io';

import 'package:flutter/material.dart';

import '../app_version.dart';
import '../theme/app_mark.dart';
import '../theme/app_theme.dart';
import '../theme/wordmark.dart';

/// The mark and the name over the whole window for a moment at launch, then
/// a fade to [child]. It never takes a click: the app underneath is already
/// live, so a quick user is not held up.
class LaunchSplash extends StatefulWidget {
  const LaunchSplash({super.key, required this.child});

  final Widget child;

  /// Off under `flutter test`, where widget tests want the app itself.
  static bool enabled = !Platform.environment.containsKey('FLUTTER_TEST');

  /// The whole show: the mark rises in, the bar fills in about two
  /// seconds, then everything fades out.
  static const duration = Duration(milliseconds: 2600);

  /// "v1.6.0-beta.2" as "v1.6.0 beta 2", for the version pill.
  static String versionLabel(String version) =>
      version.replaceFirstMapped(RegExp(r'-beta\.(\d+)$'), (m) => ' beta ${m[1]}');

  @override
  State<LaunchSplash> createState() => _LaunchSplashState();
}

class _LaunchSplashState extends State<LaunchSplash> with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  bool _done = !LaunchSplash.enabled;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: LaunchSplash.duration);
    if (!_done) {
      _controller.forward().whenComplete(() {
        if (mounted) setState(() => _done = true);
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_done) return widget.child;
    return Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        IgnorePointer(
          child: AnimatedBuilder(
            animation: _controller,
            builder: (context, _) => SplashView(progress: _controller.value),
          ),
        ),
      ],
    );
  }
}

/// One frame of the launch splash at [progress] (0 to 1).
class SplashView extends StatelessWidget {
  const SplashView({super.key, required this.progress});

  final double progress;

  double _interval(double begin, double end, [Curve curve = Curves.easeOutCubic]) =>
      curve.transform(((progress - begin) / (end - begin)).clamp(0.0, 1.0));

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final accent = Theme.of(context).colorScheme.primary;
    final fadeOut = 1 - _interval(0.86, 1.0, Curves.easeInCubic);
    Widget rise(Widget child, double begin) {
      final t = _interval(begin, begin + 0.14);
      return Opacity(
        opacity: t,
        child: Transform.translate(offset: Offset(0, 10 * (1 - t)), child: child),
      );
    }

    final fill = _interval(0.08, 0.85, Curves.easeInOutCubic);
    // Under MaterialApp but above any Scaffold: without a Material of its own
    // the text would get the yellow "missing Material" underline.
    return Material(
      type: MaterialType.transparency,
      child: Opacity(
        opacity: fadeOut,
        child: DecoratedBox(
          key: const Key('launch-splash'),
          decoration: BoxDecoration(
            color: palette.bg,
            gradient: RadialGradient(
              center: const Alignment(0, -0.15),
              radius: 0.8,
              colors: [Color.alphaBlend(accent.withValues(alpha: 0.10), palette.bg), palette.bg],
            ),
          ),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                rise(const AppMark(size: 132), 0.0),
                const SizedBox(height: 26),
                rise(
                  Text.rich(
                    TextSpan(children: [
                      const TextSpan(text: 'Command'),
                      TextSpan(text: 'S', style: TextStyle(color: accent)),
                    ]),
                    style: TextStyle(
                      fontFamily: wordmarkFontFamily,
                      fontSize: 44,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -2,
                      color: palette.text,
                    ),
                  ),
                  0.04,
                ),
                const SizedBox(height: 14),
                rise(
                  Container(
                    key: const Key('launch-splash-version'),
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                    decoration: BoxDecoration(
                      color: Color.alphaBlend(accent.withValues(alpha: 0.10), palette.bg),
                      border: Border.all(color: accent.withValues(alpha: 0.35)),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      LaunchSplash.versionLabel(appVersion),
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: accent),
                    ),
                  ),
                  0.08,
                ),
                const SizedBox(height: 24),
                rise(
                  ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: SizedBox(
                      key: const Key('launch-splash-bar'),
                      width: 180,
                      height: 3,
                      child: LinearProgressIndicator(
                        value: fill,
                        backgroundColor: palette.border,
                        valueColor: AlwaysStoppedAnimation(accent),
                      ),
                    ),
                  ),
                  0.1,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
