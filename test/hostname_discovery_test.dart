import 'dart:async';
import 'dart:io';

import 'package:commands/services/hostname_discovery.dart';
import 'package:commands/services/session_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('reads Linux, ESXi and network device prompts', () {
    expect(hostnameFromPrompt('Welcome\nuser@DEVICE-01:~\$ '), 'DEVICE-01');
    expect(hostnameFromPrompt('\x1b[32m[root@ESXI-01:~]\x1b[0m '), 'ESXI-01');
    expect(hostnameFromPrompt('HP-5406Rzl2#'), 'HP-5406Rzl2');
    expect(hostnameFromPrompt('SWITCH-01(config-if)#'), 'SWITCH-01');
    expect(hostnameFromPrompt('<HUAWEI-01>'), 'HUAWEI-01');
    expect(hostnameFromPrompt('admin@PA-01>'), 'PA-01');
  });

  test('does not turn banners, login questions or IP prompts into names', () {
    expect(hostnameFromPrompt('Please register your device now.'), isNull);
    expect(hostnameFromPrompt('Password:'), isNull);
    expect(hostnameFromPrompt('Press any key to continue'), isNull);
    expect(hostnameFromPrompt('user@192.0.2.10:~\$'), isNull);
    expect(hostnameFromPrompt('PS C:\\Users\\user>'), isNull);
  });

  test('collects split output and returns one result', () async {
    final output = StreamController<String>.broadcast(sync: true);
    final status = StreamController<SessionStatus>.broadcast(sync: true);
    final results = <HostnameDiscoveryResult>[];
    final watcher = HostnameDiscovery(
      output: output.stream,
      status: status.stream,
      onResult: results.add,
    );
    output.add('Welcome\r\nuser@DEV');
    expect(results, isEmpty);
    output.add('ICE-01:~\$ ');
    expect(results.single.hostname, 'DEVICE-01');
    output.add('user@DEVICE-02:~\$ ');
    status.add(SessionStatus.closed);
    expect(results, hasLength(1));
    watcher.dispose();
    await output.close();
    await status.close();
  });

  testWidgets('times out with a reason and output count', (tester) async {
    final output = StreamController<String>.broadcast(sync: true);
    final status = StreamController<SessionStatus>.broadcast(sync: true);
    final results = <HostnameDiscoveryResult>[];
    HostnameDiscovery(
      output: output.stream,
      status: status.stream,
      timeout: const Duration(seconds: 5),
      onResult: results.add,
    );
    output.add('Welcome to the system');
    await tester.pump(const Duration(seconds: 5));
    expect(results.single.hostname, isNull);
    expect(results.single.reason, 'timeout');
    expect(results.single.outputChars, 'Welcome to the system'.length);
    await output.close();
    await status.close();
  });

  testWidgets('does not count time while waiting for the login name', (
    tester,
  ) async {
    final output = StreamController<String>.broadcast(sync: true);
    final status = StreamController<SessionStatus>.broadcast(sync: true);
    final results = <HostnameDiscoveryResult>[];
    HostnameDiscovery(
      output: output.stream,
      status: status.stream,
      timeout: const Duration(seconds: 5),
      onResult: results.add,
    );
    await tester.pump(const Duration(seconds: 10));
    expect(results, isEmpty);
    status.add(SessionStatus.running);
    await tester.pump(const Duration(seconds: 5));
    expect(results.single.reason, 'timeout');
    await output.close();
    await status.close();
  });

  test('writes a local diagnostic without terminal or target text', () async {
    final directory = await Directory.systemTemp.createTemp(
      'commands_hostname_test_',
    );
    try {
      final log = HostnameDetectionLog(directory: directory);
      await log.record(
        connectionId: 'connection-01',
        reason: 'timeout',
        outputChars: 42,
        device: 'linux',
      );
      final text = await File(
        '${directory.path}${Platform.pathSeparator}hostname-detection.log',
      ).readAsString();
      expect(
        text,
        contains(
          'connection=connection-01 reason=timeout outputChars=42 device=linux',
        ),
      );
      expect(text, isNot(contains('192.0.2.10')));
      expect(text, isNot(contains('Password')));
    } finally {
      await directory.delete(recursive: true);
    }
  });
}
