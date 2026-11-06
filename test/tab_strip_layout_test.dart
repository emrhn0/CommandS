import 'package:commands/providers/app_state.dart';
import 'package:commands/services/pty_session.dart';
import 'package:commands/widgets/terminal_tabs.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('active tab underline reaches the bottom of the tab strip', (tester) async {
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

    final chip = find.ancestor(
      of: find.text('DEVICE-01'),
      matching: find.byWidgetPredicate(
        (widget) => widget is Container && widget.constraints?.minWidth == 120 && widget.decoration is BoxDecoration,
      ),
    );
    expect(chip, findsOneWidget);
    final divider = find.byWidgetPredicate((widget) => widget is Divider && widget.height == 1).first;
    expect(tester.getBottomLeft(chip).dy, tester.getTopLeft(divider).dy);

    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    await tester.pump(const Duration(seconds: 1));
  });
}
