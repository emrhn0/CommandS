import 'package:commands/services/rdp_keymap.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

int _hid(PhysicalKeyboardKey key) => key.usbHidUsage;

void main() {
  group('scancodes', () {
    test('letters, digits and Enter map to their PC scancodes', () {
      expect(rdpScancodeForHid(_hid(PhysicalKeyboardKey.keyA)), 0x1E);
      expect(rdpScancodeForHid(_hid(PhysicalKeyboardKey.keyQ)), 0x10);
      expect(rdpScancodeForHid(_hid(PhysicalKeyboardKey.digit1)), 0x02);
      expect(rdpScancodeForHid(_hid(PhysicalKeyboardKey.enter)), 0x1C);
    });

    test('arrows, Delete and right-hand modifiers carry the extended flag', () {
      expect(rdpScancodeForHid(_hid(PhysicalKeyboardKey.arrowLeft)), rdpExtended | 0x4B);
      expect(rdpScancodeForHid(_hid(PhysicalKeyboardKey.delete)), rdpExtended | 0x53);
      expect(rdpScancodeForHid(_hid(PhysicalKeyboardKey.altRight)), rdpExtended | 0x38);
      expect(rdpScancodeForHid(_hid(PhysicalKeyboardKey.metaLeft)), rdpExtended | 0x5B);
      expect(rdpScancodeForHid(_hid(PhysicalKeyboardKey.numpadEnter)), rdpExtended | 0x1C);
    });

    test('an ISO keyboard swaps the grave and ISO keys back', () {
      final grave = _hid(PhysicalKeyboardKey.backquote);
      final iso = _hid(PhysicalKeyboardKey.intlBackslash);
      expect(rdpScancodeForHid(grave), 0x29);
      expect(rdpScancodeForHid(iso), 0x56);
      expect(rdpScancodeForHid(grave, isoKeyboard: true), 0x56);
      expect(rdpScancodeForHid(iso, isoKeyboard: true), 0x29);
    });

    test('keys the server has no use for are dropped', () {
      expect(rdpScancodeForHid(_hid(PhysicalKeyboardKey.fn)), isNull);
      expect(rdpScancodeForHid(_hid(PhysicalKeyboardKey.audioVolumeUp)), isNull);
    });
  });

  group('Command key', () {
    final cmd = _hid(PhysicalKeyboardKey.metaLeft);
    final c = _hid(PhysicalKeyboardKey.keyC);
    const ctrl = 0x1D;
    const win = rdpExtended | 0x5B;

    test('Cmd+C is sent as Ctrl+C', () {
      final t = RdpKeyTranslator();
      expect(t.translate(cmd, down: true), isEmpty);
      expect(t.translate(c, down: true), const [RdpKeyStroke(ctrl, down: true), RdpKeyStroke(0x2E, down: true)]);
      expect(t.translate(c, down: false), const [RdpKeyStroke(0x2E, down: false)]);
      expect(t.translate(cmd, down: false), const [RdpKeyStroke(ctrl, down: false)]);
    });

    test('Command tapped on its own is the Windows key', () {
      final t = RdpKeyTranslator();
      expect(t.translate(cmd, down: true), isEmpty);
      expect(t.translate(cmd, down: false), const [RdpKeyStroke(win, down: true), RdpKeyStroke(win, down: false)]);
    });

    test('a held key repeating does not count as a second press of Command', () {
      final t = RdpKeyTranslator();
      t.translate(cmd, down: true);
      t.translate(cmd, down: true, repeat: true);
      expect(t.translate(cmd, down: false), hasLength(2));
    });

    test('losing focus releases everything still held', () {
      final t = RdpKeyTranslator();
      t.translate(_hid(PhysicalKeyboardKey.shiftLeft), down: true);
      t.translate(cmd, down: true);
      t.translate(c, down: true);
      expect(
        t.releaseAll().toSet(),
        {const RdpKeyStroke(0x2A, down: false), const RdpKeyStroke(ctrl, down: false), const RdpKeyStroke(0x2E, down: false)},
      );
      // A key-up for a key that went down before is not sent twice.
      expect(t.translate(c, down: false), isEmpty);
      expect(t.translate(cmd, down: false), isEmpty);
    });
  });

  group('pointer', () {
    test('one wheel notch either way, as Windows encodes it', () {
      expect(RdpPointer.wheelFlags(120), 0x0278);
      expect(RdpPointer.wheelFlags(-120), 0x0388);
      expect(RdpPointer.wheelFlags(-120, horizontal: true), 0x0588);
    });

    test('a turn too big for the field is clamped, not wrapped', () {
      expect(RdpPointer.wheelFlags(1000) & 0xFF, 0xFF);
      expect(RdpPointer.wheelFlags(-1000), RdpPointer.wheel | RdpPointer.wheelNegative | 0x01);
    });

    test('Flutter buttons map to RDP buttons', () {
      expect(RdpPointer.buttonFlag(kPrimaryButton), RdpPointer.button1);
      expect(RdpPointer.buttonFlag(kSecondaryButton), RdpPointer.button2);
      expect(RdpPointer.buttonFlag(kMiddleMouseButton), RdpPointer.button3);
    });
  });
}
