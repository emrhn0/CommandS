import 'dart:io';

import 'package:commands/theme/app_mark.dart';
import 'package:commands/widgets/custom_title_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      (call) async => call.method == 'isMaximized' ? false : null,
    );
  });

  String drawnAsset(WidgetTester tester) {
    final picture = tester.widget<SvgPicture>(
      find.descendant(of: find.byType(AppMark), matching: find.byType(SvgPicture)),
    );
    return (picture.bytesLoader as SvgAssetLoader).assetName;
  }

  Future<void> pumpBar(WidgetTester tester, ThemeMode mode) async {
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(brightness: Brightness.light),
      darkTheme: ThemeData(brightness: Brightness.dark),
      themeMode: mode,
      home: const Scaffold(body: Column(children: [CustomTitleBar()])),
    ));
    await tester.pump();
  }

  testWidgets('the title bar shows the same mark on a light and a dark theme', (tester) async {
    await pumpBar(tester, ThemeMode.light);
    expect(drawnAsset(tester), AppMark.asset);
    await pumpBar(tester, ThemeMode.dark);
    // MaterialApp fades from one theme to the other.
    await tester.pump(const Duration(seconds: 1));
    expect(drawnAsset(tester), AppMark.asset);
  });

  test('the mark is a listed asset, an SVG, and the only one', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    expect(pubspec, contains('- ${AppMark.asset}'));
    expect(File(AppMark.asset).readAsStringSync(), startsWith('<svg'));
    expect(pubspec, isNot(contains('commands_mark_light')));
    expect(pubspec, isNot(contains('commands_mark_dark')));
  });
}
