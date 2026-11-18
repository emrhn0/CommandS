import 'package:commands/models/models.dart';
import 'package:commands/providers/app_state.dart';
import 'package:commands/theme/app_theme.dart';
import 'package:commands/widgets/connection_tree.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('capture IP sorting preview with example connections', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 520));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final app = AppState();
    await tester.pump();
    final folder = ConnectionFolder(name: 'CUSTOMER-A');
    app.folders.add(folder);
    final hosts = [
      SavedConnection(name: 'DEVICE-10', host: '192.0.2.10', folderId: folder.id),
      SavedConnection(name: 'DEVICE-02', host: '192.0.2.2', folderId: folder.id),
      SavedConnection(name: 'DEVICE-21', host: '192.0.2.21', folderId: folder.id),
      SavedConnection(name: 'DEVICE-03', host: '192.0.2.3', folderId: folder.id),
    ];
    app.connections.addAll(hosts);
    app.connectionOrder = hosts.map((c) => c.id).toList();
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: MaterialApp(
          theme: AppTheme.dark(),
          home: const Scaffold(body: ConnectionTree()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.chevron_right));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('select-mode')));
    await tester.pumpAndSettle();
    for (final host in hosts) {
      await tester.tap(find.text(host.name));
      await tester.pump();
    }
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('sort-selected-by-ip')));
    await tester.pumpAndSettle();
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer();
    await mouse.moveTo(tester.getCenter(find.byKey(const ValueKey('sort-selected-by-ip'))));
    await tester.pump(const Duration(seconds: 1));
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('ip-sort-preview.png'));
    await mouse.removePointer();
    await tester.pumpWidget(const SizedBox());
    app.dispose();
  });
}
