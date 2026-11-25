import 'package:commands/models/models.dart';
import 'package:commands/providers/app_state.dart';
import 'package:commands/services/pty_session.dart';
import 'package:commands/widgets/connection_tree.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late AppState app;
  late ConnectionFolder a, b, c, inner;
  late SavedConnection conn;

  Future<void> pumpTree(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    app = AppState();
    await tester.pump();
    a = ConnectionFolder(name: 'ALPHA');
    b = ConnectionFolder(name: 'BRAVO');
    c = ConnectionFolder(name: 'CHARLIE');
    inner = ConnectionFolder(name: 'INNER', parentId: a.id);
    app.folders.addAll([a, b, c, inner]);
    conn = SavedConnection(name: 'DEVICE-01', host: '192.0.2.10', folderId: c.id);
    app.connections.add(conn);
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: const MaterialApp(
          home: Scaffold(body: SizedBox(width: 300, height: 400, child: ConnectionTree())),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Drags from [from] to [to] (global points) the way a mouse does.
  Future<void> drag(WidgetTester tester, Offset from, Offset to) async {
    final g = await tester.startGesture(from, kind: PointerDeviceKind.mouse);
    await tester.pump(const Duration(milliseconds: 50));
    for (var i = 1; i <= 10; i++) {
      await g.moveTo(Offset.lerp(from, to, i / 10)!);
      await tester.pump(const Duration(milliseconds: 16));
    }
    await g.up();
    await tester.pumpAndSettle();
  }

  testWidgets('a connection dropped on a folder moves into it', (tester) async {
    await pumpTree(tester);
    await tester.tap(find.byIcon(Icons.chevron_right).at(2)); // open CHARLIE
    await tester.pumpAndSettle();
    await drag(tester, tester.getCenter(find.text('DEVICE-01')), tester.getCenter(find.text('BRAVO')));
    expect(app.connections.single.folderId, b.id);
  });

  group('several selected rows', () {
    late SavedConnection one, two, three;

    Future<void> pumpThree(WidgetTester tester) async {
      await pumpTree(tester);
      one = SavedConnection(name: 'DEVICE-02', host: '192.0.2.11');
      two = SavedConnection(name: 'DEVICE-03', host: '192.0.2.12');
      three = SavedConnection(name: 'DEVICE-04', host: '192.0.2.13');
      for (final c in [one, two, three]) {
        await app.upsertConnection(c);
      }
      await tester.pumpAndSettle();
    }

    // Each press a few seconds after the last, as a hand does: with every
    // stamp at zero, a second press on a row would read as a double click.
    var clock = const Duration(seconds: 10);
    Duration tick() => clock += const Duration(seconds: 2);

    Future<void> click(WidgetTester tester, String name, {bool ctrl = false}) async {
      if (ctrl) await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      final g = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await g.down(tester.getCenter(find.text(name)), timeStamp: tick());
      await tester.pump();
      await g.up(timeStamp: clock + const Duration(milliseconds: 80));
      if (ctrl) await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      // The selection bar comes and goes with an animation: let it finish.
      await tester.pumpAndSettle();
    }

    Future<void> dragFrom(WidgetTester tester, String name, String onto) async {
      final from = tester.getCenter(find.text(name));
      final to = tester.getCenter(find.text(onto));
      final g = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await g.down(from, timeStamp: tick());
      await tester.pump(const Duration(milliseconds: 50));
      for (var i = 1; i <= 10; i++) {
        await g.moveTo(Offset.lerp(from, to, i / 10)!, timeStamp: clock + Duration(milliseconds: 50 + 16 * i));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await g.up(timeStamp: clock + const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
    }

    testWidgets('Ctrl-picked rows, dragged by one of them, all move', (tester) async {
      await pumpThree(tester);
      await click(tester, 'DEVICE-02', ctrl: true);
      await click(tester, 'DEVICE-04', ctrl: true);
      await dragFrom(tester, 'DEVICE-04', 'BRAVO');
      expect(one.folderId, b.id);
      expect(three.folderId, b.id);
      expect(two.folderId, isNull, reason: 'not selected, so it stays');
    });

    testWidgets('a plain click on one of them, without a drag, still leaves only it selected', (tester) async {
      await pumpThree(tester);
      await click(tester, 'DEVICE-02', ctrl: true);
      await click(tester, 'DEVICE-04', ctrl: true);
      await click(tester, 'DEVICE-04');
      // DEVICE-02 is no longer selected: pressing it picks it alone.
      await dragFrom(tester, 'DEVICE-02', 'BRAVO');
      expect(one.folderId, b.id);
      expect(three.folderId, isNull);
    });
  });

  group('right click on several selected folders', () {
    var clock = const Duration(seconds: 10);
    Duration tick() => clock += const Duration(seconds: 2);

    Future<void> click(WidgetTester tester, String name, {bool ctrl = false}) async {
      if (ctrl) await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      final g = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await g.down(tester.getCenter(find.text(name)), timeStamp: tick());
      await tester.pump();
      await g.up(timeStamp: clock + const Duration(milliseconds: 80));
      if (ctrl) await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
    }

    Future<void> rightClick(WidgetTester tester, String name) async {
      await tester.tap(find.text(name), buttons: kSecondaryMouseButton, kind: PointerDeviceKind.mouse);
      await tester.pumpAndSettle();
    }

    testWidgets('the menu names the selection and Color applies to all of them', (tester) async {
      await pumpTree(tester);
      await click(tester, 'ALPHA', ctrl: true);
      await click(tester, 'BRAVO', ctrl: true);
      await click(tester, 'CHARLIE', ctrl: true);
      await rightClick(tester, 'BRAVO');
      expect(find.text('3 folders selected'), findsOneWidget);
      expect(find.text('Rename'), findsNothing, reason: 'one-folder actions are left out');
      await tester.tap(find.text('Color…'));
      await tester.pumpAndSettle();
      expect(find.text('Color for 3 folders'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('folder-kind-firewall')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('folder-color-save')));
      await tester.pumpAndSettle();
      for (final f in [a, b, c]) {
        expect(f.kind, FolderKind.firewall, reason: f.name);
      }
      expect(inner.kind, isNull, reason: 'not selected');

      // A plain colour for all, again in one go.
      await rightClick(tester, 'ALPHA');
      await tester.tap(find.text('Color…'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('folder-swatch-${AppState.folderColors.first}')));
      await tester.tap(find.byKey(const Key('folder-color-save')));
      await tester.pumpAndSettle();
      for (final f in [a, b, c]) {
        expect(f.kind, isNull);
        expect(f.color, AppState.folderColors.first);
      }
    });

    testWidgets('folders that differ start with nothing picked, and Save alone changes nothing', (tester) async {
      await pumpTree(tester);
      await app.setFolderKind(a.id, FolderKind.network);
      await tester.pumpAndSettle();
      await click(tester, 'ALPHA', ctrl: true);
      await click(tester, 'BRAVO', ctrl: true);
      await rightClick(tester, 'ALPHA');
      await tester.tap(find.text('Color…'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('folder-color-save')));
      await tester.pumpAndSettle();
      expect(a.kind, FolderKind.network);
      expect(b.kind, isNull);
      expect(b.color, isNull);
    });

    testWidgets('a folder selected with one inside it counts once, and only the outer one is coloured', (
      tester,
    ) async {
      await pumpTree(tester);
      await tester.tap(find.byIcon(Icons.chevron_right).first); // open ALPHA
      await tester.pumpAndSettle();
      await click(tester, 'ALPHA', ctrl: true);
      await click(tester, 'INNER', ctrl: true);
      await click(tester, 'BRAVO', ctrl: true);
      await rightClick(tester, 'BRAVO');
      expect(find.text('2 folders selected'), findsOneWidget);
      await tester.tap(find.text('Color…'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('folder-kind-system')));
      await tester.tap(find.byKey(const Key('folder-color-save')));
      await tester.pumpAndSettle();
      expect(a.kind, FolderKind.system);
      expect(b.kind, FolderKind.system);
      expect(inner.kind, isNull, reason: 'it shows the colour of ALPHA without one of its own');
      expect(app.folderColorOf(inner.id), Color(FolderKind.system.color));
    });

    testWidgets('one selected folder keeps its own full menu', (tester) async {
      await pumpTree(tester);
      await click(tester, 'BRAVO');
      await rightClick(tester, 'BRAVO');
      expect(find.text('Rename'), findsOneWidget);
      expect(find.text('3 folders selected'), findsNothing);
    });
  });

  testWidgets('a folder dropped on the middle of another goes inside it', (tester) async {
    await pumpTree(tester);
    await drag(tester, tester.getCenter(find.text('CHARLIE')), tester.getCenter(find.text('BRAVO')));
    expect(c.parentId, b.id);
  });

  testWidgets('a folder dropped on the top edge of another goes above it, and the order stays', (
    tester,
  ) async {
    await pumpTree(tester);
    // The top third of ALPHA's 30px row: a few pixels above its text.
    final top = tester.getCenter(find.text('ALPHA')).translate(0, -10);
    await drag(tester, tester.getCenter(find.text('CHARLIE')), top);
    expect(c.parentId, isNull);
    final order = app
        .sortFolders(app.folders.where((f) => f.parentId == null).toList())
        .map((f) => f.name)
        .toList();
    expect(order, ['CHARLIE', 'ALPHA', 'BRAVO']);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList('commands.folderOrder'), isNotEmpty);
    // On screen too.
    expect(tester.getCenter(find.text('CHARLIE')).dy, lessThan(tester.getCenter(find.text('ALPHA')).dy));
  });

  group('connection order', () {
    late SavedConnection second, third;

    Future<void> withThree(WidgetTester tester) async {
      await pumpTree(tester);
      second = SavedConnection(name: 'DEVICE-02', host: '192.0.2.11', folderId: c.id);
      third = SavedConnection(name: 'DEVICE-03', host: '192.0.2.12', folderId: c.id);
      app.connections.addAll([second, third]);
      await tester.tap(find.byIcon(Icons.chevron_right).at(2)); // open CHARLIE
      await tester.pumpAndSettle();
    }

    List<String> shown() =>
        app.sortConnections(app.connections.where((e) => e.folderId == c.id).toList()).map((e) => e.name).toList();

    testWidgets('a connection dropped on the bottom edge of another goes below it, and the order stays', (
      tester,
    ) async {
      await withThree(tester);
      final bottom = tester.getCenter(find.text('DEVICE-01')).translate(0, 10);
      await drag(tester, tester.getCenter(find.text('DEVICE-03')), bottom);
      expect(shown(), ['DEVICE-01', 'DEVICE-03', 'DEVICE-02']);
      expect(tester.getCenter(find.text('DEVICE-03')).dy, lessThan(tester.getCenter(find.text('DEVICE-02')).dy));
      expect(app.connections.firstWhere((e) => e.id == third.id).folderId, c.id);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList('commands.connectionOrder'), isNotEmpty);
    });

    testWidgets('a connection dropped on the middle of a row in its own folder still takes a place', (tester) async {
      await withThree(tester);
      final top = tester.getCenter(find.text('DEVICE-01')).translate(0, -4);
      await drag(tester, tester.getCenter(find.text('DEVICE-02')), top);
      expect(shown().first, 'DEVICE-02');
    });

    testWidgets('dropped beside a row of another folder, it moves there at that place', (tester) async {
      await withThree(tester);
      final outside = SavedConnection(name: 'DEVICE-00', host: '192.0.2.13');
      app.connections.add(outside);
      app.setSidebarWidth(300); // any notification, to show the new row
      await tester.pumpAndSettle();
      final bottom = tester.getCenter(find.text('DEVICE-01')).translate(0, 10);
      await drag(tester, tester.getCenter(find.text('DEVICE-00')), bottom);
      expect(outside.folderId, c.id);
      expect(shown(), ['DEVICE-01', 'DEVICE-00', 'DEVICE-02', 'DEVICE-03']);
    });

    testWidgets('new connections with no place yet come after arranged ones, by name', (tester) async {
      await withThree(tester);
      await app.placeConnections([third.id], c.id, before: conn.id);
      app.connections.add(SavedConnection(name: 'AAA', host: '192.0.2.14', folderId: c.id));
      expect(shown().first, 'DEVICE-03');
      expect(shown().contains('AAA'), isTrue);
    });
  });

  testWidgets('a folder cannot go inside its own subfolder', (tester) async {
    await pumpTree(tester);
    await tester.tap(find.byIcon(Icons.chevron_right).first); // open ALPHA
    await tester.pumpAndSettle();
    await drag(tester, tester.getCenter(find.text('ALPHA')), tester.getCenter(find.text('INNER')));
    expect(a.parentId, isNull);
    expect(inner.parentId, a.id);
  });

  testWidgets('dropped on empty space below the rows, it goes to the top level', (tester) async {
    await pumpTree(tester);
    await tester.tap(find.byIcon(Icons.chevron_right).first); // open ALPHA
    await tester.pumpAndSettle();
    await drag(tester, tester.getCenter(find.text('INNER')), const Offset(150, 380));
    expect(inner.parentId, isNull);
  });

  testWidgets('pressing a row does not pick it up', (tester) async {
    await pumpTree(tester);
    await tester.tap(find.byIcon(Icons.chevron_right).at(2)); // open CHARLIE
    await tester.pumpAndSettle();
    final g = await tester.startGesture(
      tester.getCenter(find.text('DEVICE-01')),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump(const Duration(milliseconds: 40));
    expect(find.text('DEVICE-01'), findsOneWidget, reason: 'no drag chip on a press');
    await g.moveBy(const Offset(3, 2)); // a hand's jitter
    await tester.pump(const Duration(milliseconds: 40));
    expect(find.text('DEVICE-01'), findsOneWidget, reason: 'nor on a few pixels of jitter');
    await g.up();
    await tester.pump();
  });

  testWidgets('a jittery double click on a connection in a folder opens it and leaves it where it is', (
    tester,
  ) async {
    await pumpTree(tester);
    PtySessionController.checkReachability = false;
    addTearDown(() => PtySessionController.checkReachability = true);
    await tester.tap(find.byIcon(Icons.chevron_right).at(2)); // open CHARLIE
    await tester.pumpAndSettle();
    final p = tester.getCenter(find.text('DEVICE-01'));
    // As a real mouse delivers it: frames drawn between every event, and the
    // hand moving a little while the button is down.
    final g1 = await tester.startGesture(p, kind: PointerDeviceKind.mouse);
    await tester.pump(const Duration(milliseconds: 30));
    await g1.moveTo(p + const Offset(2, 1));
    await tester.pump(const Duration(milliseconds: 20));
    await g1.up();
    await tester.pump(const Duration(milliseconds: 70));
    final g2 = await tester.startGesture(p + const Offset(2, 1), kind: PointerDeviceKind.mouse);
    await tester.pump(const Duration(milliseconds: 30));
    await g2.up();
    await tester.pump(const Duration(milliseconds: 50));
    expect(app.connections.single.folderId, c.id, reason: 'still in its folder');
    expect(app.tabs, hasLength(1), reason: 'the double click connected');
    for (final t in app.tabs) {
      t.controller.dispose();
    }
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('picked up and put back on itself, a connection stays in its folder', (tester) async {
    await pumpTree(tester);
    await tester.tap(find.byIcon(Icons.chevron_right).at(2)); // open CHARLIE
    await tester.pumpAndSettle();
    final p = tester.getCenter(find.text('DEVICE-01'));
    await drag(tester, p, p + const Offset(30, 4));
    expect(app.connections.single.folderId, c.id);
    // Again from another spot of the row (test pointer events carry no
    // time, so a second press on the same spot would read as a double click).
    final q = p + const Offset(20, 0);
    await drag(tester, q, q + const Offset(-20, -3));
    expect(app.connections.single.folderId, c.id);
  });
}
