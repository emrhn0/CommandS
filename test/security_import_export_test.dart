import 'package:commands/models/models.dart';
import 'package:commands/providers/app_state.dart';
import 'package:commands/services/rdm_import.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppState app;
  late SavedConnection conn;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    app = AppState();
    await Future<void>.delayed(Duration.zero);
    conn = SavedConnection(name: 'DEVICE-01', host: '192.0.2.10', username: 'user1')
      ..password = 'example-secret-value'
      ..rememberPassword = true
      ..enablePassword = 'example-enable-value'
      ..credentialProfileId = 'profile-1';
    app.connections.add(conn);
  });

  test('exports leave passwords out unless picked', () {
    for (final out in [
      app.exportAll(connectionIds: {conn.id}, passwordIds: {}),
      app.exportAllXml(connectionIds: {conn.id}, passwordIds: {}),
      app.exportAllCsv(connectionIds: {conn.id}, passwordIds: {}),
    ]) {
      expect(out, isNot(contains('example-secret-value')));
      expect(out, isNot(contains('example-enable-value')));
      expect(out, isNot(contains('profile-1')));
    }
    expect(app.exportAll(connectionIds: {conn.id}, passwordIds: {conn.id}), contains('example-secret-value'));
    // The live connection keeps its secrets.
    expect(conn.password, 'example-secret-value');
  });

  test('an RDM import that moves a known entry to another host drops its password', () async {
    final moved = SavedConnection(id: conn.id, name: 'DEVICE-01', host: '198.51.100.20', username: 'user1');
    await app.importRdm(RdmImportResult(
        folders: const [], connections: [moved], skippedUnsupported: 0, passwordsNotImported: 0));
    final now = app.connections.firstWhere((c) => c.id == conn.id);
    expect(now.host, '198.51.100.20');
    expect(now.password, isEmpty);
    expect(now.rememberPassword, isFalse);
  });

  test('an RDM re-import of the same host keeps the password', () async {
    final same = SavedConnection(id: conn.id, name: 'DEVICE-01', host: '192.0.2.10', username: 'user1');
    await app.importRdm(RdmImportResult(
        folders: const [], connections: [same], skippedUnsupported: 0, passwordsNotImported: 0));
    expect(app.connections.firstWhere((c) => c.id == conn.id).password, 'example-secret-value');
  });
}
