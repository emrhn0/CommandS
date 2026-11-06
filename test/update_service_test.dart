import 'package:commands/app_version.dart';
import 'package:commands/services/update_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

UpdateInfo _info(String notes) => UpdateInfo(
      version: 'v9.9.9',
      releaseUrl: 'https://example.invalid',
      notes: notes,
      assetName: null,
      assetUrl: null,
      assetSize: 0,
      checksumsUrl: null,
      method: null,
    );

void main() {
  group('the automatic check, with the beta channel picked in Settings', () {
    Map<String, dynamic> release(String tag, {bool prerelease = false}) => {
      'tag_name': tag,
      'prerelease': prerelease,
      'draft': false,
      'assets': const [],
    };
    late Map<String, dynamic>? latest;

    setUp(() {
      SharedPreferences.setMockInitialValues({'commands.update.channel': 'beta'});
      UpdateService.fetchReleaseList = () async => [release('v99.0.0-beta.1', prerelease: true)];
      UpdateService.fetchLatest = () async => latest;
    });
    tearDown(() {
      UpdateService.fetchLatest = () async => null;
      UpdateService.fetchReleaseList = () async => null;
    });

    test('offers only a newer normal release', () async {
      latest = release('v98.0.0');
      expect((await UpdateService.check())?.version, 'v98.0.0');
    });

    test('says nothing about a beta when no normal release is newer', () async {
      latest = release('v0.0.1');
      expect(await UpdateService.check(), isNull);
    });

    test('Settings still finds the beta when asked', () async {
      latest = release('v0.0.1');
      final found = await UpdateService.checkNow();
      expect(found.info?.version, 'v99.0.0-beta.1');
      expect(found.info?.channel, ReleaseChannel.beta);
    });
  });

  group('compareVersions', () {
    test('orders by each numeric part', () {
      expect(UpdateService.compareVersions('v1.1.3', 'v1.1.2'), greaterThan(0));
      expect(UpdateService.compareVersions('v1.2.0', 'v1.1.9'), greaterThan(0));
      expect(UpdateService.compareVersions('v1.1.2', 'v1.1.2'), 0);
      expect(UpdateService.compareVersions('v1.0.25', 'v1.1.1'), lessThan(0));
    });

    test('a malformed tag never reads as newer', () {
      expect(UpdateService.compareVersions('garbage', 'v1.0.0'), lessThan(0));
      expect(UpdateService.compareVersions('v9.bad.0', 'v1.0.0'), lessThan(0));
    });

    test('orders beta builds before stable and by beta number', () {
      expect(UpdateService.compareVersions('v1.2.0-beta.2', 'v1.2.0-beta.1'), greaterThan(0));
      expect(UpdateService.compareVersions('v1.2.0-beta.2', 'v1.2.0'), lessThan(0));
      expect(UpdateService.compareVersions('v1.2.0', 'v1.2.0-beta.2'), greaterThan(0));
    });
  });

  test('selects newest published beta and rejects stable releases', () {
    Map<String, dynamic> release(String tag, {bool prerelease = true, bool draft = false}) => {
          'tag_name': tag,
          'prerelease': prerelease,
          'draft': draft,
        };
    final releases = [
      release('v1.3.0', prerelease: false),
      release('v1.4.0-beta.1', draft: true),
      release('v1.2.0-beta.2'),
      release('v1.2.0-beta.1'),
      release('v1.9.0-rc.1'),
    ];
    expect(UpdateService.selectRelease(releases, ReleaseChannel.beta)?['tag_name'], 'v1.2.0-beta.2');
    expect(UpdateService.selectRelease(releases, ReleaseChannel.stable)?['tag_name'], 'v1.3.0');
    expect(UpdateService.matchesChannel(release('v1.4.0-beta.1'), ReleaseChannel.stable), isFalse);
  });

  group('plainNotes', () {
    // Abridged from the real v1.1.1 release notes.
    const notes = '''CommandS 1.1.1

## What's new

**Automatic updates.** CommandS now checks for a new release when it starts.
- **Windows:** "Update now" downloads the installer.
- **macOS:** "Update now" downloads the new app.

> **Upgrading from 1.0.25 or earlier:** install this one by hand.

## Windows
- `..._Setup.exe` - installer. Recommended.

## macOS
1. Unzip `CommandS_1.1.1_macOS.zip`.
   ```
   xattr -dr com.apple.quarantine /Applications/CommandS.app
   ```
''';

    final plain = _info(notes).plainNotes;

    test('drops Markdown syntax', () {
      expect(plain, isNot(contains('**')));
      expect(plain, isNot(contains('##')));
      expect(plain, isNot(contains('`')));
      expect(plain, isNot(contains('> ')));
    });

    test('keeps what changed, as readable bullets', () {
      expect(plain, contains("What's new"));
      expect(plain, contains('Automatic updates. CommandS now checks'));
      expect(plain, contains('• Windows: "Update now" downloads the installer.'));
      expect(plain, contains('Upgrading from 1.0.25 or earlier: install this one by hand.'));
    });

    test('drops the manual download instructions', () {
      expect(plain, isNot(contains('Setup.exe')));
      expect(plain, isNot(contains('xattr')));
      expect(plain, isNot(contains('Unzip')));
    });
  });
}
