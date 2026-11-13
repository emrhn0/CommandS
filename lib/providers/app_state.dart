import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app_version.dart';
import '../l10n/strings.dart';
import '../models/models.dart';
import '../services/pane_layout.dart';
import '../services/mac_prefs_migration.dart';
import '../services/mac_rdp_session.dart';
import '../services/rdm_import.dart';
import '../services/rdp_session.dart';
import '../services/serial_session.dart';
import '../services/session_controller.dart';
import '../services/storage_service.dart';
import '../services/pty_session.dart';
import '../services/hostname_discovery.dart';
import '../theme/theme_presets.dart';

class OpenTab {
  OpenTab({required this.id, required this.controller, this.connectionId});
  final String id;
  final SessionController controller;

  /// The saved connection this tab was opened from, so the tree can show
  /// which connections are open. Null for quick connections, until one is
  /// saved from its tab.
  String? connectionId;
}

/// Sessions shown together in a split, which the tab bar shows as one tab:
/// switching to another tab and back brings the whole arrangement back.
class TabGroup {
  TabGroup({required this.id, required this.layout, this.name});
  final String id;

  /// The tiling, the same object the tab area shows while the group is
  /// active, so dragged dividers are kept.
  PaneNode layout;

  /// The saved layout it was opened from; null for one made in Split view
  /// (shown as "Split View").
  String? name;

  List<String> get tabIds => tabIdsInLayoutOrdered(layout);
}

class AppState extends ChangeNotifier {
  AppState({HostnameDetectionLog? hostnameLog})
      : _hostnameLog = hostnameLog ?? HostnameDetectionLog() {
    _load();
  }

  final _storage = StorageService();
  final HostnameDetectionLog _hostnameLog;
  final Map<String, HostnameDiscovery> _hostnameWatchers = {};

  List<ConnectionFolder> folders = [];
  List<SavedConnection> connections = [];

  /// Split-view arrangements saved into folders, each with its connections.
  List<SavedLayout> layouts = [];
  final List<OpenTab> tabs = [];
  int activeTabIndex = -1;

  ThemeMode themeMode = ThemeMode.light;
  ReleaseChannel updateChannel = buildChannel;

  /// Saved once the user picks a theme in Settings. Until then the default
  /// above applies, so changing that default changes what a fresh install
  /// (or anyone who never chose) sees.
  static const _kThemeMode = 'commands.themeMode';
  static const _kUpdateChannel = 'commands.update.channel';
  static const _kLanguage = 'commands.language';
  static const _kFolderOrder = 'commands.folderOrder';
  static const _kConnectionOrder = 'commands.connectionOrder';
  static const _kSidebarWidth = 'commands.sidebarWidth';
  static const _kSidebarVisible = 'commands.sidebarVisible';
  static const _kTerminalBg = 'commands.terminalBg';
  static const _kTerminalFg = 'commands.terminalFg';
  static const _kTerminalFont = 'commands.terminalFont';
  static const _kTerminalFontSize = 'commands.terminalFontSize';
  static const defaultTerminalBackground = Color(0xFF14161A);
  static const defaultTerminalForeground = Color(0xFFE8E6E1);
  Color terminalBackground = defaultTerminalBackground;
  Color terminalForeground = defaultTerminalForeground;

  /// The terminal's 16 ANSI colours from a catalogue theme; null for the
  /// CommandS defaults.
  List<Color>? terminalAnsi;

  static const _kThemeId = 'commands.themeId';
  static const _kImportedThemes = 'commands.importedThemes';
  static const _kKeepTerminalColors = 'commands.keepTerminalColors';
  static const _kTerminalAnsi = 'commands.terminalAnsi';
  static const _kTerminalFromTheme = 'commands.terminalFromTheme';
  static const maxImportedThemes = 50;

  /// The theme an install that has never opened Settings > Theme starts on.
  static const defaultThemeId = 'builtin:commands';

  /// The catalogue or imported theme in use; null means the classic Light or
  /// Dark picked with [setThemeMode].
  String? themeId;
  List<ThemePreset> importedThemes = [];

  /// When on, choosing a theme leaves the SSH terminal's colours alone.
  bool keepTerminalColors = false;

  /// Whether the terminal's colours came from a theme rather than the user,
  /// so going back to classic Light or Dark can undo them without touching
  /// colours the user picked.
  bool _terminalFromTheme = false;

  List<ThemePreset> get allThemes => [...builtInThemes, ...importedThemes];

  ThemePreset? get activeTheme {
    final id = themeId;
    if (id == null) return null;
    for (final t in allThemes) {
      if (t.id == id) return t;
    }
    return null;
  }

  /// The SSH terminal's font family; null means the platform default
  /// (Consolas on Windows, Menlo on macOS).
  String? terminalFontFamily;
  static const double defaultTerminalFontSize = 13;
  double terminalFontSize = defaultTerminalFontSize;

  Future<void> _load() async {
    // Has to run before anything is read: on macOS this is where a 1.0.23
    // install's saved connections come from (see MacPrefsMigration).
    await MacPrefsMigration.run();
    folders = await _storage.loadFolders();
    connections = await _storage.loadConnections();
    layouts = await _storage.loadLayouts();
    final changed = _dedupeExisting();
    if (changed) {
      await _storage.saveFolders(folders);
    }
    // Also what moves passwords saved in plain text by an older version into
    // encrypted form, on the first start after updating.
    if (changed || _storage.needsPasswordMigration) {
      await _storage.saveConnections(connections);
    }
    final prefs = await SharedPreferences.getInstance();
    folderOrder = prefs.getStringList(_kFolderOrder) ?? [];
    connectionOrder = prefs.getStringList(_kConnectionOrder) ?? [];
    sidebarWidth = (prefs.getDouble(_kSidebarWidth) ?? defaultSidebarWidth).clamp(minSidebarWidth, maxSidebarWidth);
    sidebarVisible = prefs.getBool(_kSidebarVisible) ?? true;
    final bg = prefs.getInt(_kTerminalBg);
    final fg = prefs.getInt(_kTerminalFg);
    if (bg != null) terminalBackground = Color(bg);
    if (fg != null) terminalForeground = Color(fg);
    final ansi = prefs.getStringList(_kTerminalAnsi);
    if (ansi != null && ansi.length == 16) {
      final parsed = [for (final v in ansi) int.tryParse(v)];
      if (!parsed.contains(null)) terminalAnsi = [for (final v in parsed) Color(v!)];
    }
    _terminalFromTheme = prefs.getBool(_kTerminalFromTheme) ?? false;
    keepTerminalColors = prefs.getBool(_kKeepTerminalColors) ?? false;
    importedThemes = [
      for (final raw in prefs.getStringList(_kImportedThemes) ?? const <String>[]) ?_readTheme(raw),
    ];
    themeId = prefs.getString(_kThemeId);
    if (activeTheme == null) themeId = null;
    final font = prefs.getString(_kTerminalFont);
    if (font != null && font.trim().isNotEmpty) terminalFontFamily = font;
    terminalFontSize = prefs.getDouble(_kTerminalFontSize) ?? defaultTerminalFontSize;
    final language = AppLanguage.fromCode(prefs.getString(_kLanguage));
    if (language != currentLanguage) {
      currentLanguage = language;
      WidgetsBinding.instance.addPostFrameCallback((_) => rebuildAllWidgets());
    }
    switch (prefs.getString(_kThemeMode)) {
      case 'light':
        themeMode = ThemeMode.light;
      case 'dark':
        themeMode = ThemeMode.dark;
    }
    // Neither key was ever written, so Settings > Theme was never opened --
    // a fresh install, or an existing one that always ran on the implicit
    // Light default. Those start on the CommandS theme instead, chrome and
    // terminal both, exactly as choosing it would set them; a deleted or
    // unreadable catalogue leaves the classic default alone rather than
    // throwing.
    if (!prefs.containsKey(_kThemeMode) && !prefs.containsKey(_kThemeId)) {
      ThemePreset? commandS;
      for (final t in builtInThemes) {
        if (t.id == defaultThemeId) commandS = t;
      }
      if (commandS != null) {
        themeId = commandS.id;
        themeMode = commandS.dark ? ThemeMode.dark : ThemeMode.light;
        terminalBackground = commandS.terminalBackground;
        terminalForeground = commandS.terminalForeground;
        terminalAnsi = commandS.ansi;
        _terminalFromTheme = true;
      }
    }
    notifyListeners();
  }

  /// Sets the SSH terminal font. A null or blank [family] goes back to the
  /// platform default; [size] is clamped to what stays readable.
  Future<void> setTerminalFont({String? family, double? size, bool resetFamily = false}) async {
    if (resetFamily) {
      terminalFontFamily = null;
    } else if (family != null) {
      terminalFontFamily = family.trim().isEmpty ? null : family.trim();
    }
    if (size != null) terminalFontSize = size.clamp(8, 32).toDouble();
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    if (terminalFontFamily == null) {
      await prefs.remove(_kTerminalFont);
    } else {
      await prefs.setString(_kTerminalFont, terminalFontFamily!);
    }
    await prefs.setDouble(_kTerminalFontSize, terminalFontSize);
  }

  Future<void> setTerminalColors({Color? background, Color? foreground}) async {
    if (background != null) terminalBackground = background;
    if (foreground != null) terminalForeground = foreground;
    // Picked by hand: these are the user's colours now.
    _terminalFromTheme = false;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kTerminalBg, terminalBackground.toARGB32());
    await prefs.setInt(_kTerminalFg, terminalForeground.toARGB32());
    await prefs.setBool(_kTerminalFromTheme, false);
    notifyListeners();
  }

  static ThemePreset? _readTheme(String raw) {
    try {
      return ThemePreset.parse(raw);
    } on FormatException {
      return null;
    }
  }

  Future<void> _saveTerminalColors(SharedPreferences prefs) async {
    await prefs.setInt(_kTerminalBg, terminalBackground.toARGB32());
    await prefs.setInt(_kTerminalFg, terminalForeground.toARGB32());
    final ansi = terminalAnsi;
    if (ansi == null) {
      await prefs.remove(_kTerminalAnsi);
    } else {
      await prefs.setStringList(_kTerminalAnsi, [for (final c in ansi) '${c.toARGB32()}']);
    }
    await prefs.setBool(_kTerminalFromTheme, _terminalFromTheme);
  }

  /// Switches the app to a catalogue or imported theme. Its terminal colours
  /// come with it unless [keepTerminalColors] is on; either way they can be
  /// changed by hand afterwards.
  Future<void> selectTheme(String id) async {
    ThemePreset? theme;
    for (final t in allThemes) {
      if (t.id == id) theme = t;
    }
    if (theme == null) return;
    themeId = theme.id;
    themeMode = theme.dark ? ThemeMode.dark : ThemeMode.light;
    if (!keepTerminalColors) {
      terminalBackground = theme.terminalBackground;
      terminalForeground = theme.terminalForeground;
      terminalAnsi = theme.ansi;
      _terminalFromTheme = true;
    }
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kThemeId, theme.id);
    await prefs.setString(_kThemeMode, theme.dark ? 'dark' : 'light');
    if (!keepTerminalColors) await _saveTerminalColors(prefs);
  }

  Future<void> setKeepTerminalColors(bool keep) async {
    keepTerminalColors = keep;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kKeepTerminalColors, keep);
  }

  /// Adds a theme from the text of a theme file and returns it. One with the
  /// same name replaces the earlier import. Throws [FormatException] with a
  /// message for the user when the file is not a valid theme.
  Future<ThemePreset> importTheme(String source) async {
    final theme = ThemePreset.parse(source);
    final others = [for (final t in importedThemes) if (t.id != theme.id) t];
    if (others.length >= maxImportedThemes) {
      throw const FormatException('Too many imported themes; remove one first.');
    }
    importedThemes = [...others, theme];
    notifyListeners();
    await _saveImportedThemes();
    return theme;
  }

  Future<void> removeImportedTheme(String id) async {
    importedThemes = [for (final t in importedThemes) if (t.id != id) t];
    final wasActive = themeId == id;
    if (wasActive) themeId = null;
    notifyListeners();
    await _saveImportedThemes();
    if (wasActive) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_kThemeId);
    }
  }

  Future<void> _saveImportedThemes() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      _kImportedThemes,
      [for (final t in importedThemes) jsonEncode(t.toJson())],
    );
  }

  /// One-time repair for data written before RDM imports used stable ids:
  /// every re-import used to mint fresh random ids, so importing the same
  /// export twice quietly duplicated every folder and connection. Merges
  /// folders that share a name+parent and connections that share a
  /// host+port+protocol, keeping the first of each and re-pointing anything
  /// that referenced a dropped duplicate. Returns true if it changed anything.
  bool _dedupeExisting() {
    var changed = false;

    final folderIdRemap = <String, String>{};
    final keptFolders = <String, ConnectionFolder>{};
    final orderedFolderKeys = <String>[];
    for (final f in folders) {
      final key = '${f.parentId ?? ''} ${f.name.trim().toLowerCase()}';
      final existing = keptFolders[key];
      if (existing == null) {
        keptFolders[key] = f;
        orderedFolderKeys.add(key);
        folderIdRemap[f.id] = f.id;
      } else {
        folderIdRemap[f.id] = existing.id;
        changed = true;
      }
    }
    if (changed) {
      folders = [for (final k in orderedFolderKeys) keptFolders[k]!];
      for (final f in folders) {
        if (f.parentId != null && folderIdRemap.containsKey(f.parentId)) {
          f.parentId = folderIdRemap[f.parentId];
        }
      }
    }

    final keptConnections = <String, SavedConnection>{};
    final orderedConnKeys = <String>[];
    for (final c in connections) {
      if (folderIdRemap.containsKey(c.folderId)) {
        final remapped = folderIdRemap[c.folderId];
        if (remapped != c.folderId) {
          c.folderId = remapped;
          changed = true;
        }
      }
      final key =
          '${c.host.trim().toLowerCase()} ${c.port} ${c.protocol.name} ${c.username.trim().toLowerCase()}';
      final existing = keptConnections[key];
      if (existing == null) {
        keptConnections[key] = c;
        orderedConnKeys.add(key);
      } else {
        // Keep whichever copy actually has a remembered password.
        if (!existing.rememberPassword && c.rememberPassword) {
          keptConnections[key] = c;
        }
        changed = true;
      }
    }
    if (orderedConnKeys.length != connections.length) {
      connections = [for (final k in orderedConnKeys) keptConnections[k]!];
    }

    return changed;
  }

  /// Applies and remembers [mode]. The theme only used to live for the
  /// session, which was fine for a header toggle but not for something set
  /// on a Settings page.
  /// The language of the app's own text; sessions and their output are not
  /// touched. Every screen redraws in it at once, nothing is closed.
  AppLanguage get language => currentLanguage;

  Future<void> setLanguage(AppLanguage value) async {
    currentLanguage = value;
    notifyListeners();
    WidgetsBinding.instance.addPostFrameCallback((_) => rebuildAllWidgets());
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kLanguage, value.name);
  }

  /// The classic Light or Dark theme. Leaving a catalogue theme also takes
  /// back the terminal colours it brought, but never colours the user picked
  /// or asked to keep.
  Future<void> setThemeMode(ThemeMode mode) async {
    themeMode = mode;
    final leftTheme = themeId != null;
    themeId = null;
    final resetTerminal = leftTheme && _terminalFromTheme && !keepTerminalColors;
    if (resetTerminal) {
      terminalBackground = defaultTerminalBackground;
      terminalForeground = defaultTerminalForeground;
      terminalAnsi = null;
      _terminalFromTheme = false;
    }
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kThemeMode, mode == ThemeMode.light ? 'light' : 'dark');
    await prefs.remove(_kThemeId);
    if (resetTerminal) await _saveTerminalColors(prefs);
  }

  Future<void> setUpdateChannel(ReleaseChannel channel) async {
    updateChannel = channel;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kUpdateChannel, channel.name);
  }

  // ---- Folders ----

  Future<void> addFolder(String name, {String? parentId}) async {
    folders.add(ConnectionFolder(name: name, parentId: parentId));
    await _storage.saveFolders(folders);
    notifyListeners();
  }

  Future<void> renameFolder(String id, String newName) async {
    final f = folders.firstWhere((e) => e.id == id);
    f.name = newName;
    await _storage.saveFolders(folders);
    notifyListeners();
  }

  Future<void> deleteFolder(String id) async {
    folders.removeWhere((e) => e.id == id);
    // Children lose their folder, they are not deleted.
    for (final c in connections) {
      if (c.folderId == id) c.folderId = null;
    }
    for (final f in folders) {
      if (f.parentId == id) f.parentId = null;
    }
    for (final l in layouts) {
      if (l.folderId == id) l.folderId = null;
    }
    await _storage.saveFolders(folders);
    await _storage.saveConnections(connections);
    await _storage.saveLayouts(layouts);
    notifyListeners();
  }

  Future<void> moveConnectionToFolder(String connectionId, String? folderId) async {
    final c = connections.firstWhere((e) => e.id == connectionId);
    c.folderId = folderId;
    await _storage.saveConnections(connections);
    notifyListeners();
  }

  // ---- Connection order ----

  /// Connection ids in the order the user arranged them by dragging. Ones not
  /// in it (never dragged, or new) come after, by name.
  List<String> connectionOrder = [];

  /// Sorts [list] (connections sharing a folder) by [connectionOrder], then
  /// name.
  List<SavedConnection> sortConnections(List<SavedConnection> list) {
    final rank = {for (var i = 0; i < connectionOrder.length; i++) connectionOrder[i]: i};
    return list
      ..sort((a, b) {
        final ra = rank[a.id], rb = rank[b.id];
        if (ra != null && rb != null) return ra.compareTo(rb);
        if (ra != null) return -1;
        if (rb != null) return 1;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
  }

  /// Puts the connections [ids] in [folderId] (null: top level), in front of
  /// [before], or at the end when [before] is null.
  Future<void> placeConnections(List<String> ids, String? folderId, {String? before}) async {
    final picked = connections.where((c) => ids.contains(c.id)).toList();
    if (picked.isEmpty) return;
    final changedFolder = picked.any((c) => c.folderId != folderId);
    // Together, in the order they were showing in.
    final moved = sortConnections(picked).map((c) => c.id).toList();
    for (final c in picked) {
      c.folderId = folderId;
    }
    final siblings = sortConnections(connections.where((c) => c.folderId == folderId).toList())
        .map((c) => c.id)
        .where((id) => !moved.contains(id))
        .toList();
    final at = before == null ? siblings.length : siblings.indexOf(before);
    siblings.insertAll(at < 0 ? siblings.length : at, moved);
    // The whole level is written out, so its order no longer depends on names.
    connectionOrder = [...connectionOrder.where((id) => !siblings.contains(id)), ...siblings];
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_kConnectionOrder, connectionOrder);
    if (changedFolder) await _storage.saveConnections(connections);
  }

  // ---- Folder order and sidebar width ----

  /// Folder ids in the order the user arranged them by dragging. Folders not
  /// in it (never dragged, or new) come after, by name.
  List<String> folderOrder = [];

  /// Sorts [list] (folders sharing a parent) by [folderOrder], then name.
  List<ConnectionFolder> sortFolders(List<ConnectionFolder> list) {
    final rank = {for (var i = 0; i < folderOrder.length; i++) folderOrder[i]: i};
    return list
      ..sort((a, b) {
        final ra = rank[a.id], rb = rank[b.id];
        if (ra != null && rb != null) return ra.compareTo(rb);
        if (ra != null) return -1;
        if (rb != null) return 1;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
  }

  /// Puts the folders [ids] under [parentId] (null: top level), in front of
  /// [before], or at the end when [before] is null. A folder is never put
  /// inside itself.
  Future<void> placeFolders(List<String> ids, String? parentId, {String? before}) async {
    for (final id in ids) {
      await moveFolderToFolder(id, parentId);
    }
    final moved = ids.where((id) => folders.any((f) => f.id == id && f.parentId == parentId)).toList();
    if (moved.isEmpty) return;
    final siblings = sortFolders(folders.where((f) => f.parentId == parentId).toList())
        .map((f) => f.id)
        .where((id) => !moved.contains(id))
        .toList();
    final at = before == null ? siblings.length : siblings.indexOf(before);
    siblings.insertAll(at < 0 ? siblings.length : at, moved);
    // The whole level is written out, so its order no longer depends on names.
    folderOrder = [...folderOrder.where((id) => !siblings.contains(id)), ...siblings];
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_kFolderOrder, folderOrder);
  }

  static const double defaultSidebarWidth = 260;
  static const double minSidebarWidth = 200;
  static const double maxSidebarWidth = 640;

  /// The connections panel's width, dragged at its right edge.
  double sidebarWidth = defaultSidebarWidth;

  void setSidebarWidth(double width, {bool save = false}) {
    sidebarWidth = width.clamp(minSidebarWidth, maxSidebarWidth);
    notifyListeners();
    if (save) {
      SharedPreferences.getInstance().then((p) => p.setDouble(_kSidebarWidth, sidebarWidth));
    }
  }

  /// Whether the connections panel is shown. Kept across restarts.
  bool sidebarVisible = true;

  void setSidebarVisible(bool visible) {
    if (sidebarVisible == visible) return;
    sidebarVisible = visible;
    notifyListeners();
    SharedPreferences.getInstance().then((p) => p.setBool(_kSidebarVisible, visible));
  }

  Future<void> moveFolderToFolder(String folderId, String? parentId) async {
    if (folderId == parentId) return;
    // Never let a folder become its own descendant.
    var cursor = parentId;
    while (cursor != null) {
      if (cursor == folderId) return;
      cursor = folders
          .firstWhere(
            (f) => f.id == cursor,
            orElse: () => ConnectionFolder(id: '', name: '', parentId: null),
          )
          .parentId;
    }
    final f = folders.firstWhere((e) => e.id == folderId);
    f.parentId = parentId;
    await _storage.saveFolders(folders);
    notifyListeners();
  }

  // ---- Connections ----

  Future<void> upsertConnection(SavedConnection conn) async {
    final old = connections.where((e) => e.id == conn.id).firstOrNull;
    if (old != null && (old.host != conn.host || !conn.autoNamePending)) {
      _hostnameWatchers.remove(conn.id)?.dispose();
    }
    connections.removeWhere((e) => e.id == conn.id);
    connections.add(conn);
    await _storage.saveConnections(connections);
    notifyListeners();
  }

  Future<void> deleteConnection(String id) async {
    _hostnameWatchers.remove(id)?.dispose();
    connections.removeWhere((e) => e.id == id);
    await _storage.saveConnections(connections);
    notifyListeners();
  }

  Future<void> renameConnection(String id, String newName) async {
    final c = connections.firstWhere((e) => e.id == id);
    _hostnameWatchers.remove(id)?.dispose();
    c.name = newName;
    c.autoNamePending = false;
    await _storage.saveConnections(connections);
    notifyListeners();
  }

  Future<void> cloneConnection(String id) async {
    final source = connections.firstWhere((e) => e.id == id);
    final copy = SavedConnection(
      name: '${source.name}_clone',
      host: source.host,
      port: source.port,
      username: source.username,
      rememberPassword: source.rememberPassword,
      password: source.password,
      folderId: source.folderId,
      protocol: source.protocol,
      domain: source.domain,
      rdpClipboard: source.rdpClipboard,
      rdpWallpaper: source.rdpWallpaper,
      device: source.device,
      deviceManual: source.deviceManual,
    );
    connections.add(copy);
    await _storage.saveConnections(connections);
    notifyListeners();
  }

  // ---- Import / Export ----

  /// [connectionIds] restricts the export to a chosen subset (from the
  /// selection dialog); folders are included whenever they contain at least
  /// one exported connection or a kept sub-folder. Null exports everything.
  ({List<ConnectionFolder> folders, List<SavedConnection> connections}) _selectSubset(
    Set<String>? connectionIds,
  ) {
    if (connectionIds == null) return (folders: folders, connections: connections);
    final selectedConnections = connections.where((c) => connectionIds.contains(c.id)).toList();
    final neededFolderIds = <String>{};
    void includeChain(String? folderId) {
      if (folderId == null || !neededFolderIds.add(folderId)) return;
      String? parentId;
      for (final f in folders) {
        if (f.id == folderId) {
          parentId = f.parentId;
          break;
        }
      }
      includeChain(parentId);
    }

    for (final c in selectedConnections) {
      includeChain(c.folderId);
    }
    final selectedFolders = folders.where((f) => neededFolderIds.contains(f.id)).toList();
    return (folders: selectedFolders, connections: selectedConnections);
  }

  String exportAll({Set<String>? connectionIds}) {
    final subset = _selectSubset(connectionIds);
    final exported = {for (final c in subset.connections) c.id};
    final folderIds = {for (final f in subset.folders) f.id};
    // A layout goes along when every connection it opens is exported; one
    // whose folder is not part of the export lands at the top level.
    final outLayouts = [
      for (final l in layouts)
        if (l.connectionIds.any((id) => id != null) &&
            l.connectionIds.every((id) => id == null || exported.contains(id)))
          SavedLayout(
            id: l.id,
            name: l.name,
            preset: l.preset,
            connectionIds: l.connectionIds,
            folderId: folderIds.contains(l.folderId) ? l.folderId : null,
          ),
    ];
    return _storage.exportJson(folders: subset.folders, connections: subset.connections, layouts: outLayouts);
  }

  String exportAllXml({Set<String>? connectionIds}) {
    final subset = _selectSubset(connectionIds);
    return _storage.exportXml(folders: subset.folders, connections: subset.connections);
  }

  String exportAllCsv({Set<String>? connectionIds}) {
    final subset = _selectSubset(connectionIds);
    return _storage.exportCsv(folders: subset.folders, connections: subset.connections);
  }

  /// Upserts a parsed folder/connection set by id — used for CommandS's own
  /// JSON/XML import once the user has picked which of the parsed entries to
  /// keep. Ids round-trip through our own export, so re-importing the same
  /// file updates in place instead of duplicating.
  Future<void> importParsed(
    List<ConnectionFolder> parsedFolders,
    List<SavedConnection> parsedConnections, {
    List<SavedLayout> parsedLayouts = const [],
  }) async {
    for (final f in parsedFolders) {
      final i = folders.indexWhere((e) => e.id == f.id);
      if (i == -1) {
        folders.add(f);
      } else {
        folders[i].name = f.name;
        folders[i].parentId = f.parentId;
      }
    }
    for (final c in parsedConnections) {
      final i = connections.indexWhere((e) => e.id == c.id);
      if (i == -1) {
        connections.add(c);
      } else {
        connections[i] = c;
      }
    }
    // Layouts, keeping only panes whose connection now exists here; one left
    // with nothing to open is not worth importing.
    final known = {for (final c in connections) c.id};
    for (final l in parsedLayouts) {
      l.connectionIds = [for (final id in l.connectionIds) known.contains(id) ? id : null];
      if (l.connectionIds.every((id) => id == null)) continue;
      if (l.folderId != null && !folders.any((f) => f.id == l.folderId)) l.folderId = null;
      layouts.removeWhere((e) => e.id == l.id);
      layouts.add(l);
    }
    await _storage.saveFolders(folders);
    await _storage.saveConnections(connections);
    await _storage.saveLayouts(layouts);
    notifyListeners();
  }

  /// Ids in [result] come from the RDM export itself (see rdm_import.dart),
  /// so re-importing the same file updates matching entries in place instead
  /// of duplicating them. A locally-remembered password survives a re-import
  /// even though RDM never supplies one.
  Future<void> importRdm(RdmImportResult result) async {
    for (final f in result.folders) {
      final i = folders.indexWhere((e) => e.id == f.id);
      if (i == -1) {
        folders.add(f);
      } else {
        folders[i].name = f.name;
        folders[i].parentId = f.parentId;
      }
    }
    for (final c in result.connections) {
      final i = connections.indexWhere((e) => e.id == c.id);
      if (i == -1) {
        connections.add(c);
      } else {
        final existing = connections[i];
        c.password = existing.password;
        c.rememberPassword = existing.rememberPassword;
        connections[i] = c;
      }
    }
    await _storage.saveFolders(folders);
    await _storage.saveConnections(connections);
    notifyListeners();
  }

  // ---- Tabs / sessions ----

  /// What the terminal area currently tiles — a single pane by default;
  /// dragging a tab chip onto another pane's edge splits it. Null means "just
  /// show the active tab", the common case, without a tree to walk.
  PaneNode? paneLayout;

  /// Always opens a tab (SSH and RDP alike) — returns null once the tab is
  /// up; only used to report a same-tick failure (e.g. an unsafe host).
  Future<String?> openConnection(SavedConnection conn) async {
    final tab = _openTab(conn);
    activeTabIndex = tabs.length - 1;
    // A freshly opened connection takes over the view; Split view in the
    // tab bar puts it back alongside others.
    paneLayout = PaneLeaf(tab.id);
    activeGroupId = null;
    notifyListeners();
    return null;
  }

  int _tabSerial = 0;

  /// Creates a tab for [conn] without changing what is on screen.
  OpenTab _openTab(SavedConnection conn) {
    final SessionController controller = conn.protocol == ConnectionProtocol.rdp
        // The embedding controller talks to a win32-only method channel
        // (windows/runner/rdp_plugin.cpp); anywhere else that channel does not
        // exist, which is what opening an RDP connection on macOS used to
        // fail on.
        ? (Platform.isWindows ? RdpSessionController(conn) : MacRdpSessionController(conn))
        : PtySessionController(
            host: conn.host,
            port: conn.port,
            username: conn.username,
            password: conn.rememberPassword ? conn.password : '',
            tabTitle: conn.name,
            recordByDefault: conn.recordSessionByDefault,
          );
    final tab = OpenTab(
      // Unique even when a layout opens several tabs within one microsecond.
      id: '${conn.id}-${DateTime.now().microsecondsSinceEpoch}-${_tabSerial++}',
      controller: controller,
      connectionId: conn.id,
    );
    if (controller is PtySessionController) {
      controller.onDeviceDetected = (kind) => _deviceDetected(conn.id, kind);
      if (conn.autoNamePending && !_hostnameWatchers.containsKey(conn.id)) {
        _hostnameWatchers[conn.id] = HostnameDiscovery(
          output: controller.outputStream,
          status: controller.statusStream,
          onResult: (result) {
            _hostnameWatchers.remove(conn.id);
            _hostnameResult(conn.id, conn.host, controller, result);
          },
        );
      }
    }
    tabs.add(tab);
    controller.statusStream.listen((_) => notifyListeners());
    return tab;
  }

  /// A session worked out what it is connected to: kept for the
  /// connection's logo, unless one was picked by hand.
  Future<void> _deviceDetected(String connectionId, DeviceKind kind) async {
    final i = connections.indexWhere((c) => c.id == connectionId);
    if (i < 0) return;
    final c = connections[i];
    if (c.deviceManual || c.device == kind) return;
    c.device = kind;
    await _storage.saveConnections(connections);
    notifyListeners();
  }

  Future<void> _hostnameResult(
    String connectionId,
    String openedHost,
    PtySessionController controller,
    HostnameDiscoveryResult result,
  ) async {
    final i = connections.indexWhere((c) => c.id == connectionId);
    if (i < 0) return;
    final c = connections[i];
    if (!c.autoNamePending || c.host != openedHost || c.protocol != ConnectionProtocol.ssh) return;
    c.autoNamePending = false;
    if (result.hostname != null) {
      c.name = result.hostname!;
      controller.tabTitle = c.name;
    } else {
      try {
        await _hostnameLog.record(
          connectionId: connectionId,
          reason: result.reason,
          outputChars: result.outputChars,
          device: c.device?.name,
        );
      } catch (error) {
        debugPrint('Could not write hostname diagnostics: $error');
      }
    }
    await _storage.saveConnections(connections);
    notifyListeners();
  }

  // ---- Saved layouts ----

  /// Saves the arrangement in [tabIds] (one per pane, reading order) as a
  /// layout in [folderId]. Panes holding a quick connection cannot be
  /// reopened later, so they are saved empty.
  Future<SavedLayout> saveLayout({
    required String name,
    required String? folderId,
    required SplitPreset preset,
    required List<String?> tabIds,
  }) async {
    final byTab = {for (final t in tabs) t.id: t.connectionId};
    final layout = SavedLayout(
      name: name,
      folderId: folderId,
      preset: preset.name,
      connectionIds: [for (final id in tabIds) id == null ? null : byTab[id]],
    );
    layouts.add(layout);
    await _storage.saveLayouts(layouts);
    notifyListeners();
    return layout;
  }

  /// Opens [layout]: each of its connections in a tab -- reusing a tab that
  /// is already open for that connection rather than opening a second
  /// session -- arranged as saved. Connections deleted since it was saved
  /// leave their pane out. Returns how many panes were filled.
  int openLayout(SavedLayout layout) {
    final preset =
        SplitPreset.values.where((p) => p.name == layout.preset).firstOrNull ?? SplitPreset.sideBySide;
    final used = <String>{};
    final slots = <String?>[];
    for (var i = 0; i < preset.slots; i++) {
      final connId = i < layout.connectionIds.length ? layout.connectionIds[i] : null;
      final conn = connId == null ? null : connections.where((c) => c.id == connId).firstOrNull;
      if (conn == null) {
        slots.add(null);
        continue;
      }
      final existing = tabs.where((t) => t.connectionId == conn.id && !used.contains(t.id)).firstOrNull;
      final tab = existing ?? _openTab(conn);
      used.add(tab.id);
      slots.add(tab.id);
    }
    final tree = buildLayout(preset, slots);
    if (tree == null) {
      notifyListeners();
      return 0;
    }
    applyLayout(tree, name: layout.name);
    return slots.whereType<String>().length;
  }

  Future<void> renameLayout(String id, String name) async {
    layouts.firstWhere((l) => l.id == id).name = name;
    await _storage.saveLayouts(layouts);
    notifyListeners();
  }

  Future<void> moveLayoutToFolder(String id, String? folderId) async {
    layouts.firstWhere((l) => l.id == id).folderId = folderId;
    await _storage.saveLayouts(layouts);
    notifyListeners();
  }

  Future<void> deleteLayout(String id) async {
    layouts.removeWhere((l) => l.id == id);
    await _storage.saveLayouts(layouts);
    notifyListeners();
  }

  /// Quick-connect for RDP: a one-off session with nothing saved. No
  /// credentials are passed, so the Remote Desktop client asks for them
  /// itself, the same way the SSH quick-connect falls back to a `login as:`
  /// prompt.
  void openQuickRdp({required String host, required int port}) {
    openConnection(SavedConnection(name: host, host: host, port: port, protocol: ConnectionProtocol.rdp));
  }

  /// What a tab opened from quick connect was connected to, as an unsaved
  /// connection (host, port and protocol filled in) for its "Save
  /// connection" entry. Null for a tab that already is a saved connection.
  SavedConnection? unsavedConnectionOf(OpenTab tab) {
    final id = tab.connectionId;
    if (id != null && connections.any((c) => c.id == id)) return null;
    final c = tab.controller;
    if (c is PtySessionController) return SavedConnection(name: c.host, host: c.host, port: c.port);
    final SavedConnection? rdp = c is RdpSessionController
        ? c.conn
        : c is MacRdpSessionController
        ? c.conn
        : null;
    if (rdp == null) return null;
    return SavedConnection(name: rdp.host, host: rdp.host, port: rdp.port, protocol: ConnectionProtocol.rdp);
  }

  /// After a quick connection was saved from its tab: the tab now counts as
  /// that connection (its dot in the tree, saved layouts) and takes its name.
  void linkTabToConnection(String tabId, SavedConnection conn) {
    for (final t in tabs) {
      if (t.id != tabId) continue;
      t.connectionId = conn.id;
      final c = t.controller;
      if (c is PtySessionController) c.tabTitle = conn.name;
      if (c is RdpSessionController) c.tabTitle = conn.name;
      if (c is MacRdpSessionController) c.tabTitle = conn.name;
    }
    notifyListeners();
  }

  /// Opens a serial console (quick connect, Serial): [port] is COM3 on
  /// Windows, a /dev path on macOS.
  void openSerial({required String port, int baud = SerialSessionController.defaultBaud}) {
    final controller = SerialSessionController(port: port, baud: baud);
    final tab = OpenTab(id: 'serial-${DateTime.now().microsecondsSinceEpoch}-${_tabSerial++}', controller: controller);
    tabs.add(tab);
    activeTabIndex = tabs.length - 1;
    paneLayout = PaneLeaf(tab.id);
    activeGroupId = null;
    notifyListeners();
    controller.statusStream.listen((_) => notifyListeners());
  }

  void openBlankHostOnly({required String host, required int port}) {
    final controller = PtySessionController(host: host, port: port);
    final tab = OpenTab(
      id: 'blank-${DateTime.now().microsecondsSinceEpoch}-${_tabSerial++}',
      controller: controller,
    );
    tabs.add(tab);
    activeTabIndex = tabs.length - 1;
    paneLayout = PaneLeaf(tab.id);
    activeGroupId = null;
    notifyListeners();
    controller.statusStream.listen((_) => notifyListeners());
  }

  // ---- Split groups ----

  final List<TabGroup> groups = [];

  /// The group on screen, if the tab area is showing one.
  String? activeGroupId;
  int _groupSerial = 0;

  TabGroup? groupOf(String tabId) => groups.where((g) => g.tabIds.contains(tabId)).firstOrNull;

  TabGroup? get activeGroup => groups.where((g) => g.id == activeGroupId).firstOrNull;

  /// Shows [group]'s split again, as it was left.
  void activateGroup(String id) {
    final g = groups.where((g) => g.id == id).firstOrNull;
    if (g == null) return;
    activeGroupId = g.id;
    paneLayout = g.layout;
    final index = tabs.indexWhere((t) => t.id == g.tabIds.first);
    if (index != -1) activeTabIndex = index;
    notifyListeners();
  }

  // ---- Dragging tabs ----

  /// The plain tab being dragged, or null. Offers the drop targets in the
  /// tab area. A split's tab can be reordered but not split further, so it
  /// does not set this.
  String? draggingTabId;

  /// A tab's drag began or ended. Embedded RDP sessions step aside meanwhile:
  /// each is a native window over its pane, which would hide the drop targets
  /// and keep the drag from reaching Flutter.
  void setTabDrag({required bool active, String? tabId}) {
    RdpTabDrag.set(active);
    final next = active ? tabId : null;
    if (draggingTabId == next) return;
    draggingTabId = next;
    notifyListeners();
  }

  /// Moves the tabs [ids] together, keeping their order, in front of
  /// [beforeTabId], or to the end when it is null.
  void moveTabs(List<String> ids, String? beforeTabId) {
    final activeId = activeTabIndex >= 0 && activeTabIndex < tabs.length ? tabs[activeTabIndex].id : null;
    final moved = tabs.where((t) => ids.contains(t.id)).toList();
    if (moved.isEmpty) return;
    tabs.removeWhere((t) => ids.contains(t.id));
    final at = beforeTabId == null ? tabs.length : tabs.indexWhere((t) => t.id == beforeTabId);
    tabs.insertAll(at < 0 ? tabs.length : at, moved);
    if (activeId != null) activeTabIndex = tabs.indexWhere((t) => t.id == activeId);
    notifyListeners();
  }

  /// Whether the tab [tabId] can be dropped next to the pane showing
  /// [targetTabId]. Limited to what the Split view dialog can show.
  ///
  /// The tab on screen can be dropped on its own pane too: it moves to that
  /// side, and the next plain tab takes the other half. One already in the
  /// split moves to its new place.
  bool canDropTabBeside(String tabId, String targetTabId) {
    final onScreen = tabIdsInLayout(paneLayout);
    if (!onScreen.contains(targetTabId)) return false;
    if (tabId == targetTabId) return onScreen.length == 1 && _partnerFor(tabId) != null;
    final after = onScreen.contains(tabId) ? onScreen.length : onScreen.length + 1;
    return after <= maxSplitPanes;
  }

  /// Splits the pane showing [targetTabId], putting [tabId] on [side] of it.
  void dropTabBeside(String tabId, String targetTabId, PaneSide side) {
    if (!canDropTabBeside(tabId, targetTabId)) return;
    var target = targetTabId;
    PaneNode base;
    if (tabId == targetTabId) {
      target = _partnerFor(tabId)!;
      base = PaneLeaf(target);
    } else {
      base = removeFromLayout(paneLayout, tabId)!;
    }
    applyLayout(insertBeside(base, target, tabId, side), editActive: activeGroupId != null);
  }

  /// The plain tab next to [tabId] (after it, else before), to share the
  /// screen with it.
  String? _partnerFor(String tabId) {
    final i = tabs.indexWhere((t) => t.id == tabId);
    final plain = [
      ...tabs.skip(i + 1),
      ...tabs.take(i < 0 ? 0 : i).toList().reversed,
    ].where((t) => groupOf(t.id) == null);
    return plain.firstOrNull?.id;
  }

  /// Takes one session out of its split, back to a tab of its own. The rest of
  /// the split stays on screen; a split left with one session is no longer one.
  void takeOutOfSplit(String tabId) {
    final g = groupOf(tabId);
    if (g == null) return;
    final wasActive = activeGroupId == g.id;
    final rest = g.tabIds.where((id) => id != tabId).toList();
    _takeFromGroups([tabId]);
    if (wasActive) {
      if (groups.contains(g)) {
        activeGroupId = g.id;
        paneLayout = g.layout;
      } else {
        activeGroupId = null;
        paneLayout = rest.isEmpty ? null : PaneLeaf(rest.first);
      }
    }
    notifyListeners();
  }

  /// Arranges the tab area as [preset] with [tabId] in [slot]. The other panes
  /// take what is on screen, then the other plain tabs; tabs that do not fit
  /// stay open behind their own chips.
  void dropTabInPreset(String tabId, SplitPreset preset, int slot) {
    final others = [
      ...tabIdsInLayoutOrdered(paneLayout),
      ...tabs.where((t) => groupOf(t.id) == null).map((t) => t.id),
    ].where((id) => id != tabId).toSet().toList();
    final slots = List<String?>.filled(preset.slots, null);
    slots[slot] = tabId;
    var next = 0;
    for (var i = 0; i < slots.length && next < others.length; i++) {
      if (slots[i] == null) slots[i] = others[next++];
    }
    applyLayout(buildLayout(preset, slots), editActive: activeGroupId != null);
  }

  /// Takes [tabIds] out of every group but [except]; a group left with a
  /// single session is no longer a split and goes back to being a plain tab.
  void _takeFromGroups(Iterable<String> tabIds, {TabGroup? except}) {
    for (final g in [...groups]) {
      if (identical(g, except)) continue;
      PaneNode? rest = g.layout;
      for (final id in tabIds) {
        rest = removeFromLayout(rest, id);
      }
      if (identical(rest, g.layout)) continue;
      if (rest == null || tabIdsInLayout(rest).length < 2) {
        groups.remove(g);
        if (activeGroupId == g.id) activeGroupId = null;
      } else {
        g.layout = rest;
      }
    }
  }

  /// Splits the group back into plain tabs; the sessions stay open.
  void ungroup(String id) {
    final g = groups.where((g) => g.id == id).firstOrNull;
    if (g == null) return;
    groups.remove(g);
    if (activeGroupId == id) {
      activeGroupId = null;
      paneLayout = PaneLeaf(g.tabIds.first);
    }
    notifyListeners();
  }

  /// Closes every session in the group.
  void closeGroup(String id) {
    final g = groups.where((g) => g.id == id).firstOrNull;
    if (g == null) return;
    for (final tabId in g.tabIds) {
      final index = tabs.indexWhere((t) => t.id == tabId);
      if (index != -1) closeTab(index);
    }
  }

  void closeTab(int index) {
    final tab = tabs.removeAt(index);
    tab.controller.dispose();
    final group = groupOf(tab.id);
    if (group != null) {
      final wasActive = activeGroupId == group.id;
      _takeFromGroups([tab.id]);
      if (wasActive) {
        final still = groups.contains(group);
        // Two left and one closed: the survivor is shown on its own.
        paneLayout = still ? group.layout : removeFromLayout(paneLayout, tab.id);
        if (still) activeGroupId = group.id;
      }
    } else {
      paneLayout = removeFromLayout(paneLayout, tab.id);
    }
    if (activeTabIndex >= tabs.length) activeTabIndex = tabs.length - 1;
    if (paneLayout == null && tabs.isNotEmpty) {
      final next = tabs[activeTabIndex];
      final g = groupOf(next.id);
      if (g != null) {
        activeGroupId = g.id;
        paneLayout = g.layout;
      } else {
        activeGroupId = null;
        paneLayout = PaneLeaf(next.id);
      }
    }
    notifyListeners();
  }

  void setActiveTab(int index) {
    activeTabIndex = index;
    // A tab in a split brings its split back; any other tab is shown on its
    // own, leaving the split to return to from its own tab.
    final g = groupOf(tabs[index].id);
    if (g != null) {
      activeGroupId = g.id;
      paneLayout = g.layout;
    } else {
      activeGroupId = null;
      paneLayout = PaneLeaf(tabs[index].id);
    }
    notifyListeners();
  }

  /// Shows [layout], as arranged in the Split view dialog or opened from a
  /// saved layout. More than one session makes it a group, shown as one
  /// tab: [editActive] (Split view) reworks the group on screen, otherwise
  /// a group of exactly these sessions is reused or a new one made. Null
  /// (nothing placed) leaves things alone.
  void applyLayout(PaneNode? layout, {String? name, bool editActive = false}) {
    if (layout == null) return;
    final ids = tabIdsInLayoutOrdered(layout);
    final index = tabs.indexWhere((t) => t.id == ids.first);
    if (index != -1) activeTabIndex = index;
    if (ids.length < 2) {
      // Back to one pane: the session is a plain tab again.
      final editing = editActive ? activeGroup : null;
      if (editing != null) groups.remove(editing);
      _takeFromGroups(ids);
      activeGroupId = null;
      paneLayout = layout;
      notifyListeners();
      return;
    }
    var group = editActive ? activeGroup : null;
    group ??= groups
        .where((g) => g.tabIds.toSet().containsAll(ids) && g.tabIds.length == ids.length)
        .firstOrNull;
    if (group == null) {
      group = TabGroup(id: 'group-${_groupSerial++}', layout: layout, name: name);
      groups.add(group);
    } else {
      group.layout = layout;
      if (name != null) group.name = name;
    }
    _takeFromGroups(ids, except: group);
    activeGroupId = group.id;
    paneLayout = layout;
    notifyListeners();
  }
}
