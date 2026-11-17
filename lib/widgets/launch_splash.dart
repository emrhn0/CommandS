import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../app_version.dart';
import '../l10n/strings.dart';
import '../theme/app_mark.dart';
import '../theme/app_theme.dart';

/// The mark and the name over the whole window for a moment at launch, then
/// a fade to [child]. It never takes a click: the app underneath is already
/// live, so a quick user is not held up.
class LaunchSplash extends StatefulWidget {
  const LaunchSplash({super.key, required this.child});

  final Widget child;

  /// Off under `flutter test`, where widget tests want the app itself.
  static bool enabled = !Platform.environment.containsKey('FLUTTER_TEST');

  /// The whole show: the mark rises in, holds, and fades out.
  static const duration = Duration(milliseconds: 1600);

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
    final fadeOut = 1 - _interval(0.72, 1.0, Curves.easeInCubic);
    Widget rise(Widget child, double begin) {
      final t = _interval(begin, begin + 0.3);
      return Opacity(
        opacity: t,
        child: Transform.translate(offset: Offset(0, 10 * (1 - t)), child: child),
      );
    }

    return Opacity(
      opacity: fadeOut,
      child: DecoratedBox(
        key: const Key('launch-splash'),
        decoration: BoxDecoration(
          color: palette.bg,
          gradient: RadialGradient(
            center: const Alignment(0, -0.1),
            radius: 0.8,
            colors: [Color.alphaBlend(accent.withValues(alpha: 0.10), palette.bg), palette.bg],
          ),
        ),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              rise(SvgPicture.asset(AppMark.darkAsset, width: 112, height: 112), 0.0),
              const SizedBox(height: 22),
              rise(
                Text.rich(
                  TextSpan(children: [
                    const TextSpan(text: 'Command'),
                    TextSpan(text: 'S', style: TextStyle(color: accent)),
                  ]),
                  style: TextStyle(fontSize: 40, fontWeight: FontWeight.w600, letterSpacing: -0.8, color: palette.text),
                ),
                0.08,
              ),
              const SizedBox(height: 10),
              rise(
                Text(
                  '${tr('SSH, RDP and serial')}  ·  $appVersion',
                  style: TextStyle(fontSize: 13, color: palette.textDim),
                ),
                0.16,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
