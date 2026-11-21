import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Stable identifiers also used for saved shortcut overrides.
enum AppCommandId {
  palette,
  quickSearch,
  settings,
  copyName,
  copyAddress,
  copyPassword,
  typePassword,
}

class AppCommand {
  const AppCommand(
    this.id,
    this.title,
    this.icon, {
    this.defaultHotkey,
  });

  final AppCommandId id;
  final String title;
  final IconData icon;
  final Hotkey? defaultHotkey;

  static const all = <AppCommand>[
    AppCommand(
      AppCommandId.palette,
      'Open command palette',
      _icons,
      defaultHotkey: Hotkey(
        LogicalKeyboardKey.keyP,
        control: true,
        shift: true,
      ),
    ),
    AppCommand(AppCommandId.quickSearch, 'Search connections', _search,
        defaultHotkey: Hotkey(LogicalKeyboardKey.keyK, control: true)),
    AppCommand(AppCommandId.settings, 'Open settings', _settings),
    AppCommand(
      AppCommandId.copyName,
      'Copy current connection name',
      _copy,
    ),
    AppCommand(
      AppCommandId.copyAddress,
      'Copy current host address',
      _copy,
    ),
    AppCommand(
      AppCommandId.copyPassword,
      'Copy current host password',
      _copy,
    ),
    AppCommand(
      AppCommandId.typePassword,
      'Type current host password',
      _keyboard,
    ),
  ];

  static const _icons = Icons.terminal;
  static const _search = Icons.search;
  static const _settings = Icons.settings_outlined;
  static const _copy = Icons.content_copy;
  static const _keyboard = Icons.keyboard_outlined;

  static AppCommand of(AppCommandId id) =>
      all.firstWhere((command) => command.id == id);
}

/// A single modified key press. Unmodified keys remain available to the terminal.
class Hotkey {
  const Hotkey(
    this.key, {
    this.control = false,
    this.shift = false,
    this.alt = false,
    this.meta = false,
  });

  final LogicalKeyboardKey key;
  final bool control;
  final bool shift;
  final bool alt;
  final bool meta;

  bool get hasModifier => control || alt || meta;

  bool matches(KeyEvent event, HardwareKeyboard keyboard) =>
      event is KeyDownEvent &&
      event.logicalKey == key &&
      keyboard.isControlPressed == control &&
      keyboard.isShiftPressed == shift &&
      keyboard.isAltPressed == alt &&
      keyboard.isMetaPressed == meta;

  static Hotkey? fromEvent(KeyEvent event, HardwareKeyboard keyboard) {
    if (event is! KeyDownEvent) return null;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.controlLeft ||
        key == LogicalKeyboardKey.controlRight ||
        key == LogicalKeyboardKey.shiftLeft ||
        key == LogicalKeyboardKey.shiftRight ||
        key == LogicalKeyboardKey.altLeft ||
        key == LogicalKeyboardKey.altRight ||
        key == LogicalKeyboardKey.metaLeft ||
        key == LogicalKeyboardKey.metaRight)
      return null;
    final hotkey = Hotkey(
      key,
      control: keyboard.isControlPressed,
      shift: keyboard.isShiftPressed,
      alt: keyboard.isAltPressed,
      meta: keyboard.isMetaPressed,
    );
    return hotkey.hasModifier ? hotkey : null;
  }

  String get label => [
    if (control) 'Ctrl',
    if (alt) 'Alt',
    if (shift) 'Shift',
    if (meta) 'Meta',
    key.keyLabel.isEmpty ? key.debugName ?? 'Key' : key.keyLabel.toUpperCase(),
  ].join(' + ');

  String encode() => jsonEncode({
    'key': key.keyId,
    'ctrl': control,
    'shift': shift,
    'alt': alt,
    'meta': meta,
  });

  static Hotkey? decode(String raw) {
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final keyId = json['key'];
      if (keyId is! int) return null;
      final key = LogicalKeyboardKey.findKeyByKeyId(keyId);
      if (key == null) return null;
      final hotkey = Hotkey(
        key,
        control: json['ctrl'] == true,
        shift: json['shift'] == true,
        alt: json['alt'] == true,
        meta: json['meta'] == true,
      );
      return hotkey.hasModifier ? hotkey : null;
    } catch (_) {
      return null;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is Hotkey &&
      other.key == key &&
      other.control == control &&
      other.shift == shift &&
      other.alt == alt &&
      other.meta == meta;

  @override
  int get hashCode => Object.hash(key, control, shift, alt, meta);
}
