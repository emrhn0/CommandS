import 'package:commands/models/models.dart';
import 'package:commands/services/mac_rdp_channel.dart';
import 'package:commands/services/mac_rdp_session.dart';
import 'package:commands/services/session_controller.dart';
import 'package:commands/widgets/mac_rdp_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Stands in for the macOS plugin: records the calls, and lets a test send
/// the events the engine would.
final _calls = <MethodCall>[];

void _mockEngine() {
  _calls.clear();
  MacRdpChannel.resetForTest();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel(MacRdpChannel.channelName),
    (call) async {
      _calls.add(call);
      switch (call.method) {
        case 'available':
          return true;
        case 'connect':
          return {'id': 7, 'textureId': 42, 'isoKeyboard': false};
      }
      return null;
    },
  );
}

Future<void> _engineSays(Map<String, Object?> event) async {
  const codec = StandardMethodCodec();
  await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.handlePlatformMessage(
    MacRdpChannel.channelName,
    codec.encodeMethodCall(MethodCall('event', {'id': 7, ...event})),
    (_) {},
  );
}

Iterable<MethodCall> _named(String method) => _calls.where((c) => c.method == method);

SavedConnection _rdp({String password = 'example-password'}) => SavedConnection(
      name: 'DEVICE-01',
      host: '192.0.2.10',
      port: 3389,
      username: 'user',
      rememberPassword: password.isNotEmpty,
      password: password,
      protocol: ConnectionProtocol.rdp,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(_mockEngine);
  tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(const MethodChannel(MacRdpChannel.channelName), null));

  testWidgets('the session is drawn in the tab, at the size the pane reports', (tester) async {
    final c = MacRdpSessionController(_rdp());
    await tester.pump();
    expect(c.embedded, isTrue);

    c.reportSize(1601, 900);
    await tester.pump();
    final connect = _named('connect').single.arguments as Map;
    expect(connect['host'], '192.0.2.10');
    expect(connect['password'], 'example-password');
    // Even width: some servers refuse odd ones for dynamic resolution.
    expect(connect['width'], 1600);
    expect(connect['height'], 900);
    expect(c.textureId, 42);

    await _engineSays({'type': 'connected'});
    expect(c.status, SessionStatus.running);
    c.dispose();
    await tester.pump();
    expect(_named('close'), hasLength(1));
  });

  testWidgets('a pane that never lays out still connects', (tester) async {
    final c = MacRdpSessionController(_rdp());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1300));
    final connect = _named('connect').single.arguments as Map;
    expect(connect['width'], 1280);
    c.dispose();
  });

  testWidgets('a resize is sent once the pane settles, not on every step', (tester) async {
    final c = MacRdpSessionController(_rdp());
    await tester.pump();
    c.reportSize(1600, 900);
    await tester.pump();
    await _engineSays({'type': 'connected'});
    for (var w = 1000; w <= 1200; w += 50) {
      c.reportSize(w, 800);
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pump(const Duration(milliseconds: 400));
    final resize = _named('resize').single.arguments as Map;
    expect(resize['width'], 1200);
    expect(resize['height'], 800);
    c.dispose();
  });

  testWidgets('no saved password: the pane asks, and the typed one is used', (tester) async {
    final c = MacRdpSessionController(_rdp(password: ''));
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: MacRdpEmbedView(controller: c, active: true))));
    await tester.pump();
    await tester.pump();
    expect(c.needsCredentials, isTrue);
    expect(_named('connect'), isEmpty);
    expect(find.text('Sign in to 192.0.2.10'), findsOneWidget);

    await tester.enterText(find.byType(TextField).last, 'typed-password');
    await tester.pump();
    await tester.tap(find.byType(FilledButton));
    await tester.pump();
    final connect = _named('connect').single.arguments as Map;
    expect(connect['password'], 'typed-password');
    expect(connect['username'], 'user');
    // Not saved anywhere.
    expect(c.conn.password, isEmpty);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });

  testWidgets('a refused password asks again instead of failing', (tester) async {
    final c = MacRdpSessionController(_rdp());
    await tester.pump();
    c.reportSize(1600, 900);
    await tester.pump();
    await _engineSays({'type': 'error', 'message': 'The user name or password was not accepted.', 'authFailed': true});
    expect(c.needsCredentials, isTrue);
    expect(c.status, isNot(SessionStatus.error));
    expect(c.lastError, contains('not accepted'));
    c.dispose();
  });

  testWidgets('keys go to the session with Cmd as Ctrl, and Ctrl+Alt+Del from the menu', (tester) async {
    final c = MacRdpSessionController(_rdp());
    await tester.pump();
    c.reportSize(1600, 900);
    await tester.pump();
    await _engineSays({'type': 'connected'});
    expect(c.canSendCtrlAltDel, isTrue);

    c.sendKey(PhysicalKeyboardKey.metaLeft.usbHidUsage, down: true);
    c.sendKey(PhysicalKeyboardKey.keyV.usbHidUsage, down: true);
    await tester.pump();
    final keys = _named('key').map((k) => (k.arguments as Map)['scancode']).toList();
    expect(keys, [0x1D, 0x2F]);

    c.sendCtrlAltDelete();
    await tester.pump();
    expect(_named('ctrlAltDel'), hasLength(1));
    c.dispose();
  });

  testWidgets('a failed session is never retried on its own (an account could lock)', (tester) async {
    final c = MacRdpSessionController(_rdp());
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: MacRdpEmbedView(controller: c, active: true))));
    await tester.pump();
    await tester.pump();
    expect(_named('connect'), hasLength(1));

    await _engineSays({'type': 'error', 'message': 'A configuration error prevented a connection to be established.'});
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(seconds: 1));
      c.reportSize(1600 + i * 2, 900);
    }
    expect(c.status, SessionStatus.error);
    expect(_named('connect'), hasLength(1));

    // Reconnect is the user's call.
    await tester.tap(find.byType(OutlinedButton));
    await tester.pump();
    expect(_named('connect'), hasLength(2));
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });

  testWidgets('a session ended from inside shows as closed, and reconnects', (tester) async {
    final c = MacRdpSessionController(_rdp());
    await tester.pump();
    c.reportSize(1600, 900);
    await tester.pump();
    await _engineSays({'type': 'connected'});
    await _engineSays({'type': 'closed'});
    expect(c.status, SessionStatus.closed);
    expect(c.textureId, isNull);

    await c.relaunch();
    await tester.pump();
    expect(_named('connect'), hasLength(2));
    c.dispose();
  });

  test('a build without the engine falls back to an external client', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel(MacRdpChannel.channelName), null);
    MacRdpChannel.resetForTest();
    expect(await MacRdpChannel.instance.available(), isFalse);
  });
}
