import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_version.dart';
import '../providers/app_state.dart';
import '../services/update_service.dart';
import '../theme/app_theme.dart';
import '../widgets/custom_title_bar.dart';
import '../widgets/import_export_dialog.dart';
import '../widgets/update_dialog.dart';

/// Opens the Settings page.
Future<void> showSettings(BuildContext context) {
  return Navigator.of(context).push(
    MaterialPageRoute<void>(builder: (_) => const SettingsScreen()),
  );
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
            decoration: BoxDecoration(border: Border(bottom: BorderSide(color: divider))),
            child: Row(
              children: [
                IconButton(
                  tooltip: 'Back',
                  icon: const Icon(Icons.arrow_back, size: 18),
                  onPressed: () => Navigator.of(context).pop(),
                ),
                const SizedBox(width: 4),
                const Text('Settings', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
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
                          _Label('Terminal colors'),
                          _TerminalColors(),
                        ],
                      ),
                      SizedBox(height: 22),
                      _Section(
                        title: 'Connections',
                        children: [_ImportExport()],
                      ),
                      SizedBox(height: 22),
                      _Section(
                        title: 'Updates',
                        children: [_UpdatesPanel()],
                      ),
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
          Text(title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
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
        text,
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
  const _ThemeCard({
    required this.label,
    required this.light,
    required this.selected,
    required this.onTap,
  });

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
                Text(label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
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

class _TerminalColors extends StatelessWidget {
  const _TerminalColors();

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final bg = app.terminalBackground;
    final fg = app.terminalForeground;
    final mono = Platform.isMacOS ? 'Menlo' : 'Consolas';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // A real terminal's worth of text, so contrast can be judged on
        // something closer to what the session will actually look like.
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
            'Vlan10           10.35.10.1      up       up\n'
            'Gi1/0/1          unassigned      up       up',
            style: TextStyle(color: fg, fontFamily: mono, fontSize: 13, height: 1.5),
          ),
        ),
        const SizedBox(height: 18),
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

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500)),
        const SizedBox(height: 10),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            for (final c in colors)
              MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  onTap: () => onPick(c),
                  child: Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      color: c,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: selected.toARGB32() == c.toARGB32() ? accent : Colors.black26,
                        width: selected.toARGB32() == c.toARGB32() ? 3 : 1,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
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
                description:
                    'From a CommandS export (JSON, XML or CSV), or a Remote Desktop Manager export.',
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
              Text(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            description,
            style: TextStyle(fontSize: 12, height: 1.45, color: theme.textTheme.bodySmall?.color),
          ),
          const SizedBox(height: 14),
          OutlinedButton(onPressed: onPressed, child: Text(action)),
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
        _error = 'Could not reach GitHub to check for updates. '
            'Check the internet connection and try again.';
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
                  Text('CommandS $appVersion',
                      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 3),
                  Text('Installed version', style: TextStyle(fontSize: 12, color: dim)),
                ],
              ),
            ),
            OutlinedButton.icon(
              onPressed: busy ? null : _check,
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('Check for updates'),
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
              Text('Checking for updates…', style: TextStyle(color: dim)),
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
                  "You're up to date — $appVersion is the latest version.",
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
                      'CommandS ${info.version} is available',
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
              Text('Update to ${info.version} now?', style: TextStyle(fontSize: 12, color: dim)),
              const SizedBox(height: 10),
              if (info.canSelfInstall)
                ElevatedButton.icon(
                  onPressed: _install,
                  icon: const Icon(Icons.system_update_alt, size: 16),
                  label: const Text('Yes, update'),
                )
              else
                // Only when the release itself is missing this platform's
                // build; every copy that has a build to use updates in place.
                OutlinedButton(
                  onPressed: () => UpdateService.openReleasePage(info),
                  child: const Text('Open download page'),
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
                    ? 'Downloading ${_info?.version ?? 'the update'}…'
                    : 'Downloading ${_info?.version ?? 'the update'}… ${(p * 100).toStringAsFixed(0)}%',
                style: const TextStyle(fontWeight: FontWeight.w500),
              ),
              const SizedBox(height: 10),
              LinearProgressIndicator(value: p),
              const SizedBox(height: 10),
              Text(
                'CommandS will close and reopen on the new version by itself.',
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
              Text(_error ?? 'Something went wrong.', style: TextStyle(color: theme.colorScheme.error)),
              const SizedBox(height: 12),
              Wrap(
                spacing: 10,
                runSpacing: 8,
                children: [
                  OutlinedButton(
                    onPressed: _installFailed ? _install : _check,
                    child: const Text('Try again'),
                  ),
                  // The last resort, and only after an update has actually
                  // failed: the normal path never sends anyone to a web page.
                  if (_installFailed && _info != null)
                    TextButton(
                      onPressed: () => UpdateService.openReleasePage(_info!),
                      child: const Text('Open download page'),
                    ),
                ],
              ),
            ],
          ),
        );
    }
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
