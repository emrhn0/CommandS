import 'package:commands/models/models.dart';
import 'package:commands/providers/app_state.dart';
import 'package:commands/theme/app_theme.dart';
import 'package:commands/widgets/new_connection_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('editing a connection: switch to RDP, set options, save in place', (tester) async {
    tester.view.physicalSize = const Size(1000, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final app = AppState();
    await tester.pump();
    final folder = ConnectionFolder(name: 'CUSTOMER-A');
    final conn = SavedConnection(name: 'DEVICE-01', host: '192.0.2.10', username: 'admin', folderId: folder.id);
    app.folders.add(folder);
    app.connections.add(conn);

    await tester.pumpWidget(ChangeNotifierProvider.value(
      value: app,
      child: MaterialApp(
        theme: AppTheme.light(),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(onPressed: () => showEditConnectionDialog(context, conn), child: const Text('open')),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('Edit Connection'), findsOneWidget);
    expect(find.text('CONNECTION'), findsOneWidget);
    expect(find.text('CUSTOMER-A'), findsOneWidget);
    expect(find.text('Domain'), findsNothing);
    expect(find.text('Share clipboard'), findsNothing);

    await tester.tap(find.text('RDP'));
    await tester.pumpAndSettle();
    expect(find.text('Domain'), findsOneWidget);
    expect(find.text('3389'), findsOneWidget, reason: 'the default port follows the protocol');
    await tester.ensureVisible(find.text('Show wallpaper'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Show wallpaper'));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(OutlinedButton, 'Save'));
    await tester.pumpAndSettle();
    expect(find.text('Edit Connection'), findsNothing);
    final saved = app.connections.single;
    expect(saved.id, conn.id);
    expect(saved.protocol, ConnectionProtocol.rdp);
    expect(saved.port, 3389);
    expect(saved.rdpWallpaper, isTrue);
    expect(saved.folderId, folder.id);
  });
}
