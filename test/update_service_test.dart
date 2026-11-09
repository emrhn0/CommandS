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
  group('the check', () {
    late List<String> tags;
    final asked = <String>[];

    setUp(() {
      asked.clear();
      UpdateService.fetchTags = () async => tags;
      UpdateService.fetchRelease = (tag) async {
        asked.add(tag);
        return {'tag_name': tag, 'draft': false, 'assets': const []};
      };
    });
    tearDown(() {
      UpdateService.fetchTags = () async => null;
      UpdateService.fetchRelease = (_) async => null;
    });

    test('without beta updates, only a newer normal release is offered', () async {
      SharedPreferences.setMockInitialValues({});
      tags = ['v99.0.0-beta.2', 'v98.0.0', 'v0.0.1'];
      expect((await UpdateService.check())?.version, 'v98.0.0');
      tags = ['v99.0.0-beta.2', 'v0.0.1'];
      expect(await UpdateService.check(), isNull);
    });

    test('with beta updates on, the newest of both is offered', () async {
      SharedPreferences.setMockInitialValues({'commands.update.channel': 'beta'});
      tags = ['v99.0.0-beta.2', 'v99.0.0-beta.1', 'v98.0.0'];
      final found = await UpdateService.check();
      expect(found?.version, 'v99.0.0-beta.2');
      expect(found?.channel, ReleaseChannel.beta);
      tags = ['v99.0.0', 'v99.0.0-beta.2'];
      expect((await UpdateService.check())?.version, 'v99.0.0', reason: 'the normal release that follows a beta');
    });

    test('nothing newer: the API is not asked at all', () async {
      SharedPreferences.setMockInitialValues({'commands.update.channel': 'beta'});
      tags = ['v0.0.1', 'v0.0.1-beta.1'];
      expect(await UpdateService.check(), isNull);
      expect(asked, isEmpty);
    });

    test('a feed that cannot be read is a failed check, not an update', () async {
      UpdateService.fetchTags = () async => null;
      expect((await UpdateService.checkNow()).failed, isTrue);
    });

    test('tags are read from the releases feed', () {
      const feed = '<?xml version="1.0" encoding="UTF-8"?><feed xmlns="http://www.w3.org/2005/Atom">'
          '<link type="text/html" rel="alternate" href="https://github.com/example/app/releases"/>'
          '<entry><link rel="alternate" type="text/html" href="https://github.com/example/app/releases/tag/v2.0.0"/></entry>'
          '<entry><link rel="alternate" type="text/html" href="https://github.com/example/app/releases/tag/v2.1.0-beta.1"/></entry>'
          '</feed>';
      expect(UpdateService.tagsFromFeed(feed), ['v2.0.0', 'v2.1.0-beta.1']);
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
