import 'package:commands/providers/app_state.dart';
import 'package:commands/services/pty_session.dart';
import 'package:commands/widgets/terminal_tabs.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('tabs are pills inside the strip, the one in use raised and underlined with the accent', (tester) async {
    SharedPreferences.setMockInitialValues({});
    PtySessionController.checkReachability = false;
    addTearDown(() => PtySessionController.checkReachability = true);
    final app = AppState();
    await tester.pump();
    final controller = PtySessionController(host: '192.0.2.10', port: 22, username: 'user', tabTitle: 'DEVICE-01');
    app.tabs.add(OpenTab(id: 'one', controller: controller));
    app.setActiveTab(0);

    await tester.binding.setSurfaceSize(const Size(800, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(ChangeNotifierProvider.value(
      value: app,
      child: const MaterialApp(home: Scaffold(body: TerminalTabsArea())),
    ));
    await tester.pump(const Duration(milliseconds: 50));

    final chip = find.byKey(const ValueKey('tab-pill-one'));
    expect(chip, findsOneWidget);
    final divider = find.byWidgetPredicate((widget) => widget is Divider && widget.height == 1).first;
    // Inside the strip, with room above and below.
    final pill = tester.getRect(find.descendant(of: chip, matching: find.byType(DecoratedBox)).first);
    expect(pill.bottom, lessThan(tester.getTopLeft(divider).dy));
    expect(pill.top, greaterThan(tester.getRect(find.byType(TerminalTabsArea)).top));
    expect(pill.height, 28);
    final theme = Theme.of(tester.element(chip));
    final box = tester.widget<Container>(chip).decoration as BoxDecoration;
    // Not filled with the accent (it hid the folder colour): a step raised,
    // with the accent as the line along its foot when it has no folder.
    expect(box.color, isNot(theme.colorScheme.primary));
    expect(box.borderRadius, BorderRadius.circular(8));
    final line = find.descendant(of: chip, matching: find.byKey(const ValueKey('tab-underline')));
    expect(tester.widget<Container>(line).color, theme.colorScheme.primary);
    expect(tester.getRect(line).bottom, pill.bottom);

    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    await tester.pump(const Duration(seconds: 1));
  });
}
