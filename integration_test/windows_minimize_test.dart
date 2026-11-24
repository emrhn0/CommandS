import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:window_manager/window_manager.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('minimizing hides the Flutter view and restoring enables frames', (tester) async {
    await windowManager.ensureInitialized();
    await windowManager.setTitleBarStyle(TitleBarStyle.hidden);
    await tester.pumpWidget(const ColoredBox(color: Colors.blue));
    await windowManager.show();

    Future<void> waitUntil(bool Function() condition, String reason) async {
      await tester.runAsync(() async {
        final timer = Stopwatch()..start();
        while (!condition() && timer.elapsed < const Duration(seconds: 3)) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      expect(condition(), isTrue, reason: reason);
    }

    try {
      await windowManager.minimize();
      await waitUntil(() => binding.lifecycleState == AppLifecycleState.hidden,
          'the child Flutter view must also become hidden');
      expect(await windowManager.isMinimized(), isTrue);
      expect(binding.framesEnabled, isFalse);
    } finally {
      await windowManager.restore();
    }

    await waitUntil(() => binding.framesEnabled, 'restoring the window must allow frames again');
    expect(await windowManager.isMinimized(), isFalse);
  }, skip: !Platform.isWindows);
}
