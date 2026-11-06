import 'package:commands/widgets/custom_title_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      (call) async => call.method == 'isMaximized' ? false : null,
    );
  });

  for (final width in [900.0, 1280.0, 1920.0]) {
    testWidgets('the name is in the middle of a $width px window', (tester) async {
      tester.view.physicalSize = Size(width, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(const MaterialApp(home: Scaffold(body: Column(children: [CustomTitleBar()]))));
      await tester.pump();
      final name = tester.getCenter(find.byKey(const ValueKey('title-bar-name')));
      expect((name.dx - width / 2).abs(), lessThan(1));
    });
  }
}
