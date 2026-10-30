import 'package:commands/models/models.dart';
import 'package:commands/providers/app_state.dart';
import 'package:commands/widgets/connection_tree.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late AppState app;
  late ConnectionFolder folder;

  Future<void> pumpTree(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('commands/rdp'),
      (call) async => call.method == 'create' ? 1 : (call.method == 'connect' ? true : null),
    );
    app = AppState();
    await tester.pump();
    folder = ConnectionFolder(name: 'CUSTOMER-A');
    app.folders.add(folder);
    app.connections.add(
      SavedConnection(
        name: 'DEVICE-01',
        host: '192.0.2.10',
        port: 3389,
        protocol: ConnectionProtocol.rdp,
        folderId: folder.id,
      ),
    );
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: const MaterialApp(
          home: Scaffold(body: SizedBox(width: 280, height: 500, child: ConnectionTree())),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('a single click on a folder only selects it; a double click opens it', (tester) async {
    await pumpTree(tester);
    await tester.tap(find.text('CUSTOMER-A'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('DEVICE-01'), findsNothing, reason: 'still closed');

    await tester.tap(find.text('CUSTOMER-A'));
    await tester.tap(find.text('CUSTOMER-A'));
    await tester.pumpAndSettle();
    expect(find.text('DEVICE-01'), findsOneWidget);
  });

  testWidgets('the chevron still opens a folder with one click', (tester) async {
    await pumpTree(tester);
    await tester.tap(find.byIcon(Icons.chevron_right));
    await tester.pumpAndSettle();
    expect(find.text('DEVICE-01'), findsOneWidget);
  });

  testWidgets('a single click on a connection does not connect; a double click does', (tester) async {
    await pumpTree(tester);
    await tester.tap(find.byIcon(Icons.chevron_right));
    await tester.pumpAndSettle();

    await tester.tap(find.text('DEVICE-01'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(app.tabs, isEmpty);

    await tester.tap(find.text('DEVICE-01'));
    await tester.tap(find.text('DEVICE-01'));
    await tester.pump();
    expect(app.tabs, hasLength(1));
    for (final t in app.tabs) {
      t.controller.dispose();
    }
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('one selected row shows no bulk-action bar; two do', (tester) async {
    await pumpTree(tester);
    await tester.tap(find.byIcon(Icons.chevron_right));
    await tester.pumpAndSettle();
    await tester.tap(find.text('DEVICE-01'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.textContaining('selected'), findsNothing);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.tap(find.text('CUSTOMER-A'));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.textContaining('2 selected'), findsOneWidget);
  });
}
