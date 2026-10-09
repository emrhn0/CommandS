import 'package:commands/models/models.dart';
import 'package:commands/services/rdp_session.dart';
import 'package:commands/widgets/rdp_embed_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // At any pane width -- a full window or one side of a split -- the bar's
  // buttons sit in the top-right corner of the session.
  for (final width in [480.0, 830.0, 1600.0]) {
    testWidgets('session bar buttons hug the right edge at $width px', (tester) async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('commands/rdp'),
        (call) async => call.method == 'create' ? 1 : (call.method == 'connect' ? true : null),
      );
      tester.view.physicalSize = Size(width, 300);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final c = RdpSessionController(
        SavedConnection(name: 'SERVER-01', host: '192.0.2.20', port: 3389, protocol: ConnectionProtocol.rdp),
      );
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: RdpEmbedView(controller: c, active: true))));
      for (var i = 0; i < 15; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      final button = tester.getRect(find.byIcon(Icons.refresh));
      expect(width - button.right, lessThan(30));
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    });
  }
}
