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
/// character is the key's plain letter (Ü for that key), and the real
/// character (~, or â after a) comes with the next key. Text fields ignore
/// that first character; the terminal, which reads characters from key
/// events (`hardwareKeyboardOnly`), typed it, so ~ came out as ü~. The
/// terminal now asks Windows whether the key, with the modifiers held, is a
/// dead key, and skips it if so.
class DeadKeys {
  DeadKeys._();

  /// Whether [event] is the press of a dead key. Replaced in tests.
  static bool Function(KeyEvent event) isDeadKey = _isDeadKeyWindows;

  static final Map<int, int> _scanCodeOf = {
    for (final e in kWindowsToPhysicalKey.entries) e.value.usbHidUsage: e.key,
  };

  static bool _isDeadKeyWindows(KeyEvent event) {
    if (!Platform.isWindows || event is KeyUpEvent) return false;
    final character = event.character;
    if (character == null || character.isEmpty) return false;
    final scanCode = _scanCodeOf[event.physicalKey.usbHidUsage];
    if (scanCode == null) return false;
    try {
      // The layout of the window the keys go to: this isolate's thread has
      // its own, which need not be the one in use.
      final thread = GetWindowThreadProcessId(GetForegroundWindow(), nullptr);
      final layout = GetKeyboardLayout(thread);
      return isDeadOnLayout(scanCode, layout);
    } catch (_) {
      return false;
    }
  }

  /// Whether the key with [scanCode] is a dead key on [layout] with the
  /// modifiers held right now ([held], virtual-key codes, in tests). Asks
  /// Windows without touching the keyboard state, so a dead key being
  /// composed is not disturbed.
  @visibleForTesting
  static bool isDeadOnLayout(int scanCode, int layout, {List<int>? held}) {
    final vk = MapVirtualKeyEx(scanCode, MAPVK_VSC_TO_VK_EX, layout);
    if (vk == 0) return false;
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
      return result < 0;
    } finally {
      calloc.free(state);
      calloc.free(buffer);
    }
  }
}
