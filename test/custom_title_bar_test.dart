import 'package:commands/theme/app_theme.dart';
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

  testWidgets('title bar matches the light background and keeps the dark color', (tester) async {
    Future<Color?> titleBarColor(ThemeData theme) async {
      await tester.pumpWidget(MaterialApp(theme: theme, home: const Scaffold(body: CustomTitleBar())));
      await tester.pumpAndSettle();
      final container = tester.widget<Container>(
        find.descendant(of: find.byType(CustomTitleBar), matching: find.byType(Container)).first,
      );
      return container.color;
    }

    expect(await titleBarColor(AppTheme.light()), const Color(0xFFFAFAFA));
    expect(await titleBarColor(AppTheme.dark()), AppColors.darkBg);
  });
}
