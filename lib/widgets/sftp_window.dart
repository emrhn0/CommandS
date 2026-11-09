import 'dart:convert';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../l10n/strings.dart';
import '../theme/app_theme.dart';
import '../services/pty_session.dart';
import '../services/sftp_client.dart';
import 'sftp_browser.dart';
import 'custom_title_bar.dart';
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
    this.sessionId = '',
    this.language = 'en',
  });

  static const type = 'sftp';

  /// Which session's panel to bring back when the window is shrunk.
  final String sessionId;

  /// The main window's language, so both speak the same one.
  final String language;

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
    'sessionId': sessionId,
    'language': language,
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
        sessionId: json['sessionId'] as String? ?? '',
        language: json['language'] as String? ?? 'en',
      );
    } catch (_) {
      return null;
    }
  }
}

/// The main window learns through this that a window was shrunk.
const _channel = WindowMethodChannel('commands/sftp-window', mode: ChannelMode.unidirectional);

/// Sessions with their files in a window of their own, by the id the window
/// was given. Only this, the main window's engine, uses it.
final _windowSessions = <String, PtySessionController>{};
bool _listening = false;

Future<void> _listen() async {
  if (_listening) return;
  _listening = true;
  await _channel.setMethodCallHandler((call) async {
    if (call.method == 'shrink') {
      final session = _windowSessions.remove(call.arguments as String? ?? '');
      try {
        session?.sftpOpen.value = true;
      } catch (_) {
        // The tab was closed meanwhile.
      }
    }
    return null;
  });
}

/// Opens [session]'s files in a new window, in place of its panel: one view
/// of the files at a time. Shrinking the window brings the panel back.
Future<void> openSftpWindow(PtySessionController session, {required bool dark}) async {
  final info = await session.sftpConnection();
  await _listen();
  final id = '${identityHashCode(session)}';
  _windowSessions[id] = session;
  session.sftpOpen.value = false;
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
        sessionId: id,
        language: currentLanguage.name,
      ).encode(),
    ),
  );
  await controller.show();
}

/// Runs in the new window's own engine.
Future<void> runSftpWindow(SftpWindowArguments args) async {
  currentLanguage = AppLanguage.fromCode(args.language);
  try {
    await windowManager.ensureInitialized();
    // CommandS's own title bar, as in the main window, not the system's.
    await windowManager.setTitleBarStyle(
      TitleBarStyle.hidden,
      windowButtonVisibility: defaultTargetPlatform == TargetPlatform.macOS,
    );
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

  /// Back to the panel beside the terminal: tells the main window, then goes.
  Future<void> _shrink() async {
    try {
      await _channel.invokeMethod('shrink', args.sessionId);
    } catch (_) {}
    await windowManager.close();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: args.dark ? AppTheme.dark() : AppTheme.light(),
      home: Scaffold(
        body: Column(
          children: [
            CustomTitleBar(
              title: ['SFTP', args.title].join(' · '),
              actions: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Center(
                    child: ToolButton(
                      key: const ValueKey('sftp-shrink'),
                      icon: Icons.close_fullscreen_rounded,
                      tooltip: tr('Shrink'),
                      onPressed: onShrink ?? _shrink,
                      size: 26,
                    ),
                  ),
                ),
              ],
            ),
            const Divider(height: 1),
            Expanded(child: SftpBrowser(createClient: createClient, localBrowser: localBrowser, wide: true)),
          ],
        ),
      ),
    );
  }
}
