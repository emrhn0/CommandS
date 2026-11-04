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
  final outside = find.byKey(const ValueKey('outside'));

  Future<void> pumpTree(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    app = AppState();
    await tester.pump();
    final folder = ConnectionFolder(name: 'ALPHA');
    app.folders.add(folder);
    app.connections.addAll([
      SavedConnection(name: 'DEVICE-01', host: '192.0.2.10', folderId: folder.id),
      SavedConnection(name: 'DEVICE-02', host: '192.0.2.11', folderId: folder.id),
    ]);
    await tester.binding.setSurfaceSize(const Size(800, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: MaterialApp(
          home: Scaffold(
            body: Row(
              children: [
                const SizedBox(width: 300, child: ConnectionTree()),
                Expanded(
                  child: GestureDetector(
                    key: const ValueKey('outside'),
                    behavior: HitTestBehavior.opaque,
                    child: const SizedBox.expand(),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.chevron_right));
    await tester.pumpAndSettle();
  }

  /// Selects everything from the keyboard, so nothing was clicked in the list.
  Future<void> selectAll(WidgetTester tester) async {
    await tester.tap(find.byIcon(Icons.library_add_check_rounded));
    await tester.pumpAndSettle();
    expect(find.text('3'), findsOneWidget, reason: 'the selection bar counts 3');
  }

  Finder bar() => find.text('3');

  testWidgets('a click in the rest of the app drops the selection', (tester) async {
    await pumpTree(tester);
    await selectAll(tester);
    await tester.tap(outside);
    await tester.pumpAndSettle();
    expect(bar(), findsNothing);
  });

  testWidgets('a click on the empty space below the rows drops it', (tester) async {
    await pumpTree(tester);
    await selectAll(tester);
    await tester.tapAt(const Offset(150, 500));
    await tester.pumpAndSettle();
    expect(bar(), findsNothing);
  });

  testWidgets('closing a folder drops it', (tester) async {
    await pumpTree(tester);
    await selectAll(tester);
    await tester.tap(find.byIcon(Icons.chevron_right).first);
    await tester.pumpAndSettle();
    expect(bar(), findsNothing);
  });

  testWidgets('the app losing the keyboard to a session drops it', (tester) async {
    await pumpTree(tester);
    await selectAll(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pumpAndSettle();
    expect(bar(), findsNothing);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });

  testWidgets('a click on the selection bar keeps it', (tester) async {
    await pumpTree(tester);
    await selectAll(tester);
    await tester.tapAt(tester.getCenter(bar()), kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    expect(bar(), findsOneWidget);
  });

  testWidgets('a right-click menu on a selected row does not lose it', (tester) async {
    await pumpTree(tester);
    await selectAll(tester);
    await tester.tap(find.text('DEVICE-01'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    expect(bar(), findsOneWidget);
  });
}
