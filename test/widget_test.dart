import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:commands/theme/app_theme.dart';

void main() {
  testWidgets('themes build without throwing', (WidgetTester tester) async {
    expect(AppTheme.dark(), isA<ThemeData>());
    expect(AppTheme.light(), isA<ThemeData>());
  });
}
