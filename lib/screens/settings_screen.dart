import 'dart:io';

import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:provider/provider.dart';

import '../app_version.dart';
import '../providers/app_state.dart';
import '../services/feedback_service.dart';
import '../services/mcp_server.dart';
import '../services/session_log.dart';
import '../services/terminal_appearance.dart';
import '../services/update_service.dart';
import '../theme/app_theme.dart';
import '../theme/theme_presets.dart';
import '../widgets/color_picker_dialog.dart';
import '../widgets/custom_title_bar.dart';
import '../widgets/import_export_dialog.dart';
import '../widgets/update_dialog.dart';
import '../l10n/strings.dart';
import '../models/models.dart';
import '../widgets/device_icon.dart';

/// Opens the Settings page.
Future<void> showSettings(BuildContext context) {
  return Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const SettingsScreen()));
}

/// The pages of Settings, in the order the sidebar lists them.
enum SettingsPage {
  general('General', Icons.tune),
  theme('Theme', Icons.palette_outlined),
  terminal('SSH terminal', Icons.terminal),
  connections('Connections', Icons.swap_vert),
  sessionLogs('Session logs', Icons.description_outlined),
  privacy('Privacy', Icons.shield_outlined),
  updates('Updates', Icons.system_update_alt),
  support('Support & feedback', Icons.chat_bubble_outline);

  const SettingsPage(this.title, this.icon);

  /// English text, the key for [tr].
  final String title;
  final IconData icon;
}

/// Settings, laid out like a desktop app's preferences: the sections down a
/// sidebar on the left, one page at a time on the right.
///
/// A full page rather than a dialog: it carries the app's own title bar, so
/// the window can still be moved and closed while it is open, and opening it
/// suspends any embedded RDP session the same way a dialog does (the session
/// is a window of its own, drawn above the app, and would otherwise cover it).
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, this.initialPage = SettingsPage.general});

  /// The page shown first; tests open the one they are about.
  final SettingsPage initialPage;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late SettingsPage _page = widget.initialPage;

  List<Widget> _content(SettingsPage page, bool hasMcpServer) {
    switch (page) {
      case SettingsPage.general:
        return const [_Section(children: [_LanguagePicker()])];
      case SettingsPage.theme:
        return const [_Section(children: [_ThemePicker()])];
      case SettingsPage.terminal:
        return const [_Section(children: [_TerminalAppearance()])];
      case SettingsPage.connections:
        return const [_Section(children: [_ImportExport()])];
      case SettingsPage.sessionLogs:
        return const [_Section(children: [_SessionLogSettings()])];
      case SettingsPage.privacy:
        return [
          if (hasMcpServer) ...[
            const _Section(title: 'MCP integration', children: [_McpPanel()]),
            const SizedBox(height: 18),
          ],
          const _Section(title: 'Passwords', children: [_PasswordsNote()]),
        ];
      case SettingsPage.updates:
        return const [_Section(children: [_UpdatesPanel()])];
      case SettingsPage.support:
        return const [_Section(children: [_FeedbackPanel()])];
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final divider = theme.dividerColor;
    final hasMcpServer = context.watch<McpServer?>() != null;
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
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _SettingsNav(current: _page, onSelect: (p) => setState(() => _page = p)),
                Expanded(
                  child: SingleChildScrollView(
                    key: ValueKey('settings-page-${_page.name}'),
                    padding: const EdgeInsets.fromLTRB(32, 26, 32, 32),
                    child: Align(
                      alignment: Alignment.topLeft,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 780),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(tr(_page.title), style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
                            const SizedBox(height: 18),
                            ..._content(_page, hasMcpServer),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SettingsNav extends StatelessWidget {
  const _SettingsNav({required this.current, required this.onSelect});

  final SettingsPage current;
  final ValueChanged<SettingsPage> onSelect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = AppPalette.of(context);
    final dark = theme.brightness == Brightness.dark;
    final selected = palette.text.withValues(alpha: dark ? 0.10 : 0.07);
    return Container(
      width: 224,
      decoration: BoxDecoration(
        color: palette.panel,
        border: Border(right: BorderSide(color: theme.dividerColor)),
      ),
      padding: const EdgeInsets.fromLTRB(10, 14, 10, 14),
      child: ListView(
        children: [
          for (final page in SettingsPage.values)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Material(
                color: page == current ? selected : Colors.transparent,
                borderRadius: BorderRadius.circular(kControlRadius),
                child: InkWell(
                  key: ValueKey('settings-nav-${page.name}'),
                  borderRadius: BorderRadius.circular(kControlRadius),
                  onTap: () => onSelect(page),
                  child: Container(
                    height: 36,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    child: Row(
                      children: [
                        Icon(
                          page.icon,
                          size: 17,
                          color: page == current ? palette.text : palette.textDim,
                        ),
                        const SizedBox(width: 11),
                        Expanded(
                          child: Text(
                            tr(page.title),
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: page == current ? FontWeight.w600 : FontWeight.w400,
                              color: page == current ? palette.text : palette.textDim,
                            ),
                          ),
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

class _PasswordsNote extends StatelessWidget {
  const _PasswordsNote();

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(Icons.lock_outline, size: 18),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            tr('Remembered passwords are encrypted and kept on this computer. An export includes them only if you choose to.'),
            style: TextStyle(fontSize: 13, height: 1.45, color: Theme.of(context).textTheme.bodySmall?.color),
          ),
        ),
      ],
    );
  }
}

class _SessionLogSettings extends StatefulWidget {
  const _SessionLogSettings();

  @override
  State<_SessionLogSettings> createState() => _SessionLogSettingsState();
}

class _SessionLogSettingsState extends State<_SessionLogSettings> {
  String? _directory;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final directory = await SessionLogSettings.directory();
      if (mounted) setState(() => _directory = directory);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  Future<void> _choose() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final selected = await FilePicker.platform.getDirectoryPath(
        dialogTitle: tr('Choose log folder'),
        initialDirectory: _directory,
      );
      if (selected == null) return;
      await SessionLogSettings.setDirectory(selected);
      if (mounted) setState(() { _directory = selected; _error = null; });
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final dim = Theme.of(context).textTheme.bodySmall?.color;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(tr('SSH output is saved as UTF-8 under <host>/<YYYY-MM-DD>/<HH-mm-ss>.log.'),
            style: TextStyle(fontSize: 12, color: dim)),
        const SizedBox(height: 10),
        SelectableText(_directory ?? tr('Loading…'), style: const TextStyle(fontSize: 12)),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          onPressed: _busy ? null : _choose,
          icon: const Icon(Icons.folder_open_outlined, size: 16),
          label: Text(tr('Choose log folder')),
        ),
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error, fontSize: 12)),
        ],
      ],
    );
  }
}

class _McpPanel extends StatelessWidget {
  const _McpPanel();

  Future<void> _confirmNewUrl(BuildContext context, McpServer server) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('Create a new address?')),
        content: Text(tr('The current address stops working at once. Agents connected with it lose access until you give them the new one.')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('Cancel'))),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(tr('New address'))),
        ],
      ),
    );
    if (ok == true) await server.regenerateUrl();
  }

  @override
  Widget build(BuildContext context) {
    final server = context.watch<McpServer>();
    final secondary = Theme.of(context).textTheme.bodySmall?.color;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(tr('Allow MCP access')),
                  const SizedBox(height: 4),
                  Text(tr('Lets a connected agent open saved SSH connections, send commands, and read terminal output.'),
                      style: TextStyle(fontSize: 12, color: secondary)),
                ],
              ),
            ),
            Switch(
              value: server.enabled,
              onChanged: (value) async {
                if (value) {
                  await server.start();
                } else {
                  await server.stop();
                }
              },
            ),
          ],
        ),
        if (server.url case final url?) ...[
          const SizedBox(height: 12),
          Text(tr('MCP server URL'), style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(child: SelectableText(url)),
              TextButton.icon(
                key: const ValueKey('mcp-new-url'),
                icon: const Icon(Icons.refresh_rounded, size: 16),
                label: Text(tr('New address')),
                onPressed: () => _confirmNewUrl(context, server),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(tr('Use this URL directly in ChatGPT Work desktop, or point a Secure MCP Tunnel at it for hosted ChatGPT Work. Keep the URL private.'),
              style: TextStyle(fontSize: 12, color: secondary)),
        ],
        if (server.gateway case final AppMcpGateway gateway) ...[
          const SizedBox(height: 20),
          Text(tr('Allowed connections'), style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text(
            tr('Tick the SSH connections an agent may use; a folder ticks everything in it. The agent sees only the anonymous name. On network devices, show and display commands run at once; every other command asks you first. Terminal output is sent as it is, so it can still show device names and addresses.'),
            style: TextStyle(fontSize: 12, color: secondary),
          ),
          const SizedBox(height: 10),
          _McpConnectionPicker(gateway: gateway),
        ],
        if (server.error case final error?) ...[
          const SizedBox(height: 8),
          Text(error, style: TextStyle(color: Theme.of(context).colorScheme.error)),
        ],
      ],
    );
  }
}

/// Which saved SSH connections an agent may use, picked from the same folder
/// tree as the sidebar. Ticking a folder allows every SSH connection in it,
/// subfolders included; a half-ticked folder has some of them.
class _McpConnectionPicker extends StatefulWidget {
  const _McpConnectionPicker({required this.gateway});

  final AppMcpGateway gateway;

  @override
  State<_McpConnectionPicker> createState() => _McpConnectionPickerState();
}

class _McpConnectionPickerState extends State<_McpConnectionPicker> {
  final _expanded = <String>{};
  final _search = TextEditingController();

  void _changed() => setState(() {});

  @override
  void initState() {
    super.initState();
    widget.gateway.addListener(_changed);
  }

  @override
  void didUpdateWidget(_McpConnectionPicker old) {
    super.didUpdateWidget(old);
    if (old.gateway != widget.gateway) {
      old.gateway.removeListener(_changed);
      widget.gateway.addListener(_changed);
    }
  }

  @override
  void dispose() {
    widget.gateway.removeListener(_changed);
    _search.dispose();
    super.dispose();
  }

  static int _byName(String a, String b) => a.toLowerCase().compareTo(b.toLowerCase());

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final gateway = widget.gateway;
    final palette = AppPalette.of(context);
    final query = _search.text.trim().toLowerCase();

    final ssh = [
      for (final c in app.connections)
        if (c.protocol == ConnectionProtocol.ssh && (query.isEmpty || c.name.toLowerCase().contains(query))) c,
    ];
    final folderIds = {for (final f in app.folders) f.id};
    final childFolders = <String?, List<ConnectionFolder>>{};
    for (final f in app.folders) {
      final parent = folderIds.contains(f.parentId) ? f.parentId : null;
      childFolders.putIfAbsent(parent, () => []).add(f);
    }
    final directConnections = <String?, List<SavedConnection>>{};
    for (final c in ssh) {
      final folder = folderIds.contains(c.folderId) ? c.folderId : null;
      directConnections.putIfAbsent(folder, () => []).add(c);
    }

    // Every SSH connection under a folder, subfolders included.
    final under = <String, List<SavedConnection>>{};
    List<SavedConnection> collect(String id) => under[id] ??= [
          ...?directConnections[id],
          for (final sub in childFolders[id] ?? const <ConnectionFolder>[]) ...collect(sub.id),
        ];

    final rows = <Widget>[];
    void addConnection(SavedConnection c, int depth) {
      final allowed = gateway.isAllowed(c.id);
      final kind = DeviceIcon.of(c);
      rows.add(_TreeRow(
        key: ValueKey('mcp-conn-${c.id}'),
        depth: depth,
        leading: const SizedBox(width: 20),
        checkbox: Checkbox(
          value: allowed,
          visualDensity: VisualDensity.compact,
          onChanged: (v) => gateway.setAllowed(c.id, v ?? false),
        ),
        icon: kind == null ? Icon(Icons.terminal, size: 15, color: palette.textDim) : DeviceIcon(kind, size: 15),
        label: c.name,
        trailing: allowed
            ? Text(gateway.aliasOf(c.id)!, style: TextStyle(fontSize: 11, color: palette.textDim, fontFamily: 'Consolas'))
            : null,
        onTap: () => gateway.setAllowed(c.id, !allowed),
      ));
    }

    void addFolder(ConnectionFolder f, int depth) {
      final inside = collect(f.id);
      if (inside.isEmpty) return;
      final count = inside.where((c) => gateway.isAllowed(c.id)).length;
      final open = query.isNotEmpty || _expanded.contains(f.id);
      void toggleOpen() => setState(() => open ? _expanded.remove(f.id) : _expanded.add(f.id));
      rows.add(_TreeRow(
        key: ValueKey('mcp-folder-${f.id}'),
        depth: depth,
        leading: InkWell(
          onTap: toggleOpen,
          child: Icon(open ? Icons.expand_more : Icons.chevron_right, size: 18, color: palette.textDim),
        ),
        checkbox: Checkbox(
          tristate: true,
          value: count == 0 ? false : (count == inside.length ? true : null),
          visualDensity: VisualDensity.compact,
          onChanged: (_) => gateway.setAllowedAll(
            [for (final c in inside) c.id],
            count < inside.length,
          ),
        ),
        icon: Icon(open ? Icons.folder_open_outlined : Icons.folder_outlined, size: 16, color: palette.textDim),
        label: f.name,
        bold: true,
        trailing: Text('$count/${inside.length}', style: TextStyle(fontSize: 11, color: palette.textDim)),
        onTap: toggleOpen,
      ));
      if (!open) return;
      for (final sub in [...?childFolders[f.id]]..sort((a, b) => _byName(a.name, b.name))) {
        addFolder(sub, depth + 1);
      }
      for (final c in [...?directConnections[f.id]]..sort((a, b) => _byName(a.name, b.name))) {
        addConnection(c, depth + 1);
      }
    }

    for (final f in [...?childFolders[null]]..sort((a, b) => _byName(a.name, b.name))) {
      addFolder(f, 0);
    }
    for (final c in [...?directConnections[null]]..sort((a, b) => _byName(a.name, b.name))) {
      addConnection(c, 0);
    }

    final total = app.connections.where((c) => c.protocol == ConnectionProtocol.ssh).length;
    final allowedCount = gateway.allowedConnections.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: TextField(
                key: const ValueKey('mcp-search'),
                controller: _search,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: tr('Search connections'),
                  prefixIcon: const Icon(Icons.search, size: 16),
                  prefixIconConstraints: const BoxConstraints(minWidth: 34, minHeight: 20),
                ),
              ),
            ),
            const SizedBox(width: 14),
            Text(
              tr('{n} of {total} allowed', {'n': allowedCount, 'total': total}),
              style: TextStyle(fontSize: 12, color: palette.textDim),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Container(
          constraints: const BoxConstraints(maxHeight: 340),
          decoration: BoxDecoration(
            border: Border.all(color: palette.border),
            borderRadius: BorderRadius.circular(kControlRadius),
          ),
          child: rows.isEmpty
              ? Padding(
                  padding: const EdgeInsets.all(14),
                  child: Text(
                    query.isEmpty ? tr('No saved SSH connections yet.') : tr('No connection matches.'),
                    style: TextStyle(fontSize: 12, color: palette.textDim),
                  ),
                )
              : ListView(
                  shrinkWrap: true,
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  children: rows,
                ),
        ),
      ],
    );
  }
}

class _TreeRow extends StatelessWidget {
  const _TreeRow({
    super.key,
    required this.depth,
    required this.leading,
    required this.checkbox,
    required this.icon,
    required this.label,
    required this.onTap,
    this.trailing,
    this.bold = false,
  });

  final int depth;
  final Widget leading;
  final Widget checkbox;
  final Widget icon;
  final String label;
  final Widget? trailing;
  final bool bold;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: SizedBox(
        height: 32,
        child: Row(
          children: [
            SizedBox(width: 6.0 + depth * 20),
            SizedBox(width: 20, child: leading),
            checkbox,
            icon,
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13, fontWeight: bold ? FontWeight.w600 : FontWeight.w400),
              ),
            ),
            if (trailing != null) ...[trailing!, const SizedBox(width: 12)],
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Layout pieces
// ---------------------------------------------------------------------------

class _Section extends StatelessWidget {
  const _Section({this.title, required this.children});
  final String? title;
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
          if (title != null) ...[
            Text(tr(title!), style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
            const SizedBox(height: 16),
          ],
          ...children,
        ],
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
        // A menu rather than side-by-side buttons, so more languages fit.
        SizedBox(
          width: 280,
          child: _MenuField<AppLanguage>(
            key: const ValueKey('language'),
            label: tr('Language'),
            current: app.language,
            onSelected: app.setLanguage,
            choices: [for (final l in AppLanguage.values) _MenuChoice(l, l.label)],
          ),
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

  Future<void> _import(BuildContext context) async {
    final app = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    final result = await FilePicker.platform.pickFiles(
      dialogTitle: tr('Import theme'),
      type: FileType.custom,
      allowedExtensions: const ['json'],
    );
    final path = result?.files.single.path;
    if (path == null) return;
    try {
      final file = File(path);
      if (await file.length() > ThemePreset.maxFileBytes) {
        throw const FormatException('The theme file is too large.');
      }
      final theme = await app.importTheme(await file.readAsString());
      await app.selectTheme(theme.id);
      messenger.showSnackBar(SnackBar(content: Text(tr('Theme imported: {name}', {'name': theme.name}))));
    } on FormatException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(tr('Could not import the theme: {error}', {'error': tr(e.message)}))));
    } on FileSystemException {
      messenger.showSnackBar(SnackBar(content: Text(tr('Could not read the theme file.'))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final classic = app.themeId == null;
    final dim = Theme.of(context).textTheme.bodySmall?.color;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Light and Dark first, then the catalogue and imported themes, all
        // the same size.
        Wrap(
          spacing: 12,
          runSpacing: 14,
          children: [
            _ThemeCard(
              key: const ValueKey('theme-light'),
              label: 'Light',
              compact: true,
              palette: AppPalette.classicLight,
              selected: classic && app.themeMode == ThemeMode.light,
              onTap: () => app.setThemeMode(ThemeMode.light),
            ),
            _ThemeCard(
              key: const ValueKey('theme-dark'),
              label: 'Dark',
              compact: true,
              palette: AppPalette.classicDark,
              selected: classic && app.themeMode == ThemeMode.dark,
              onTap: () => app.setThemeMode(ThemeMode.dark),
            ),
            for (final t in app.allThemes)
              _ThemeCard(
                key: ValueKey('theme-${t.id}'),
                label: t.name,
                translate: false,
                compact: true,
                palette: AppPalette(
                  bg: t.background,
                  panel: t.panel,
                  panelAlt: t.panelAlt,
                  border: t.border,
                  text: t.text,
                  textDim: t.textDim,
                ),
                accent: t.accent,
                terminal: t.ansi,
                selected: app.themeId == t.id,
                onTap: () => app.selectTheme(t.id),
                onRemove: t.imported ? () => app.removeImportedTheme(t.id) : null,
              ),
          ],
        ),
        const SizedBox(height: 14),
        Wrap(
          spacing: 18,
          runSpacing: 10,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            OutlinedButton.icon(
              key: const ValueKey('import-theme'),
              onPressed: () => _import(context),
              icon: const Icon(Icons.file_open_outlined, size: 16),
              label: Text(tr('Import theme…')),
            ),
            Text(
              tr('A JSON file in the CommandS theme format.'),
              style: TextStyle(fontSize: 12, color: dim),
            ),
          ],
        ),
        const SizedBox(height: 14),
        Row(
          children: [
            Switch(
              key: const ValueKey('keep-terminal-colors'),
              value: app.keepTerminalColors,
              onChanged: app.setKeepTerminalColors,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(tr('Keep my SSH terminal colours'), style: const TextStyle(fontSize: 13)),
                  const SizedBox(height: 2),
                  Text(
                    tr('A theme then changes only the app, not the terminal colours you set.'),
                    style: TextStyle(fontSize: 12, color: dim),
                  ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// A miniature of the app in one theme -- title bar, sidebar, content -- so
/// the choice is made by looking rather than by reading a word. Catalogue
/// themes also show a strip of their terminal colours.
class _ThemeCard extends StatelessWidget {
  const _ThemeCard({
    super.key,
    required this.label,
    required this.palette,
    required this.selected,
    required this.onTap,
    this.accent,
    this.terminal,
    this.compact = false,
    this.translate = true,
    this.onRemove,
  });

  final String label;
  final AppPalette palette;
  final Color? accent;
  final List<Color>? terminal;
  final bool selected;
  final bool compact;

  /// Theme names are names; only Light and Dark are translated.
  final bool translate;
  final VoidCallback onTap;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final selectedColor = Theme.of(context).colorScheme.primary;
    final width = compact ? 160.0 : 220.0;
    final height = compact ? 96.0 : 132.0;
    final line = palette.border;

    Widget bar(double w) => Container(
      width: w,
      height: compact ? 4 : 5,
      margin: EdgeInsets.only(bottom: compact ? 5 : 6),
      decoration: BoxDecoration(color: line, borderRadius: BorderRadius.circular(2)),
    );

    final colours = terminal;
    Widget tint(Color c, double w) => Container(
      width: w,
      height: compact ? 4 : 5,
      margin: EdgeInsets.only(bottom: compact ? 5 : 6),
      decoration: BoxDecoration(color: c.withValues(alpha: 0.85), borderRadius: BorderRadius.circular(2)),
    );
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: SizedBox(
          width: width,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                width: width,
                height: height,
                decoration: BoxDecoration(
                  color: palette.bg,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: selected ? selectedColor : Theme.of(context).dividerColor,
                    width: selected ? 2 : 1,
                  ),
                ),
                clipBehavior: Clip.antiAlias,
                child: Column(
                  children: [
                    Container(height: compact ? 10 : 14, color: palette.panelAlt),
                    Expanded(
                      child: Row(
                        children: [
                          Container(
                            width: compact ? 46 : 66,
                            color: palette.panel,
                            padding: EdgeInsets.fromLTRB(compact ? 6 : 8, compact ? 8 : 10, compact ? 6 : 8, 0),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [bar(compact ? 30 : 44), bar(compact ? 24 : 36), bar(compact ? 32 : 48)],
                            ),
                          ),
                          Expanded(
                            child: Padding(
                              padding: EdgeInsets.all(compact ? 8 : 12),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Container(
                                    width: compact ? 44 : 60,
                                    height: compact ? 5 : 7,
                                    margin: EdgeInsets.only(bottom: compact ? 7 : 9),
                                    decoration: BoxDecoration(
                                      color: accent ?? palette.text,
                                      borderRadius: BorderRadius.circular(2),
                                    ),
                                  ),
                                  // A catalogue theme shows its own terminal
                                  // colours, so the cards tell apart at a glance.
                                  if (colours != null) ...[
                                    tint(colours[2], compact ? 64 : 92),
                                    tint(colours[4], compact ? 48 : 70),
                                    tint(colours[3], compact ? 56 : 80),
                                  ] else ...[
                                    bar(compact ? 70 : 100),
                                    bar(compact ? 56 : 84),
                                  ],
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
                children: [
                  Icon(
                    selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                    size: 16,
                    color: selected ? selectedColor : Theme.of(context).textTheme.bodySmall?.color,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      translate ? tr(label) : label,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                    ),
                  ),
                  if (onRemove != null)
                    IconButton(
                      tooltip: tr('Remove theme'),
                      visualDensity: VisualDensity.compact,
                      iconSize: 15,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                      onPressed: onRemove,
                      icon: const Icon(Icons.close),
                    ),
                ],
              ),
            ],
          ),
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

/// One row of a [_MenuField].
class _MenuChoice<T> {
  const _MenuChoice(this.value, this.label, {this.style, this.dividerBefore = false});
  final T value;
  final String label;
  final TextStyle? style;
  final bool dividerBefore;
}

/// A field that opens the app's own desktop menu (hairline border, soft
/// shadow, compact rows) instead of Material's tall dropdown sheet, with a
/// tick on the current choice. Used for the font and the language, and for
/// anything with more choices to come.
class _MenuField<T> extends StatelessWidget {
  const _MenuField({
    super.key,
    required this.label,
    required this.choices,
    required this.current,
    required this.onSelected,
  });

  final String label;
  final List<_MenuChoice<T>> choices;
  final T current;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) {
    _MenuChoice<T>? chosen;
    for (final c in choices) {
      if (c.value == current) chosen = c;
    }
    return LayoutBuilder(
      builder: (context, constraints) => PopupMenuButton<T>(
        tooltip: label,
        position: PopupMenuPosition.under,
        offset: const Offset(0, 4),
        constraints: BoxConstraints(
          minWidth: constraints.maxWidth,
          maxWidth: constraints.maxWidth,
          maxHeight: 360,
        ),
        initialValue: current,
        onSelected: onSelected,
        itemBuilder: (_) => [
          for (final c in choices) ...[
            if (c.dividerBefore) const PopupMenuDivider(height: 9),
            PopupMenuItem<T>(
              value: c.value,
              height: 34,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Row(
                children: [
                  SizedBox(
                    width: 22,
                    child: c.value == current ? const Icon(Icons.check, size: 15) : null,
                  ),
                  Expanded(
                    child: Text(c.label, style: c.style ?? const TextStyle(fontSize: 13), overflow: TextOverflow.ellipsis),
                  ),
                ],
              ),
            ),
          ],
        ],
        child: InputDecorator(
          decoration: InputDecoration(
            labelText: label,
            isDense: true,
            suffixIcon: const Icon(Icons.expand_more, size: 18),
            suffixIconConstraints: const BoxConstraints(minWidth: 32, minHeight: 20),
          ),
          child: Text(chosen?.label ?? '', style: chosen?.style, overflow: TextOverflow.ellipsis),
        ),
      ),
    );
  }
}

/// The font picker: each font shown in itself.
class _FontMenuField extends StatelessWidget {
  const _FontMenuField({
    required this.fonts,
    required this.current,
    required this.otherValue,
    required this.onSelected,
  });

  final List<String> fonts;
  final String current;
  final String otherValue;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    TextStyle face(String f) => TextStyle(fontFamily: f, fontFamilyFallback: const ['Consolas', 'Menlo'], fontSize: 13);
    return _MenuField<String>(
      key: const ValueKey('terminal-font'),
      label: tr('Font'),
      current: current,
      onSelected: onSelected,
      choices: [
        for (final f in fonts)
          _MenuChoice(f, f == defaultTerminalFont ? tr('{font} (default)', {'font': f}) : f, style: face(f)),
        _MenuChoice(
          otherValue,
          tr('Other font by name…'),
          style: TextStyle(fontSize: 13, color: Theme.of(context).textTheme.bodySmall?.color),
          dividerBefore: true,
        ),
      ],
    );
  }
}

class _TerminalAppearance extends StatefulWidget {
  const _TerminalAppearance();

  @override
  State<_TerminalAppearance> createState() => _TerminalAppearanceState();
}

class _TerminalAppearanceState extends State<_TerminalAppearance> {
  static const _other = '\u0000other';
  // The bundled fonts are there from the start; the installed ones join once
  // the system has been asked.
  List<String> _fonts = withBundledFonts([defaultTerminalFont]);
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
            '"Türk! Öğün, çalış, güven." - Mustafa Kemal Atatürk',
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
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SizedBox(
              width: 280,
              child: _FontMenuField(
                fonts: options,
                current: _typingFont ? _other : family,
                otherValue: _other,
                onSelected: (v) {
                  if (v == _other) {
                    setState(() {
                      _typingFont = true;
                      _fontName.text = '';
                    });
                  } else {
                    setState(() => _typingFont = false);
                    app.setTerminalFont(
                      family: v == defaultTerminalFont ? null : v,
                      resetFamily: v == defaultTerminalFont,
                    );
                  }
                },
              ),
            ),
            // The size and its value sit on the slider's own line, level with
            // the font field, rather than floating above it.
            SizedBox(
              width: 280,
              child: Row(
                children: [
                  Text(tr('Size'), style: TextStyle(fontSize: 12, color: dim)),
                  Expanded(
                    child: Slider(
                      value: size.clamp(9, 24),
                      min: 9,
                      max: 24,
                      divisions: 15,
                      label: '${size.round()} pt',
                      onChanged: (v) => app.setTerminalFont(size: v),
                    ),
                  ),
                  SizedBox(
                    width: 38,
                    child: Text('${size.round()} pt', style: TextStyle(fontSize: 12, color: dim)),
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
        final sideBySide = constraints.maxWidth >= 560;
        final importTile = _ActionTile(
          key: const Key('settings-import-card'),
          icon: Icons.file_download_outlined,
          title: 'Import connections',
          description: 'From an export file (JSON, XML or CSV).',
          action: 'Import…',
          fillHeight: sideBySide,
          onPressed: () => showImportDialog(context),
        );
        final exportTile = _ActionTile(
          key: const Key('settings-export-card'),
          icon: Icons.file_upload_outlined,
          title: 'Export connections',
          description: 'Save some or all of your connections as JSON, XML or CSV.',
          action: 'Export…',
          fillHeight: sideBySide,
          onPressed: () => showExportDialog(context),
        );
        if (!sideBySide) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [importTile, const SizedBox(height: 14), exportTile],
          );
        }
        return IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: importTile),
              const SizedBox(width: 14),
              Expanded(child: exportTile),
            ],
          ),
        );
      },
    );
  }
}

class _ActionTile extends StatelessWidget {
  const _ActionTile({
    super.key,
    required this.icon,
    required this.title,
    required this.description,
    required this.action,
    required this.fillHeight,
    required this.onPressed,
  });

  final IconData icon;
  final String title;
  final String description;
  final String action;
  final bool fillHeight;
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
          if (fillHeight) const Spacer(),
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

  Future<void> _chooseChannel(ReleaseChannel channel) async {
    await context.read<AppState>().setUpdateChannel(channel);
    UpdateService.available.value = null;
    if (!mounted) return;
    setState(() {
      _phase = _Phase.idle;
      _info = null;
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
                  Text(tr('Receive beta updates')),
                  const SizedBox(height: 4),
                  Text(
                    tr('Betas are offered too, as they come out. A beta replaces this version, with the same connections and settings, and may have bugs.'),
                    style: TextStyle(fontSize: 12, color: dim),
                  ),
                ],
              ),
            ),
            Switch(
              key: const ValueKey('beta-updates'),
              value: context.watch<AppState>().updateChannel == ReleaseChannel.beta,
              onChanged: (on) => _chooseChannel(on ? ReleaseChannel.beta : ReleaseChannel.stable),
            ),
          ],
        ),
        const SizedBox(height: 20),
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '$appName $appVersion',
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
                      tr(info.channel == ReleaseChannel.beta
                          ? 'CommandS Beta {version} is available'
                          : 'CommandS {version} is available', {'version': info.version}),
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
