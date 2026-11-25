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

  /// Null when the system does not say.
  final bool? onMains;
}

typedef _SettingCallback = Void Function(Pointer<Void> context, Uint32 type, Pointer<Uint8> setting);

/// DEVICE_NOTIFY_SUBSCRIBE_PARAMETERS.
final class _Subscribe extends Struct {
  external Pointer<NativeFunction<_SettingCallback>> callback;
  external Pointer<Void> context;
}

typedef _RegisterNative = Uint32 Function(
    Pointer<GUID> setting, Uint32 flags, Pointer<_Subscribe> recipient, Pointer<Pointer<Void>> handle);
typedef _RegisterDart = int Function(
    Pointer<GUID> setting, int flags, Pointer<_Subscribe> recipient, Pointer<Pointer<Void>> handle);

/// Keeps the app told of [PowerState].
///
/// On Windows it subscribes to the power settings themselves, so Windows
/// reports each change the moment it happens and nothing is polled:
/// GUID_ENERGY_SAVER_STATUS is Windows 11's Energy Saver (GetSystemPowerStatus
/// does not see it), GUID_POWER_SAVING_STATUS the Battery Saver of older
/// systems, GUID_ACDC_POWER_SOURCE mains or battery. A Mac is asked with
/// `pmset` every [every] and when the app comes back to the front.
class SystemPower {
  SystemPower._();

  static const every = Duration(seconds: 10);

  static const _energySaverStatus = '{550E8400-E29B-41D4-A716-446655440000}';
  static const _powerSavingStatus = '{E00958C0-C213-4ACE-AC77-FECCED2EEEA5}';
  static const _acDcPowerSource = '{5D3E9A59-E9D5-4B00-A6BD-FF34FF516548}';

  /// DEVICE_NOTIFY_CALLBACK and PBT_POWERSETTINGCHANGE.
  static const _notifyCallback = 2;
  static const _powerSettingChange = 0x8013;

  static bool _watching = false;
  static Timer? _timer;
  static AppLifecycleListener? _listener;
  static PowerState? _last;

  /// Kept for as long as the app runs: Windows calls into them.
  static final _keepAlive = <Object>[];

  /// Starts watching. Called once at start; does nothing under tests.
  static void watch(void Function(PowerState state) onChange) {
    if (_watching || Platform.environment.containsKey('FLUTTER_TEST')) return;
    _watching = true;
    void report(PowerState state) {
      final last = _last;
      if (last != null && last.energySaver == state.energySaver && last.onMains == state.onMains) return;
      _last = state;
      onChange(state);
    }

    try {
      if (Platform.isWindows) {
        _watchWindows(report);
      } else if (Platform.isMacOS) {
        Future<void> poll() async {
          final state = await _readMac();
          if (state != null) report(state);
        }

        unawaited(poll());
        _timer = Timer.periodic(every, (_) => poll());
        _listener = AppLifecycleListener(onResume: () => unawaited(poll()));
      }
    } catch (_) {
      // Unknown: power saver then reads as off under Same as system.
    }
  }

  static void _watchWindows(void Function(PowerState state) report) {
    final powrprof = DynamicLibrary.open('powrprof.dll');
    final register = powrprof.lookupFunction<_RegisterNative, _RegisterDart>('PowerSettingRegisterNotification');
    bool? energySaver; // from Energy Saver, or Battery Saver where it is missing
    bool? legacySaver;
    bool? onMains;
    var hasEnergySaver = false;

    void emit() => report(PowerState(
          energySaver: (hasEnergySaver ? energySaver : legacySaver) ?? false,
          onMains: onMains,
        ));

    /// Subscribes to [guid]; Windows answers at once with the current value,
    /// then on every change. Returns whether the setting exists here.
    bool subscribe(String guid, void Function(int value) onValue) {
      // POWERBROADCAST_SETTING: the setting's GUID (16 bytes), the data's
      // length, then the data, here one DWORD. Called on a Windows thread:
      // a listener hands it to the app's own.
      final callback = NativeCallable<_SettingCallback>.listener((Pointer<Void> _, int type, Pointer<Uint8> setting) {
        if (type != _powerSettingChange || setting == nullptr) return;
        if ((setting + 16).cast<Uint32>().value < 4) return;
        onValue((setting + 20).cast<Uint32>().value);
      });
      final params = calloc<_Subscribe>()
        ..ref.callback = callback.nativeFunction
        ..ref.context = nullptr;
      final handle = calloc<Pointer<Void>>();
      final ok = register(GUIDFromString(guid), _notifyCallback, params, handle) == 0;
      if (ok) {
        _keepAlive.addAll([callback, params, handle]);
      } else {
        callback.close();
        calloc
          ..free(params)
          ..free(handle);
      }
      return ok;
    }

    // 0 off; 1 standard and 2 extra savings are both on.
    hasEnergySaver = subscribe(_energySaverStatus, (v) {
      energySaver = v != 0;
      emit();
    });
    subscribe(_powerSavingStatus, (v) {
      legacySaver = v != 0;
      if (!hasEnergySaver) emit();
    });
    // 0 mains, 1 battery, 2 a UPS (on its battery).
    subscribe(_acDcPowerSource, (v) {
      onMains = v == 0;
      emit();
    });
  }

  /// `pmset -g`: "lowpowermode 1" while Low Power Mode is on; `pmset -g ps`
  /// names the source drawn from.
  static Future<PowerState?> _readMac() async {
    try {
      final settings = await Process.run('pmset', ['-g']);
      if (settings.exitCode != 0) return null;
      final low = RegExp(r'lowpowermode\s+1').hasMatch(settings.stdout as String);
      final source = await Process.run('pmset', ['-g', 'ps']);
      final ps = source.stdout as String;
      return PowerState(
        energySaver: low,
        onMains: ps.contains("'AC Power'") ? true : (ps.contains("'Battery Power'") ? false : null),
      );
    } catch (_) {
      return null;
    }
  }

  /// For tests: forgets what was reported.
  @visibleForTesting
  static void stop() {
    _timer?.cancel();
    _timer = null;
    _listener?.dispose();
    _listener = null;
    _last = null;
  }
}
