import 'package:commands/models/models.dart';
import 'package:commands/services/mac_rdp_session.dart';
import 'package:commands/services/mcp_command_policy.dart';
import 'package:commands/services/session_log.dart';
import 'package:commands/services/ssh_options.dart';
import 'package:commands/widgets/sftp_browser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('MCP read-only policy', () {
    test('control characters never run without asking', () {
      expect(runsWithoutAsking('show \u0015configure terminal', DeviceKind.cisco), isFalse);
      expect(runsWithoutAsking('show \u007f\u007f\u007f\u007f\u007freload', DeviceKind.cisco), isFalse);
      expect(runsWithoutAsking('show\tversion', DeviceKind.cisco), isFalse);
      expect(runsWithoutAsking('show version\u2028reload', DeviceKind.cisco), isFalse);
      expect(hasHiddenCharacters('show \u202Eversion'), isTrue);
      expect(runsWithoutAsking('show version', DeviceKind.cisco), isTrue);
    });

    test('command substitution always asks', () {
      expect(runsWithoutAsking(r'get $(id)', DeviceKind.fortinet), isFalse);
      expect(runsWithoutAsking(r'show ${HOME}', DeviceKind.cisco), isFalse);
      expect(runsWithoutAsking(r'show run | include ^interface$', DeviceKind.cisco), isTrue);
    });
  });

  test('known_hosts path with a space stays one file for OpenSSH', () {
    expect(
      knownHostsOption(r'C:\Users\user 1\AppData\Roaming\CommandS\known_hosts',
          home: r'C:\Users\user 1'),
      '~/AppData/Roaming/CommandS/known_hosts',
    );
    expect(knownHostsOption(r'D:\Data Dir\known_hosts', home: r'C:\Users\user1'), '"D:/Data Dir/known_hosts"');
    expect(knownHostsOption(r'C:\Users\user1\x\known_hosts', home: r'C:\Users\user1'),
        'C:/Users/user1/x/known_hosts');
  });

  test('askpass batch file never passes the server prompt to cmd.exe', () {
    expect(windowsAskpassCmd.contains('%'), isTrue); // only %~dp0
    expect(windowsAskpassCmd.contains('%*'), isFalse);
    expect(RegExp(r'%[0-9*]').hasMatch(windowsAskpassCmd), isFalse);
  });

  test('remote file names that leave the folder are refused', () {
    for (final name in [r'..\..\x.cmd', r'AppData\Roaming\x', 'a/b', 'C:x', '..', 'NUL', 'nul.txt', 'x.', 'x ']) {
      expect(isSafeLocalName(name, windows: true), isFalse, reason: name);
    }
    expect(isSafeLocalName('report.pdf', windows: true), isTrue);
    expect(isSafeLocalName(r'a\b', windows: false), isTrue);
  });

  test('log cleaner bounds device-chosen cursor moves', () {
    final cleaner = TerminalTextCleaner();
    final watch = Stopwatch()..start();
    final out = cleaner.clean('\x1B[9999999999Gx\x1B[3000000000@y\x1B[999999999Bz\r\n');
    expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
    expect(out.length, lessThan(70000 * 3));
  });

  test('a line break in an imported RDP host adds no .rdp settings', () {
    final text = MacRdpSessionController.rdpFileContents(
      host: '192.0.2.10\ndrivestoredirect:s:*',
      port: 3389,
      user: 'DEVICE-01\ngatewayhostname:s:198.51.100.5',
      clipboard: false,
      wallpaper: false,
    );
    expect(text.split('\n').where((l) => l.startsWith('drivestoredirect')), isEmpty);
    expect(text.split('\n').where((l) => l.startsWith('gatewayhostname')), isEmpty);
    expect(text, contains('authentication level:i:2'));
  });
}
