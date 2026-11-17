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

  /// The accent of a dead key pressed last, waiting for the next key.
  static String? _pendingAccent;

  static final Map<int, int> _scanCodeOf = {
    for (final e in kWindowsToPhysicalKey.entries) e.value.usbHidUsage: e.key,
  };

  /// Whether AltGr is held, asked every way there is: Flutter's record (as
  /// the right Alt, or as Ctrl with Alt) and Windows' own key state. One
  /// source alone missed it.
  static bool _altGrHeld() {
    final k = HardwareKeyboard.instance;
    if (k.isLogicalKeyPressed(LogicalKeyboardKey.altRight)) return true;
    if (k.isControlPressed && k.isAltPressed) return true;
    bool down(int vk) => GetAsyncKeyState(vk) & 0x8000 != 0;
    if (down(VK_RMENU)) return true;
    return down(VK_CONTROL) && down(VK_MENU);
  }

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
      final altGr = _altGrHeld();
      final caps = HardwareKeyboard.instance.lockModesEnabled.contains(KeyboardLockMode.capsLock);
      final key = keyOnLayout(scanCode, layout, held: _heldAtEvent(altGr), capsLock: caps);
      // The key's own letter, with nothing held. Flutter names the key by
      // its Windows key code, not its letter, so the letter is asked here.
      final plain = keyOnLayout(scanCode, layout, held: const [], capsLock: false);
      return decide(
        character: character,
        altGr: altGr,
        key: key,
        plain: plain?.text,
      );
    } catch (_) {
      return null;
    }
  }

  /// What a key press types, given what Windows says about the key:
  /// - a dead key (AltGr+Ü for ~) types nothing yet;
  /// - the key after it types the accent: on its own when it is the same
  ///   space bar, twice when it is the same dead key again (as Windows does),
///   else the accent then its own text
  ///   (~ then a is "~a", not the "ã" Windows would compose);
  /// - with AltGr held, a key reporting its own plain letter (the ü that
  ///   Flutter sends for AltGr+Ü) types nothing, whatever else was missed;
  /// - anything else goes through as usual (null).
  @visibleForTesting
  static String? decide({
    required String character,
    required bool altGr,
    required ({String text, bool dead})? key,
    required String? plain,
  }) {
    final pending = _pendingAccent;
    if (key != null && key.dead) {
      if (pending != null) {
        // As everywhere in Windows: the dead key twice types the accent
        // twice (and the pending one with another dead key, both).
        _pendingAccent = null;
        return '$pending${key.text}';
      }
      _pendingAccent = key.text;
      return '';
    }
    if (pending != null) {
      _pendingAccent = null;
      final own = key?.text ?? character;
      return own == ' ' ? pending : '$pending$own';
    }
    if (altGr && plain != null && plain.isNotEmpty && character.toLowerCase() == plain.toLowerCase()) {
      return '';
    }
    return null;
  }

  /// The modifiers held when the key was pressed, as Windows virtual keys.
  /// AltGr is Ctrl and Alt to Windows.
  static List<int> _heldAtEvent(bool altGr) {
    final k = HardwareKeyboard.instance;
    return [
      if (k.isShiftPressed) ...[VK_SHIFT, VK_LSHIFT],
      if (altGr) ...[VK_CONTROL, VK_LCONTROL, VK_MENU, VK_RMENU],
      if (!altGr && k.isAltPressed) ...[VK_MENU, VK_LMENU],
      if (!altGr && k.isControlPressed) ...[VK_CONTROL, VK_LCONTROL],
    ];
  }

  /// What the key with [scanCode] types on [layout] with the modifiers held
  /// right now ([held], virtual-key codes, in tests): its text, and whether
  /// it is a dead key (then the text is its accent, such as ~). Asks Windows
  /// without touching the keyboard state, and from a thread with no accent
  /// waiting, so the answer is the key on its own.
  @visibleForTesting
  static ({String text, bool dead})? keyOnLayout(
    int scanCode,
    int layout, {
    List<int>? held,
    bool? capsLock,
  }) {
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
      if (capsLock ?? (held == null && GetKeyState(VK_CAPITAL) & 1 != 0)) state[VK_CAPITAL] = 0x01;
      // Flag 4 is meant to leave the keyboard state alone, but a dead key
      // still stays pending in this thread and turns the next answer into
      // "~~" or "~ü" (seen with real key presses). So nothing is left
      // pending before or after.
      _flush(layout, buffer);
      final result = ToUnicodeEx(vk, scanCode, state, buffer.cast(), 8, 4, layout);
      final answer = [for (var i = 0; i < (result < 0 ? 1 : result); i++) buffer[i]];
      if (result < 0) _flush(layout, buffer);
      if (result == 0) return null;
      final text = String.fromCharCodes(answer);
      return (text: text, dead: result < 0);
    } finally {
      calloc.free(state);
      calloc.free(buffer);
    }
  }

  /// Ends any dead key waiting in this thread: a space types it out.
  static void _flush(int layout, Pointer<Uint16> buffer) {
    final empty = calloc<Uint8>(256);
    try {
      for (var i = 0; i < 3; i++) {
        if (ToUnicodeEx(VK_SPACE, 0x39, empty, buffer.cast(), 8, 4, layout) >= 0) break;
      }
    } finally {
      calloc.free(empty);
    }
  }

  @visibleForTesting
  static void reset() => _pendingAccent = null;
}
