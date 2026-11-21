import 'package:commands/models/models.dart';
import 'package:commands/providers/app_state.dart';
import 'package:commands/screens/home_screen.dart';
import 'package:commands/screens/settings_screen.dart';
import 'package:commands/services/app_commands.dart';
import 'package:commands/services/pane_layout.dart';
import 'package:commands/services/pty_session.dart';
import 'package:commands/services/session_controller.dart';
import 'package:commands/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _RecordingSession extends PtySessionController {
  _RecordingSession(String host) : super(host: host, port: 22, startImmediately: false);

  String? typed;

  @override
  void sendInput(String data) => typed = data;
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('window_manager'),
          (call) async => call.method == 'isMaximized' ? false : null,
        );
  });

  testWidgets('hotkeys persist, can be removed, and reject conflicts', (
    tester,
  ) async {
    final app = AppState();
    await app.ready;
    expect(
      app.hotkeyFor(AppCommandId.palette),
      const Hotkey(LogicalKeyboardKey.keyP, control: true, shift: true),
    );
    const custom = Hotkey(LogicalKeyboardKey.keyH, control: true, alt: true);
    expect(
      await app.setCommandHotkey(AppCommandId.copyAddress, custom),
      isTrue,
    );
    expect(await app.setCommandHotkey(AppCommandId.copyName, custom), isFalse);
    expect(
      await app.setCommandHotkey(
        AppCommandId.copyName,
        const Hotkey(LogicalKeyboardKey.keyK, control: true),
      ),
      isFalse,
    );
    final reloaded = AppState();
    await reloaded.ready;
    expect(reloaded.hotkeyFor(AppCommandId.copyAddress), custom);
    await reloaded.setCommandHotkey(AppCommandId.palette, null);
    final removed = AppState();
    await removed.ready;
    expect(removed.hotkeyFor(AppCommandId.palette), isNull);
    await removed.resetCommandHotkey(AppCommandId.palette);
    expect(removed.hotkeyFor(AppCommandId.palette), isNotNull);
    app.dispose();
    reloaded.dispose();
    removed.dispose();
  });

  testWidgets(
    'host actions use the focused saved connection and its credential profile',
    (tester) async {
      final app = AppState();
      await app.ready;
      final first = SavedConnection(name: 'DEVICE-01', host: '192.0.2.10');
      final second = SavedConnection(
        name: 'DEVICE-02',
        host: '192.0.2.11',
        credentialProfileId: 'profile',
      );
      app.connections.addAll([first, second]);
      app.credentialProfiles.add(
        CredentialProfile(
          id: 'profile',
          name: 'Shared',
          password: 'test-secret',
        ),
      );
      final firstSession = PtySessionController(
        host: first.host,
        port: 22,
        startImmediately: false,
      );
      final secondSession = PtySessionController(
        host: second.host,
        port: 22,
        startImmediately: false,
      );
      app.tabs.addAll([
        OpenTab(id: 'first', controller: firstSession, connectionId: first.id),
        OpenTab(
          id: 'second',
          controller: secondSession,
          connectionId: second.id,
        ),
      ]);
      app.activeTabIndex = 0;
      app.paneLayout = PaneSplit(
        first: const PaneLeaf('first'),
        second: const PaneLeaf('second'),
        axis: Axis.horizontal,
      );
      app.focusCommandTab('second');
      expect(app.commandConnection?.name, 'DEVICE-02');
      expect(app.commandPassword, 'test-secret');
      expect(app.canRunCommand(AppCommandId.copyPassword), isTrue);
      expect(app.canRunCommand(AppCommandId.typePassword), isFalse);
      secondSession.debugSetStatus(SessionStatus.running);
      expect(app.canRunCommand(AppCommandId.typePassword), isTrue);
      app.focusCommandTab('first');
      expect(app.canRunCommand(AppCommandId.copyPassword), isFalse);
      firstSession.dispose();
      secondSession.dispose();
      app.dispose();
    },
  );

  testWidgets('Ctrl+Shift+P searches and runs commands', (tester) async {
    tester.view.physicalSize = const Size(1000, 650);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final app = AppState();
    await app.ready;
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: MaterialApp(theme: AppTheme.light(), home: const HomeScreen()),
      ),
    );
    await tester.pumpAndSettle();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyP);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('command-palette-dialog')), findsOneWidget);
    expect(find.text('Ctrl + Shift + P'), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('command-palette-search')),
      'settings',
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('command-settings')), findsOneWidget);
    expect(find.byKey(const ValueKey('command-copyAddress')), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.text('Settings'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    app.dispose();
  });

  testWidgets('Hotkeys settings captures a shortcut and shows it', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final app = AppState();
    await app.ready;
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const SettingsScreen(initialPage: SettingsPage.hotkeys),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('hotkey-edit-copyAddress')));
    await tester.pumpAndSettle();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyH);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(
      app.hotkeyFor(AppCommandId.copyAddress),
      const Hotkey(LogicalKeyboardKey.keyH, control: true, alt: true),
    );
    expect(find.text('Ctrl + Alt + H'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    app.dispose();
  });

  testWidgets('password commands copy and type the active profile password', (tester) async {
    String? copied;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String?;
        return null;
      },
    );
    tester.view.physicalSize = const Size(1000, 650);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final app = AppState();
    await app.ready;
    final connection = SavedConnection(name: 'DEVICE-01', host: '192.0.2.10', credentialProfileId: 'profile');
    app.connections.add(connection);
    app.credentialProfiles.add(CredentialProfile(id: 'profile', name: 'Shared', password: 'test-secret'));
    final session = _RecordingSession(connection.host)..debugSetStatus(SessionStatus.running);
    app.tabs.add(OpenTab(id: 'device', controller: session, connectionId: connection.id));
    app.activeTabIndex = 0;
    app.paneLayout = const PaneLeaf('device');
    await app.setCommandHotkey(AppCommandId.copyPassword,
        const Hotkey(LogicalKeyboardKey.keyC, control: true, alt: true));
    await app.setCommandHotkey(AppCommandId.typePassword,
        const Hotkey(LogicalKeyboardKey.keyT, control: true, alt: true));
    await app.setCommandHotkey(AppCommandId.copyName,
        const Hotkey(LogicalKeyboardKey.keyN, control: true, alt: true));
    await app.setCommandHotkey(AppCommandId.copyAddress,
        const Hotkey(LogicalKeyboardKey.keyA, control: true, alt: true));
    await tester.pumpWidget(ChangeNotifierProvider.value(
      value: app,
      child: MaterialApp(theme: AppTheme.light(), home: const HomeScreen()),
    ));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
    await tester.pump(const Duration(milliseconds: 100));
    expect(copied, 'DEVICE-01');
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.pump(const Duration(milliseconds: 100));
    expect(copied, '192.0.2.10');
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.pump(const Duration(milliseconds: 100));
    expect(copied, 'test-secret');
    await tester.sendKeyEvent(LogicalKeyboardKey.keyT);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump(const Duration(milliseconds: 100));
    expect(session.typed, 'test-secret');
    await tester.pumpWidget(const SizedBox());
    session.dispose();
    app.dispose();
  });
}
