import 'dart:async';
import 'dart:io';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show LicenseEntryWithLineBreaks, LicenseRegistry;
import 'package:flutter/services.dart' show rootBundle;
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

import 'providers/app_state.dart';
import 'app_version.dart';
import 'screens/home_screen.dart';
import 'services/app_activity.dart';
import 'services/system_power.dart';
import 'services/rdp_session.dart';
import 'services/mcp_server.dart';
import 'services/terminal_appearance.dart';
import 'widgets/launch_splash.dart';
import 'widgets/mcp_approval_dialog.dart';
import 'theme/app_theme.dart';
import 'widgets/sftp_window.dart';
import 'widgets/system_brightness_watcher.dart';
import 'widgets/update_dialog.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Decorative motion runs only while the window is in front.
  AppActivity.listen();
  // The bundled terminal fonts' licences, read only if the list is shown.
  LicenseRegistry.addLicense(() async* {
    for (final entry in bundledFontLicences.entries) {
      yield LicenseEntryWithLineBreaks([entry.key], await rootBundle.loadString(entry.value));
    }
  });
  // A second window (the SFTP file manager) runs this same entry point in its
  // own engine, with its launch arguments telling it what to be.
  final sftp = await _sftpWindowArguments();
  if (sftp != null) {
    await runSftpWindow(sftp);
    return;
  }
  // No frame until the saved theme and connections are read. The window is
  // shown on its first frame (windows/runner/flutter_window.cpp), and a
  // first frame drawn before them came out in the default light theme with
  // an empty list, then repainted: a white flash at every start. A load that
  // fails or hangs does not keep the app from opening.
  WidgetsBinding.instance.deferFirstFrame();
  await windowManager.ensureInitialized();
  final app = AppState();
  try {
    await app.ready.timeout(const Duration(seconds: 5));
  } catch (error) {
    debugPrint('Starting before the saved state was read: $error');
  }
  await windowManager.waitUntilReadyToShow(
    const WindowOptions(
      size: Size(1280, 800),
      minimumSize: Size(900, 600),
      title: appName,
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
        await windowManager.setTitleBarStyle(
          TitleBarStyle.hidden,
          windowButtonVisibility: true,
        );
        await windowManager.show();
      }
      await windowManager.focus();
    },
  );
  // Power saver can follow the computer's own energy saver.
  SystemPower.watch(app.setSystemPower);
  runApp(CommandSApp(app: app));
  WidgetsBinding.instance.allowFirstFrame();
}

Future<SftpWindowArguments?> _sftpWindowArguments() async {
  try {
    final controller = await WindowController.fromCurrentEngine();
    return SftpWindowArguments.decode(controller.arguments);
  } catch (_) {
    return null;
  }
}

class CommandSApp extends StatelessWidget {
  const CommandSApp({super.key, required this.app});

  /// Created and loaded in [main] before the window is shown.
  final AppState app;

  /// One instance for the life of the app: this whole subtree rebuilds on
  /// every AppState change, and handing MaterialApp a fresh observer list each
  /// time would detach and re-attach it constantly, losing the count of how
  /// many routes are currently open.
  static final _rdpModalObserver = RdpModalObserver();

  /// For the MCP approval dialog, which is asked for from outside any widget.
  static final _navigatorKey = GlobalKey<NavigatorState>();

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider.value(
      value: app,
      child: ChangeNotifierProvider<McpServer>(
        lazy: false,
        create: (context) {
          final gateway = AppMcpGateway(
            context.read<AppState>(),
            approve: (approval) => askMcpApproval(_navigatorKey, approval),
            approveCatalog: (approval) => askMcpCatalogApproval(_navigatorKey, approval),
          );
          final server = McpServer(gateway);
          unawaited(gateway.load().then((_) => server.restore()));
          return server;
        },
        child: SystemBrightnessWatcher(
          app: app,
          child: Consumer<AppState>(
            builder: (context, app, _) => MaterialApp(
              title: appName,
              navigatorKey: _navigatorKey,
              debugShowCheckedModeBanner: false,
              // A catalogue theme is one look, light or dark; otherwise the
              // classic pair, switched by themeMode.
              themeMode: app.themeMode,
              theme: app.activeTheme != null && !app.activeTheme!.dark
                  ? AppTheme.fromPreset(app.activeTheme!)
                  : AppTheme.light(),
              darkTheme: app.activeTheme != null && app.activeTheme!.dark
                  ? AppTheme.fromPreset(app.activeTheme!)
                  : AppTheme.dark(),
              // Embedded RDP sessions are windows of their own, drawn above the
              // app; this tells them to step aside while a dialog is open. See
              // [RdpModalObserver].
              navigatorObservers: [_rdpModalObserver],
              // Asks, once a launch, whether to install a newer release.
              home: const LaunchSplash(child: UpdateGate(child: HomeScreen())),
            ),
          ),
        ),
      ),
    );
  }
}
