import 'package:commands/services/update_service.dart';
import 'package:flutter_test/flutter_test.dart';

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
  group('compareVersions', () {
    test('orders by each numeric part', () {
      expect(UpdateService.compareVersions('v1.1.3', 'v1.1.2'), greaterThan(0));
      expect(UpdateService.compareVersions('v1.2.0', 'v1.1.9'), greaterThan(0));
      expect(UpdateService.compareVersions('v1.1.2', 'v1.1.2'), 0);
      expect(UpdateService.compareVersions('v1.0.25', 'v1.1.1'), lessThan(0));
    });

    test('a malformed tag never reads as newer', () {
      expect(UpdateService.compareVersions('garbage', 'v1.0.0'), lessThan(0));
    });
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
