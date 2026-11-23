/// Keyboard and mouse translation for the embedded macOS RDP session
/// ([MacRdpSessionController]).
///
/// Keys are sent to the server as PC scancodes (set 1), the way mstsc and the
/// Microsoft clients do it: the server's own keyboard layout then decides what
/// character a key makes, so a Turkish Q layout on the remote side types
/// Turkish whatever the Mac is set to. Flutter's [PhysicalKeyboardKey] gives a
/// USB HID usage for every key, which maps to exactly one scancode.
library;

/// RDP scancode with the extended (E0) prefix in bit 8, as FreeRDP's
/// `MAKE_RDP_SCANCODE` builds it.
const int rdpExtended = 0x100;

/// USB HID usage (page 7, the low 16 bits of `usbHidUsage`) to RDP scancode.
const Map<int, int> _hidToScancode = {
  // Letters a-z.
  0x04: 0x1E, 0x05: 0x30, 0x06: 0x2E, 0x07: 0x20, 0x08: 0x12, 0x09: 0x21,
  0x0A: 0x22, 0x0B: 0x23, 0x0C: 0x17, 0x0D: 0x24, 0x0E: 0x25, 0x0F: 0x26,
  0x10: 0x32, 0x11: 0x31, 0x12: 0x18, 0x13: 0x19, 0x14: 0x10, 0x15: 0x13,
  0x16: 0x1F, 0x17: 0x14, 0x18: 0x16, 0x19: 0x2F, 0x1A: 0x11, 0x1B: 0x2D,
  0x1C: 0x15, 0x1D: 0x2C,
  // Digits 1-9, 0.
  0x1E: 0x02, 0x1F: 0x03, 0x20: 0x04, 0x21: 0x05, 0x22: 0x06, 0x23: 0x07,
  0x24: 0x08, 0x25: 0x09, 0x26: 0x0A, 0x27: 0x0B,
  0x28: 0x1C, // Enter
  0x29: 0x01, // Escape
  0x2A: 0x0E, // Backspace
  0x2B: 0x0F, // Tab
  0x2C: 0x39, // Space
  0x2D: 0x0C, // - _
  0x2E: 0x0D, // = +
  0x2F: 0x1A, // [ {
  0x30: 0x1B, // ] }
  0x31: 0x2B, // \ |
  0x32: 0x2B, // non-US # ~
  0x33: 0x27, // ; :
  0x34: 0x28, // ' "
  0x35: 0x29, // ` ~
  0x36: 0x33, // , <
  0x37: 0x34, // . >
  0x38: 0x35, // / ?
  0x39: 0x3A, // Caps Lock
  // F1-F12.
  0x3A: 0x3B, 0x3B: 0x3C, 0x3C: 0x3D, 0x3D: 0x3E, 0x3E: 0x3F, 0x3F: 0x40,
  0x40: 0x41, 0x41: 0x42, 0x42: 0x43, 0x43: 0x44, 0x44: 0x57, 0x45: 0x58,
  0x46: rdpExtended | 0x37, // Print Screen
  0x47: 0x46, // Scroll Lock
  0x49: rdpExtended | 0x52, // Insert
  0x4A: rdpExtended | 0x47, // Home
  0x4B: rdpExtended | 0x49, // Page Up
  0x4C: rdpExtended | 0x53, // Delete (forward)
  0x4D: rdpExtended | 0x4F, // End
  0x4E: rdpExtended | 0x51, // Page Down
  0x4F: rdpExtended | 0x4D, // Right
  0x50: rdpExtended | 0x4B, // Left
  0x51: rdpExtended | 0x50, // Down
  0x52: rdpExtended | 0x48, // Up
  0x53: 0x45, // Num Lock (Clear on a Mac keypad)
  0x54: rdpExtended | 0x35, // Keypad /
  0x55: 0x37, // Keypad *
  0x56: 0x4A, // Keypad -
  0x57: 0x4E, // Keypad +
  0x58: rdpExtended | 0x1C, // Keypad Enter
  0x59: 0x4F, 0x5A: 0x50, 0x5B: 0x51, 0x5C: 0x4B, 0x5D: 0x4C, 0x5E: 0x4D,
  0x5F: 0x47, 0x60: 0x48, 0x61: 0x49, 0x62: 0x52, // Keypad 1-9, 0
  0x63: 0x53, // Keypad .
  0x64: 0x56, // the key next to left Shift on ISO keyboards
  0x65: rdpExtended | 0x5D, // Menu
  0x67: 0x59, // Keypad =
  0x68: 0x64, 0x69: 0x65, 0x6A: 0x66, // F13-F15
  0x87: 0x73, // International Ro
  0x89: 0x7D, // International Yen
  0xE0: 0x1D, // Left Control
  0xE1: 0x2A, // Left Shift
  0xE2: 0x38, // Left Option / Alt
  0xE3: rdpExtended | 0x5B, // Left Command / Windows
  0xE4: rdpExtended | 0x1D, // Right Control
  0xE5: 0x36, // Right Shift
  0xE6: rdpExtended | 0x38, // Right Option / AltGr
  0xE7: rdpExtended | 0x5C, // Right Command / Windows
};

const int _scanBackquote = 0x29;
const int _scanIntlBackslash = 0x56;
const int _scanLeftControl = 0x1D;
const int _scanLeftWindows = rdpExtended | 0x5B;
const int _scanRightWindows = rdpExtended | 0x5C;

/// The RDP scancode for a key, from Flutter's `PhysicalKeyboardKey.usbHidUsage`.
/// Null for a key the server has no use for (media keys, Fn).
///
/// [isoKeyboard]: on Apple's ISO keyboards macOS reports the key left of 1 as
/// the ISO key and the key next to left Shift as the grave key, the other way
/// round from a PC. Swapping them back puts `<` and `"` (on a Turkish Q
/// layout) where the keycaps say.
int? rdpScancodeForHid(int usbHidUsage, {bool isoKeyboard = false}) {
  if ((usbHidUsage >> 16) != 0x07) return null;
  final code = _hidToScancode[usbHidUsage & 0xFFFF];
  if (code == null || !isoKeyboard) return code;
  if (code == _scanBackquote) return _scanIntlBackslash;
  if (code == _scanIntlBackslash) return _scanBackquote;
  return code;
}

/// One key event to send: down or up, with its scancode.
class RdpKeyStroke {
  const RdpKeyStroke(this.scancode, {required this.down});
  final int scancode;
  final bool down;

  @override
  bool operator ==(Object other) => other is RdpKeyStroke && other.scancode == scancode && other.down == down;

  @override
  int get hashCode => Object.hash(scancode, down);

  @override
  String toString() => 'RdpKeyStroke(0x${scancode.toRadixString(16)}, ${down ? 'down' : 'up'})';
}

/// Turns Mac key presses into what a Windows desktop expects.
///
/// Command is the one key whose meaning differs: a Mac user presses Cmd+C to
/// copy, which on Windows is Ctrl+C. So Command held with another key is sent
/// as Control, the way Microsoft's own Mac client does it by default. Command
/// pressed and released on its own is still the Windows key, so the Start menu
/// is one tap away.
class RdpKeyTranslator {
  RdpKeyTranslator({this.isoKeyboard = false});

  bool isoKeyboard;

  /// Command keys held right now, and whether another key went down while
  /// they were (then they act as Control).
  final Set<int> _commandHeld = {};
  bool _commandUsed = false;

  /// Keys currently down on the server, so a lost focus can release them.
  final Set<int> _down = {};

  static bool _isCommand(int scancode) => scancode == _scanLeftWindows || scancode == _scanRightWindows;

  /// What to send for one key event. [repeat] is the key held down.
  List<RdpKeyStroke> translate(int usbHidUsage, {required bool down, bool repeat = false}) {
    final scancode = rdpScancodeForHid(usbHidUsage, isoKeyboard: isoKeyboard);
    if (scancode == null) return const [];
    final out = <RdpKeyStroke>[];
    if (_isCommand(scancode)) {
      if (down) {
        if (!repeat) _commandHeld.add(scancode);
        return out;
      }
      if (!_commandHeld.remove(scancode)) return out;
      if (_commandHeld.isEmpty) {
        if (_commandUsed) {
          _commandUsed = false;
          if (_down.remove(_scanLeftControl)) out.add(const RdpKeyStroke(_scanLeftControl, down: false));
        } else {
          out
            ..add(RdpKeyStroke(scancode, down: true))
            ..add(RdpKeyStroke(scancode, down: false));
        }
      }
      return out;
    }
    if (down && _commandHeld.isNotEmpty && !_commandUsed) {
      _commandUsed = true;
      if (_down.add(_scanLeftControl)) out.add(const RdpKeyStroke(_scanLeftControl, down: true));
    }
    if (down) {
      _down.add(scancode);
    } else if (!_down.remove(scancode)) {
      // Never went down here (pressed before the session had focus).
      return out;
    }
    out.add(RdpKeyStroke(scancode, down: down));
    return out;
  }

  /// Key-ups for everything still held, for when the session loses focus
  /// mid-press: otherwise the server sees Shift or Control stuck down.
  List<RdpKeyStroke> releaseAll() {
    final out = [for (final s in _down) RdpKeyStroke(s, down: false)];
    _down.clear();
    _commandHeld.clear();
    _commandUsed = false;
    return out;
  }
}

/// RDP pointer flags (MS-RDPBCGR 2.2.8.1.1.3.1.1.3).
abstract final class RdpPointer {
  static const move = 0x0800;
  static const down = 0x8000;
  static const button1 = 0x1000; // left
  static const button2 = 0x2000; // right
  static const button3 = 0x4000; // middle
  static const wheel = 0x0200;
  static const hWheel = 0x0400;
  static const wheelNegative = 0x0100;

  /// One wheel notch, as Windows counts them.
  static const wheelDelta = 120;

  /// Flutter's button bitmask (kPrimaryButton...) to the RDP button flag.
  static int? buttonFlag(int flutterButton) => switch (flutterButton) {
        1 => button1,
        2 => button2,
        4 => button3,
        _ => null,
      };

  /// Wheel flags for a turn of [value] (120 is one notch; positive scrolls
  /// content up, as Windows counts it). Clamped to what fits the 9-bit field.
  static int wheelFlags(int value, {bool horizontal = false}) {
    final v = value.clamp(-255, 255);
    var flags = horizontal ? hWheel : wheel;
    if (v < 0) {
      flags |= wheelNegative | ((0x100 + v) & 0xFF);
    } else {
      flags |= v & 0xFF;
    }
    return flags;
  }
}
