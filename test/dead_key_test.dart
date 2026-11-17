import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:commands/providers/app_state.dart';
import 'package:commands/services/dead_keys.dart';
import 'package:commands/services/pty_session.dart';
import 'package:commands/widgets/terminal_tabs.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:ffi/ffi.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:win32/win32.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    PtySessionController.checkReachability = false;
  });
  tearDown(() => PtySessionController.checkReachability = true);

  // The Ü key of a Turkish Q keyboard (where [ is on a US one).
  const keyUe = LogicalKeyboardKey.bracketLeft;
  const physicalUe = PhysicalKeyboardKey.bracketLeft;

  Future<List<String>> typeInTerminal(WidgetTester tester, Future<void> Function() keys) async {
    final app = AppState();
    await tester.pump();
    final session = PtySessionController(host: '192.0.2.10', port: 22, startImmediately: false)
      ..status = SessionStatus.running;
    final sent = <String>[];
    session.writeOverride = sent.add;
    app.tabs.add(OpenTab(id: 'ssh', controller: session));
    app.setActiveTab(0);
    await tester.binding.setSurfaceSize(const Size(1000, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(ChangeNotifierProvider.value(
      value: app,
      child: const MaterialApp(home: Scaffold(body: TerminalTabsArea())),
    ));
    await tester.pump(const Duration(milliseconds: 100));
    await keys();
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    session.dispose();
    return sent;
  }

  testWidgets('a dead key types nothing; the character that follows it does', (tester) async {
    final original = DeadKeys.isDeadKey;
    // AltGr+Ü on a Turkish keyboard: a dead key that becomes ~.
    DeadKeys.isDeadKey = (e) => e.logicalKey == keyUe && HardwareKeyboard.instance.isAltPressed;
    addTearDown(() => DeadKeys.isDeadKey = original);

    final sent = await typeInTerminal(tester, () async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altRight);
      await tester.sendKeyDownEvent(keyUe, physicalKey: physicalUe, character: 'ü');
      await tester.sendKeyUpEvent(keyUe, physicalKey: physicalUe);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altRight);
      // Windows then hands over the composed character with the next key.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.space, character: '~');
      await tester.sendKeyUpEvent(LogicalKeyboardKey.space);
    });
    expect(sent.join(), '~');
  });

  testWidgets('the same key without AltGr still types ü', (tester) async {
    final original = DeadKeys.isDeadKey;
    DeadKeys.isDeadKey = (e) => e.logicalKey == keyUe && HardwareKeyboard.instance.isAltPressed;
    addTearDown(() => DeadKeys.isDeadKey = original);

    final sent = await typeInTerminal(tester, () async {
      await tester.sendKeyDownEvent(keyUe, physicalKey: physicalUe, character: 'ü');
      await tester.sendKeyUpEvent(keyUe, physicalKey: physicalUe);
    });
    expect(sent.join(), 'ü');
  });

  test('on Windows, a plain letter with nothing held is not a dead key', () {
    final event = KeyDownEvent(
      physicalKey: PhysicalKeyboardKey.keyA,
      logicalKey: LogicalKeyboardKey.keyA,
      character: 'a',
      timeStamp: Duration.zero,
    );
    expect(DeadKeys.isDeadKey(event), isFalse);
  }, skip: !Platform.isWindows);

  test('on a Turkish Q keyboard, AltGr+Ü is a dead key and Ü alone is not', () {
    final list = calloc<ffi.IntPtr>(16);
    try {
      final n = GetKeyboardLayoutList(16, list);
      final turkishQ = [for (var i = 0; i < n; i++) list[i]].where((l) => l & 0xFFFF == 0x041F).firstOrNull;
      if (turkishQ == null) {
        markTestSkipped('no Turkish keyboard installed');
        return;
      }
      const ueScanCode = 0x1A; // the key right of P
      expect(DeadKeys.isDeadOnLayout(ueScanCode, turkishQ, held: const []), isFalse);
      expect(
        DeadKeys.isDeadOnLayout(ueScanCode, turkishQ, held: const [VK_CONTROL, VK_LCONTROL, VK_MENU, VK_RMENU]),
        isTrue,
      );
    } finally {
      calloc.free(list);
    }
  }, skip: !Platform.isWindows);
}
