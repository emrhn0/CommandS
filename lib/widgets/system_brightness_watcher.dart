import 'package:flutter/widgets.dart';

import '../providers/app_state.dart';

/// Tells [AppState] when the computer switches between light and dark mode,
/// so "Same as the computer" can follow it. Any other theme ignores it.
class SystemBrightnessWatcher extends StatefulWidget {
  const SystemBrightnessWatcher({super.key, required this.app, required this.child});

  final AppState app;
  final Widget child;

  @override
  State<SystemBrightnessWatcher> createState() => _SystemBrightnessWatcherState();
}

class _SystemBrightnessWatcherState extends State<SystemBrightnessWatcher> with WidgetsBindingObserver {
  Brightness get _system => WidgetsBinding.instance.platformDispatcher.platformBrightness;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.app.platformBrightness != _system) widget.app.setPlatformBrightness(_system);
  }

  @override
  void didChangePlatformBrightness() => widget.app.setPlatformBrightness(_system);

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
