import 'package:commands/services/app_commands.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// A keyboard holding exactly the given modifiers.
class _Held extends HardwareKeyboard {
  _Held({this.control = false, this.meta = false});

  final bool control;
  final bool meta;

  @override
  bool get isControlPressed => control;
  @override
  bool get isMetaPressed => meta;
  @override
  bool get isShiftPressed => false;
  @override
  bool get isAltPressed => false;
}

void main() {
  const search = Hotkey(LogicalKeyboardKey.keyK, control: true);
  const k = KeyDownEvent(
    physicalKey: PhysicalKeyboardKey.keyK,
    logicalKey: LogicalKeyboardKey.keyK,
    timeStamp: Duration.zero,
  );

  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('Cmd+K is the Ctrl+K shortcut on a Mac', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    expect(search.matches(k, _Held(meta: true)), isTrue);
    expect(search.matches(k, _Held(control: true)), isTrue);
    expect(search.matches(k, _Held(control: true, meta: true)), isFalse);
  });

  test('Windows takes Ctrl+K only', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    expect(search.matches(k, _Held(meta: true)), isFalse);
    expect(search.matches(k, _Held(control: true)), isTrue);
  });
}
