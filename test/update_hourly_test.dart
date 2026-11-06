import 'package:commands/services/update_service.dart';
import 'package:commands/widgets/update_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _release = UpdateInfo(
  version: 'v99.0.0',
  releaseUrl: 'https://example.com/release',
  notes: 'Something new',
  assetName: 'setup.exe',
  assetUrl: 'https://example.com/setup.exe',
  assetSize: 1,
  checksumsUrl: null,
  method: UpdateMethod.windowsInstaller,
);

void main() {
  late int checks;
  UpdateInfo? answer;

  Future<void> pumpGate(WidgetTester tester) async {
    checks = 0;
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      MaterialApp(
        home: UpdateGate(
          checker: () async {
            checks++;
            return answer;
          },
          child: const Scaffold(body: SizedBox()),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 4));
  }

  Future<void> wait(WidgetTester tester, Duration d) async {
    await tester.pump(d);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  final prompt = find.text('Remind me later');

  testWidgets('a release that comes out while the app is open is offered within the hour', (tester) async {
    answer = null;
    await pumpGate(tester);
    expect(checks, 1, reason: 'the launch check');
    expect(prompt, findsNothing);

    answer = _release;
    await wait(tester, const Duration(minutes: 59));
    expect(checks, 1, reason: 'not before the hour');
    await wait(tester, const Duration(minutes: 2));
    expect(checks, 2);
    expect(prompt, findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('"Remind me later" brings it back an hour later, not sooner', (tester) async {
    answer = _release;
    await pumpGate(tester);
    await wait(tester, Duration.zero);
    expect(prompt, findsOneWidget);
    await tester.tap(prompt);
    await tester.pumpAndSettle();
    expect(prompt, findsNothing);
    await wait(tester, const Duration(minutes: 59));
    expect(prompt, findsNothing);
    await wait(tester, const Duration(minutes: 2));
    expect(prompt, findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a prompt left open does not get a second one over it', (tester) async {
    answer = _release;
    await pumpGate(tester);
    await wait(tester, Duration.zero);
    await wait(tester, const Duration(hours: 3));
    expect(checks, 1);
    expect(prompt, findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a skipped version stays quiet', (tester) async {
    answer = _release;
    await pumpGate(tester);
    await wait(tester, Duration.zero);
    await tester.tap(find.text('Skip this version'));
    await tester.pumpAndSettle();
    await wait(tester, const Duration(hours: 2));
    expect(prompt, findsNothing);
    expect(checks, greaterThan(1), reason: 'a newer version would still be found');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('another dialog being open puts the prompt off, without losing it', (tester) async {
    answer = null;
    await pumpGate(tester);
    showDialog<void>(
      context: tester.element(find.byType(Scaffold)),
      builder: (_) => const AlertDialog(content: Text('BUSY')),
    );
    await tester.pump(const Duration(milliseconds: 300));
    answer = _release;
    await wait(tester, const Duration(hours: 1, minutes: 1));
    expect(prompt, findsNothing);
    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pumpAndSettle();
    await wait(tester, const Duration(minutes: 2));
    expect(prompt, findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  for (final dark in [false, true]) {
    testWidgets('the update button is green in the ${dark ? 'dark' : 'light'} theme', (tester) async {
      UpdateService.available.value = _release;
      addTearDown(() => UpdateService.available.value = null);
      await tester.pumpWidget(MaterialApp(
        theme: dark ? ThemeData.dark() : ThemeData.light(),
        home: const Scaffold(body: Center(child: UpdateButton(compact: true))),
      ));
      final material = tester.widget<Material>(find.byKey(const ValueKey('update-button')));
      expect(material.color, updateGreen);
    });
  }
}
