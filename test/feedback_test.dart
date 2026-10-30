import 'dart:io';

import 'package:commands/providers/app_state.dart';
import 'package:commands/screens/settings_screen.dart';
import 'package:commands/services/feedback_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late List<String> sent;
  late bool succeed;

  setUp(() {
    sent = [];
    succeed = true;
    FeedbackService.debugSender = (body) async {
      sent.add(body);
      return succeed;
    };
  });
  tearDown(() => FeedbackService.debugSender = null);

  test('only the message, the version and the OS are sent -- nothing that names the sender', () {
    final body = FeedbackService.compose('  Split view needs a 2x3 grid  ');
    expect(body, startsWith('Split view needs a 2x3 grid'));
    expect(body, contains('CommandS v'));
    final user = Platform.environment['USERNAME'] ?? Platform.environment['USER'] ?? '\u0000';
    final machine = Platform.environment['COMPUTERNAME'] ?? Platform.localHostname;
    expect(body.toLowerCase(), isNot(contains(user.toLowerCase())));
    expect(body.toLowerCase(), isNot(contains(machine.toLowerCase())));
  });

  Future<void> pumpSettings(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      (call) async => call.method.startsWith('is') ? false : null,
    );
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final app = AppState();
    await tester.pump();
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder sendButton() => find.widgetWithText(ElevatedButton, 'Send');

  testWidgets('Send stays off until something is written; a sent message clears the box', (tester) async {
    await pumpSettings(tester);
    expect(find.text('Support & feedback'), findsOneWidget);
    expect(tester.widget<ElevatedButton>(sendButton()).onPressed, isNull);

    await tester.enterText(find.byKey(const ValueKey('feedback-text')), 'Please add serial logging');
    await tester.pump();
    await tester.tap(sendButton());
    await tester.pumpAndSettle();
    expect(sent.single, startsWith('Please add serial logging'));
    expect(find.text('Sent. Thank you!'), findsOneWidget);
    expect(tester.widget<TextField>(find.byKey(const ValueKey('feedback-text'))).controller!.text, isEmpty);
  });

  testWidgets('a failed send says so and keeps the text', (tester) async {
    succeed = false;
    await pumpSettings(tester);
    await tester.enterText(find.byKey(const ValueKey('feedback-text')), 'hello');
    await tester.pump();
    await tester.tap(sendButton());
    await tester.pumpAndSettle();
    expect(find.textContaining('Could not send'), findsOneWidget);
    expect(tester.widget<TextField>(find.byKey(const ValueKey('feedback-text'))).controller!.text, 'hello');
  });
}
