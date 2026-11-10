import 'package:commands/providers/app_state.dart';
import 'package:commands/models/models.dart';
import 'package:commands/widgets/app_dialog.dart';
import 'package:commands/widgets/new_connection_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('blank SSH name keeps host until the first session', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final app = AppState();
    await tester.pump();
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showNewConnectionDialog(context),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(
      find.text('Hostname after first SSH connection, otherwise host'),
      findsOneWidget,
    );
    final host = find.descendant(
      of: find.widgetWithText(LabeledField, 'Host'),
      matching: find.byType(TextField),
    );
    await tester.enterText(host, '192.0.2.10');
    await tester.tap(find.widgetWithText(OutlinedButton, 'Save'));
    await tester.pumpAndSettle();
    expect(app.connections.single.name, '192.0.2.10');
    expect(app.connections.single.autoNamePending, isTrue);
  });

  testWidgets('editing the name explicitly disables automatic naming', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final app = AppState();
    await tester.pump();
    final connection = SavedConnection(
      name: '192.0.2.10',
      host: '192.0.2.10',
      autoNamePending: true,
    );
    await app.upsertConnection(connection);
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showEditConnectionDialog(context, connection),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    final name = find.descendant(
      of: find.widgetWithText(LabeledField, 'Name'),
      matching: find.byType(TextField),
    );
    await tester.enterText(name, 'MY-DEVICE');
    await tester.tap(find.widgetWithText(OutlinedButton, 'Save'));
    await tester.pumpAndSettle();
    expect(app.connections.single.name, 'MY-DEVICE');
    expect(app.connections.single.autoNamePending, isFalse);
  });

  testWidgets('blank RDP name still uses the host without SSH detection', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final app = AppState();
    await tester.pump();
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showNewConnectionDialog(context),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('RDP'));
    await tester.pumpAndSettle();
    final host = find.descendant(
      of: find.widgetWithText(LabeledField, 'Host'),
      matching: find.byType(TextField),
    );
    await tester.enterText(host, '192.0.2.20');
    await tester.tap(find.widgetWithText(OutlinedButton, 'Save'));
    await tester.pumpAndSettle();
    expect(app.connections.single.name, '192.0.2.20');
    expect(app.connections.single.autoNamePending, isFalse);
  });
}
