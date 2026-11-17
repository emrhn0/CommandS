import 'dart:ui' as ui;

import 'package:commands/models/models.dart';
import 'package:commands/services/rdp_session.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => RdpStartQueue.instance = RdpStartQueue(spacing: Duration.zero));

  test('moving a session to a new pane does not hide it', () async {
    // Stand in for windows/runner/rdp_plugin.cpp and record what the Dart
    // side asks the native window to do.
    final visibility = <bool>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('commands/rdp'), (call) async {
      switch (call.method) {
        case 'create':
          return 1;
        case 'connect':
          return true;
        case 'setVisible':
          visibility.add((call.arguments as Map)['visible'] as bool);
      }
      return null;
    });

    final controller = RdpSessionController(
      SavedConnection(name: 'test', host: '192.0.2.10', port: 3389, protocol: ConnectionProtocol.rdp),
    );
    addTearDown(controller.dispose);

    final oldPane = Object();
    controller.attachView(oldPane, showing: true);
    controller.reposition(const ui.Rect.fromLTWH(0, 0, 1000, 700), 1);
    await Future<void>.delayed(Duration.zero);

    // Applying a split: Flutter mounts the pane's new view, *then* disposes
    // the old one.
    final newPane = Object();
    controller.attachView(newPane, showing: true);
    controller.attachView(oldPane, showing: false);

    expect(visibility.where((v) => !v), isEmpty, reason: 'the session window was hidden');

    // And once no view shows it any more (tab switched away), it is hidden.
    controller.attachView(newPane, showing: false);
    expect(visibility.last, isFalse);
  });

  test('a session opened behind other tabs stays hidden, even when its start timer fires', () async {
    final calls = <String>[];
    var created = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('commands/rdp'), (call) async {
      final args = call.arguments is Map ? call.arguments as Map : const {};
      switch (call.method) {
        case 'create':
          return ++created;
        case 'connect':
          return true;
        case 'setVisible':
          calls.add('visible ${args['id']} ${args['visible']}');
      }
      return null;
    });
    RdpStartQueue.instance = RdpStartQueue(spacing: Duration.zero);

    // Open all connections: several sessions, no view built for any yet.
    final sessions = [
      for (final h in ['192.0.2.21', '192.0.2.22', '192.0.2.23'])
        RdpSessionController(SavedConnection(name: h, host: h, port: 3389, protocol: ConnectionProtocol.rdp)),
    ];
    for (final s in sessions) {
      addTearDown(s.dispose);
    }
    // Past the fallback timer that starts a session no pane has measured.
    await Future<void>.delayed(const Duration(milliseconds: 1400));
    expect(created, 3);
    expect(calls.where((c) => c.endsWith('true')), isEmpty,
        reason: 'a window nobody looks at stood over the app');
  });

  test('sessions start one after another, a moment apart', () async {
    final queue = RdpStartQueue(spacing: const Duration(milliseconds: 200));
    final log = <String>[];
    final watch = Stopwatch()..start();
    Future<void> start(String id) async {
      log.add('start $id ${watch.elapsedMilliseconds ~/ 100}');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      log.add('done $id');
    }

    await Future.wait([queue.run(() => start('a')), queue.run(() => start('b')), queue.run(() => throw StateError('x')), queue.run(() => start('c'))]);
    expect(log.where((l) => l.startsWith('done')), ['done a', 'done b', 'done c']);
    expect(log[0], 'start a 0');
    expect(log[1], 'done a');
    // b waits for a to finish and then the spacing.
    expect(int.parse(log[2].split(' ').last), greaterThanOrEqualTo(2));
  });
}
