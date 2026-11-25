import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/widgets.dart';
import 'package:win32/win32.dart';

/// The computer's own power state: whether its energy saver is on (Windows'
/// Energy Saver, the one in the taskbar's quick settings, or a Mac's Low
/// Power Mode) and whether it runs on mains power.
class PowerState {
  const PowerState({required this.energySaver, this.onMains});

  final bool energySaver;

  /// Null when the system does not say (a desktop without a battery says
  /// it is on mains).
  final bool? onMains;
}

/// Reads [PowerState] from the system and keeps [onChange] told: at start,
/// every [every], and whenever the app comes back to the front, so turning
/// the energy saver on or off reaches the app within moments.
class SystemPower {
  SystemPower._();

  static const every = Duration(seconds: 10);

  static Timer? _timer;
  static AppLifecycleListener? _listener;
  static PowerState? _last;

  /// Starts watching. Called once at start; does nothing under tests.
  static void watch(void Function(PowerState state) onChange) {
    if (_timer != null || Platform.environment.containsKey('FLUTTER_TEST')) return;
    Future<void> poll() async {
      final state = await read();
      if (state == null) return;
      final last = _last;
      if (last != null && last.energySaver == state.energySaver && last.onMains == state.onMains) return;
      _last = state;
      onChange(state);
    }

    unawaited(poll());
    _timer = Timer.periodic(every, (_) => poll());
    _listener = AppLifecycleListener(onResume: () => unawaited(poll()));
  }

  /// The power state now, or null where it cannot be read.
  static Future<PowerState?> read() async {
    try {
      if (Platform.isWindows) return _readWindows();
      if (Platform.isMacOS) return await _readMac();
    } catch (_) {
      // Unknown: the app keeps what it had.
    }
    return null;
  }

  /// GetSystemPowerStatus: SystemStatusFlag is 1 while Energy Saver (Battery
  /// Saver before Windows 11) is on; ACLineStatus 1 is mains, 0 battery.
  static PowerState? _readWindows() {
    final status = calloc<SYSTEM_POWER_STATUS>();
    try {
      if (GetSystemPowerStatus(status) == 0) return null;
      final line = status.ref.ACLineStatus;
      return PowerState(
        energySaver: status.ref.SystemStatusFlag == 1,
        onMains: line == 1 ? true : (line == 0 ? false : null),
      );
    } finally {
      calloc.free(status);
    }
  }

  /// `pmset -g`: "lowpowermode 1" while Low Power Mode is on; `pmset -g ps`
  /// names the source drawn from.
  static Future<PowerState?> _readMac() async {
    final settings = await Process.run('pmset', ['-g']);
    if (settings.exitCode != 0) return null;
    final low = RegExp(r'lowpowermode\s+1').hasMatch(settings.stdout as String);
    final source = await Process.run('pmset', ['-g', 'ps']);
    final ps = source.stdout as String;
    return PowerState(
      energySaver: low,
      onMains: ps.contains("'AC Power'") ? true : (ps.contains("'Battery Power'") ? false : null),
    );
  }

  /// For tests: stops watching.
  @visibleForTesting
  static void stop() {
    _timer?.cancel();
    _timer = null;
    _listener?.dispose();
    _listener = null;
    _last = null;
  }
}
