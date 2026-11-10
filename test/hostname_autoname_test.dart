import 'dart:io';

import 'package:commands/models/models.dart';
import 'package:commands/providers/app_state.dart';
import 'package:commands/services/hostname_discovery.dart';
import 'package:commands/services/pty_session.dart';
import 'package:commands/services/storage_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MemoryLog extends HostnameDetectionLog {
  _MemoryLog() : super(directory: Directory.systemTemp);
  final reasons = <String>[];

  @override
  Future<void> record({
    required String connectionId,
    required String reason,
    required int outputChars,
    String? device,
  }) async {
    reasons.add(reason);
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    PtySessionController.checkReachability = false;
  });
  tearDown(() => PtySessionController.checkReachability = true);

  test('old saved connections do not become auto named', () {
    final old = SavedConnection.fromJson({
      'id': 'connection-01',
      'name': 'DEVICE-01',
      'host': '192.0.2.10',
    });
    expect(old.autoNamePending, isFalse);
    final pending = SavedConnection(
      name: '192.0.2.10',
      host: '192.0.2.10',
      autoNamePending: true,
    );
    expect(SavedConnection.fromJson(pending.toJson()).autoNamePending, isTrue);
  });

  testWidgets('first prompt replaces only an automatic name and persists it', (
    tester,
  ) async {
    final log = _MemoryLog();
    final app = AppState(hostnameLog: log);
    await tester.pump();
    final connection = SavedConnection(
      name: '192.0.2.10',
      host: '192.0.2.10',
      username: 'user',
      autoNamePending: true,
    );
    await app.upsertConnection(connection);
    await app.openConnection(connection);
    final session = app.tabs.single.controller as PtySessionController;
    session.debugReceiveOutput('Welcome\nuser@DEVICE-01:~\$ ');
    await tester.pump();
    expect(connection.name, 'DEVICE-01');
    expect(connection.autoNamePending, isFalse);
    expect(session.tabTitle, 'DEVICE-01');
    expect((await StorageService().loadConnections()).single.name, 'DEVICE-01');
    expect(log.reasons, isEmpty);
    app.closeTab(0);
  });

  testWidgets('manual rename wins over a late prompt', (tester) async {
    final app = AppState(hostnameLog: _MemoryLog());
    await tester.pump();
    final connection = SavedConnection(
      name: '192.0.2.10',
      host: '192.0.2.10',
      username: 'user',
      autoNamePending: true,
    );
    await app.upsertConnection(connection);
    await app.openConnection(connection);
    final session = app.tabs.single.controller as PtySessionController;
    await app.renameConnection(connection.id, 'MY-DEVICE');
    session.debugReceiveOutput('user@DEVICE-01:~\$ ');
    await tester.pump();
    expect(connection.name, 'MY-DEVICE');
    expect(connection.autoNamePending, isFalse);
    app.closeTab(0);
  });

  testWidgets('unreadable first session keeps host and records a reason', (
    tester,
  ) async {
    final log = _MemoryLog();
    final app = AppState(hostnameLog: log);
    await tester.pump();
    final connection = SavedConnection(
      name: '192.0.2.10',
      host: '192.0.2.10',
      username: 'user',
      autoNamePending: true,
    );
    await app.upsertConnection(connection);
    await app.openConnection(connection);
    final session = app.tabs.single.controller as PtySessionController;
    session.debugReceiveOutput('Welcome to the system\nPassword:');
    app.closeTab(0);
    await tester.pump();
    expect(connection.name, '192.0.2.10');
    expect(connection.autoNamePending, isFalse);
    expect(log.reasons, ['session-closed']);
  });
}
