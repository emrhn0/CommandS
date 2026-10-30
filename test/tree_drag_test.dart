import 'package:commands/models/models.dart';
import 'package:commands/providers/app_state.dart';
import 'package:commands/services/pty_session.dart';
import 'package:commands/widgets/connection_tree.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late AppState app;
  late ConnectionFolder a, b, c, inner;
  late SavedConnection conn;

  Future<void> pumpTree(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    app = AppState();
    await tester.pump();
    a = ConnectionFolder(name: 'ALPHA');
    b = ConnectionFolder(name: 'BRAVO');
    c = ConnectionFolder(name: 'CHARLIE');
    inner = ConnectionFolder(name: 'INNER', parentId: a.id);
    app.folders.addAll([a, b, c, inner]);
    conn = SavedConnection(name: 'DEVICE-01', host: '192.0.2.10', folderId: c.id);
    app.connections.add(conn);
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: const MaterialApp(
          home: Scaffold(body: SizedBox(width: 300, height: 400, child: ConnectionTree())),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Drags from [from] to [to] (global points) the way a mouse does.
  Future<void> drag(WidgetTester tester, Offset from, Offset to) async {
    final g = await tester.startGesture(from, kind: PointerDeviceKind.mouse);
    await tester.pump(const Duration(milliseconds: 50));
    for (var i = 1; i <= 10; i++) {
      await g.moveTo(Offset.lerp(from, to, i / 10)!);
      await tester.pump(const Duration(milliseconds: 16));
    }
    await g.up();
    await tester.pumpAndSettle();
  }

  testWidgets('a connection dropped on a folder moves into it', (tester) async {
    await pumpTree(tester);
    await tester.tap(find.byIcon(Icons.chevron_right).at(2)); // open CHARLIE
    await tester.pumpAndSettle();
    await drag(tester, tester.getCenter(find.text('DEVICE-01')), tester.getCenter(find.text('BRAVO')));
    expect(app.connections.single.folderId, b.id);
  });

  testWidgets('a folder dropped on the middle of another goes inside it', (tester) async {
    await pumpTree(tester);
    await drag(tester, tester.getCenter(find.text('CHARLIE')), tester.getCenter(find.text('BRAVO')));
    expect(c.parentId, b.id);
  });

  testWidgets('a folder dropped on the top edge of another goes above it, and the order stays', (
    tester,
  ) async {
    await pumpTree(tester);
    // The top third of ALPHA's 30px row: a few pixels above its text.
    final top = tester.getCenter(find.text('ALPHA')).translate(0, -10);
    await drag(tester, tester.getCenter(find.text('CHARLIE')), top);
    expect(c.parentId, isNull);
    final order = app
        .sortFolders(app.folders.where((f) => f.parentId == null).toList())
        .map((f) => f.name)
        .toList();
    expect(order, ['CHARLIE', 'ALPHA', 'BRAVO']);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList('commands.folderOrder'), isNotEmpty);
    // On screen too.
    expect(tester.getCenter(find.text('CHARLIE')).dy, lessThan(tester.getCenter(find.text('ALPHA')).dy));
  });

  testWidgets('a folder cannot go inside its own subfolder', (tester) async {
    await pumpTree(tester);
    await tester.tap(find.byIcon(Icons.chevron_right).first); // open ALPHA
    await tester.pumpAndSettle();
    await drag(tester, tester.getCenter(find.text('ALPHA')), tester.getCenter(find.text('INNER')));
    expect(a.parentId, isNull);
    expect(inner.parentId, a.id);
  });

  testWidgets('dropped on empty space below the rows, it goes to the top level', (tester) async {
    await pumpTree(tester);
    await tester.tap(find.byIcon(Icons.chevron_right).first); // open ALPHA
    await tester.pumpAndSettle();
    await drag(tester, tester.getCenter(find.text('INNER')), const Offset(150, 380));
    expect(inner.parentId, isNull);
  });

  testWidgets('pressing a row does not pick it up', (tester) async {
    await pumpTree(tester);
    await tester.tap(find.byIcon(Icons.chevron_right).at(2)); // open CHARLIE
    await tester.pumpAndSettle();
    final g = await tester.startGesture(
      tester.getCenter(find.text('DEVICE-01')),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump(const Duration(milliseconds: 40));
    expect(find.text('DEVICE-01'), findsOneWidget, reason: 'no drag chip on a press');
    await g.moveBy(const Offset(3, 2)); // a hand's jitter
    await tester.pump(const Duration(milliseconds: 40));
    expect(find.text('DEVICE-01'), findsOneWidget, reason: 'nor on a few pixels of jitter');
    await g.up();
    await tester.pump();
  });

  testWidgets('a jittery double click on a connection in a folder opens it and leaves it where it is', (
    tester,
  ) async {
    await pumpTree(tester);
    PtySessionController.checkReachability = false;
    addTearDown(() => PtySessionController.checkReachability = true);
    await tester.tap(find.byIcon(Icons.chevron_right).at(2)); // open CHARLIE
    await tester.pumpAndSettle();
    final p = tester.getCenter(find.text('DEVICE-01'));
    // As a real mouse delivers it: frames drawn between every event, and the
    // hand moving a little while the button is down.
    final g1 = await tester.startGesture(p, kind: PointerDeviceKind.mouse);
    await tester.pump(const Duration(milliseconds: 30));
    await g1.moveTo(p + const Offset(2, 1));
    await tester.pump(const Duration(milliseconds: 20));
    await g1.up();
    await tester.pump(const Duration(milliseconds: 70));
    final g2 = await tester.startGesture(p + const Offset(2, 1), kind: PointerDeviceKind.mouse);
    await tester.pump(const Duration(milliseconds: 30));
    await g2.up();
    await tester.pump(const Duration(milliseconds: 50));
    expect(app.connections.single.folderId, c.id, reason: 'still in its folder');
    expect(app.tabs, hasLength(1), reason: 'the double click connected');
    for (final t in app.tabs) {
      t.controller.dispose();
    }
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('picked up and put back on itself, a connection stays in its folder', (tester) async {
    await pumpTree(tester);
    await tester.tap(find.byIcon(Icons.chevron_right).at(2)); // open CHARLIE
    await tester.pumpAndSettle();
    final p = tester.getCenter(find.text('DEVICE-01'));
    await drag(tester, p, p + const Offset(30, 4));
    expect(app.connections.single.folderId, c.id);
    // Again from another spot of the row (test pointer events carry no
    // time, so a second press on the same spot would read as a double click).
    final q = p + const Offset(20, 0);
    await drag(tester, q, q + const Offset(-20, -3));
    expect(app.connections.single.folderId, c.id);
  });
}
