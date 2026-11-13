import 'package:commands/widgets/terminal_hover_scrollbar.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

void main() {
  testWidgets('terminal thumb appears at the right edge and can scroll', (
    tester,
  ) async {
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    final terminal = Terminal();
    for (var i = 0; i < 120; i++) {
      terminal.write('line $i\r\n');
    }

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 320,
              height: 240,
              child: TerminalHoverScrollbar(
                controller: scroll,
                color: Colors.white,
                child: TerminalView(terminal, scrollController: scroll),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(scroll.hasClients, isTrue);
    expect(scroll.position.maxScrollExtent, greaterThan(0));

    final scrollbar = find.byType(RawScrollbar);
    final rect = tester.getRect(find.byType(TerminalHoverScrollbar));
    Color thumbColor() => tester.widget<RawScrollbar>(scrollbar).thumbColor!;
    expect(thumbColor(), Colors.transparent);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset(rect.center.dx, rect.center.dy));
    await tester.pump();
    expect(thumbColor(), Colors.transparent);

    await mouse.moveTo(Offset(rect.right - 10, rect.center.dy));
    await tester.pump();
    expect(thumbColor().a, greaterThan(0));
    expect(tester.widget<RawScrollbar>(scrollbar).thickness, 4);

    scroll.jumpTo(scroll.position.minScrollExtent);
    await tester.pump();
    await mouse.moveTo(Offset(rect.right - 5, rect.top + 12));
    await tester.pump();
    await mouse.down(Offset(rect.right - 5, rect.top + 12));
    await tester.pump();
    await mouse.moveBy(const Offset(0, 100));
    await tester.pump();
    await mouse.up();
    await tester.pump();
    expect(scroll.offset, greaterThan(0));

    await mouse.moveTo(rect.center);
    await tester.pump();
    expect(thumbColor(), Colors.transparent);
    await mouse.removePointer();
  });
}
