import 'package:commands/models/models.dart';
import 'package:commands/providers/app_state.dart';
import 'package:commands/services/mcp_server.dart';
import 'package:commands/services/pty_session.dart';
import 'package:commands/widgets/terminal_tabs.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('a tab the agent opened is marked AI; the user\'s own tab is not', (tester) async {
    SharedPreferences.setMockInitialValues({});
    PtySessionController.checkReachability = false;
    addTearDown(() => PtySessionController.checkReachability = true);
    final app = AppState();
    await tester.pump();
    app.connections = [SavedConnection(id: 'c1', name: 'DEVICE-01', host: '192.0.2.10', username: 'user1')];
    final gateway = AppMcpGateway(app);
    await tester.runAsync(gateway.load);
    await tester.runAsync(() => gateway.setAllowed('c1', true));
    final server = McpServer(gateway);

    await tester.binding.setSurfaceSize(const Size(1000, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: app),
        ChangeNotifierProvider<McpServer>.value(value: server),
      ],
      child: const MaterialApp(home: Scaffold(body: TerminalTabsArea())),
    ));

    await tester.runAsync(() => app.openConnection(app.connections.first));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byKey(const ValueKey('tab-agent-mark')), findsNothing);

    final session = await tester.runAsync(() => gateway.openConnection('DEVICE-01'));
    await tester.pump(const Duration(milliseconds: 50));
    final mark = find.byKey(const ValueKey('tab-agent-mark'));
    expect(mark, findsOneWidget);
    expect(find.text('AI'), findsOneWidget);
    // On the agent's tab, not the user's.
    expect(
      find.ancestor(of: mark, matching: find.byKey(ValueKey('tab-$session'))),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox());
    gateway.close();
    for (final t in app.tabs) {
      t.controller.dispose();
    }
    await tester.pump(const Duration(seconds: 1));
  });
}
