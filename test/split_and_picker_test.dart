import 'package:commands/models/models.dart';
import 'package:commands/providers/app_state.dart';
import 'package:commands/services/pane_layout.dart';
import 'package:commands/services/session_controller.dart';
import 'package:commands/widgets/folder_picker.dart';
import 'package:commands/widgets/split_view_dialog.dart';
import 'package:commands/widgets/terminal_clipboard.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart';

/// A tab's session without a real SSH/RDP connection behind it.
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
  group('buildLayout', () {
    test('side by side and stacked', () {
      final h = buildLayout(SplitPreset.sideBySide, ['a', 'b']) as PaneSplit;
      expect(h.axis, Axis.horizontal);
      expect(tabIdsInLayoutOrdered(h), ['a', 'b']);
      final v = buildLayout(SplitPreset.stacked, ['a', 'b']) as PaneSplit;
      expect(v.axis, Axis.vertical);
    });

    test('grid keeps reading order', () {
      expect(tabIdsInLayoutOrdered(buildLayout(SplitPreset.grid, ['a', 'b', 'c', 'd'])), ['a', 'b', 'c', 'd']);
    });

    test('empty panes collapse instead of leaving holes', () {
      expect(buildLayout(SplitPreset.grid, ['a', null, null, null]), isA<PaneLeaf>());
      final two = buildLayout(SplitPreset.oneLeftTwoRight, ['a', null, 'c']) as PaneSplit;
      expect(tabIdsInLayoutOrdered(two), ['a', 'c']);
      expect(buildLayout(SplitPreset.sideBySide, [null, null]), isNull);
    });

    test('three columns come out equal', () {
      final s = buildLayout(SplitPreset.threeColumns, ['a', 'b', 'c']) as PaneSplit;
      expect(s.ratio, closeTo(1 / 3, 1e-9));
      expect((s.second as PaneSplit).ratio, 0.5);
    });
  });

  group('Split view dialog', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    testWidgets('drag a tab into a pane and apply', (tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final app = AppState();
      app.tabs.addAll([
        OpenTab(id: 'ssh', controller: _FakeSession('linux-01')),
        OpenTab(id: 'rdp', controller: _FakeSession('windows-01')),
        OpenTab(id: 'ssh2', controller: _FakeSession('switch-01')),
      ]);
      app.paneLayout = const PaneLeaf('ssh');

      await tester.pumpWidget(ChangeNotifierProvider.value(
        value: app,
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(onPressed: () => showSplitViewDialog(context), child: const Text('open')),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      // Starts from what is on screen plus the next tab, side by side.
      expect(find.text('Split View'), findsOneWidget);

      // Pick the 3-pane layout, then drag the third tab into the empty pane.
      await tester.tap(find.text('One + two'));
      await tester.pumpAndSettle();
      final emptyPane = find.text('Drop a tab here');
      expect(emptyPane, findsOneWidget);
      final chip = find.descendant(of: find.byType(Wrap).last, matching: find.text('switch-01'));
      final gesture = await tester.startGesture(tester.getCenter(chip));
      await tester.pump();
      // Several steps, as a real drag would: Draggable needs to see movement
      // past its threshold before it starts.
      final from = tester.getCenter(chip);
      final to = tester.getCenter(emptyPane);
      for (var i = 1; i <= 10; i++) {
        await gesture.moveTo(Offset.lerp(from, to, i / 10)!);
        await tester.pump(const Duration(milliseconds: 16));
      }
      await gesture.up();
      await tester.pumpAndSettle();
      expect(find.text('Drop a tab here'), findsNothing);

      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();
      expect(tabIdsInLayoutOrdered(app.paneLayout), ['ssh', 'rdp', 'ssh2']);
    });
  });

  group('folder picker', () {
    final folders = [
      ConnectionFolder(id: 'cust', name: 'CUSTOMER-A'),
      ConnectionFolder(id: 'sw', name: 'Core switches', parentId: 'cust'),
      ConnectionFolder(id: 'other', name: 'CUSTOMER-B'),
    ];

    test('folderPath reads like a breadcrumb', () {
      expect(folderPath(folders, 'sw'), 'CUSTOMER-A  ›  Core switches');
      expect(folderPath(folders, null), isNull);
    });

    Future<void> open(WidgetTester tester, {String? selected}) async {
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showFolderPicker(context, folders: folders, connections: const [], selected: selected),
              child: const Text('pick'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('pick'));
      await tester.pumpAndSettle();
    }

    testWidgets('sub-folders sit under their parent, not in a flat list', (tester) async {
      await open(tester);
      expect(find.text('CUSTOMER-A'), findsOneWidget);
      expect(find.text('CUSTOMER-B'), findsOneWidget);
      // Collapsed: the child is not listed alongside the top-level folders.
      expect(find.text('Core switches'), findsNothing);
      await tester.tap(find.byIcon(Icons.chevron_right).first);
      await tester.pumpAndSettle();
      expect(find.text('Core switches'), findsOneWidget);
      // Indented one level further than its parent.
      expect(tester.getTopLeft(find.text('Core switches')).dx, greaterThan(tester.getTopLeft(find.text('CUSTOMER-A')).dx));
    });

    testWidgets('the current folder is revealed and marked', (tester) async {
      await open(tester, selected: 'sw');
      expect(find.text('Core switches'), findsOneWidget);
      expect(find.byIcon(Icons.check), findsOneWidget);
    });

    testWidgets('search finds nested folders and shows where they are', (tester) async {
      await open(tester);
      await tester.enterText(find.byType(TextField), 'core');
      await tester.pumpAndSettle();
      expect(find.text('Core switches'), findsOneWidget);
      expect(find.text('in CUSTOMER-A'), findsOneWidget);
    });
  });

  group('PuTTY clipboard', () {
    late List<MethodCall> calls;
    String? clipboard;

    setUp(() {
      calls = [];
      clipboard = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
        calls.add(call);
        if (call.method == 'Clipboard.setData') {
          clipboard = (call.arguments as Map)['text'] as String?;
        }
        if (call.method == 'Clipboard.getData') return {'text': clipboard};
        return null;
      });
    });

    test('selecting copies, once the selection settles', () async {
      final terminal = Terminal();
      terminal.write('admin@core-sw1:~\$ show vlan');
      final controller = TerminalController();
      final clip = TerminalClipboard(terminal: terminal, controller: controller);
      addTearDown(clip.dispose);

      controller.setSelection(
        terminal.buffer.createAnchor(0, 0),
        terminal.buffer.createAnchor(14, 0),
      );
      expect(clipboard, isNull, reason: 'not copied mid-drag');
      await Future<void>.delayed(TerminalClipboard.settle + const Duration(milliseconds: 50));
      expect(clipboard, 'admin@core-sw1');
    });

    test('right-click paste sends line breaks as Enter', () async {
      final terminal = Terminal();
      final sent = StringBuffer();
      terminal.onOutput = sent.write;
      final clip = TerminalClipboard(terminal: terminal, controller: TerminalController());
      addTearDown(clip.dispose);

      clipboard = 'show run\r\nshow ver\n';
      await clip.paste();
      expect(sent.toString(), 'show run\rshow ver\r');
    });
  });

}
