import 'dart:async';
import 'dart:io';

import 'package:commands/models/models.dart';
import 'package:commands/providers/app_state.dart';
import 'package:commands/services/device_detect.dart';
import 'package:commands/services/pty_session.dart';
import 'package:commands/theme/app_theme.dart';
import 'package:commands/widgets/connection_tree.dart';
import 'package:commands/widgets/new_connection_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('detectDevice', () {
    test('from the server identification line', () {
      expect(detectDevice(serverVersion: 'SSH-2.0-Cisco-1.25'), DeviceKind.cisco);
      expect(detectDevice(serverVersion: 'SSH-2.0-HUAWEI-1.5'), DeviceKind.huawei);
      expect(detectDevice(serverVersion: 'SSH-2.0-OpenSSH_for_Windows_8.1'), DeviceKind.windows);
      expect(detectDevice(serverVersion: 'SSH-2.0-OpenSSH_9.6'), isNull);
    });

    test('from what the device prints after login', () {
      expect(
        detectDevice(output: 'The time and date of this login have been sent to the system logs.\r\n\r\n'
            'VMware offers supported, powerful system administration tools.\r\n[root@host:~] '),
        DeviceKind.vmware,
      );
      expect(
        detectDevice(output: 'Last login: Mon Oct 27 10:00:00 2026\r\n'
            'Number of failed attempts since last successful login: 0\r\n\r\nadmin@FW-01> '),
        DeviceKind.paloalto,
      );
      expect(detectDevice(output: 'Version: FortiGate-60F v7.2.5,build1517\r\n'), DeviceKind.fortinet);
      expect(
        detectDevice(output: 'Info: The max number of VTY users is 10, and the number\r\n'
            '      of current VTY users on line is 1.\r\n<SW-01>'),
        DeviceKind.huawei,
      );
      expect(detectDevice(output: 'ArubaOS-CX\r\n(c) Copyright Hewlett Packard Enterprise\r\nSW-01# '), DeviceKind.aruba);
      expect(detectDevice(output: 'Cisco IOS Software, C2960X Software\r\nSW-01>'), DeviceKind.cisco);
      expect(detectDevice(output: 'Welcome to Ubuntu 22.04.3 LTS (GNU/Linux 5.15.0 x86_64)\r\n'), DeviceKind.linux);
      expect(detectDevice(output: 'Microsoft Windows [Version 10.0.20348.2340]\r\n'), DeviceKind.windows);
    });

    test('a coloured bash prompt is Linux; a bare ESXi prompt is not', () {
      expect(
        detectDevice(output: '\x1B[01;32muser@host\x1B[00m:\x1B[01;34m~\x1B[00m\$ '),
        DeviceKind.linux,
      );
      expect(detectDevice(output: '[root@host:~] '), isNull);
    });

    test('an appliance banner beats the Linux signs it also prints', () {
      expect(
        detectDevice(output: 'VMware vCenter Server 8.0\r\nroot@vcsa:~# '),
        DeviceKind.vmware,
      );
    });

    test('a Debian/Ubuntu version line alone counts only once settled', () {
      const v = 'SSH-2.0-OpenSSH_8.9p1 Ubuntu-3ubuntu0.6';
      expect(detectDevice(serverVersion: v), isNull);
      expect(detectDevice(serverVersion: v, settled: true), DeviceKind.linux);
      expect(detectDevice(serverVersion: v, output: 'VMware vCenter Server', settled: true), DeviceKind.vmware);
    });
  });

  test('the identification line is read without sending anything', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final received = <int>[];
    server.listen((s) {
      s.listen(received.addAll, onError: (_) {});
      s.add('SSH-2.0-Test_1.0\r\n'.codeUnits);
    });
    final socket = await Socket.connect(InternetAddress.loopbackIPv4, server.port);
    final line = await PtySessionController.readIdentification(socket);
    socket.destroy();
    await server.close();
    expect(line, 'SSH-2.0-Test_1.0');
    expect(received, isEmpty);
  });

  test('a server that says nothing gives an empty line, not a hang', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final held = <Socket>[];
    server.listen(held.add);
    final socket = await Socket.connect(InternetAddress.loopbackIPv4, server.port);
    final line = await PtySessionController.readIdentification(socket).timeout(const Duration(seconds: 5));
    socket.destroy();
    for (final s in held) {
      s.destroy();
    }
    await server.close();
    expect(line, '');
  });

  test('the device is saved with the connection', () {
    final c = SavedConnection(name: 'DEVICE-01', host: '192.0.2.10', device: DeviceKind.paloalto);
    final back = SavedConnection.fromJson(c.toJson());
    expect(back.device, DeviceKind.paloalto);
    expect(back.deviceManual, isFalse);
    expect(SavedConnection.fromJson(SavedConnection(name: 'x', host: '192.0.2.1').toJson()).device, isNull);
  });

  testWidgets('the list shows the logo; RDP is always Windows', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final app = AppState();
    await tester.pump();
    app.connections.addAll([
      SavedConnection(name: 'DEVICE-01', host: '192.0.2.10', device: DeviceKind.paloalto),
      SavedConnection(name: 'DEVICE-02', host: '192.0.2.11', port: 3389, protocol: ConnectionProtocol.rdp),
      SavedConnection(name: 'DEVICE-03', host: '192.0.2.12'),
    ]);
    await tester.pumpWidget(ChangeNotifierProvider.value(
      value: app,
      child: const MaterialApp(home: Scaffold(body: SizedBox(width: 300, height: 400, child: ConnectionTree()))),
    ));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('device-paloalto')), findsOneWidget);
    expect(find.byKey(const ValueKey('device-windows')), findsOneWidget);
    expect(find.byIcon(Icons.terminal), findsOneWidget, reason: 'unknown devices keep the plain icon');
  });

  Future<AppState> openEdit(WidgetTester tester, SavedConnection conn) async {
    tester.view.physicalSize = const Size(1000, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final app = AppState();
    await tester.pump();
    app.connections.add(conn);
    await tester.pumpWidget(ChangeNotifierProvider.value(
      value: app,
      child: MaterialApp(
        theme: AppTheme.light(),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(onPressed: () => showEditConnectionDialog(context, conn), child: const Text('open')),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return app;
  }

  Future<void> save(WidgetTester tester) async {
    await tester.tap(find.widgetWithText(OutlinedButton, 'Save'));
    await tester.pumpAndSettle();
  }

  testWidgets('editing keeps a detected device', (tester) async {
    final app = await openEdit(tester, SavedConnection(name: 'DEVICE-01', host: '192.0.2.10', device: DeviceKind.cisco));
    expect(find.text('Automatic (Cisco)'), findsOneWidget);
    await save(tester);
    expect(app.connections.single.device, DeviceKind.cisco);
    expect(app.connections.single.deviceManual, isFalse);
  });

  testWidgets('a device picked by hand sticks', (tester) async {
    final app = await openEdit(tester, SavedConnection(name: 'DEVICE-01', host: '192.0.2.10'));
    await tester.tap(find.byKey(const ValueKey('device-field')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Huawei').last);
    await tester.pumpAndSettle();
    await save(tester);
    expect(app.connections.single.device, DeviceKind.huawei);
    expect(app.connections.single.deviceManual, isTrue);
  });

  testWidgets('detection updates a connection but never a hand-picked one', (tester) async {
    SharedPreferences.setMockInitialValues({});
    PtySessionController.checkReachability = false;
    addTearDown(() => PtySessionController.checkReachability = true);
    final app = AppState();
    await tester.pump();
    final auto = SavedConnection(name: 'DEVICE-01', host: '192.0.2.10', username: 'u');
    final manual = SavedConnection(
      name: 'DEVICE-02',
      host: '192.0.2.11',
      username: 'u',
      device: DeviceKind.aruba,
      deviceManual: true,
    );
    app.connections.addAll([auto, manual]);
    await app.openConnection(auto);
    await app.openConnection(manual);
    for (final t in app.tabs) {
      (t.controller as PtySessionController).onDeviceDetected!(DeviceKind.linux);
    }
    await tester.pump();
    expect(auto.device, DeviceKind.linux);
    expect(manual.device, DeviceKind.aruba);
    for (final t in app.tabs) {
      t.controller.dispose();
    }
    await tester.pump(const Duration(seconds: 1));
  });
}
