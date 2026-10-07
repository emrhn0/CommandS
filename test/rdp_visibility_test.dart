import 'dart:ui' as ui;

import 'package:commands/models/models.dart';
import 'package:commands/services/rdp_session.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
}
