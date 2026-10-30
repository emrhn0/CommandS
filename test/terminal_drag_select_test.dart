import 'package:commands/widgets/terminal_drag_select.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

void main() {
  testWidgets('dragging below the view scrolls it and the selection keeps growing from where it started', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(700, 400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final terminal = Terminal(maxLines: 1000);
    for (var i = 0; i < 300; i++) {
      terminal.write('line $i\r\n');
    }
    final controller = TerminalController();
    final viewKey = GlobalKey<TerminalViewState>();
    final scroll = ScrollController();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              SizedBox(
                height: 200,
                child: TerminalDragSelect(
                  viewKey: viewKey,
                  scroll: scroll,
                  terminal: terminal,
                  controller: controller,
                  child: TerminalView(
                    terminal,
                    key: viewKey,
                    scrollController: scroll,
                    controller: controller,
                  ),
                ),
              ),
              const Expanded(child: SizedBox()),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // Back to the top of the output.
    scroll.jumpTo(0);
    await tester.pump();
    final view = tester.getRect(find.byType(TerminalView));
    final visibleRows = (view.height / viewKey.currentState!.renderTerminal.lineHeight).floor();

    final g = await tester.startGesture(view.topLeft + const Offset(4, 5), kind: PointerDeviceKind.mouse);
    await tester.pump(const Duration(milliseconds: 50));
    // Out past the bottom edge, and hold there.
    await g.moveTo(view.bottomLeft + const Offset(40, 60));
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(scroll.position.pixels, greaterThan(0), reason: 'the view scrolled on its own');
    await g.up();
    await tester.pump();

    final text = terminal.buffer.getText(controller.selection!);
    expect(text, startsWith('line 0'), reason: 'the start stayed where the drag began');
    final last = RegExp(r'line (\d+)').allMatches(text).map((m) => int.parse(m.group(1)!)).last;
    expect(last, greaterThan(visibleRows + 5), reason: 'it reached rows that were off screen');
  });
}
