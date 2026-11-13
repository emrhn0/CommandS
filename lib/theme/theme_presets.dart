import 'dart:convert';
import 'dart:ui' show Color;

/// A complete colour theme: the app's own surfaces and the SSH terminal's
/// colours, including its 16 ANSI colours.
///
/// Built-in themes ship with the app. Others are imported from a JSON file in
/// the format described in docs/theme-format.md and written by [toJson].
class ThemePreset {
  const ThemePreset({
    required this.id,
    required this.name,
    required this.dark,
    required this.background,
    required this.panel,
    required this.panelAlt,
    required this.border,
    required this.text,
    required this.textDim,
    required this.accent,
    required this.terminalBackground,
    required this.terminalForeground,
    required this.ansi,
  });

  /// `builtin:<slug>` for the shipped themes, `custom:<slug>` for imported.
  final String id;
  final String name;
  final bool dark;
  final Color background;
  final Color panel;
  final Color panelAlt;
  final Color border;
  final Color text;
  final Color textDim;
  final Color accent;
  final Color terminalBackground;
  final Color terminalForeground;

  /// Black, red, green, yellow, blue, magenta, cyan, white, then the same
  /// eight bright.
  final List<Color> ansi;

  bool get imported => id.startsWith(customPrefix);

  static const formatName = 'commands-theme';
  static const formatVersion = 1;
  static const customPrefix = 'custom:';
  static const maxNameLength = 40;

  /// Largest theme file accepted, far above any real one.
  static const maxFileBytes = 64 * 1024;

  Map<String, Object?> toJson() => {
        'format': formatName,
        'version': formatVersion,
        'name': name,
        'dark': dark,
        'ui': {
          'background': _hex(background),
          'panel': _hex(panel),
          'panelAlt': _hex(panelAlt),
          'border': _hex(border),
          'text': _hex(text),
          'textDim': _hex(textDim),
          'accent': _hex(accent),
        },
        'terminal': {
          'background': _hex(terminalBackground),
          'foreground': _hex(terminalForeground),
          'ansi': [for (final c in ansi) _hex(c)],
        },
      };

  /// Reads a theme file. Throws [FormatException] with a message fit to show
  /// when anything is missing, unknown or out of range.
  static ThemePreset fromJson(Object? json) {
    if (json is! Map) throw const FormatException('A theme file is a JSON object.');
    if (json['format'] != formatName) {
      throw const FormatException('Not a CommandS theme: "format" must be "$formatName".');
    }
    if (json['version'] != formatVersion) {
      throw const FormatException('Unsupported theme version; this CommandS reads version $formatVersion.');
    }
    final rawName = json['name'];
    if (rawName is! String || rawName.trim().isEmpty) {
      throw const FormatException('The theme needs a "name".');
    }
    final name = rawName.trim().replaceAll(RegExp(r'[\x00-\x1F\x7F]'), '');
    if (name.isEmpty || name.length > maxNameLength) {
      throw const FormatException('The theme name must be 1 to $maxNameLength characters.');
    }
    final dark = json['dark'];
    if (dark is! bool) throw const FormatException('"dark" must be true or false.');
    final ui = json['ui'];
    final terminal = json['terminal'];
    if (ui is! Map) throw const FormatException('The theme needs a "ui" object.');
    if (terminal is! Map) throw const FormatException('The theme needs a "terminal" object.');

    Color color(Map from, String section, String key) {
      final value = from[key];
      final parsed = value is String ? _parseHex(value) : null;
      if (parsed == null) {
        throw FormatException('"$section.$key" must be a colour like #1A2B3C.');
      }
      return parsed;
    }

    final ansiRaw = terminal['ansi'];
    if (ansiRaw is! List || ansiRaw.length != 16) {
      throw const FormatException('"terminal.ansi" must list exactly 16 colours.');
    }
    final ansi = <Color>[];
    for (var i = 0; i < 16; i++) {
      final parsed = ansiRaw[i] is String ? _parseHex(ansiRaw[i] as String) : null;
      if (parsed == null) throw FormatException('"terminal.ansi[$i]" must be a colour like #1A2B3C.');
      ansi.add(parsed);
    }

    return ThemePreset(
      id: '$customPrefix${slug(name)}',
      name: name,
      dark: dark,
      background: color(ui, 'ui', 'background'),
      panel: color(ui, 'ui', 'panel'),
      panelAlt: color(ui, 'ui', 'panelAlt'),
      border: color(ui, 'ui', 'border'),
      text: color(ui, 'ui', 'text'),
      textDim: color(ui, 'ui', 'textDim'),
      accent: color(ui, 'ui', 'accent'),
      terminalBackground: color(terminal, 'terminal', 'background'),
      terminalForeground: color(terminal, 'terminal', 'foreground'),
      ansi: List.unmodifiable(ansi),
    );
  }

  /// Parses the text of a theme file.
  static ThemePreset parse(String source) {
    if (source.length > maxFileBytes) throw const FormatException('The theme file is too large.');
    final Object? json;
    try {
      json = jsonDecode(source);
    } on FormatException {
      throw const FormatException('The file is not valid JSON.');
    }
    return fromJson(json);
  }

  static String slug(String name) {
    final s = name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');
    return s.isEmpty ? 'theme' : s;
  }

  static String _hex(Color c) =>
      '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';

  static Color? _parseHex(String s) {
    final m = RegExp(r'^#([0-9a-fA-F]{6})$').firstMatch(s.trim());
    return m == null ? null : Color(0xFF000000 | int.parse(m.group(1)!, radix: 16));
  }
}

List<Color> _c(List<int> values) => [for (final v in values) Color(0xFF000000 | v)];

/// The themes shipped with CommandS. Colours follow each theme's published
/// palette, except CommandS itself: the app's own, white on black with the
/// icon's orange, and the one an install with no theme choice of its own
/// starts on (see [AppState.defaultThemeId]).
final List<ThemePreset> builtInThemes = List.unmodifiable([
  ThemePreset(
    id: 'builtin:commands',
    name: 'CommandS',
    dark: true,
    background: const Color(0xFF0D0D0D),
    panel: const Color(0xFF161616),
    panelAlt: const Color(0xFF1F1F1F),
    border: const Color(0xFF2C2C2C),
    text: const Color(0xFFF5F3EF),
    textDim: const Color(0xFF9A9690),
    accent: const Color(0xFFFF8A3D),
    terminalBackground: const Color(0xFF0D0D0D),
    terminalForeground: const Color(0xFFF5F3EF),
    ansi: _c([
      0x1A1A1A, 0xFF5C5C, 0x6BCB77, 0xFF8A3D, 0x5B9BD5, 0xC77DFF, 0x4FD1C5, 0xD9D5CE,
      0x4A4A4A, 0xFF8080, 0x8FE3A0, 0xFFB066, 0x8FC1E8, 0xDDA8FF, 0x7FE8DB, 0xF5F3EF,
    ]),
  ),
  ThemePreset(
    id: 'builtin:tokyo-night',
    name: 'Tokyo Night',
    dark: true,
    background: const Color(0xFF1A1B26),
    panel: const Color(0xFF16161E),
    panelAlt: const Color(0xFF1F2335),
    border: const Color(0xFF292E42),
    text: const Color(0xFFC0CAF5),
    textDim: const Color(0xFF737AA2),
    accent: const Color(0xFF7AA2F7),
    terminalBackground: const Color(0xFF1A1B26),
    terminalForeground: const Color(0xFFC0CAF5),
    ansi: _c([
      0x15161E, 0xF7768E, 0x9ECE6A, 0xE0AF68, 0x7AA2F7, 0xBB9AF7, 0x7DCFFF, 0xA9B1D6,
      0x414868, 0xF7768E, 0x9ECE6A, 0xE0AF68, 0x7AA2F7, 0xBB9AF7, 0x7DCFFF, 0xC0CAF5,
    ]),
  ),
  ThemePreset(
    id: 'builtin:dracula',
    name: 'Dracula',
    dark: true,
    background: const Color(0xFF282A36),
    panel: const Color(0xFF21222C),
    panelAlt: const Color(0xFF343746),
    border: const Color(0xFF44475A),
    text: const Color(0xFFF8F8F2),
    textDim: const Color(0xFF8C93BC),
    accent: const Color(0xFFBD93F9),
    terminalBackground: const Color(0xFF282A36),
    terminalForeground: const Color(0xFFF8F8F2),
    ansi: _c([
      0x21222C, 0xFF5555, 0x50FA7B, 0xF1FA8C, 0xBD93F9, 0xFF79C6, 0x8BE9FD, 0xF8F8F2,
      0x6272A4, 0xFF6E6E, 0x69FF94, 0xFFFFA5, 0xD6ACFF, 0xFF92DF, 0xA4FFFF, 0xFFFFFF,
    ]),
  ),
  ThemePreset(
    id: 'builtin:one-dark',
    name: 'One Dark',
    dark: true,
    background: const Color(0xFF282C34),
    panel: const Color(0xFF21252B),
    panelAlt: const Color(0xFF2C313A),
    border: const Color(0xFF3E4451),
    text: const Color(0xFFABB2BF),
    textDim: const Color(0xFF7F848E),
    accent: const Color(0xFF61AFEF),
    terminalBackground: const Color(0xFF282C34),
    terminalForeground: const Color(0xFFABB2BF),
    ansi: _c([
      0x1E2127, 0xE06C75, 0x98C379, 0xE5C07B, 0x61AFEF, 0xC678DD, 0x56B6C2, 0xABB2BF,
      0x5C6370, 0xE06C75, 0x98C379, 0xE5C07B, 0x61AFEF, 0xC678DD, 0x56B6C2, 0xFFFFFF,
    ]),
  ),
  ThemePreset(
    id: 'builtin:monokai',
    name: 'Monokai',
    dark: true,
    background: const Color(0xFF272822),
    panel: const Color(0xFF1E1F1C),
    panelAlt: const Color(0xFF3E3D32),
    border: const Color(0xFF49483E),
    text: const Color(0xFFF8F8F2),
    textDim: const Color(0xFF908A6F),
    accent: const Color(0xFFA6E22E),
    terminalBackground: const Color(0xFF272822),
    terminalForeground: const Color(0xFFF8F8F2),
    ansi: _c([
      0x272822, 0xF92672, 0xA6E22E, 0xF4BF75, 0x66D9EF, 0xAE81FF, 0xA1EFE4, 0xF8F8F2,
      0x75715E, 0xF92672, 0xA6E22E, 0xF4BF75, 0x66D9EF, 0xAE81FF, 0xA1EFE4, 0xF9F8F5,
    ]),
  ),
  ThemePreset(
    id: 'builtin:nord',
    name: 'Nord',
    dark: true,
    background: const Color(0xFF2E3440),
    panel: const Color(0xFF292E39),
    panelAlt: const Color(0xFF3B4252),
    border: const Color(0xFF434C5E),
    text: const Color(0xFFECEFF4),
    textDim: const Color(0xFF8C97AD),
    accent: const Color(0xFF88C0D0),
    terminalBackground: const Color(0xFF2E3440),
    terminalForeground: const Color(0xFFD8DEE9),
    ansi: _c([
      0x3B4252, 0xBF616A, 0xA3BE8C, 0xEBCB8B, 0x81A1C1, 0xB48EAD, 0x88C0D0, 0xE5E9F0,
      0x4C566A, 0xBF616A, 0xA3BE8C, 0xEBCB8B, 0x81A1C1, 0xB48EAD, 0x8FBCBB, 0xECEFF4,
    ]),
  ),
  ThemePreset(
    id: 'builtin:gruvbox-dark',
    name: 'Gruvbox Dark',
    dark: true,
    background: const Color(0xFF282828),
    panel: const Color(0xFF1D2021),
    panelAlt: const Color(0xFF3C3836),
    border: const Color(0xFF504945),
    text: const Color(0xFFEBDBB2),
    textDim: const Color(0xFFA89984),
    accent: const Color(0xFFFABD2F),
    terminalBackground: const Color(0xFF282828),
    terminalForeground: const Color(0xFFEBDBB2),
    ansi: _c([
      0x282828, 0xCC241D, 0x98971A, 0xD79921, 0x458588, 0xB16286, 0x689D6A, 0xA89984,
      0x928374, 0xFB4934, 0xB8BB26, 0xFABD2F, 0x83A598, 0xD3869B, 0x8EC07C, 0xEBDBB2,
    ]),
  ),
  ThemePreset(
    id: 'builtin:catppuccin-mocha',
    name: 'Catppuccin Mocha',
    dark: true,
    background: const Color(0xFF1E1E2E),
    panel: const Color(0xFF181825),
    panelAlt: const Color(0xFF313244),
    border: const Color(0xFF45475A),
    text: const Color(0xFFCDD6F4),
    textDim: const Color(0xFF9399B2),
    accent: const Color(0xFFCBA6F7),
    terminalBackground: const Color(0xFF1E1E2E),
    terminalForeground: const Color(0xFFCDD6F4),
    ansi: _c([
      0x45475A, 0xF38BA8, 0xA6E3A1, 0xF9E2AF, 0x89B4FA, 0xF5C2E7, 0x94E2D5, 0xBAC2DE,
      0x585B70, 0xF38BA8, 0xA6E3A1, 0xF9E2AF, 0x89B4FA, 0xF5C2E7, 0x94E2D5, 0xA6ADC8,
    ]),
  ),
  ThemePreset(
    id: 'builtin:rose-pine',
    name: 'Rosé Pine',
    dark: true,
    background: const Color(0xFF191724),
    panel: const Color(0xFF1F1D2E),
    panelAlt: const Color(0xFF26233A),
    border: const Color(0xFF403D52),
    text: const Color(0xFFE0DEF4),
    textDim: const Color(0xFF908CAA),
    accent: const Color(0xFFEBBCBA),
    terminalBackground: const Color(0xFF191724),
    terminalForeground: const Color(0xFFE0DEF4),
    ansi: _c([
      0x26233A, 0xEB6F92, 0x31748F, 0xF6C177, 0x9CCFD8, 0xC4A7E7, 0xEBBCBA, 0xE0DEF4,
      0x6E6A86, 0xEB6F92, 0x31748F, 0xF6C177, 0x9CCFD8, 0xC4A7E7, 0xEBBCBA, 0xE0DEF4,
    ]),
  ),
  ThemePreset(
    id: 'builtin:everforest-dark',
    name: 'Everforest Dark',
    dark: true,
    background: const Color(0xFF2D353B),
    panel: const Color(0xFF232A2E),
    panelAlt: const Color(0xFF343F44),
    border: const Color(0xFF475258),
    text: const Color(0xFFD3C6AA),
    textDim: const Color(0xFF9DA9A0),
    accent: const Color(0xFFA7C080),
    terminalBackground: const Color(0xFF2D353B),
    terminalForeground: const Color(0xFFD3C6AA),
    ansi: _c([
      0x343F44, 0xE67E80, 0xA7C080, 0xDBBC7F, 0x7FBBB3, 0xD699B6, 0x83C092, 0xD3C6AA,
      0x859289, 0xE67E80, 0xA7C080, 0xDBBC7F, 0x7FBBB3, 0xD699B6, 0x83C092, 0xE5DFC5,
    ]),
  ),
  ThemePreset(
    id: 'builtin:kanagawa',
    name: 'Kanagawa',
    dark: true,
    background: const Color(0xFF1F1F28),
    panel: const Color(0xFF16161D),
    panelAlt: const Color(0xFF2A2A37),
    border: const Color(0xFF363646),
    text: const Color(0xFFDCD7BA),
    textDim: const Color(0xFF8A8980),
    accent: const Color(0xFF7E9CD8),
    terminalBackground: const Color(0xFF1F1F28),
    terminalForeground: const Color(0xFFDCD7BA),
    ansi: _c([
      0x090618, 0xC34043, 0x76946A, 0xC0A36E, 0x7E9CD8, 0x957FB8, 0x6A9589, 0xC8C093,
      0x727169, 0xE82424, 0x98BB6C, 0xE6C384, 0x7FB4CA, 0x938AA9, 0x7AA89F, 0xDCD7BA,
    ]),
  ),
  ThemePreset(
    id: 'builtin:github-dark',
    name: 'GitHub Dark',
    dark: true,
    background: const Color(0xFF0D1117),
    panel: const Color(0xFF010409),
    panelAlt: const Color(0xFF161B22),
    border: const Color(0xFF30363D),
    text: const Color(0xFFE6EDF3),
    textDim: const Color(0xFF8D96A0),
    accent: const Color(0xFF58A6FF),
    terminalBackground: const Color(0xFF0D1117),
    terminalForeground: const Color(0xFFE6EDF3),
    ansi: _c([
      0x484F58, 0xFF7B72, 0x3FB950, 0xD29922, 0x58A6FF, 0xBC8CFF, 0x39C5CF, 0xB1BAC4,
      0x6E7681, 0xFFA198, 0x56D364, 0xE3B341, 0x79C0FF, 0xD2A8FF, 0x56D4DD, 0xFFFFFF,
    ]),
  ),
  ThemePreset(
    id: 'builtin:solarized-dark',
    name: 'Solarized Dark',
    dark: true,
    background: const Color(0xFF002B36),
    panel: const Color(0xFF00252E),
    panelAlt: const Color(0xFF073642),
    border: const Color(0xFF0E4552),
    text: const Color(0xFF93A1A1),
    textDim: const Color(0xFF6C8288),
    accent: const Color(0xFF268BD2),
    terminalBackground: const Color(0xFF002B36),
    terminalForeground: const Color(0xFF839496),
    ansi: _c([
      0x073642, 0xDC322F, 0x859900, 0xB58900, 0x268BD2, 0xD33682, 0x2AA198, 0xEEE8D5,
      0x002B36, 0xCB4B16, 0x586E75, 0x657B83, 0x839496, 0x6C71C4, 0x93A1A1, 0xFDF6E3,
    ]),
  ),
  ThemePreset(
    id: 'builtin:solarized-light',
    name: 'Solarized Light',
    dark: false,
    background: const Color(0xFFFDF6E3),
    panel: const Color(0xFFFFFBEF),
    panelAlt: const Color(0xFFEEE8D5),
    border: const Color(0xFFDDD6C1),
    text: const Color(0xFF586E75),
    textDim: const Color(0xFF839496),
    accent: const Color(0xFF268BD2),
    terminalBackground: const Color(0xFFFDF6E3),
    terminalForeground: const Color(0xFF657B83),
    ansi: _c([
      0x073642, 0xDC322F, 0x859900, 0xB58900, 0x268BD2, 0xD33682, 0x2AA198, 0xEEE8D5,
      0x002B36, 0xCB4B16, 0x586E75, 0x657B83, 0x839496, 0x6C71C4, 0x93A1A1, 0xFDF6E3,
    ]),
  ),
  ThemePreset(
    id: 'builtin:github-light',
    name: 'GitHub Light',
    dark: false,
    background: const Color(0xFFFFFFFF),
    panel: const Color(0xFFF6F8FA),
    panelAlt: const Color(0xFFEAEEF2),
    border: const Color(0xFFD0D7DE),
    text: const Color(0xFF1F2328),
    textDim: const Color(0xFF656D76),
    accent: const Color(0xFF0969DA),
    terminalBackground: const Color(0xFFFFFFFF),
    terminalForeground: const Color(0xFF1F2328),
    ansi: _c([
      0x24292F, 0xCF222E, 0x116329, 0x4D2D00, 0x0969DA, 0x8250DF, 0x1B7C83, 0x6E7781,
      0x57606A, 0xA40E26, 0x1A7F37, 0x633C01, 0x218BFF, 0xA475F9, 0x3192AA, 0x8C959F,
    ]),
  ),
  ThemePreset(
    id: 'builtin:catppuccin-latte',
    name: 'Catppuccin Latte',
    dark: false,
    background: const Color(0xFFEFF1F5),
    panel: const Color(0xFFE6E9EF),
    panelAlt: const Color(0xFFDCE0E8),
    border: const Color(0xFFCCD0DA),
    text: const Color(0xFF4C4F69),
    textDim: const Color(0xFF6C6F85),
    accent: const Color(0xFF8839EF),
    terminalBackground: const Color(0xFFEFF1F5),
    terminalForeground: const Color(0xFF4C4F69),
    ansi: _c([
      0x5C5F77, 0xD20F39, 0x40A02B, 0xDF8E1D, 0x1E66F5, 0xEA76CB, 0x179299, 0xACB0BE,
      0x6C6F85, 0xD20F39, 0x40A02B, 0xDF8E1D, 0x1E66F5, 0xEA76CB, 0x179299, 0xBCC0CC,
    ]),
  ),
  // Not a published palette like the others above: CommandS's own, after the
  // violet-to-cyan glow the user picked from a mockup.
  ThemePreset(
    id: 'builtin:aurora',
    name: 'Aurora',
    dark: true,
    background: const Color(0xFF0A0A10),
    panel: const Color(0xFF15121F),
    panelAlt: const Color(0xFF211B33),
    border: const Color(0xFF2A2440),
    text: const Color(0xFFEDEDF5),
    textDim: const Color(0xFF8B8AA6),
    accent: const Color(0xFF8C7CFF),
    terminalBackground: const Color(0xFF0A0A10),
    terminalForeground: const Color(0xFFE4E4F0),
    ansi: _c([
      0x15121F, 0xFF5B6E, 0x5BFFA3, 0xFFC85B, 0x5B9BFF, 0xC58CFF, 0x5BE0FF, 0xC7C7E0,
      0x3A3550, 0xFF8299, 0x8CFFC2, 0xFFDD8C, 0x8CC2FF, 0xDDB3FF, 0x8CEBFF, 0xEDEDF5,
    ]),
  ),
]);
