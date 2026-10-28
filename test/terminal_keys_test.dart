import 'package:commands/widgets/terminal_clipboard.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

/// The terminal view as the app sets it up, recording what it sends.
Future<(Terminal, List<String>)> _pump(WidgetTester tester) async {
  final terminal = Terminal();
  final sent = <String>[];
  terminal.onOutput = sent.add;
  final controller = TerminalController();
  final clipboard = TerminalClipboard(terminal: terminal, controller: controller);
  addTearDown(clipboard.dispose);
  final focus = FocusNode();
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: TerminalView(
          terminal,
          controller: controller,
          focusNode: focus,
          autofocus: true,
          hardwareKeyboardOnly: true,
          shortcuts: TerminalClipboard.shortcuts,
          onKeyEvent: clipboard.handleKey,
        ),
      ),
    ),
  );
  focus.requestFocus();
  await tester.pump();
  return (terminal, sent);
}

void main() {
  testWidgets('arrow keys reach the session, for the shell history', (tester) async {
    final (_, sent) = await _pump(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    expect(sent.join(), '\x1b[A\x1b[B');
  });

  testWidgets('Ctrl+A and Ctrl+V go to the session, as in PuTTY', (tester) async {
    final (_, sent) = await _pump(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    expect(sent.join(), '\x01\x16');
  });

  testWidgets('Shift+Insert pastes, with line breaks sent as Enter', (tester) async {
    String? clip = 'show version\r\nshow clock';
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.getData') return {'text': clip};
      if (call.method == 'Clipboard.setData') clip = (call.arguments as Map)['text'] as String?;
      return null;
    });
    final (_, sent) = await _pump(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.insert);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    expect(sent.join(), 'show version\rshow clock');
  });
}
