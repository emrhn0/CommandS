import 'dart:convert';

import 'package:commands/models/models.dart';
import 'package:commands/providers/app_state.dart';
import 'package:commands/services/pty_session.dart';
import 'package:commands/services/storage_service.dart';
import 'package:commands/theme/app_theme.dart';
import 'package:commands/widgets/credential_profiles.dart';
import 'package:commands/widgets/new_connection_dialog.dart';
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

  test('a connection remembers its profile, and an old save loads without one', () {
    final c = SavedConnection(name: 'DEVICE-01', host: '192.0.2.10', credentialProfileId: 'p1');
    expect(SavedConnection.fromJson(c.toJson()).credentialProfileId, 'p1');
    final old = SavedConnection(name: 'DEVICE-02', host: '192.0.2.11').toJson();
    expect(old.containsKey('credentialProfileId'), isFalse);
    expect(SavedConnection.fromJson(old).credentialProfileId, isNull);
  });

  test('a profile password is stored encrypted and comes back', () async {
    final storage = StorageService();
    await storage.saveProfiles([CredentialProfile(name: 'Network admin', username: 'user1', password: 'example-secret')]);
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('commands.credentialProfiles')!;
    expect(raw, isNot(contains('example-secret')));
    final stored = (jsonDecode(raw) as List).single as Map;
    expect(stored['password'], '');
    expect(stored['passwordEnc'], isNotNull);
    final loaded = (await StorageService().loadProfiles()).single;
    expect(loaded.username, 'user1');
    expect(loaded.password, 'example-secret');
  });

  testWidgets('a connection with a profile logs in with the profile, and its own fields stay', (tester) async {
    final app = AppState();
    await tester.pump();
    final profile = CredentialProfile(name: 'Network admin', username: 'user1', password: 'example-secret');
    await app.upsertProfile(profile);
    final conn = SavedConnection(
      name: 'DEVICE-01', host: '192.0.2.10', username: 'old-user', password: 'old', rememberPassword: true,
      credentialProfileId: profile.id,
      enablePassword: 'enable-example-secret',
    );
    app.connections.add(conn);
    expect(app.resolved(conn).username, 'user1');
    expect(app.resolved(conn).password, 'example-secret');
    expect(app.resolved(conn).enablePassword, 'enable-example-secret');
    expect(conn.username, 'old-user', reason: 'the saved connection is not changed');

    await app.openConnection(conn);
    final session = app.tabs.single.controller as PtySessionController;
    expect(session.connectionForDuplicate().username, 'user1');
    expect(session.hasSavedPassword, isTrue);
    expect(session.connectionForDuplicate().enablePassword, 'enable-example-secret');
    expect(app.tabs.single.connectionId, conn.id);

    // A changed profile password is what the next connection uses.
    await app.upsertProfile(CredentialProfile(id: profile.id, name: 'Network admin', username: 'user2', password: 'new'));
    expect(app.resolved(conn).username, 'user2');
    for (final t in app.tabs) {
      t.controller.dispose();
    }
    app.dispose();
  });

  testWidgets('deleting a profile leaves its connections working, with its user name and password', (tester) async {
    final app = AppState();
    await tester.pump();
    final profile = CredentialProfile(name: 'Network admin', username: 'user1', password: 'example-secret');
    await app.upsertProfile(profile);
    final conn = SavedConnection(name: 'DEVICE-01', host: '192.0.2.10', credentialProfileId: profile.id);
    await app.upsertConnection(conn);
    expect(app.profileUseCount(profile.id), 1);
    await app.deleteProfile(profile.id);
    expect(app.credentialProfiles, isEmpty);
    final kept = app.connections.single;
    expect(kept.credentialProfileId, isNull);
    expect(kept.username, 'user1');
    expect(kept.password, 'example-secret');
    app.dispose();
  });

  Future<AppState> pumpDialog(WidgetTester tester, {SavedConnection? edit}) async {
    tester.view.physicalSize = const Size(1000, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final app = AppState();
    await tester.pump();
    if (edit != null) app.connections.add(edit);
    await tester.pumpWidget(ChangeNotifierProvider.value(
      value: app,
      child: MaterialApp(
        theme: AppTheme.light(),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => edit == null ? showNewConnectionDialog(context) : showEditConnectionDialog(context, edit),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    return app;
  }

  testWidgets('in a connection, "New profile…" creates one and picks it', (tester) async {
    final conn = SavedConnection(name: 'DEVICE-01', host: '192.0.2.10', username: 'old-user');
    final app = await pumpDialog(tester, edit: conn);
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Username'), findsOneWidget);

    await tester.tap(find.text('Its own user name and password'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('New profile…').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('profile-name')), 'Network admin');
    await tester.enterText(find.byKey(const Key('profile-username')), 'user1');
    await tester.enterText(find.byKey(const Key('profile-password')), 'example-secret');
    await tester.tap(find.byKey(const Key('profile-save')));
    await tester.pumpAndSettle();

    expect(app.credentialProfiles.single.name, 'Network admin');
    expect(find.text('Profile: Network admin'), findsOneWidget);
    expect(find.text('Username'), findsNothing, reason: 'the profile supplies it');
    expect(find.textContaining('Logs in as user1'), findsOneWidget);

    await tester.tap(find.widgetWithText(OutlinedButton, 'Save'));
    await tester.pumpAndSettle();
    final saved = app.connections.single;
    expect(saved.credentialProfileId, app.credentialProfiles.single.id);
    expect(saved.username, 'old-user', reason: 'its own user name is kept for later');
    app.dispose();
  });

  testWidgets('Settings lists the profiles and can add one', (tester) async {
    tester.view.physicalSize = const Size(1000, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final app = AppState();
    await tester.pump();
    await app.upsertProfile(CredentialProfile(name: 'Network admin', username: 'user1'));
    await tester.pumpWidget(ChangeNotifierProvider.value(
      value: app,
      child: MaterialApp(theme: AppTheme.light(), home: const Scaffold(body: CredentialProfilesPanel())),
    ));
    await tester.pump();
    expect(find.textContaining('Network admin'), findsOneWidget);
    await tester.tap(find.byKey(const Key('profile-add')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('profile-name')), 'Lab');
    await tester.tap(find.byKey(const Key('profile-save')));
    await tester.pumpAndSettle();
    expect(app.credentialProfiles.map((p) => p.name), containsAll(['Network admin', 'Lab']));
    app.dispose();
  });
}
