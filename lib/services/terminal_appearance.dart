import 'dart:io';
import 'dart:ui' show Color;

import 'package:xterm/xterm.dart' show TerminalStyle;

/// The terminal font when the user has not picked one. xterm.dart asks for
/// the family "monospace", which CoreText does not know: on macOS that
/// resolves to a proportional system face and every column in the grid
/// drifts. So name fonts that are actually installed.
String get defaultTerminalFont => Platform.isMacOS ? 'Menlo' : 'Consolas';

const _fallback = ['Consolas', 'Menlo', 'Cascadia Mono', 'SF Mono', 'Monaco', 'Courier New', 'monospace'];

/// The style an SSH tab is drawn with. A chosen family that is not installed
/// falls through to the platform's fonts rather than to a proportional one.
TerminalStyle terminalStyle({String? family, required double size}) {
  final primary = (family == null || family.trim().isEmpty) ? defaultTerminalFont : family.trim();
  return TerminalStyle(
    fontFamily: primary,
    fontSize: size,
    fontFamilyFallback: [for (final f in _fallback) if (f != primary) f],
  );
}

/// Monospace families worth offering. Flutter has no API to list installed
/// fonts, so this is a known list, filtered by [installedTerminalFonts] to
/// what is actually on the machine; anything else can still be typed in by
/// name on the Settings page.
const knownMonospaceFonts = [
  'Consolas', 'Cascadia Mono', 'Cascadia Code', 'Lucida Console', 'Courier New',
  'Menlo', 'Monaco', 'SF Mono', 'Andale Mono',
  'JetBrains Mono', 'Fira Code', 'Fira Mono', 'Source Code Pro', 'Hack',
  'DejaVu Sans Mono', 'Ubuntu Mono', 'Roboto Mono', 'Inconsolata', 'IBM Plex Mono',
  'Noto Sans Mono', 'Liberation Mono', 'Victor Mono', 'Iosevka', 'MesloLGS NF', 'Meslo LG M',
];

String _squash(String s) => s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

/// Which of [knownMonospaceFonts] are installed. Never throws; on failure it
/// returns the platform default alone.
Future<List<String>> installedTerminalFonts() async {
  try {
    final names = <String>[];
    if (Platform.isWindows) {
      // Installed fonts are listed under these keys as "Cascadia Mono Regular
      // (TrueType)" and so on -- machine-wide, and per user for fonts
      // installed without admin rights.
      for (final root in ['HKLM', 'HKCU']) {
        final r = await Process.run('reg', ['query', '$root\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Fonts']);
        if (r.exitCode == 0) names.addAll((r.stdout as String).split('\n'));
      }
    } else if (Platform.isMacOS) {
      final home = Platform.environment['HOME'] ?? '';
      for (final dir in [
        '/System/Library/Fonts', '/System/Library/Fonts/Supplemental', '/Library/Fonts', '$home/Library/Fonts',
      ]) {
        final d = Directory(dir);
        if (!d.existsSync()) continue;
        names.addAll(d.listSync().map((e) => e.path.split('/').last));
      }
    }
    final haystack = names.map(_squash).toList();
    bool present(String font) {
      final keys = {_squash(font), if (font == 'SF Mono') 'sfnsmono'};
      return haystack.any((h) => keys.any(h.startsWith));
    }

    final found = [for (final f in knownMonospaceFonts) if (present(f)) f];
    if (!found.contains(defaultTerminalFont)) found.insert(0, defaultTerminalFont);
    return found;
  } catch (_) {
    return [defaultTerminalFont];
  }
}

/// Parses a colour typed as a code: `#1E1E1E`, `1E1E1E`, `#FFF`,
/// `rgb(30, 30, 30)` or `30,30,30`. Null if it is none of those.
Color? parseColorCode(String input) {
  final s = input.trim();
  final hex = RegExp(r'^#?([0-9a-fA-F]{3}|[0-9a-fA-F]{6})$').firstMatch(s);
  if (hex != null) {
    var h = hex.group(1)!;
    if (h.length == 3) h = h.split('').map((c) => '$c$c').join();
    return Color(0xFF000000 | int.parse(h, radix: 16));
  }
  final rgb = RegExp(r'^(?:rgb\s*\()?\s*(\d{1,3})\s*[, ]\s*(\d{1,3})\s*[, ]\s*(\d{1,3})\s*\)?$', caseSensitive: false)
      .firstMatch(s);
  if (rgb != null) {
    final parts = [for (var i = 1; i <= 3; i++) int.parse(rgb.group(i)!)];
    if (parts.any((v) => v > 255)) return null;
    return Color.fromARGB(255, parts[0], parts[1], parts[2]);
  }
  return null;
}

/// `#RRGGBB` for [c].
String colorToHex(Color c) =>
    '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';
