import 'package:commands/theme/wordmark.dart';
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

  testWidgets('with a search box in the middle, the name moves to the start', (tester) async {
    tester.view.physicalSize = const Size(1280, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: Column(children: [CustomTitleBar(center: SizedBox(key: Key('middle'), width: 300, height: 20))])),
    ));
    await tester.pump();
    final name = tester.getRect(find.byKey(const ValueKey('title-bar-name')));
    final middle = tester.getCenter(find.byKey(const Key('middle')));
    expect(name.left, lessThan(24));
    expect((middle.dx - 640).abs(), lessThan(1));
    final word = tester.widget<Text>(find.descendant(of: find.byKey(const ValueKey('title-bar-name')), matching: find.byType(Text)).first);
    expect(word.data, 'CommandS');
    expect(word.style!.fontFamily, wordmarkFontFamily);
    // Tests build the normal app: no Beta tag.
    expect(find.byKey(const ValueKey('title-bar-beta')), findsNothing);
  });
}
