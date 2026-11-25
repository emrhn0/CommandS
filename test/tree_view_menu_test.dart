import 'package:commands/models/models.dart';
import 'package:commands/providers/app_state.dart';
import 'package:commands/widgets/connection_tree.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late AppState app;
  late ConnectionFolder outer, inner, other;
  late SavedConnection d1, d2, d3, rdp;

  Future<void> pumpTree(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    app = AppState();
    await tester.pump();
    outer = ConnectionFolder(name: 'CUSTOMER-A');
    inner = ConnectionFolder(name: 'SITE-1', parentId: outer.id);
    other = ConnectionFolder(name: 'CUSTOMER-B');
    d1 = SavedConnection(name: 'DEVICE-01', host: '192.0.2.10', folderId: outer.id);
    d2 = SavedConnection(name: 'DEVICE-02', host: '192.0.2.11', folderId: outer.id);
    d3 = SavedConnection(name: 'DEVICE-03', host: '192.0.2.12', folderId: inner.id);
    rdp = SavedConnection(name: 'SERVER-01', host: '198.51.100.5', protocol: ConnectionProtocol.rdp);
    app.folders.addAll([outer, inner, other]);
    app.connections.addAll([d1, d2, d3, rdp]);
    await tester.binding.setSurfaceSize(const Size(400, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(ChangeNotifierProvider.value(
      value: app,
      child: const MaterialApp(home: Scaffold(body: SizedBox(width: 360, child: ConnectionTree()))),
    ));
    await tester.pumpAndSettle();
  }

  Future<void> openMenu(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('tree-view-menu')));
    await tester.pumpAndSettle();
  }

  double top(WidgetTester tester, String text) => tester.getTopLeft(find.text(text)).dy;

  testWidgets('the view menu sorts the whole list after asking, with nothing selected', (tester) async {
    await pumpTree(tester);
    await openMenu(tester);
    // Select comes first, right under the button; the orders after it.
    expect(top(tester, 'Select'), lessThan(top(tester, 'Name (A–Z)')));
    expect(top(tester, 'Name (A–Z)'), lessThan(top(tester, 'Collapse all folders')));
    await tester.tap(find.text('Name (Z–A)'));
    await tester.pumpAndSettle();
    expect(find.text('Sort the whole list?'), findsOneWidget);
    await tester.tap(find.text('Sort').last);
    await tester.pumpAndSettle();
    // Every level, folders and connections, without selecting anything.
    expect(top(tester, 'CUSTOMER-B'), lessThan(top(tester, 'CUSTOMER-A')));
    expect(app.sortConnections(app.connections.where((c) => c.folderId == outer.id).toList()), [d2, d1]);
    app.dispose();
  });

  testWidgets('cancelling the question leaves the order alone', (tester) async {
    await pumpTree(tester);
    await openMenu(tester);
    await tester.tap(find.text('Name (Z–A)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(top(tester, 'CUSTOMER-A'), lessThan(top(tester, 'CUSTOMER-B')));
    app.dispose();
  });

  testWidgets('the view menu opens and closes every folder', (tester) async {
    await pumpTree(tester);
    expect(find.text('DEVICE-03'), findsNothing);
    await openMenu(tester);
    await tester.tap(find.text('Expand all folders'));
    await tester.pumpAndSettle();
    expect(find.text('DEVICE-03'), findsOneWidget, reason: 'inside a folder inside a folder');
    await openMenu(tester);
    await tester.tap(find.text('Collapse all folders'));
    await tester.pumpAndSettle();
    expect(find.text('DEVICE-01'), findsNothing);
    app.dispose();
  });

  testWidgets('the chips show only one kind, and a second click shows all again', (tester) async {
    await pumpTree(tester);
    await tester.tap(find.byKey(const ValueKey('tree-filter-rdp')));
    await tester.pumpAndSettle();
    expect(find.text('SERVER-01'), findsOneWidget);
    expect(find.text('DEVICE-01'), findsNothing);
    expect(find.text('CUSTOMER-A'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('tree-filter-ssh')));
    await tester.pumpAndSettle();
    expect(find.text('DEVICE-03'), findsOneWidget, reason: 'found at any depth');
    expect(find.text('SERVER-01'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('tree-filter-ssh')));
    await tester.pumpAndSettle();
    expect(find.text('CUSTOMER-A'), findsOneWidget);
    expect(find.text('SERVER-01'), findsOneWidget);
    app.dispose();
  });

  testWidgets('the favorites chip appears once there is a favorite', (tester) async {
    await pumpTree(tester);
    expect(find.byKey(const ValueKey('tree-filter-favorites')), findsNothing);
    await app.toggleFavorite(d2.id);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('tree-filter-favorites')));
    await tester.pumpAndSettle();
    expect(find.text('DEVICE-02'), findsOneWidget);
    expect(find.text('DEVICE-01'), findsNothing);
    app.dispose();
  });
}
