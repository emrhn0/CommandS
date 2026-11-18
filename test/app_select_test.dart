import 'dart:io';

import 'package:commands/theme/app_theme.dart';
import 'package:commands/widgets/app_select.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<List<String?>> pump(WidgetTester tester, {String? value = 'b'}) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final picked = <String?>[];
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.dark(),
      home: Scaffold(
        body: Padding(
          padding: const EdgeInsets.all(40),
          child: SizedBox(
            width: 320,
            child: AppSelect<String?>(
              key: const Key('field'),
              value: value,
              onChanged: picked.add,
              items: const [
                AppSelectItem(null, 'Automatic', leading: Icon(Icons.auto_awesome_outlined, size: 16)),
                AppSelectItem('a', 'Option A', dividerBefore: true),
                AppSelectItem('b', 'Option B'),
                AppSelectItem('new', 'Make a new one…', dividerBefore: true, action: true),
              ],
            ),
          ),
        ),
      ),
    ));
    return picked;
  }

  testWidgets('shows the current choice, and opens a compact menu just below, as wide as the field', (tester) async {
    await pump(tester);
    expect(find.text('Option B'), findsOneWidget);
    final field = tester.getRect(find.byKey(const Key('field')));
    await tester.tap(find.byKey(const Key('field')));
    await tester.pumpAndSettle();
    final rows = find.byType(MenuItemButton);
    expect(rows, findsNWidgets(4));
    final first = tester.getRect(rows.first);
    expect(first.top, greaterThanOrEqualTo(field.bottom), reason: 'below the field, not over it');
    expect(first.height, lessThan(40), reason: 'desktop-sized rows');
    expect((first.left - field.left).abs(), lessThan(12));
    expect(find.byIcon(Icons.check_rounded), findsOneWidget, reason: 'the current choice is ticked');
  });

  testWidgets('a click picks a row and closes the menu', (tester) async {
    final picked = await pump(tester);
    await tester.tap(find.byKey(const Key('field')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Option A'));
    await tester.pumpAndSettle();
    expect(picked, ['a']);
    expect(find.byType(MenuItemButton), findsNothing);
  });

  testWidgets('the keyboard works: arrows move, Enter picks, Esc closes', (tester) async {
    final picked = await pump(tester);
    await tester.tap(find.byKey(const Key('field')));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(MenuItemButton), findsNothing);
    expect(picked, isEmpty);

    await tester.tap(find.byKey(const Key('field')));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(picked, hasLength(1));
  });

  testWidgets('a null value is a choice like any other, and an action is never shown as chosen', (tester) async {
    await pump(tester, value: null);
    expect(find.text('Automatic'), findsOneWidget);
    await pump(tester, value: 'new');
    expect(find.text('Make a new one…'), findsNothing, reason: 'an action is not a value');
  });

  test("Material's tall dropdown is no longer used anywhere", () {
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>()) {
      if (!f.path.endsWith('.dart')) continue;
      final src = f.readAsStringSync();
      expect(src.contains('DropdownButtonFormField') || src.contains('DropdownButton<'), isFalse, reason: f.path);
    }
  });
}
