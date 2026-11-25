import 'package:flutter/widgets.dart';

/// Whether the window is in front and in use, for the decorative motion
/// (the welcome screen's blinking cursor and pulsing dot): it runs only
/// then, so a window behind others or minimized draws nothing on its own.
///
/// Only those decorations follow it. Menus, hovers and dialogs keep their
/// own animations, which run only while something happens anyway.
class AppActivity {
  AppActivity._();

  /// True while the app is resumed (shown and focused). Starts true, so a
  /// test or a platform that never reports a state still animates.
  static final ValueNotifier<bool> foreground = ValueNotifier(true);

  static AppLifecycleListener? _listener;

  /// Follows the app's lifecycle from now on. Called once at start.
  static void listen() {
    _listener ??= AppLifecycleListener(
      onStateChange: (state) => foreground.value = state == AppLifecycleState.resumed,
    );
  }
}
