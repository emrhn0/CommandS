import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:commands/models/models.dart';
import 'package:commands/services/password_vault.dart';
import 'package:commands/services/storage_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _BrokenKeyStore implements KeyStore {
  @override
  Future<Uint8List?> read() async => throw StateError('store unavailable');

  @override
  Future<void> write(Uint8List key) async => throw StateError('store unavailable');
}

void main() {
  const secret = 'example-secret-value';

  setUp(() {
    PasswordVault.storeOverride = MemoryKeyStore();
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(() => PasswordVault.storeOverride = null);

  SavedConnection connection() => SavedConnection(
    id: 'id-1',
    name: 'DEVICE-01',
    host: '192.0.2.10',
    rememberPassword: true,
    password: secret,
  );

  Future<String> stored() async => (await SharedPreferences.getInstance()).getString('commands.connections')!;

  test('a remembered password is not saved in plain text, and comes back', () async {
    await StorageService().saveConnections([connection()]);
    final raw = await stored();
    expect(raw, isNot(contains(secret)));
    expect((jsonDecode(raw) as List).single['password'], '');
    final loaded = await StorageService().loadConnections();
    expect(loaded.single.password, secret);
  });

  test('a password saved in plain text by an older version is moved over', () async {
    final old = connection().toJson();
    SharedPreferences.setMockInitialValues({
      'commands.connections': jsonEncode([old]),
    });
    final storage = StorageService();
    final loaded = await storage.loadConnections();
    expect(loaded.single.password, secret);
    expect(storage.needsPasswordMigration, isTrue);
    await storage.saveConnections(loaded);
    expect(storage.needsPasswordMigration, isFalse);
    expect(await stored(), isNot(contains(secret)));
    expect((await StorageService().loadConnections()).single.password, secret);
  });

  test('a value cannot be moved onto another connection', () async {
    final vault = PasswordVault(MemoryKeyStore());
    final sealed = await vault.encrypt(secret, 'id-1');
    expect(await vault.decrypt(sealed, 'id-1'), secret);
    expect(() => vault.decrypt(sealed, 'id-2'), throwsA(anything));
  });

  test('when the key cannot be read, the encrypted value survives a save', () async {
    await StorageService().saveConnections([connection()]);
    final before = (jsonDecode(await stored()) as List).single['passwordEnc'];
    PasswordVault.storeOverride = _BrokenKeyStore();
    final storage = StorageService();
    final loaded = await storage.loadConnections();
    expect(loaded.single.password, '');
    await storage.saveConnections(loaded);
    expect((jsonDecode(await stored()) as List).single['passwordEnc'], before);
  });

  test('when encryption is unavailable the password is kept, and retried later', () async {
    PasswordVault.storeOverride = _BrokenKeyStore();
    final storage = StorageService();
    await storage.saveConnections([connection()]);
    expect(storage.needsPasswordMigration, isTrue);
    expect((jsonDecode(await stored()) as List).single['password'], secret);
  });

  test('forgetting a password removes it', () async {
    final c = connection();
    final storage = StorageService();
    await storage.saveConnections([c]);
    c
      ..rememberPassword = false
      ..password = '';
    await storage.saveConnections([c]);
    final json = (jsonDecode(await stored()) as List).single as Map<String, dynamic>;
    expect(json.containsKey('passwordEnc'), isFalse);
  });

  test('the Windows store round-trips through DPAPI', () async {
    final dir = await Directory.systemTemp.createTemp('commands-key');
    addTearDown(() => dir.delete(recursive: true));
    final store = DpapiKeyStore(path: '${dir.path}\\password.key');
    expect(await store.read(), isNull);
    final key = Uint8List.fromList(List.generate(32, (i) => i));
    await store.write(key);
    expect(await File('${dir.path}\\password.key').readAsBytes(), isNot(key));
    expect(await store.read(), key);
  }, skip: !Platform.isWindows);
}
