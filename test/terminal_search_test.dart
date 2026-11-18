import 'package:commands/providers/app_state.dart';
import 'package:commands/services/pty_session.dart';
import 'package:commands/widgets/terminal_search.dart';
import 'package:commands/widgets/terminal_tabs.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart';

void main() {
  group('findInTerminal', () {
    test('finds every match, ignoring case, top to bottom', () {
      final t = Terminal();
      t.write('interface Vlan10\r\n ip address 192.0.2.1 255.255.255.0\r\ninterface vlan20\r\n');
      final m = findInTerminal(t, 'VLAN');
      expect(m.map((e) => e.row), [0, 2]);
      expect(m.first, const TerminalSearchMatch(0, 10, 14));
    });

    test('several matches on one line, and nothing for an empty query', () {
      final t = Terminal();
      t.write('ab ab ab\r\n');
      expect(findInTerminal(t, 'ab'), hasLength(3));
      expect(findInTerminal(t, ''), isEmpty);
    });

    test('the scrollback is searched too', () {
      final t = Terminal(maxLines: 1000);
      for (var i = 0; i < 300; i++) {
        t.write('line $i\r\n');
      }
      expect(findInTerminal(t, 'line 7').first.row, 7);
      expect(findInTerminal(t, 'line 299'), hasLength(1));
    });
  });

  group('the search bar', () {
    late AppState app;
    late PtySessionController c;

    Future<void> pumpSession(WidgetTester tester) async {
      PtySessionController.checkReachability = false;
      SharedPreferences.setMockInitialValues({});
      app = AppState();
      await tester.pump();
      c = PtySessionController(host: '192.0.2.10', port: 22, username: 'user1', tabTitle: 'DEVICE-01');
      c.writeOverride = (_) {};
      app.tabs.add(OpenTab(id: 'a', controller: c));
      app.setActiveTab(0);
      await tester.binding.setSurfaceSize(const Size(1000, 500));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(ChangeNotifierProvider.value(
        value: app,
        child: const MaterialApp(home: Scaffold(body: TerminalTabsArea())),
      ));
      await tester.pump(const Duration(milliseconds: 50));
      c.debugReceiveOutput('switch-01# show vlan\r\nVLAN0010 active\r\nVLAN0020 active\r\nswitch-01# \r\n');
      await tester.pump();
    }

    Future<void> cleanUp(WidgetTester tester) async {
      c.writeOverride = null;
      await tester.pumpWidget(const SizedBox());
      c.dispose();
      await tester.pump(const Duration(seconds: 1));
    }

    double width(WidgetTester tester) => tester.getSize(find.byKey(const Key('terminal-search'))).width;
    String count(WidgetTester tester) => tester.widget<Text>(find.byKey(const Key('terminal-search-count'))).data!;

    testWidgets('a small magnifier widens into a field, and counts the matches', (tester) async {
      await pumpSession(tester);
      expect(width(tester), lessThan(40));
      await tester.tap(find.byKey(const Key('terminal-search-open')));
      await tester.pumpAndSettle();
      expect(width(tester), greaterThan(300));
      await tester.enterText(find.byKey(const Key('terminal-search-field')), 'active');
      await tester.pump();
      expect(count(tester), '2/2', reason: 'starts on the newest match');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(count(tester), '1/2', reason: 'Enter goes back up');
      await tester.tap(find.byIcon(Icons.keyboard_arrow_down));
      await tester.pump();
      expect(count(tester), '2/2');
      await cleanUp(tester);
    });

    testWidgets('no match says so', (tester) async {
      await pumpSession(tester);
      await tester.tap(find.byKey(const Key('terminal-search-open')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('terminal-search-field')), 'nothing-like-this');
      await tester.pump();
      expect(count(tester), 'No results');
      await cleanUp(tester);
    });

    testWidgets('Ctrl+Shift+F opens it from the terminal, and Esc closes it', (tester) async {
      await pumpSession(tester);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(width(tester), greaterThan(300));
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(width(tester), lessThan(40));
      await cleanUp(tester);
    });
  });
}
