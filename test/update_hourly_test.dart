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

  testWidgets('a release that comes out while the app is open is offered within a minute', (tester) async {
    answer = null;
    await pumpGate(tester);
    expect(checks, 1, reason: 'the launch check');
    expect(prompt, findsNothing);

    answer = _release;
    await wait(tester, const Duration(seconds: 50));
    expect(checks, 1, reason: 'not before a minute');
    await wait(tester, const Duration(seconds: 15));
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
    // Still checked every minute, but the same version stays quiet.
    for (var i = 0; i < 58; i++) {
      await wait(tester, const Duration(minutes: 1));
    }
    expect(prompt, findsNothing);
    expect(checks, greaterThan(50));
    await wait(tester, const Duration(minutes: 3));
    expect(prompt, findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('after "Remind me later", a newer version is offered at once', (tester) async {
    answer = _release;
    await pumpGate(tester);
    await wait(tester, Duration.zero);
    await tester.tap(prompt);
    await tester.pumpAndSettle();
    answer = const UpdateInfo(
      version: 'v99.0.1',
      releaseUrl: 'https://example.com/release',
      notes: 'Newer',
      assetName: 'setup.exe',
      assetUrl: 'https://example.com/setup.exe',
      assetSize: 1,
      checksumsUrl: null,
      method: UpdateMethod.windowsInstaller,
    );
    await wait(tester, const Duration(seconds: 65));
    expect(prompt, findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a prompt left open keeps checking, but never gets a second one over it', (tester) async {
    answer = _release;
    await pumpGate(tester);
    await wait(tester, Duration.zero);
    await wait(tester, const Duration(minutes: 5));
    expect(checks, greaterThan(3), reason: 'a newer version could come out meanwhile');
    expect(prompt, findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a newer version that comes out while the prompt is open takes its place', (tester) async {
    answer = _release;
    await pumpGate(tester);
    await wait(tester, Duration.zero);
    expect(find.text('CommandS v99.0.0 is available'), findsOneWidget);
    answer = const UpdateInfo(
      version: 'v99.1.0',
      releaseUrl: 'https://example.com/release',
      notes: 'Newer',
      assetName: 'setup.exe',
      assetUrl: 'https://example.com/setup.exe',
      assetSize: 1,
      checksumsUrl: null,
      method: UpdateMethod.windowsInstaller,
    );
    await wait(tester, const Duration(seconds: 65));
    await tester.pumpAndSettle();
    expect(find.text('CommandS v99.0.0 is available'), findsNothing);
    expect(find.text('CommandS v99.1.0 is available'), findsOneWidget);
    expect(prompt, findsOneWidget, reason: 'one prompt, not two');
    expect(find.byKey(const Key('update-replaces')), findsOneWidget);
    expect(find.text('A newer version came out: v99.1.0 replaces v99.0.0.'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the same version found again leaves the open prompt alone', (tester) async {
    answer = _release;
    await pumpGate(tester);
    await wait(tester, Duration.zero);
    await wait(tester, const Duration(seconds: 65));
    expect(find.byKey(const Key('update-replaces')), findsNothing);
    expect(find.text('CommandS v99.0.0 is available'), findsOneWidget);
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
    await wait(tester, const Duration(minutes: 3));
    expect(prompt, findsNothing);
    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pumpAndSettle();
    await wait(tester, const Duration(seconds: 65));
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
