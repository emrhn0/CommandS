
import 'package:commands/models/models.dart';
import 'package:commands/providers/app_state.dart';
import 'package:commands/services/rdp_session.dart';
import 'package:commands/services/session_controller.dart';
import 'package:commands/widgets/rdp_embed_view.dart';
import 'package:commands/widgets/terminal_tabs.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late List<String> calls;
  List<Object?> frames = const [];

  setUp(() {
    calls = [];
    frames = const [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('commands/rdp'),
      (call) async {
        final args = call.arguments;
        calls.add(call.method == 'setSuspended' ? 'setSuspended:${(args as Map)['suspended']}' : call.method);
        return switch (call.method) {
          'create' => 1,
          'connect' => true,
          'captureFrames' => frames,
          _ => null,
        };
      },
    );
  });

  // A connecting session has a spinner, so pumpAndSettle would never return.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  RdpSessionController session() => RdpSessionController(
    SavedConnection(name: 'SERVER-01', host: '192.0.2.20', port: 3389, protocol: ConnectionProtocol.rdp),
  );

  testWidgets('the session has no bar above it', (tester) async {
    tester.view.physicalSize = const Size(800, 400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final c = session();
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: RdpEmbedView(controller: c, active: true))));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byIcon(Icons.keyboard), findsNothing);
    expect(find.text('SERVER-01'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('Ctrl+Alt+Del is in a live session tab menu, and goes to the session', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final app = AppState();
    await tester.pump();
    final c = session();
    app.tabs.add(OpenTab(id: 'rdp', controller: c));
    app.setActiveTab(0);
    await tester.binding.setSurfaceSize(const Size(1000, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: MaterialApp(
          navigatorObservers: [RdpModalObserver()],
          home: const Scaffold(body: TerminalTabsArea()),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));

    // Not offered until it can go anywhere.
    await tester.tap(find.text('SERVER-01').first, buttons: kSecondaryButton);
    await settle(tester);
    expect(find.text('Send Ctrl+Alt+Del'), findsNothing);
    await tester.tapAt(const Offset(900, 500));
    await settle(tester);

    c.status = SessionStatus.running;
    await tester.tap(find.text('SERVER-01').first, buttons: kSecondaryButton);
    await settle(tester);
    await tester.tap(find.text('Send Ctrl+Alt+Del'));
    await settle(tester);
    await tester.pump(const Duration(milliseconds: 200));
    expect(calls, contains('sendCtrlAltDel'));
    expect(calls.indexOf('sendCtrlAltDel'), greaterThan(calls.lastIndexOf('setSuspended:false')));

    await tester.pumpWidget(const SizedBox());
    c.dispose();
    await tester.pump(const Duration(seconds: 2));
  });

  test('the picture is taken before the session steps aside', () async {
    RdpChannel.instance.holdSuspended(true);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(calls, ['captureFrames', 'setSuspended:true']);
    RdpChannel.instance.holdSuspended(false);
    expect(calls.last, 'setSuspended:false');
  });

  test('two holds: the session comes back only when both let go', () async {
    RdpChannel.instance.holdSuspended(true);
    RdpChannel.instance.holdSuspended(true);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    RdpChannel.instance.holdSuspended(false);
    expect(calls, isNot(contains('setSuspended:false')));
    RdpChannel.instance.holdSuspended(false);
    expect(calls.last, 'setSuspended:false');
  });

  test('let go while the picture is being taken, the session does not hide', () async {
    RdpChannel.instance.holdSuspended(true);
    RdpChannel.instance.holdSuspended(false);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(calls, isNot(contains('setSuspended:true')));
  });

  testWidgets('a picture of the session is shown while it is away, then goes', (tester) async {
    await tester.runAsync(() async {
      final c = session();
      RdpChannel.instance.register(7, (_) {}, frame: c.frozenFrame);
      frames = [
        {'id': 7, 'width': 2, 'height': 1, 'pixels': Uint8List.fromList(List.filled(8, 255))},
      ];
      RdpChannel.instance.holdSuspended(true);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(c.frozenFrame.value, isNotNull);
      expect(calls.last, 'setSuspended:true');
      RdpChannel.instance.holdSuspended(false);
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(c.frozenFrame.value, isNull);
      RdpChannel.instance.unregister(7);
      c.dispose();
    });
  });
}
