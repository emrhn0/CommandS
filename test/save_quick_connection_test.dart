import 'package:commands/models/models.dart';
import 'package:commands/providers/app_state.dart';
import 'package:commands/widgets/app_dialog.dart';
import 'package:commands/widgets/terminal_tabs.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late AppState app;
  late ConnectionFolder folder;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('commands/rdp'),
      (call) async => call.method == 'create' ? 1 : (call.method == 'connect' ? true : null),
    );
    app = AppState();
    await Future<void>.delayed(Duration.zero);
    folder = ConnectionFolder(name: 'CUSTOMER-A');
    app.folders.add(folder);
  });

  Future<void> pumpTabs(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: const MaterialApp(home: Scaffold(body: TerminalTabsArea())),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }

  // The RDP pane shows a spinner until its native session reports in, so
  // pumpAndSettle would never return; let animations run for a fixed time.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> openTabMenu(WidgetTester tester, String title) async {
    await tester.tap(find.text(title).first, buttons: kSecondaryMouseButton);
    await settle(tester);
  }

  testWidgets('a quick SSH tab is saved with its host and port filled in, then counts as saved', (
    tester,
  ) async {
    app.openBlankHostOnly(host: '192.0.2.50', port: 2222);
    await pumpTabs(tester);

    await openTabMenu(tester, '192.0.2.50');
    expect(find.text('Edit connection…'), findsNothing);
    await tester.tap(find.text('Save connection…'));
    await tester.pumpAndSettle();

    expect(find.text('Save Connection'), findsOneWidget);
    // What it is connected to is already there; only the rest is asked for.
    expect(find.widgetWithText(TextField, '192.0.2.50'), findsOneWidget);
    expect(find.widgetWithText(TextField, '2222'), findsOneWidget);
    expect(find.text('Save and Connect'), findsNothing, reason: 'the session is already open');

    Finder labeled(String label) =>
        find.descendant(of: find.widgetWithText(LabeledField, label), matching: find.byType(TextField));
    await tester.enterText(labeled('Username'), 'admin');
    await tester.enterText(labeled('Password'), 'secret123');
    await tester.tap(find.text('No folder (top level)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('CUSTOMER-A').last);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ElevatedButton, 'Save'));
    await tester.pumpAndSettle();

    final saved = app.connections.single;
    expect(saved.host, '192.0.2.50');
    expect(saved.port, 2222);
    expect(saved.protocol, ConnectionProtocol.ssh);
    expect(saved.username, 'admin');
    expect(saved.password, 'secret123');
    expect(saved.folderId, folder.id);
    expect(saved.name, '192.0.2.50', reason: 'name defaults to the host');
    // The open tab is now that connection: the tree shows it as open, and
    // its menu offers Edit instead of Save.
    expect(app.tabs.single.connectionId, saved.id);
    expect(app.unsavedConnectionOf(app.tabs.single), isNull);
    await openTabMenu(tester, '192.0.2.50');
    expect(find.text('Save connection…'), findsNothing);
    expect(find.text('Edit connection…'), findsOneWidget);
    await tester.tap(find.text('Close tab'));
    await tester.pumpAndSettle();
    expect(app.tabs, isEmpty);
  });

  testWidgets('a quick RDP tab is saved as RDP on its port', (tester) async {
    app.openQuickRdp(host: '192.0.2.60', port: 3390);
    final target = app.unsavedConnectionOf(app.tabs.single)!;
    expect(target.protocol, ConnectionProtocol.rdp);
    expect(target.host, '192.0.2.60');
    expect(target.port, 3390);

    await pumpTabs(tester);
    await openTabMenu(tester, '192.0.2.60');
    await tester.tap(find.text('Save connection…'));
    await settle(tester);
    expect(find.text('Domain'), findsOneWidget, reason: 'the RDP form');
    await tester.tap(find.widgetWithText(ElevatedButton, 'Save'));
    await settle(tester);
    expect(app.connections.single.protocol, ConnectionProtocol.rdp);
    expect(app.connections.single.port, 3390);
    expect(app.tabs.single.connectionId, app.connections.single.id);
    for (final t in app.tabs) {
      t.controller.dispose();
    }
  });

  testWidgets('cancelling leaves the tab a quick connection', (tester) async {
    app.openBlankHostOnly(host: '192.0.2.51', port: 22);
    await pumpTabs(tester);
    await openTabMenu(tester, '192.0.2.51');
    await tester.tap(find.text('Save connection…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(app.connections, isEmpty);
    expect(app.unsavedConnectionOf(app.tabs.single), isNotNull);
  });
}
