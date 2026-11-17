import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:win32/win32.dart';

/// Dead keys in the terminal: the accent keys that wait for the next key,
/// such as AltGr+Ü for ~ on a Turkish Q keyboard, ^ and ´ on a German one, or
/// ' and " on US-International.
///
/// On Windows, Flutter reports the press of a dead key as a key-down whose
/// character is the key's plain letter (Ü for that key), and the accent comes
/// only with the next key, composed with it where it can be (~ then a gives
/// ã). A terminal wants neither: AltGr+Ü should type ~ at once, as in PuTTY,
/// and the next key its own letter. So the terminal asks Windows what the
/// key is ([translate]) and types that instead of the event's character.
class DeadKeys {
  DeadKeys._();

  /// What to type for [event] instead of its own character: the accent of a
  /// dead key at once, and for the key after it the key's plain character.
  /// Null when the event is not about a dead key and goes through as usual.
  /// Replaced in tests.
  static String? Function(KeyEvent event) translate = _translateWindows;

  /// A dead key was typed and Windows still holds it to compose with the
  /// next key; that key is typed plain.
  static bool _afterDeadKey = false;

  static final Map<int, int> _scanCodeOf = {
    for (final e in kWindowsToPhysicalKey.entries) e.value.usbHidUsage: e.key,
  };

  static String? _translateWindows(KeyEvent event) {
    if (!Platform.isWindows || event is KeyUpEvent) return null;
    final character = event.character;
    // Modifiers (Shift for a capital after the accent) carry no character
    // and leave a pending dead key pending.
    if (character == null || character.isEmpty) return null;
    final scanCode = _scanCodeOf[event.physicalKey.usbHidUsage];
    if (scanCode == null) return null;
    try {
      // The layout of the window the keys go to: this isolate's thread has
      // its own, which need not be the one in use.
      final thread = GetWindowThreadProcessId(GetForegroundWindow(), nullptr);
      final layout = GetKeyboardLayout(thread);
      final key = keyOnLayout(scanCode, layout);
      if (key == null) return null;
      if (key.dead) {
        _afterDeadKey = true;
        return key.text;
      }
      if (_afterDeadKey) {
        _afterDeadKey = false;
        return key.text;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// What the key with [scanCode] types on [layout] with the modifiers held
  /// right now ([held], virtual-key codes, in tests): its text, and whether
  /// it is a dead key (then the text is its accent, such as ~). Asks Windows
  /// without touching the keyboard state, and from a thread with no accent
  /// waiting, so the answer is the key on its own.
  @visibleForTesting
  static ({String text, bool dead})? keyOnLayout(int scanCode, int layout, {List<int>? held}) {
    final vk = MapVirtualKeyEx(scanCode, MAPVK_VSC_TO_VK_EX, layout);
    if (vk == 0) return null;
    final state = calloc<Uint8>(256);
    final buffer = calloc<Uint16>(8);
    try {
      for (final key in const [
        VK_SHIFT,
        VK_LSHIFT,
        VK_RSHIFT,
        VK_CONTROL,
        VK_LCONTROL,
        VK_RCONTROL,
        VK_MENU,
        VK_LMENU,
        VK_RMENU,
      ]) {
        final down = held != null ? held.contains(key) : GetAsyncKeyState(key) & 0x8000 != 0;
        if (down) state[key] = 0x80;
      }
      if (held == null && GetKeyState(VK_CAPITAL) & 1 != 0) state[VK_CAPITAL] = 0x01;
      // Flag 4: leave the keyboard state alone (Windows 10 1607 and later).
      final result = ToUnicodeEx(vk, scanCode, state, buffer.cast(), 8, 4, layout);
      if (result == 0) return null;
      final length = result < 0 ? 1 : result;
      final text = String.fromCharCodes([for (var i = 0; i < length; i++) buffer[i]]);
      return (text: text, dead: result < 0);
    } finally {
      calloc.free(state);
      calloc.free(buffer);
    }
  }

  @visibleForTesting
  static void reset() => _afterDeadKey = false;
}
