import 'dart:async';

import 'package:commands/services/rdp_session.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// What the Dart side asked the native RDP host (windows/runner/rdp_plugin.cpp)
/// to do, with captureFrames answered by [capture].
List<String> _record(Future<Object?> Function() capture) {
  final calls = <String>[];
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(const MethodChannel('commands/rdp'), (call) async {
    switch (call.method) {
      case 'captureFrames':
        calls.add('capture');
        return capture();
      case 'setSuspended':
        calls.add('suspend ${(call.arguments as Map)['suspended']}');
    }
    return null;
  });
  return calls;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('sessions step aside even when their picture never comes', () async {
    // The case behind the update prompt: the picture taken before hiding the
    // sessions did not arrive, and the session stayed in front of the dialog.
    final never = Completer<Object?>();
    final calls = _record(() => never.future);
    RdpChannel.instance.holdSuspended(true);
    addTearDown(() => RdpChannel.instance.holdSuspended(false));
    await Future<void>.delayed(RdpChannel.captureTimeout + const Duration(milliseconds: 100));
    expect(calls, containsAllInOrder(['capture', 'suspend true']));
  });

  test('a picture comes first, then the sessions step aside at once', () async {
    final calls = _record(() async => <Object?>[]);
    RdpChannel.instance.holdSuspended(true);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(calls, ['capture', 'suspend true']);
    RdpChannel.instance.holdSuspended(false);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(calls.last, 'suspend false');
  });

  test('while held, stepping aside is said again; once let go, it stops', () async {
    final calls = _record(() async => <Object?>[]);
    RdpChannel.instance.holdSuspended(true);
    await Future<void>.delayed(RdpChannel.reassertEvery * 2.5);
    expect(calls.where((c) => c == 'suspend true').length, greaterThanOrEqualTo(3),
        reason: 'a session that came back meanwhile is hidden again');
    RdpChannel.instance.holdSuspended(false);
    final count = calls.length;
    await Future<void>.delayed(RdpChannel.reassertEvery * 2);
    expect(calls.length, count, reason: 'nothing after the hold ends');
    expect(calls.last, 'suspend false');
  });

  test('two holds: the sessions come back only when both are gone', () async {
    final calls = _record(() async => <Object?>[]);
    RdpChannel.instance.holdSuspended(true);
    RdpChannel.instance.holdSuspended(true);
    RdpChannel.instance.holdSuspended(false);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(calls, isNot(contains('suspend false')));
    RdpChannel.instance.holdSuspended(false);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(calls.last, 'suspend false');
  });
}
