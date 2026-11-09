import 'package:commands/services/mcp_server.dart';
import 'package:commands/widgets/mcp_approval_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const approval = McpApproval(connectionName: 'CUSTOMER-A SWITCH', alias: 'DEVICE-01', command: 'show version');
  final key = GlobalKey<NavigatorState>();

  Future<Future<bool>> ask(WidgetTester tester) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      (call) async => null,
    );
    await tester.pumpWidget(MaterialApp(navigatorKey: key, home: const Scaffold()));
    final answer = askMcpApproval(key, approval);
    await tester.pumpAndSettle();
    return answer;
  }

  testWidgets('shows the command and the real name, and Run says yes', (tester) async {
    final answer = await ask(tester);
    expect(find.text('show version'), findsOneWidget);
    expect(find.textContaining('CUSTOMER-A SWITCH'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('mcp-allow')));
    await tester.pumpAndSettle();
    expect(await answer, isTrue);
  });

  testWidgets('Do not run says no', (tester) async {
    final answer = await ask(tester);
    await tester.tap(find.byKey(const ValueKey('mcp-deny')));
    await tester.pumpAndSettle();
    expect(await answer, isFalse);
  });

  testWidgets('no answer in time is a no, and the dialog goes', (tester) async {
    final answer = await ask(tester);
    await tester.pump(mcpApprovalTimeout + const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(await answer, isFalse);
    expect(find.text('show version'), findsNothing);
  });
}
