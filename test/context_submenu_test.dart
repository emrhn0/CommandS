import 'package:commands/widgets/context_menu.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('submenu flips left and stays on screen near the bottom right', (tester) async {
    const size = Size(520, 400);
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    String? result;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Builder(builder: (context) {
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapUp: (details) async {
          result = await showContextMenu(
            context,
            position: details.globalPosition,
            actions: const [
              MenuAction('rename', 'Rename', Icons.edit_outlined),
              MenuAction('sort', 'Sort contents', Icons.sort, children: [
                MenuAction('name', 'Name (A–Z)', Icons.arrow_downward),
                MenuAction('address', 'IP address', Icons.lan_outlined),
                MenuAction('device', 'Device type', Icons.devices_other_outlined),
              ]),
            ],
          );
        },
        child: const SizedBox.expand(),
      );
    }))));

    await tester.tapAt(const Offset(505, 387));
    await tester.pumpAndSettle();
    final trigger = find.byKey(const ValueKey('context-submenu-trigger-sort'));
    final panel = find.byKey(const ValueKey('context-submenu-sort'));
    await tester.tap(trigger);
    await tester.pumpAndSettle();
    final bounds = tester.getRect(panel);
    expect(bounds.right, tester.getRect(trigger).left);
    expect(bounds.left, greaterThanOrEqualTo(8));
    expect(bounds.bottom, lessThanOrEqualTo(size.height - 8));
    expect(find.text('Rename'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(panel, findsNothing);
    expect(trigger, findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(panel, findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(trigger, findsNothing);
    expect(panel, findsNothing);
    expect(result, 'address');

    await tester.tapAt(const Offset(505, 387));
    await tester.pumpAndSettle();
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(20, 20));
    addTearDown(mouse.removePointer);
    await tester.pump();
    await mouse.moveTo(tester.getCenter(trigger));
    await tester.pumpAndSettle();
    expect(panel, findsOneWidget);

    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();
    expect(trigger, findsNothing);
    expect(panel, findsNothing);
    expect(result, isNull);
  });
}
