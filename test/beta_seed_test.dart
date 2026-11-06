import 'dart:convert';
import 'dart:io';

import 'package:commands/services/beta_seed.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late Directory dir;
  final stableConnections = jsonEncode([
    {'id': 'c1', 'name': 'DEVICE-01', 'host': '192.0.2.10', 'passwordEnc': 'v1:<SEALED>'},
  ]);

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('commands-seed');
    File('${dir.path}/stable.json').writeAsStringSync(jsonEncode({
      'flutter.commands.connections': stableConnections,
      'flutter.commands.folders': '[]',
      'flutter.commands.folderOrder': ['f1'],
      'flutter.commands.terminalFontSize': 14.0,
      'flutter.commands.update.channel': 'stable',
      'other.key': 'x',
    }));
    File('${dir.path}/stable.key').writeAsBytesSync([1, 2, 3]);
    BetaSeed.stablePrefsPath = '${dir.path}/stable.json';
    BetaSeed.stableKeyPath = '${dir.path}/stable.key';
    BetaSeed.betaKeyPath = '${dir.path}/beta/password.key';
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('an empty beta gets the normal app\'s connections, settings and key', () async {
    SharedPreferences.setMockInitialValues({});
    await BetaSeed.run(force: true);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('commands.connections'), stableConnections);
    expect(prefs.getStringList('commands.folderOrder'), ['f1']);
    expect(prefs.getDouble('commands.terminalFontSize'), 14.0);
    expect(prefs.getString('commands.update.channel'), isNull, reason: 'update state stays its own');
    expect(File('${dir.path}/beta/password.key').readAsBytesSync(), [1, 2, 3]);
  });

  test('only once, and never over the beta\'s own connections or key', () async {
    SharedPreferences.setMockInitialValues({'commands.connections': '[{"id":"own"}]'});
    Directory('${dir.path}/beta').createSync();
    File('${dir.path}/beta/password.key').writeAsBytesSync([9]);
    await BetaSeed.run(force: true);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('commands.connections'), '[{"id":"own"}]');
    expect(File('${dir.path}/beta/password.key').readAsBytesSync(), [9]);

    // Emptied later, it is still not filled again.
    await prefs.setString('commands.connections', '[]');
    await BetaSeed.run(force: true);
    expect(prefs.getString('commands.connections'), '[]');
  });

  test('the normal app is never touched', () async {
    SharedPreferences.setMockInitialValues({});
    final before = File('${dir.path}/stable.json').readAsStringSync();
    await BetaSeed.run(force: true);
    expect(File('${dir.path}/stable.json').readAsStringSync(), before);
    expect(File('${dir.path}/stable.key').readAsBytesSync(), [1, 2, 3]);
  });
}
