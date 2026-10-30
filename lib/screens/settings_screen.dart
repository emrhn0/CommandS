import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_version.dart';
import '../providers/app_state.dart';
import '../services/feedback_service.dart';
import '../services/terminal_appearance.dart';
import '../services/update_service.dart';
import '../theme/app_theme.dart';
import '../widgets/color_picker_dialog.dart';
import '../widgets/custom_title_bar.dart';
import '../widgets/import_export_dialog.dart';
import '../widgets/update_dialog.dart';
import '../l10n/strings.dart';

/// Opens the Settings page.
Future<void> showSettings(BuildContext context) {
  return Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const SettingsScreen()));
}

/// Everything that used to be scattered across four unlabelled icons in the
/// sidebar header -- theme, terminal colours, import, export -- plus checking
/// for updates, on one page with room to explain itself.
///
/// A full page rather than a dialog: it carries the app's own title bar, so
/// the window can still be moved and closed while it is open, and opening it
/// suspends any embedded RDP session the same way a dialog does (the session
/// is a window of its own, drawn above the app, and would otherwise cover it).
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final divider = Theme.of(context).dividerColor;
    return Scaffold(
      body: Column(
        children: [
          const CustomTitleBar(),
          Container(
            height: 44,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: divider)),
            ),
            child: Row(
              children: [
                IconButton(
                  tooltip: tr('Back'),
                  icon: const Icon(Icons.arrow_back, size: 18),
                  onPressed: () => Navigator.of(context).pop(),
                ),
                const SizedBox(width: 4),
                Text(tr('Settings'), style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
              ],
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 760),
                  child: const Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _Section(
                        title: 'Appearance',
                        children: [
                          _Label('Theme'),
                          _ThemePicker(),
                          SizedBox(height: 28),
                          _Label('SSH terminal'),
                          _TerminalAppearance(),
                          SizedBox(height: 28),
                          _Label('Language'),
                          _LanguagePicker(),
                        ],
                      ),
                      SizedBox(height: 22),
                      _Section(title: 'Connections', children: [_ImportExport()]),
                      SizedBox(height: 22),
                      _Section(title: 'Updates', children: [_UpdatesPanel()]),
                      SizedBox(height: 22),
                      _Section(title: 'Support & feedback', children: [_FeedbackPanel()]),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Layout pieces
// ---------------------------------------------------------------------------

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(22, 18, 22, 22),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border.all(color: theme.dividerColor),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(tr(title), style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
          const SizedBox(height: 18),
          ...children,
        ],
      ),
    );
  }
}

class _Label extends StatelessWidget {
  const _Label(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Text(
        tr(text),
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.3,
          color: Theme.of(context).textTheme.bodySmall?.color,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Language
// ---------------------------------------------------------------------------

/// The app's own wording only: what remote machines print is never touched.
class _LanguagePicker extends StatelessWidget {
  const _LanguagePicker();

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SegmentedButton<AppLanguage>(
          showSelectedIcon: false,
          segments: [for (final l in AppLanguage.values) ButtonSegment(value: l, label: Text(l.label))],
          selected: {app.language},
          onSelectionChanged: (s) => app.setLanguage(s.first),
        ),
        const SizedBox(height: 8),
        Text(
          tr('Applies to CommandS itself; sessions are not affected.'),
          style: TextStyle(fontSize: 12, color: Theme.of(context).textTheme.bodySmall?.color),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Theme
// ---------------------------------------------------------------------------

class _ThemePicker extends StatelessWidget {
  const _ThemePicker();

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return Wrap(
      spacing: 14,
      runSpacing: 14,
      children: [
        _ThemeCard(
          label: 'Light',
          light: true,
          selected: app.themeMode == ThemeMode.light,
          onTap: () => app.setThemeMode(ThemeMode.light),
        ),
        _ThemeCard(
          label: 'Dark',
          light: false,
          selected: app.themeMode == ThemeMode.dark,
          onTap: () => app.setThemeMode(ThemeMode.dark),
        ),
      ],
    );
  }
}

/// A miniature of the app in one theme -- title bar, sidebar, content -- so
/// the choice is made by looking rather than by reading a word.
class _ThemeCard extends StatelessWidget {
  const _ThemeCard({required this.label, required this.light, required this.selected, required this.onTap});

  final String label;
  final bool light;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final bg = light ? AppColors.lightBg : AppColors.darkBg;
    final panel = light ? AppColors.lightPanelAlt : AppColors.darkPanelAlt;
    final line = light ? AppColors.lightBorder : AppColors.darkBorder;
    final ink = light ? AppColors.lightText : AppColors.darkText;

    Widget bar(double width) => Container(
      width: width,
      height: 5,
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(color: line, borderRadius: BorderRadius.circular(2)),
    );

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              width: 220,
              height: 132,
              decoration: BoxDecoration(
                color: bg,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: selected ? accent : Theme.of(context).dividerColor,
                  width: selected ? 2 : 1,
                ),
              ),
              clipBehavior: Clip.antiAlias,
              child: Column(
                children: [
                  Container(height: 14, color: panel),
                  Expanded(
                    child: Row(
                      children: [
                        Container(
                          width: 66,
                          color: panel,
                          padding: const EdgeInsets.fromLTRB(8, 10, 8, 0),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [bar(44), bar(36), bar(48), bar(30), bar(40)],
                          ),
                        ),
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Container(
                                  width: 60,
                                  height: 7,
                                  margin: const EdgeInsets.only(bottom: 9),
                                  decoration: BoxDecoration(
                                    color: ink,
                                    borderRadius: BorderRadius.circular(2),
                                  ),
                                ),
                                bar(100),
                                bar(84),
                                bar(92),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                  size: 16,
                  color: selected ? accent : Theme.of(context).textTheme.bodySmall?.color,
                ),
                const SizedBox(width: 6),
                Text(tr(label), style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Terminal colours
// ---------------------------------------------------------------------------

const _bgPresets = [
  Color(0xFF14161A), // CommandS default
  Color(0xFF000000), // pure black
  Color(0xFF0C0C0C), // Windows Terminal black
  Color(0xFF1E1E1E), // VS Code dark
  Color(0xFF002B36), // Solarized dark
  Color(0xFFFDF6E3), // Solarized light
  Color(0xFFFFFFFF), // white
];

const _fgPresets = [
  Color(0xFFE8E6E1), // CommandS default
  Color(0xFFFFFFFF), // white
  Color(0xFF00FF00), // classic green phosphor
  Color(0xFFC9973A), // amber
  Color(0xFF839496), // Solarized body
  Color(0xFF000000), // black (for light backgrounds)
];

class _TerminalAppearance extends StatefulWidget {
  const _TerminalAppearance();

  @override
  State<_TerminalAppearance> createState() => _TerminalAppearanceState();
}

class _TerminalAppearanceState extends State<_TerminalAppearance> {
  static const _other = '\u0000other';
  List<String> _fonts = [defaultTerminalFont];
  bool _typingFont = false;
  final _fontName = TextEditingController();

  @override
  void initState() {
    super.initState();
    installedTerminalFonts().then((fonts) {
      if (mounted) setState(() => _fonts = fonts);
    });
  }

  @override
  void dispose() {
    _fontName.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final bg = app.terminalBackground;
    final fg = app.terminalForeground;
    final family = app.terminalFontFamily ?? defaultTerminalFont;
    final size = app.terminalFontSize;
    final dim = Theme.of(context).textTheme.bodySmall?.color;
    // A font typed in by name that is not in the detected list still shows
    // as the current choice.
    final options = [..._fonts, if (!_fonts.contains(family)) family];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // A real terminal's worth of text in the chosen font, size and
        // colours, so the choice is judged on what a session will look like.
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: Theme.of(context).dividerColor),
          ),
          child: Text(
            'admin@core-sw1:~\$ show ip interface brief\n'
            'Interface        IP-Address      Status   Protocol\n'
            'Vlan10           192.0.2.1       up       up\n'
            'Gi1/0/1          unassigned      up       up\n'
            'Türkçe: çağrı şişe ığdır öğün İstanbul',
            style: TextStyle(
              color: fg,
              fontFamily: family,
              fontFamilyFallback: const ['Consolas', 'Menlo', 'Courier New'],
              fontSize: size,
              height: 1.5,
            ),
          ),
        ),
        const SizedBox(height: 18),
        Wrap(
          spacing: 24,
          runSpacing: 14,
          crossAxisAlignment: WrapCrossAlignment.end,
          children: [
            SizedBox(
              width: 280,
              child: DropdownButtonFormField<String>(
                initialValue: _typingFont ? _other : family,
                isExpanded: true,
                borderRadius: BorderRadius.circular(6),
                decoration: InputDecoration(labelText: tr('Font'), isDense: true),
                items: [
                  for (final f in options)
                    DropdownMenuItem(
                      value: f,
                      child: Text(
                        f == defaultTerminalFont ? tr('{font} (default)', {'font': f}) : f,
                        style: TextStyle(fontFamily: f, fontFamilyFallback: const ['Consolas', 'Menlo']),
                      ),
                    ),
                  DropdownMenuItem(value: _other, child: Text(tr('Other font by name…'))),
                ],
                onChanged: (v) {
                  if (v == _other) {
                    setState(() {
                      _typingFont = true;
                      _fontName.text = '';
                    });
                  } else if (v != null) {
                    setState(() => _typingFont = false);
                    app.setTerminalFont(
                      family: v == defaultTerminalFont ? null : v,
                      resetFamily: v == defaultTerminalFont,
                    );
                  }
                },
              ),
            ),
            SizedBox(
              width: 280,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(tr('Size: {n} pt', {'n': size.round()}), style: TextStyle(fontSize: 12, color: dim)),
                  Slider(
                    value: size.clamp(9, 24),
                    min: 9,
                    max: 24,
                    divisions: 15,
                    label: '${size.round()} pt',
                    onChanged: (v) => app.setTerminalFont(size: v),
                  ),
                ],
              ),
            ),
          ],
        ),
        if (_typingFont) ...[
          const SizedBox(height: 12),
          Row(
            children: [
              SizedBox(
                width: 280,
                child: TextField(
                  controller: _fontName,
                  autofocus: true,
                  decoration: InputDecoration(
                    labelText: tr('Font name, as installed (e.g. JetBrains Mono)'),
                    isDense: true,
                  ),
                  onSubmitted: (v) {
                    if (v.trim().isEmpty) return;
                    app.setTerminalFont(family: v);
                    setState(() => _typingFont = false);
                  },
                ),
              ),
              const SizedBox(width: 10),
              OutlinedButton(
                onPressed: () {
                  if (_fontName.text.trim().isEmpty) return;
                  app.setTerminalFont(family: _fontName.text);
                  setState(() => _typingFont = false);
                },
                child: Text(tr('Use')),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            tr(
              'A font that is not installed falls back to the default, so a typo shows straight away in the preview.',
            ),
            style: TextStyle(fontSize: 11, color: dim),
          ),
        ],
        const SizedBox(height: 22),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: _SwatchGroup(
                title: 'Background',
                colors: _bgPresets,
                selected: bg,
                onPick: (c) => app.setTerminalColors(background: c),
              ),
            ),
            const SizedBox(width: 24),
            Expanded(
              child: _SwatchGroup(
                title: 'Text',
                colors: _fgPresets,
                selected: fg,
                onPick: (c) => app.setTerminalColors(foreground: c),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// A colour typed as a code -- `#1E1E1E`, `#FFF`, `rgb(30, 30, 30)` or
/// `30,30,30` -- for colours the swatches do not have. Applied as soon as it
/// parses; shows what it expects while it does not.
class _ColorCodeField extends StatefulWidget {
  const _ColorCodeField({required this.color, required this.onChanged});
  final Color color;
  final ValueChanged<Color> onChanged;

  @override
  State<_ColorCodeField> createState() => _ColorCodeFieldState();
}

class _ColorCodeFieldState extends State<_ColorCodeField> {
  late final _text = TextEditingController(text: colorToHex(widget.color));
  final _focus = FocusNode();
  bool _invalid = false;

  @override
  void didUpdateWidget(_ColorCodeField old) {
    super.didUpdateWidget(old);
    // A swatch was clicked: show its code, unless the user is mid-typing.
    if (old.color != widget.color && !_focus.hasFocus) {
      _text.text = colorToHex(widget.color);
      _invalid = false;
    }
  }

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _apply(String v) {
    final c = parseColorCode(v);
    setState(() => _invalid = c == null && v.trim().isNotEmpty);
    if (c != null) widget.onChanged(c);
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 220,
      child: TextField(
        controller: _text,
        focusNode: _focus,
        onChanged: _apply,
        onSubmitted: _apply,
        style: const TextStyle(fontSize: 13),
        decoration: InputDecoration(
          isDense: true,
          labelText: tr('Color code'),
          hintText: tr('#1E1E1E or rgb(30, 30, 30)'),
          errorText: _invalid ? tr('Use #RRGGBB, #RGB or rgb(r, g, b)') : null,
          // The colour itself: click it for the palette.
          prefixIcon: Tooltip(
            message: tr('Pick a color'),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: () async {
                final c = await showColorPicker(context, initial: widget.color, title: 'Pick a color');
                if (c != null) widget.onChanged(c);
              },
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Container(
                  width: 16,
                  height: 16,
                  decoration: BoxDecoration(
                    color: widget.color,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.black26),
                  ),
                ),
              ),
            ),
          ),
          prefixIconConstraints: const BoxConstraints(minWidth: 36, minHeight: 36),
        ),
      ),
    );
  }
}

class _SwatchGroup extends StatelessWidget {
  const _SwatchGroup({
    required this.title,
    required this.colors,
    required this.selected,
    required this.onPick,
  });

  final String title;
  final List<Color> colors;
  final Color selected;
  final ValueChanged<Color> onPick;

  /// The last swatch: opens the palette for any colour, not only these.
  Widget _paletteButton(BuildContext context) {
    final theme = Theme.of(context);
    return Tooltip(
      message: tr('Pick a color'),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: () async {
            final c = await showColorPicker(context, initial: selected, title: 'Pick a color');
            if (c != null) onPick(c);
          },
          child: Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: const SweepGradient(
                colors: [
                  Color(0xFFFF0000),
                  Color(0xFFFFFF00),
                  Color(0xFF00FF00),
                  Color(0xFF00FFFF),
                  Color(0xFF0000FF),
                  Color(0xFFFF00FF),
                  Color(0xFFFF0000),
                ],
              ),
              border: Border.all(color: theme.dividerColor),
            ),
            child: Center(
              child: Container(
                width: 20,
                height: 20,
                decoration: BoxDecoration(color: theme.colorScheme.surface, shape: BoxShape.circle),
                child: Icon(Icons.colorize, size: 12, color: theme.textTheme.bodyMedium?.color),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _swatch(Color c, Color accent) {
    final on = selected.toARGB32() == c.toARGB32();
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => onPick(c),
        child: Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: c,
            shape: BoxShape.circle,
            border: Border.all(color: on ? accent : Colors.black26, width: on ? 3 : 1),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final custom = !colors.any((c) => c.toARGB32() == selected.toARGB32());
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(tr(title), style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500)),
        const SizedBox(height: 10),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            for (final c in colors) _swatch(c, accent),
            // A colour entered by code shows as its own selected swatch, so
            // it is clear which colour is in use.
            if (custom) _swatch(selected, accent),
            _paletteButton(context),
          ],
        ),
        const SizedBox(height: 14),
        _ColorCodeField(color: selected, onChanged: onPick),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Import / export
// ---------------------------------------------------------------------------

class _ImportExport extends StatelessWidget {
  const _ImportExport();

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final tileWidth = constraints.maxWidth >= 560
            ? (constraints.maxWidth - 14) / 2
            : constraints.maxWidth;
        return Wrap(
          spacing: 14,
          runSpacing: 14,
          children: [
            SizedBox(
              width: tileWidth,
              child: _ActionTile(
                icon: Icons.file_download_outlined,
                title: 'Import connections',
                description: 'From an export file (JSON, XML or CSV).',
                action: 'Import…',
                onPressed: () => showImportDialog(context),
              ),
            ),
            SizedBox(
              width: tileWidth,
              child: _ActionTile(
                icon: Icons.file_upload_outlined,
                title: 'Export connections',
                description: 'Save some or all of your connections as JSON, XML or CSV.',
                action: 'Export…',
                onPressed: () => showExportDialog(context),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _ActionTile extends StatelessWidget {
  const _ActionTile({
    required this.icon,
    required this.title,
    required this.description,
    required this.action,
    required this.onPressed,
  });

  final IconData icon;
  final String title;
  final String description;
  final String action;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        border: Border.all(color: theme.dividerColor),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 20),
              const SizedBox(width: 10),
              Flexible(
                child: Text(tr(title), style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            tr(description),
            style: TextStyle(fontSize: 12, height: 1.45, color: theme.textTheme.bodySmall?.color),
          ),
          const SizedBox(height: 14),
          OutlinedButton(onPressed: onPressed, child: Text(tr(action))),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Updates
// ---------------------------------------------------------------------------

enum _Phase { idle, checking, upToDate, available, installing, failed }

/// "Check for updates", answered on the page itself rather than in a popup.
///
/// Separate from the prompt shown at launch, which stays: that one comes to
/// the user; this is for the user who comes looking.
class _UpdatesPanel extends StatefulWidget {
  const _UpdatesPanel();

  @override
  State<_UpdatesPanel> createState() => _UpdatesPanelState();
}

class _UpdatesPanelState extends State<_UpdatesPanel> {
  _Phase _phase = _Phase.idle;
  UpdateInfo? _info;
  double? _progress;
  String? _error;
  bool _installFailed = false;

  @override
  void initState() {
    super.initState();
    // Already found at launch: say so straight away instead of making the
    // user press a button to learn what the app already knows.
    final known = UpdateService.available.value;
    if (known != null) {
      _info = known;
      _phase = _Phase.available;
    }
  }

  Future<void> _check() async {
    setState(() {
      _phase = _Phase.checking;
      _error = null;
      _installFailed = false;
    });
    final result = await UpdateService.checkNow();
    if (!mounted) return;
    setState(() {
      if (result.failed) {
        _phase = _Phase.failed;
        _error = tr(
          'Could not reach GitHub to check for updates. Check the internet connection and try again.',
        );
      } else if (result.info == null) {
        _phase = _Phase.upToDate;
      } else {
        _info = result.info;
        UpdateService.available.value = result.info;
        _phase = _Phase.available;
      }
    });
  }

  Future<void> _install() async {
    final info = _info;
    if (info == null) return;
    setState(() {
      _phase = _Phase.installing;
      _progress = 0;
      _error = null;
    });
    final error = await installUpdate(
      info,
      onProgress: (p) {
        if (mounted) setState(() => _progress = p);
      },
    );
    if (!mounted) return;
    setState(() {
      _phase = _Phase.failed;
      _installFailed = true;
      _error = error;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dim = theme.textTheme.bodySmall?.color;
    final busy = _phase == _Phase.checking || _phase == _Phase.installing;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'CommandS $appVersion',
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 3),
                  Text(tr('Installed version'), style: TextStyle(fontSize: 12, color: dim)),
                ],
              ),
            ),
            OutlinedButton.icon(
              onPressed: busy ? null : _check,
              icon: const Icon(Icons.refresh, size: 16),
              label: Text(tr('Check for updates')),
            ),
          ],
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 160),
          alignment: Alignment.topCenter,
          child: _status(context),
        ),
      ],
    );
  }

  Widget _status(BuildContext context) {
    final theme = Theme.of(context);
    final dim = theme.textTheme.bodySmall?.color;
    switch (_phase) {
      case _Phase.idle:
        return const SizedBox(width: double.infinity);
      case _Phase.checking:
        return _StatusBox(
          child: Row(
            children: [
              const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
              const SizedBox(width: 12),
              Text(tr('Checking for updates…'), style: TextStyle(color: dim)),
            ],
          ),
        );
      case _Phase.upToDate:
        return _StatusBox(
          child: Row(
            children: [
              const Icon(Icons.check_circle_outline, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  tr("You're up to date — {version} is the latest version.", {'version': appVersion}),
                  style: const TextStyle(fontWeight: FontWeight.w500),
                ),
              ),
            ],
          ),
        );
      case _Phase.available:
        final info = _info!;
        final notes = info.plainNotes;
        return _StatusBox(
          emphasised: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.new_releases_outlined, size: 20),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      tr('CommandS {version} is available', {'version': info.version}),
                      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
                    ),
                  ),
                  if (info.sizeLabel.isNotEmpty)
                    Text(info.sizeLabel, style: TextStyle(fontSize: 12, color: dim)),
                ],
              ),
              if (notes.isNotEmpty) ...[
                const SizedBox(height: 12),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 200),
                  child: SingleChildScrollView(
                    child: Text(notes, style: const TextStyle(fontSize: 12, height: 1.5)),
                  ),
                ),
              ],
              const SizedBox(height: 16),
              Text(
                tr('Update to {version} now?', {'version': info.version}),
                style: TextStyle(fontSize: 12, color: dim),
              ),
              const SizedBox(height: 10),
              if (info.canSelfInstall)
                ElevatedButton.icon(
                  onPressed: _install,
                  icon: const Icon(Icons.system_update_alt, size: 16),
                  label: Text(tr('Yes, update')),
                )
              else
                // Only when the release itself is missing this platform's
                // build; every copy that has a build to use updates in place.
                OutlinedButton(
                  onPressed: () => UpdateService.openReleasePage(info),
                  child: Text(tr('Open download page')),
                ),
            ],
          ),
        );
      case _Phase.installing:
        final p = _progress;
        return _StatusBox(
          emphasised: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                p == null
                    ? tr('Downloading {version}…', {'version': _info?.version ?? tr('the update')})
                    : tr('Downloading {version}… {percent}%', {
                        'version': _info?.version ?? tr('the update'),
                        'percent': (p * 100).toStringAsFixed(0),
                      }),
                style: const TextStyle(fontWeight: FontWeight.w500),
              ),
              const SizedBox(height: 10),
              LinearProgressIndicator(value: p),
              const SizedBox(height: 10),
              Text(
                tr('CommandS will close and reopen on the new version by itself.'),
                style: TextStyle(fontSize: 12, color: dim),
              ),
            ],
          ),
        );
      case _Phase.failed:
        return _StatusBox(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_error ?? tr('Something went wrong.'), style: TextStyle(color: theme.colorScheme.error)),
              const SizedBox(height: 12),
              Wrap(
                spacing: 10,
                runSpacing: 8,
                children: [
                  OutlinedButton(onPressed: _installFailed ? _install : _check, child: Text(tr('Try again'))),
                  // The last resort, and only after an update has actually
                  // failed: the normal path never sends anyone to a web page.
                  if (_installFailed && _info != null)
                    TextButton(
                      onPressed: () => UpdateService.openReleasePage(_info!),
                      child: Text(tr('Open download page')),
                    ),
                ],
              ),
            ],
          ),
        );
    }
  }
}

// ---------------------------------------------------------------------------
// Support & feedback
// ---------------------------------------------------------------------------

/// A box to write in and a Send button. Anonymous: see [FeedbackService].
class _FeedbackPanel extends StatefulWidget {
  const _FeedbackPanel();

  @override
  State<_FeedbackPanel> createState() => _FeedbackPanelState();
}

class _FeedbackPanelState extends State<_FeedbackPanel> {
  final _text = TextEditingController();
  bool _sending = false;

  /// null: nothing sent yet; true: sent; false: failed.
  bool? _result;

  @override
  void initState() {
    super.initState();
    _text.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    setState(() {
      _sending = true;
      _result = null;
    });
    final ok = await FeedbackService.send(_text.text);
    if (!mounted) return;
    setState(() {
      _sending = false;
      _result = ok;
      if (ok) _text.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dim = theme.textTheme.bodySmall?.color;
    final canSend = !_sending && _text.text.trim().isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          tr(
            'Found a problem, or have an idea? Write it here. Sending is anonymous: only your message, the app version and the operating system are sent.',
          ),
          style: TextStyle(fontSize: 12, height: 1.45, color: dim),
        ),
        const SizedBox(height: 12),
        TextField(
          key: const ValueKey('feedback-text'),
          controller: _text,
          minLines: 4,
          maxLines: 10,
          maxLength: FeedbackService.maxLength,
          enabled: !_sending,
          style: const TextStyle(fontSize: 13),
          decoration: InputDecoration(hintText: tr('Your message')),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                child: _result == null
                    ? const SizedBox.shrink()
                    : Row(
                        key: ValueKey(_result),
                        children: [
                          Icon(
                            _result! ? Icons.check_circle_outline : Icons.error_outline,
                            size: 18,
                            color: _result! ? null : theme.colorScheme.error,
                          ),
                          const SizedBox(width: 8),
                          Flexible(
                            child: Text(
                              _result!
                                  ? tr('Sent. Thank you!')
                                  : tr('Could not send. Check the internet connection and try again.'),
                              style: TextStyle(
                                fontSize: 12.5,
                                color: _result! ? null : theme.colorScheme.error,
                              ),
                            ),
                          ),
                        ],
                      ),
              ),
            ),
            const SizedBox(width: 12),
            ElevatedButton.icon(
              onPressed: canSend ? _send : null,
              icon: _sending
                  ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.send_outlined, size: 16),
              label: Text(tr('Send')),
            ),
          ],
        ),
      ],
    );
  }
}

class _StatusBox extends StatelessWidget {
  const _StatusBox({required this.child, this.emphasised = false});
  final Widget child;
  final bool emphasised;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: emphasised ? theme.colorScheme.primary.withValues(alpha: 0.06) : null,
        border: Border.all(
          color: emphasised ? theme.colorScheme.primary.withValues(alpha: 0.5) : theme.dividerColor,
        ),
        borderRadius: BorderRadius.circular(6),
      ),
      child: child,
    );
  }
}
