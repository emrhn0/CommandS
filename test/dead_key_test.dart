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

  /// Stands in for Windows, through the real decision: AltGr+Ü is a dead
  /// key for ~; other keys type their own letter.
  String? fakeWindows(KeyEvent e) {
    final altGr = HardwareKeyboard.instance.isAltPressed;
    final isUe = e.logicalKey == keyUe;
    final key = isUe && altGr
        ? (text: '~', dead: true)
        : e.logicalKey == LogicalKeyboardKey.keyA
        ? (text: 'a', dead: false)
        : e.logicalKey == LogicalKeyboardKey.keyB
        ? (text: 'b', dead: false)
        : isUe
        ? (text: 'ü', dead: false)
        : null;
    final character = e.character;
    if (character == null || character.isEmpty) return null;
    return DeadKeys.decide(character: character, altGr: altGr, key: key, plain: isUe ? 'ü' : key?.text);
  }

  Future<void> altGrUe(WidgetTester tester, String character) async {
    await tester.sendKeyDownEvent(keyUe, physicalKey: physicalUe, character: character);
    await tester.sendKeyUpEvent(keyUe, physicalKey: physicalUe);
  }

  testWidgets('holding AltGr: the first Ü types nothing, the second types ~', (tester) async {
    final original = DeadKeys.translate;
    DeadKeys.reset();
    DeadKeys.translate = fakeWindows;
    addTearDown(() => DeadKeys.translate = original);

    final sent = await typeInTerminal(tester, () async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altRight);
      await altGrUe(tester, 'ü');
      // Windows sends ~ with the second press.
      await altGrUe(tester, '~');
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altRight);
    });
    expect(sent.join(), '~', reason: 'no ü before it');
  });

  testWidgets('~ then a letter types both, not a composed letter', (tester) async {
    final original = DeadKeys.translate;
    DeadKeys.reset();
    DeadKeys.translate = fakeWindows;
    addTearDown(() => DeadKeys.translate = original);

    final sent = await typeInTerminal(tester, () async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altRight);
      await altGrUe(tester, 'ü');
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altRight);
      // Windows composes the waiting ~ into the next key: ã.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyA, character: 'ã');
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyA);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyB, character: 'b');
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyB);
    });
    expect(sent.join(), '~ab');
  });

  testWidgets('the same key without AltGr still types ü', (tester) async {
    final original = DeadKeys.translate;
    DeadKeys.reset();
    DeadKeys.translate = fakeWindows;
    addTearDown(() => DeadKeys.translate = original);

    final sent = await typeInTerminal(tester, () async {
      await tester.sendKeyDownEvent(keyUe, physicalKey: physicalUe, character: 'ü');
      await tester.sendKeyUpEvent(keyUe, physicalKey: physicalUe);
    });
    expect(sent.join(), 'ü');
  });

  test('on a Turkish Q keyboard, AltGr+Ü is a dead key typing ~, and Ü alone types ü', () {
    final list = calloc<ffi.IntPtr>(16);
    try {
      final n = GetKeyboardLayoutList(16, list);
      final turkishQ = [for (var i = 0; i < n; i++) list[i]].where((l) => l & 0xFFFF == 0x041F).firstOrNull;
      if (turkishQ == null) {
        markTestSkipped('no Turkish keyboard installed');
        return;
      }
      const ueScanCode = 0x1B; // two keys right of P (Ğ is 0x1A)
      const aScanCode = 0x1E;
      final altGr = DeadKeys.keyOnLayout(
        ueScanCode,
        turkishQ,
        held: const [VK_CONTROL, VK_LCONTROL, VK_MENU, VK_RMENU],
      );
      expect(altGr, (text: '~', dead: true));
      expect(DeadKeys.keyOnLayout(ueScanCode, turkishQ, held: const []), (text: 'ü', dead: false));
      expect(DeadKeys.keyOnLayout(aScanCode, turkishQ, held: const []), (text: 'a', dead: false));
    } finally {
      calloc.free(list);
    }
  }, skip: !Platform.isWindows);

  group('what a key press types', () {
    const deadTilde = (text: '~', dead: true);
    setUp(DeadKeys.reset);

    test('AltGr+Ü: the first press types nothing, the second types ~', () {
      expect(DeadKeys.decide(character: 'ü', altGr: true, key: deadTilde, plain: 'ü'), '');
      expect(DeadKeys.decide(character: '~', altGr: true, key: deadTilde, plain: 'ü'), '~');
    });

    test('~ then a letter types both, not a composed letter', () {
      expect(DeadKeys.decide(character: 'ü', altGr: true, key: deadTilde, plain: 'ü'), '');
      expect(DeadKeys.decide(character: 'ã', altGr: false, key: (text: 'a', dead: false), plain: 'a'), '~a');
    });

    test('~ then space types ~ alone', () {
      DeadKeys.decide(character: 'ü', altGr: true, key: deadTilde, plain: 'ü');
      expect(DeadKeys.decide(character: '~', altGr: false, key: (text: ' ', dead: false), plain: ' '), '~');
    });

    test('with AltGr held, a key sending its own plain letter types nothing, whatever Windows said', () {
      expect(DeadKeys.decide(character: 'ü', altGr: true, key: null, plain: 'ü'), '');
      expect(DeadKeys.decide(character: 'ü', altGr: true, key: (text: 'ü', dead: false), plain: 'ü'), '');
    });

    test('everything else goes through as usual', () {
      expect(DeadKeys.decide(character: 'ü', altGr: false, key: (text: 'ü', dead: false), plain: 'ü'), isNull);
      expect(DeadKeys.decide(character: '@', altGr: true, key: (text: '@', dead: false), plain: 'q'), isNull);
    });
  });
}
