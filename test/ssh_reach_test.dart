import 'dart:io';

import 'package:commands/services/pty_session.dart';
import 'package:flutter_test/flutter_test.dart';

String screen(PtySessionController c) {
  final b = StringBuffer();
  for (var i = 0; i < c.terminal.buffer.lines.length; i++) {
    b.writeln(c.terminal.buffer.lines[i].toString());
  }
  return b.toString();
}

Future<void> until(bool Function() ok) async {
  final end = DateTime.now().add(const Duration(seconds: 15));
  while (!ok() && DateTime.now().isBefore(end)) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

void main() {
  test('nothing listening: red tab with the reason, no login prompt', () async {
    // A port that was free a moment ago: connection refused.
    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = probe.port;
    await probe.close();

    final c = PtySessionController(host: '127.0.0.1', port: port);
    await until(() => c.status == SessionStatus.error);
    expect(c.status, SessionStatus.error);
    expect(c.lastError, contains('Could not connect to 127.0.0.1:$port'));
    expect(c.lastError, contains('refused'));
    expect(screen(c), isNot(contains('login as:')));
    c.dispose();
  });

  test('a server that answers: login as: is asked, and the tab is not green yet', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((s) => s.destroy());
    final c = PtySessionController(host: '127.0.0.1', port: server.port);
    await until(() => screen(c).contains('login as:'));
    expect(screen(c), contains('login as:'));
    expect(c.status, SessionStatus.starting);
    c.dispose();
    await server.close();
  });
}
