import 'dart:io';

import 'package:commands/services/serial_session.dart';
import 'package:commands/services/session_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseSerialTarget', () {
    test('a port number is a COM port at 9600 baud', () {
      expect(parseSerialTarget('3'), (port: 'COM3', baud: 9600));
      expect(parseSerialTarget(' 12 '), (port: 'COM12', baud: 9600));
    });
    test(':speed sets the baud rate', () {
      expect(parseSerialTarget('3:115200'), (port: 'COM3', baud: 115200));
    });
    test('anything else is refused', () {
      for (final bad in ['', 'COM3', '0', '257', '3:', '3:abc', '3:10', 'x', '3:9600:1']) {
        expect(parseSerialTarget(bad), isNull, reason: bad);
      }
    });
    test('macOS takes a /dev device name', () {
      expect(parseSerialTarget('tty.usbserial-120', windows: false), (
        port: '/dev/tty.usbserial-120',
        baud: 9600,
      ));
      expect(parseSerialTarget('../etc/passwd', windows: false), isNull);
    });
  });

  test('a port that does not exist reports so plainly', () async {
    if (!Platform.isWindows) return;
    final c = SerialSessionController(port: 'COM250');
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (c.status == SessionStatus.starting && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(c.status, SessionStatus.error);
    expect(c.lastError, contains('COM250 not found'));
    c.dispose();
  });
}
