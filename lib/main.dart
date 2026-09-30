import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';
import 'providers/app_state.dart';
import 'services/rdp_session.dart';
import 'screens/home_screen.dart';
import 'theme/app_theme.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();
  await windowManager.waitUntilReadyToShow(
    const WindowOptions(
      size: Size(1280, 800),
      minimumSize: Size(900, 600),
      title: 'CommandS',
      // Replaced by CustomTitleBar — the native caption only showed the OS
      // accent color (orange here) behind plain system buttons, nothing
      // like the rest of the app.
      titleBarStyle: TitleBarStyle.hidden,
    ),
    () async {
      // Hiding the title bar hides macOS's close/minimise/zoom buttons with
      // it, and the Windows-style caption buttons CustomTitleBar draws are
      // not what a Mac window is closed with. Put the real traffic lights
      // back; CustomTitleBar leaves room for them and draws no buttons of
      // its own there.
      if (Platform.isMacOS) {
        await windowManager.setTitleBarStyle(TitleBarStyle.hidden, windowButtonVisibility: true);
      }
      await windowManager.show();
      await windowManager.focus();
    },
  );
  runApp(const CommandSApp());
}

class CommandSApp extends StatelessWidget {
  const CommandSApp({super.key});

  /// One instance for the life of the app: this whole subtree rebuilds on
  /// every AppState change, and handing MaterialApp a fresh observer list each
  /// time would detach and re-attach it constantly, losing the count of how
  /// many routes are currently open.
  static final _rdpModalObserver = RdpModalObserver();

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => AppState(),
      child: Consumer<AppState>(
        builder: (context, app, _) => MaterialApp(
          title: 'CommandS',
          debugShowCheckedModeBanner: false,
          themeMode: app.themeMode,
          theme: AppTheme.light(),
          darkTheme: AppTheme.dark(),
          // Embedded RDP sessions are windows of their own, drawn above the
          // app; this tells them to step aside while a dialog is open. See
          // [RdpModalObserver].
          navigatorObservers: [_rdpModalObserver],
          home: const HomeScreen(),
        ),
      ),
    );
  }
}
