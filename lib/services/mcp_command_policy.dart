import '../models/models.dart';

/// Which agent commands may run without asking the user: only commands that
/// read, on network devices whose CLI is known. Everything else asks.
///
/// Abbreviations are not accepted: on Cisco, "sh" in interface configuration
/// means shutdown.
const _networkDevices = {
  DeviceKind.huawei,
  DeviceKind.cisco,
  DeviceKind.aruba,
  DeviceKind.hpe,
  DeviceKind.paloalto,
  DeviceKind.fortinet,
};

/// Pipe filters that only narrow what is shown. Anything else after a pipe
/// (redirect, tee, append, save...) can write somewhere, so it asks.
const _filters = [
  'include', 'exclude', 'begin', 'section', 'count',
  'match', 'except', 'grep', 'no-more', 'last',
];

/// Turn off "---- More ----" for this session only. None of them is saved.
const _sessionPaging = {
  'screen-length 0 temporary', // Huawei
  'screen-length disable', // HPE Comware, user view
  'terminal length 0', // Cisco IOS
  'terminal pager 0', // Cisco ASA
  'set cli pager off', // Palo Alto
};

bool runsWithoutAsking(String command, DeviceKind? device) {
  if (!_networkDevices.contains(device)) return false;
  final text = command.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();
  if (text.isEmpty) return false;
  if (_sessionPaging.contains(text)) return true;
  // Chaining, redirection and shell syntax are never read-only here.
  if (RegExp(r'[;&<>`$\\]').hasMatch(text)) return false;
  final parts = text.split('|');
  final words = parts.first.trim().split(' ');
  final verb = words.first;
  final reads = verb == 'show' ||
      verb == 'display' ||
      (verb == 'get' && device == DeviceKind.fortinet);
  if (!reads) return false;
  for (final pipe in parts.skip(1)) {
    final filter = pipe.trim().split(' ').first;
    if (filter.isEmpty || !_filters.any((f) => f.startsWith(filter))) return false;
  }
  return true;
}
