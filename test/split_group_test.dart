import 'package:commands/models/models.dart';
import 'package:commands/providers/app_state.dart';
import 'package:commands/services/pty_session.dart';
import 'package:commands/services/pane_layout.dart';
import 'package:commands/services/session_controller.dart';
import 'package:commands/widgets/terminal_tabs.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeSession implements SessionController {
  _FakeSession(this.host);
  @override
  final String host;
  @override
  String? get tabTitle => host;
  @override
  SessionStatus status = SessionStatus.running;
  @override
  Stream<SessionStatus> get statusStream => const Stream.empty();
  @override
  void dispose() {}
}

void main() {
  late AppState app;

  setUp(() async {
    // Tab and dialog behaviour only; no network.
    PtySessionController.checkReachability = false;
    SharedPreferences.setMockInitialValues({});
    app = AppState();
    await Future<void>.delayed(Duration.zero);
  });

  OpenTab fake(String id) {
    final t = OpenTab(id: id, controller: _FakeSession('192.0.2.$id'));
    app.tabs.add(t);
    return t;
  }

  group('split groups', () {
    test('a split becomes one group; another tab can be shown and the split brought back', () {
      fake('1');
      fake('2');
      fake('3');
      app.applyLayout(buildLayout(SplitPreset.oneLeftTwoRight, ['1', '2', '3']), editActive: true);
      expect(app.groups, hasLength(1));
      final g = app.groups.single;
      expect(g.name, isNull, reason: 'shown as "Split View"');
      expect(app.activeGroupId, g.id);

      fake('4');
      app.setActiveTab(3);
      expect(app.activeGroupId, isNull);
      expect(tabIdsInLayout(app.paneLayout), {'4'});

      app.activateGroup(g.id);
      expect(tabIdsInLayoutOrdered(app.paneLayout), ['1', '2', '3']);
      expect(identical(app.paneLayout, g.layout), isTrue, reason: 'dragged dividers are kept');
    });

    test('a saved layout opens as a group named after it, and opening it again reuses it', () {
      final a = SavedConnection(name: 'DEVICE-01', host: '192.0.2.11');
      final b = SavedConnection(name: 'DEVICE-02', host: '192.0.2.12');
      app.connections.addAll([a, b]);
      app.tabs.add(OpenTab(id: 'a', controller: _FakeSession(a.host), connectionId: a.id));
      app.tabs.add(OpenTab(id: 'b', controller: _FakeSession(b.host), connectionId: b.id));
      final layout = SavedLayout(name: 'Core switches', preset: 'sideBySide', connectionIds: [a.id, b.id]);
      app.openLayout(layout);
      app.openLayout(layout);
      expect(app.groups, hasLength(1));
      expect(app.groups.single.name, 'Core switches');
    });

    test('closing a session leaves the rest of the split; down to one, it is a plain tab again', () {
      fake('1');
      fake('2');
      fake('3');
      app.applyLayout(buildLayout(SplitPreset.oneLeftTwoRight, ['1', '2', '3']), editActive: true);
      app.closeTab(app.tabs.indexWhere((t) => t.id == '3'));
      expect(app.groups.single.tabIds, ['1', '2']);
      expect(tabIdsInLayoutOrdered(app.paneLayout), ['1', '2']);
      app.closeTab(app.tabs.indexWhere((t) => t.id == '2'));
      expect(app.groups, isEmpty);
      expect(app.activeGroupId, isNull);
      expect(tabIdsInLayout(app.paneLayout), {'1'});
    });

    test('a session moved into a new split leaves its old one', () {
      for (final id in ['1', '2', '3', '4']) {
        fake(id);
      }
      app.applyLayout(buildLayout(SplitPreset.sideBySide, ['1', '2']), editActive: true);
      app.setActiveTab(2);
      app.applyLayout(buildLayout(SplitPreset.oneLeftTwoRight, ['2', '3', '4']), editActive: true);
      // The first split lost a session and is down to one: no longer a group.
      expect(app.groups, hasLength(1));
      expect(app.groups.single.tabIds, ['2', '3', '4']);
      expect(app.groupOf('1'), isNull);
    });

    test('editing the split on screen reworks it rather than making another', () {
      for (final id in ['1', '2', '3']) {
        fake(id);
      }
      app.applyLayout(buildLayout(SplitPreset.sideBySide, ['1', '2']), editActive: true);
      final g = app.groups.single;
      app.applyLayout(buildLayout(SplitPreset.oneLeftTwoRight, ['1', '2', '3']), editActive: true);
      expect(app.groups.single, same(g));
      expect(g.tabIds, ['1', '2', '3']);
      // Back to one pane: no split left.
      app.applyLayout(buildLayout(SplitPreset.single, ['1']), editActive: true);
      expect(app.groups, isEmpty);
    });
  });

  testWidgets('the tab bar shows a split as one "Split View" tab, with its own menu', (tester) async {
    tester.view.physicalSize = const Size(1400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    for (final h in ['192.0.2.71', '192.0.2.72', '192.0.2.73']) {
      app.openBlankHostOnly(host: h, port: 22);
    }
    final ids = app.tabs.map((t) => t.id).toList();
    app.applyLayout(buildLayout(SplitPreset.oneLeftTwoRight, ids), editActive: true);
    app.openBlankHostOnly(host: '192.0.2.74', port: 22);

    await tester.pumpWidget(ChangeNotifierProvider.value(
      value: app,
      child: const MaterialApp(home: Scaffold(body: TerminalTabsArea())),
    ));
    await tester.pump(const Duration(milliseconds: 100));

    // One tab for the split and one for the new session -- not four.
    expect(find.text('Split View'), findsNWidgets(2), reason: 'the split tab and the Split View button');
    expect(find.text('192.0.2.71'), findsNothing);
    expect(find.text('192.0.2.74'), findsOneWidget);
    expect(app.activeGroupId, isNull);

    await tester.tap(find.text('Split View').first);
    await tester.pump(const Duration(milliseconds: 100));
    expect(app.activeGroupId, app.groups.single.id);
    expect(tabIdsInLayoutOrdered(app.paneLayout), ids);

    await tester.tap(find.text('Split View').first, buttons: kSecondaryMouseButton);
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.tap(find.text('Separate into tabs'));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(app.groups, isEmpty);
    expect(find.text('192.0.2.71'), findsOneWidget);
    expect(find.text('192.0.2.74'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    for (final t in [...app.tabs]) {
      t.controller.dispose();
    }
  });
}
