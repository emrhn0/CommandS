import 'dart:convert';
import 'dart:io';

import 'package:commands/services/update_service.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

/// The update ends by running what was downloaded, so a release that
/// published SHA256SUMS.txt is never installed without matching it.
void main() {
  late Directory dir;
  late File build;
  late String hash;

  UpdateInfo info({String? checksumsUrl = 'https://example.invalid/SHA256SUMS.txt'}) => UpdateInfo(
        version: 'v9.9.9',
        releaseUrl: 'https://example.invalid',
        notes: '',
        assetName: 'CommandS-Setup.exe',
        assetUrl: 'https://example.invalid/CommandS-Setup.exe',
        assetSize: 0,
        checksumsUrl: checksumsUrl,
        method: UpdateMethod.windowsInstaller,
      );

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('commands-update-');
    build = File('${dir.path}${Platform.pathSeparator}CommandS-Setup.exe');
    final bytes = List<int>.generate(2 * 1024 * 1024, (i) => i % 251);
    await build.writeAsBytes(bytes);
    hash = sha256.convert(bytes).toString();
  });

  tearDown(() async {
    UpdateService.fetchChecksums = (_) async => null;
    await dir.delete(recursive: true);
  });

  test('a matching checksum passes', () async {
    UpdateService.fetchChecksums = (_) async => utf8.encode('$hash *CommandS-Setup.exe\n');
    expect(await UpdateService.verifyDownload(info(), build), isNull);
  });

  test('a different checksum stops the update', () async {
    UpdateService.fetchChecksums = (_) async => utf8.encode('${'0' * 64}  CommandS-Setup.exe\n');
    expect(await UpdateService.verifyDownload(info(), build), contains('checksum'));
  });

  test('a checksum file that cannot be read stops the update', () async {
    UpdateService.fetchChecksums = (_) async => null;
    expect(await UpdateService.verifyDownload(info(), build), isNotNull);
  });

  test('a checksum file that does not list the build stops the update', () async {
    UpdateService.fetchChecksums = (_) async => utf8.encode('$hash  CommandS-portable.zip\n');
    expect(await UpdateService.verifyDownload(info(), build), isNotNull);
  });

  test('a release from before checksums is still accepted on size', () async {
    UpdateService.fetchChecksums = (_) async => throw StateError('not asked');
    expect(await UpdateService.verifyDownload(info(checksumsUrl: null), build), isNull);
  });
}
