import 'dart:io';
import 'dart:ui' as ui;

import 'package:commands/providers/app_state.dart';
import 'package:commands/screens/home_screen.dart';
import 'package:commands/services/update_service.dart';
import 'package:commands/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('New Connection shares header with Settings and opens its dialog', (tester) async {
    SharedPreferences.setMockInitialValues({});
    UpdateService.available.value = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      (call) async => call.method == 'isMaximized' ? false : null,
    );
    tester.view.physicalSize = const Size(900, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    addTearDown(() => UpdateService.available.value = null);

    final captureKey = GlobalKey();
    await tester.pumpWidget(RepaintBoundary(
      key: captureKey,
      child: ChangeNotifierProvider(
        create: (_) => AppState(),
        child: MaterialApp(theme: AppTheme.light(), home: const HomeScreen()),
      ),
    ));
    await tester.pumpAndSettle();

    final button = find.byKey(const Key('sidebar-new-connection'));
    expect(button, findsOneWidget);
    expect((tester.getCenter(button).dy - tester.getCenter(find.byIcon(Icons.settings_outlined)).dy).abs(),
        lessThan(4));

    if (Platform.environment['COMMANDS_CAPTURE_PR_SCREENSHOT'] == '1') {
      final boundary = captureKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final full = await boundary.toImage(pixelRatio: 1);
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      const crop = ui.Rect.fromLTWH(0, 0, 284, 147);
      canvas.drawImageRect(full, crop, crop, ui.Paint());
      final cropped = await recorder.endRecording().toImage(284, 147);
      final bytes = await cropped.toByteData(format: ui.ImageByteFormat.png);
      await File('docs/pr-images/new-connection-after.png').writeAsBytes(bytes!.buffer.asUint8List());
    }

    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(find.text('CONNECTION'), findsOneWidget);
  });
}
