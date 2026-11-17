import 'package:commands/providers/app_state.dart';
import 'package:commands/services/pty_session.dart';
import 'package:commands/widgets/terminal_tabs.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    PtySessionController.checkReachability = false;
  });
  tearDown(() => PtySessionController.checkReachability = true);

  Future<AppState> show(WidgetTester tester, int count) async {
    tester.view.physicalSize = const Size(900, 500);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final app = AppState();
    await tester.pump();
    for (var i = 0; i < count; i++) {
      app.tabs.add(OpenTab(
        id: 't$i',
        controller: PtySessionController(host: '192.0.2.${10 + i}', port: 22, tabTitle: 'DEVICE-$i', startImmediately: false),
      ));
    }
    app.setActiveTab(0);
    await tester.pumpWidget(ChangeNotifierProvider.value(
      value: app,
      child: const MaterialApp(home: Scaffold(body: TerminalTabsArea())),
    ));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump();
    return app;
  }

  Future<void> cleanUp(WidgetTester tester, AppState app) async {
    await tester.pumpWidget(const SizedBox());
    for (final t in app.tabs) {
      t.controller.dispose();
    }
  }

  testWidgets('a few tabs: no arrows', (tester) async {
    final app = await show(tester, 2);
    expect(find.byKey(const ValueKey('tabs-forward')), findsNothing);
    expect(find.byKey(const ValueKey('tabs-back')), findsNothing);
    await cleanUp(tester, app);
  });

  testWidgets('more tabs than fit: the arrow brings the last ones into view', (tester) async {
    final app = await show(tester, 14);
    final forward = find.byKey(const ValueKey('tabs-forward'));
    expect(forward, findsOneWidget);
    final strip = tester.getRect(find.byType(ListView).first);
    bool lastVisible() {
      // Built only once the list gets near it.
      final last = find.byKey(const ValueKey('tab-t13'));
      if (!tester.any(last)) return false;
      final r = tester.getRect(last);
      return r.right <= strip.right + 1;
    }

    expect(lastVisible(), isFalse);
    for (var i = 0; i < 20 && tester.widget<IconButton>(forward).onPressed != null; i++) {
      await tester.tap(forward);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
    }
    expect(lastVisible(), isTrue);
    // At the end: forward is off, back is on.
    expect(tester.widget<IconButton>(forward).onPressed, isNull);
    await tester.tap(find.byKey(const ValueKey('tabs-back')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(lastVisible(), isFalse);
    await cleanUp(tester, app);
  });
}
