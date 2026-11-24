import 'package:commands/models/models.dart';
import 'package:commands/services/mac_rdp_session.dart';
import 'package:commands/services/session_controller.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Stands in for the system clipboard: what Clipboard.setData last wrote.
String? _clipboard;

void _mockClipboard() {
  _clipboard = null;
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(SystemChannels.platform, (call) async {
    switch (call.method) {
      case 'Clipboard.setData':
        _clipboard = (call.arguments as Map)['text'] as String?;
        return null;
      case 'Clipboard.getData':
        return _clipboard == null ? null : {'text': _clipboard};
    }
    return null;
  });
}

SavedConnection _rdp({bool rememberPassword = true}) => SavedConnection(
      name: 'DEVICE-01',
      host: '192.0.2.10',
      port: 3389,
      username: 'user',
      rememberPassword: rememberPassword,
      password: 'example-password',
      protocol: ConnectionProtocol.rdp,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(_mockClipboard);
  tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(SystemChannels.platform, null));

  testWidgets('a copied password is taken off the clipboard after 30 seconds', (tester) async {
    final controller = MacRdpSessionController.idle(_rdp());
    expect(await controller.copyPasswordToClipboard(), isTrue);
    expect(_clipboard, 'example-password');

    await tester.pump(const Duration(seconds: 29));
    expect(_clipboard, 'example-password');
    await tester.pump(const Duration(seconds: 2));
    expect(_clipboard, '');
    controller.dispose();
  });

  testWidgets('something the user copied afterwards is left alone', (tester) async {
    final controller = MacRdpSessionController.idle(_rdp());
    await controller.copyPasswordToClipboard();
    await Clipboard.setData(const ClipboardData(text: 'copied later'));

    await tester.pump(MacRdpSessionController.clipboardClearDelay + const Duration(seconds: 1));
    expect(_clipboard, 'copied later');
    controller.dispose();
  });

  testWidgets('the password is cleared even when the tab closed first', (tester) async {
    final controller = MacRdpSessionController.idle(_rdp());
    await controller.copyPasswordToClipboard();
    controller.dispose();

    await tester.pump(MacRdpSessionController.clipboardClearDelay + const Duration(seconds: 1));
    expect(_clipboard, '');
  });

  test('nothing is copied without a remembered password', () async {
    final controller = MacRdpSessionController.idle(_rdp(rememberPassword: false));
    expect(await controller.copyPasswordToClipboard(), isFalse);
    expect(_clipboard, isNull);
    controller.dispose();
  });

  test('FreeRDP trusts a certificate on first use instead of ignoring it', () {
    final controller = MacRdpSessionController.idle(_rdp());
    final args = controller.freeRdpArguments();
    expect(args, contains('/cert:tofu'));
    expect(args, isNot(contains('/cert:ignore')));
    expect(args, contains('/v:192.0.2.10:3389'));
    controller.dispose();
  });

  test('under test, a build without the engine starts no outside RDP client', () async {
    expect(MacRdpSessionController.launchExternalClients, isFalse);
    final controller = MacRdpSessionController(_rdp());
    final end = DateTime.now().add(const Duration(seconds: 5));
    while (controller.status == SessionStatus.starting && DateTime.now().isBefore(end)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(controller.status, SessionStatus.error);
    expect(controller.backend, isNull, reason: 'neither FreeRDP nor Windows App was opened');
    controller.dispose();
  });
}
