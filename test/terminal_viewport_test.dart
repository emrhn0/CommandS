import 'package:commands/services/terminal_appearance.dart';
import 'package:commands/widgets/terminal_tabs.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

void main() {
  // Heights that are not a whole number of lines -- what a split pane gets.
  for (final paneHeight in [203.0, 251.5, 317.0]) {
    testWidgets('a terminal in a $paneHeight px pane shows whole lines only, inside the pane', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(600, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final terminal = Terminal();
      for (var i = 0; i < 200; i++) {
        terminal.write('line $i\r\n');
      }
      final style = terminalStyle(size: 13);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                const SizedBox(height: 50, child: ColoredBox(color: Colors.white)),
                SizedBox(
                  key: const ValueKey('pane'),
                  height: paneHeight,
                  child: TerminalViewport(
                    style: style,
                    background: Colors.black,
                    child: TerminalView(terminal, textStyle: style),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final line = TerminalViewport.cellHeight(style, TextScaler.noScaling);
      final pane = tester.getRect(find.byKey(const ValueKey('pane')));
      final view = tester.getRect(find.byType(TerminalView));
      expect(view.top, greaterThanOrEqualTo(pane.top));
      expect(view.bottom, lessThanOrEqualTo(pane.bottom));
      // A whole number of lines, and as many as fit.
      final rows = view.height / line;
      expect(rows, closeTo(rows.roundToDouble(), 0.001));
      expect(pane.height - TerminalViewport.margin - view.height, lessThan(line));
      expect(terminal.viewHeight, rows.round());
      // Painting is clipped to the view regardless.
      expect(find.ancestor(of: find.byType(TerminalView), matching: find.byType(ClipRect)), findsWidgets);
    });
  }
}
