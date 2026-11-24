import 'package:commands/models/models.dart';
import 'package:commands/providers/app_state.dart';
import 'package:commands/services/storage_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<AppState> start() async {
    SharedPreferences.setMockInitialValues({});
    final app = AppState();
    await app.ready;
    return app;
  }

  /// The same entry as a file without passwords brings it, as the import
  /// dialog leaves it for an entry whose password is not ticked.
  SavedConnection withoutLogin(SavedConnection c) => SavedConnection.fromJson(c.toJson())
    ..password = ''
    ..rememberPassword = false
    ..enablePassword = ''
    ..credentialProfileId = null;

  group('importing an entry that is already here', () {
    test('without passwords keeps the password remembered here', () async {
      final app = await start();
      final c = SavedConnection(name: 'DEVICE-01', host: '192.0.2.10', username: 'user',
          rememberPassword: true, password: 'example-password', enablePassword: 'example-enable');
      await app.upsertConnection(c);
      await app.importParsed(const [], [withoutLogin(c)..name = 'DEVICE-01 renamed']);
      final now = app.connections.single;
      expect(now.name, 'DEVICE-01 renamed', reason: 'the rest of the file still applies');
      expect(now.password, 'example-password');
      expect(now.rememberPassword, isTrue);
      expect(now.enablePassword, 'example-enable');
    });

    test('without passwords keeps the credential profile it uses', () async {
      final app = await start();
      final profile = CredentialProfile(name: 'Shared', username: 'user', password: 'example-password');
      await app.upsertProfile(profile);
      final c = SavedConnection(name: 'DEVICE-01', host: '192.0.2.10', credentialProfileId: profile.id);
      await app.upsertConnection(c);
      await app.importParsed(const [], [withoutLogin(c)..username = 'user']);
      expect(app.connections.single.credentialProfileId, profile.id);
      expect(app.resolved(app.connections.single).password, 'example-password');
    });

    test('pointed at another host, it does not take the saved password along', () async {
      final app = await start();
      final c = SavedConnection(name: 'DEVICE-01', host: '192.0.2.10', username: 'user',
          rememberPassword: true, password: 'example-password', enablePassword: 'example-enable');
      await app.upsertConnection(c);
      await app.importParsed(const [], [withoutLogin(c)..host = '198.51.100.10']);
      final now = app.connections.single;
      expect(now.host, '198.51.100.10');
      expect(now.password, isEmpty);
      expect(now.enablePassword, isEmpty);
    });

    test('with another user, it does not take the saved password along', () async {
      final app = await start();
      final c = SavedConnection(name: 'DEVICE-01', host: '192.0.2.10', username: 'user',
          rememberPassword: true, password: 'example-password');
      await app.upsertConnection(c);
      await app.importParsed(const [], [withoutLogin(c)..username = 'other']);
      expect(app.connections.single.password, isEmpty);
    });

    test('a password in the file replaces the one here', () async {
      final app = await start();
      final c = SavedConnection(name: 'DEVICE-01', host: '192.0.2.10', username: 'user',
          rememberPassword: true, password: 'example-password');
      await app.upsertConnection(c);
      await app.importParsed(const [], [
        SavedConnection.fromJson(c.toJson())..password = 'example-new-password',
      ]);
      expect(app.connections.single.password, 'example-new-password');
    });
  });

  group('exporting a connection that uses a credential profile', () {
    Future<(AppState, SavedConnection)> setUpProfile() async {
      final app = await start();
      final profile = CredentialProfile(name: 'Shared', username: 'user', password: 'example-password');
      await app.upsertProfile(profile);
      final c = SavedConnection(name: 'DEVICE-01', host: '192.0.2.10', credentialProfileId: profile.id);
      await app.upsertConnection(c);
      return (app, c);
    }

    Future<SavedConnection> importedElsewhere(String json) async {
      final other = await start();
      final parsed = StorageService().parseJson(json);
      await other.importParsed(parsed.folders, parsed.connections);
      return other.resolved(other.connections.single);
    }

    test('with passwords, the file carries the profile login', () async {
      final (app, c) = await setUpProfile();
      final login = await importedElsewhere(app.exportAll(passwordIds: {c.id}));
      expect(login.username, 'user');
      expect(login.password, 'example-password');
      expect(login.credentialProfileId, isNull, reason: 'profiles are not exported');
    });

    test('without passwords, the file still carries the user name', () async {
      final (app, c) = await setUpProfile();
      final login = await importedElsewhere(app.exportAll(passwordIds: <String>{}));
      expect(login.username, 'user');
      expect(login.password, isEmpty);
    });

    test('in CSV and XML too', () async {
      final (app, c) = await setUpProfile();
      final storage = StorageService();
      final xml = storage.parseXml(app.exportAllXml(passwordIds: {c.id})).connections.single;
      expect((xml.username, xml.password), ('user', 'example-password'));
      final csv = storage.parseCsv(app.exportAllCsv(passwordIds: {c.id})).connections.single;
      expect((csv.username, csv.password), ('user', 'example-password'));
    });

    test('the connection here keeps using its profile', () async {
      final (app, c) = await setUpProfile();
      app.exportAll(passwordIds: {c.id});
      expect(app.connections.single.credentialProfileId, isNotNull);
      expect(app.connections.single.username, isEmpty);
    });
  });
}
