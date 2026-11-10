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
  // Chaining and redirection are never read-only here. "$" and "\" are
  // allowed: in these CLIs they only appear in filter patterns.
  if (RegExp(r'[;&<>`]').hasMatch(text)) return false;
  final parts = text.split('|');
  final verb = parts.first.trim().split(' ').first;
  final reads = verb == 'show' ||
      verb == 'display' ||
      (verb == 'get' && device == DeviceKind.fortinet);
  if (!reads) return false;
  for (var i = 1; i < parts.length; i++) {
    final part = parts[i];
    final word = part.trim().split(' ').first;
    if (word.isEmpty) return false;
    // In "include A|B|C" the bars belong to the pattern. A bar with a space
    // beside it, or the first one, starts a new pipe, which must filter.
    final newPipe = i == 1 || parts[i - 1].endsWith(' ') || part.startsWith(' ');
    if (newPipe) {
      if (!_filters.any((f) => f.startsWith(word))) return false;
    } else if (_writers.any((w) => word.length >= 3 && w.startsWith(word))) {
      // A pattern part that reads like a writing pipe ("...|redirect x")
      // could be one where several pipes are allowed, so ask.
      return false;
    }
  }
  return true;
}

/// Pipe commands that write or send output somewhere.
const _writers = [
  'redirect', 'tee', 'append', 'save', 'email', 'mail', 'tftp', 'ftp',
  'scp', 'python', 'vsh', 'copy', 'write', 'file', 'archive',
];
