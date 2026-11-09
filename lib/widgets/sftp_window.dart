import 'dart:convert';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../l10n/strings.dart';
import '../services/pty_session.dart';
import '../services/sftp_client.dart';
import '../theme/app_theme.dart';
import 'sftp_browser.dart';
import 'tool_button.dart';

/// The SFTP file manager in a window of its own: this computer's files beside
/// the device's, over a window that can be moved and resized freely. It is a
/// second window of the same CommandS, under the same taskbar button.
///
/// Each window has its own Flutter engine, so what the new window needs to
/// connect is handed to it as its launch arguments, in memory, within this
/// process. Nothing is written to disk.
class SftpWindowArguments {
  const SftpWindowArguments({
    required this.title,
    required this.host,
    required this.port,
    required this.username,
    required this.password,
    required this.sshOptions,
    required this.dark,
  });

  static const type = 'sftp';

  final String title;
  final String host;
  final int port;
  final String username;
  final String password;
  final List<String> sshOptions;
  final bool dark;

  String encode() => jsonEncode({
    'type': type,
    'title': title,
    'host': host,
    'port': port,
    'username': username,
    'password': password,
    'sshOptions': sshOptions,
    'dark': dark,
  });

  /// Null for anything that is not an SFTP window's arguments, the main
  /// window's empty ones included.
  static SftpWindowArguments? decode(String raw) {
    if (raw.isEmpty) return null;
    try {
      final json = jsonDecode(raw);
      if (json is! Map || json['type'] != type) return null;
      return SftpWindowArguments(
        title: json['title'] as String? ?? 'SFTP',
        host: json['host'] as String,
        port: (json['port'] as num).toInt(),
        username: json['username'] as String,
        password: json['password'] as String? ?? '',
        sshOptions: [for (final o in json['sshOptions'] as List? ?? const []) '$o'],
        dark: json['dark'] as bool? ?? false,
      );
    } catch (_) {
      return null;
    }
  }
}

/// Opens [session]'s files in a new window.
Future<void> openSftpWindow(PtySessionController session, {required bool dark}) async {
  final info = await session.sftpConnection();
  final controller = await WindowController.create(
    WindowConfiguration(
      hiddenAtLaunch: true,
      arguments: SftpWindowArguments(
        title: session.tabTitle ?? session.host,
        host: info.host,
        port: info.port,
        username: info.username,
        password: info.password,
        sshOptions: info.sshOptions,
        dark: dark,
      ).encode(),
    ),
  );
  await controller.show();
}

/// Runs in the new window's own engine.
Future<void> runSftpWindow(SftpWindowArguments args) async {
  try {
    await windowManager.ensureInitialized();
    await windowManager.setTitle('SFTP · ${args.title}');
    await windowManager.setSize(const Size(1180, 720));
    await windowManager.setMinimumSize(const Size(720, 420));
    await windowManager.center();
  } catch (_) {
    // A window with the default size and title still works.
  }
  runApp(
    SftpWindowApp(
      args: args,
      createClient: (password) async => OpenSshSftpClient(
        host: args.host,
        port: args.port,
        username: args.username,
        password: password ?? args.password,
        sshOptions: args.sshOptions,
      ),
    ),
  );
}

class SftpWindowApp extends StatelessWidget {
  const SftpWindowApp({super.key, required this.args, required this.createClient, this.localBrowser, this.onShrink});

  final SftpWindowArguments args;
  final SftpClientFactory createClient;
  final LocalFileBrowser? localBrowser;

  /// Closes this window; the session's panel in the main window stays.
  final VoidCallback? onShrink;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: args.dark ? AppTheme.dark() : AppTheme.light(),
      home: Builder(
        builder: (context) {
          final isDark = Theme.of(context).brightness == Brightness.dark;
          final dim = isDark ? AppColors.darkTextDim : AppColors.lightTextDim;
          return Scaffold(
            body: Column(
              children: [
                Container(
                  height: 40,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    border: Border(bottom: BorderSide(color: Theme.of(context).dividerColor)),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.folder_rounded, size: 16, color: dim),
                      const SizedBox(width: 8),
                      Text('SFTP · ${args.title}', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                      const Spacer(),
                      ToolButton(
                        key: const ValueKey('sftp-shrink'),
                        icon: Icons.close_fullscreen_rounded,
                        tooltip: tr('Shrink'),
                        onPressed: onShrink ?? () => windowManager.close(),
                        size: 28,
                      ),
                    ],
                  ),
                ),
                Expanded(child: SftpBrowser(createClient: createClient, localBrowser: localBrowser, wide: true)),
              ],
            ),
          );
        },
      ),
    );
  }
}
