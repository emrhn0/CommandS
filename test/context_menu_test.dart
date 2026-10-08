import 'package:commands/models/models.dart';
import 'package:commands/providers/app_state.dart';
import 'package:commands/widgets/connection_tree.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late AppState app;
  late SavedConnection conn;

  Future<void> pumpTree(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    app = AppState();
    await tester.pump();
    conn = SavedConnection(name: 'switch-01', host: '192.0.2.11');
    app.connections.add(conn);
    await tester.pumpWidget(ChangeNotifierProvider.value(
      value: app,
      child: const MaterialApp(home: Scaffold(body: SizedBox(width: 260, height: 600, child: ConnectionTree()))),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('right-click opens a compact, grouped menu named after the row', (tester) async {
    await pumpTree(tester);
    await tester.tap(find.text('switch-01'), buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();

    for (final label in ['Connect', 'Edit…', 'Rename', 'Clone', 'Move to folder…', 'Delete']) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    // The row's name heads the menu, so it is clear what it acts on.
    expect(find.text('switch-01'), findsNWidgets(2));
    // Desktop-sized rows, not 48px touch targets.
    final row = find.ancestor(of: find.text('Rename'), matching: find.byType(PopupMenuItem<String>));
    expect(tester.getSize(row).height, lessThanOrEqualTo(32));
    // Separators between groups.
    expect(find.byType(PopupMenuDivider), findsNWidgets(3));
    // Delete stands out.
    final delete = tester.widget<Text>(find.text('Delete'));
    expect(delete.style?.color, Theme.of(tester.element(find.text('Delete'))).colorScheme.error);
  });

  testWidgets('the "..." button opens the same menu and actions still run', (tester) async {
    await pumpTree(tester);
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: tester.getCenter(find.text('switch-01')));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.more_horiz));
    await tester.pumpAndSettle();
    expect(find.text('Move to folder…'), findsOneWidget);

    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(app.connections, isEmpty);
  });

  testWidgets('Rename and Delete folder use the app dialogs', (tester) async {
    await pumpTree(tester);
    await tester.tap(find.text('switch-01'), buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rename'));
    await tester.pumpAndSettle();
    expect(find.text('Rename connection'), findsOneWidget);
    await tester.enterText(find.byType(TextField).last, 'switch-renamed');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(app.connections.single.name, 'switch-renamed');

    final folder = ConnectionFolder(name: 'CUSTOMER-A');
    app.folders.add(folder);
    app.notifyListeners();
    await tester.pumpAndSettle();
    await tester.tap(find.text('CUSTOMER-A'), buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete folder'));
    await tester.pumpAndSettle();
    expect(find.text('Delete "CUSTOMER-A"?'), findsOneWidget);
    // Closing with the title bar's X keeps the folder.
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    expect(app.folders, hasLength(1));

    await tester.tap(find.text('CUSTOMER-A'), buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete folder'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ElevatedButton, 'Delete folder'));
    await tester.pumpAndSettle();
    expect(app.folders, isEmpty);
  });
}
