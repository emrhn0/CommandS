import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../models/models.dart';
import '../providers/app_state.dart';
import '../screens/settings_screen.dart';
import '../services/app_commands.dart';
import '../services/session_controller.dart';
import '../theme/app_mark.dart';
import '../theme/app_theme.dart';
import '../theme/wordmark.dart';
import 'import_export_dialog.dart';
import 'new_connection_dialog.dart';
import 'quick_search.dart';

/// What the session area shows while no tab is open: the mark and a
/// greeting, the two ways to add a connection, and the saved connections
/// opened most recently, each one click away.
class WelcomePanel extends StatefulWidget {
  const WelcomePanel({super.key, this.sidebarVisible = true, this.now});

  final bool sidebarVisible;

  /// The time the greeting is picked for; tests pass one in.
  final DateTime? now;

  /// Picked once a launch, so the lighter lines come in a different order.
  static final int launchSeed = Random().nextInt(1 << 16);

  /// The lines for the part of the day [time] falls in: morning from five,
  /// afternoon from noon, evening from six, night from eleven. The first of
  /// each is the plain greeting.
  static List<String> greetingsFor(DateTime time) {
    final h = time.hour;
    if (h >= 5 && h < 12) {
      return [
        tr('Good morning'),
        tr('Good morning. Coffee ready? Let us start'),
        tr('Good morning. Which device today?'),
        tr('Early at the console'),
        tr('Good morning. The logs are waiting'),
        tr('A new day, a clean session'),
      ];
    }
    if (h >= 12 && h < 18) {
      return [
        tr('Good afternoon'),
        tr('The afternoon shift is on'),
        tr('Pick up where you left off'),
        tr('One more connection, then tea'),
        tr('Everything looks fine'),
        tr('Hope it goes easy'),
      ];
    }
    if (h >= 18 && h < 23) {
      return [
        tr('Good evening'),
        tr('Good evening. One last check?'),
        tr('Work is over, but the switches never sleep'),
        tr('A session in the quiet of the evening'),
        tr('Evening already, and the screen is still on'),
      ];
    }
    return [
      tr('Good night'),
      tr('It is late. A change window?'),
      tr('Night shift, quiet and calm'),
      tr('Maintenance work at this hour, probably'),
      tr('Midnight, and it is just you on screen'),
    ];
  }

  /// How long one line stays before the next fades in.
  static const rotateEvery = Duration(seconds: 30);

  /// Off under `flutter test`: the pulsing dot would keep tests from settling.
  static bool animate = !Platform.environment.containsKey('FLUTTER_TEST');

  /// Which line of [greetingsFor] the panel shows, for this run of the app.
  static final picker = GreetingPicker(seed: launchSeed);

  @override
  State<WelcomePanel> createState() => _WelcomePanelState();
}

/// Picks the greeting: the plain one ("Good morning") the first time in each
/// part of the day, then the lighter lines in turn, a new one each time the
/// panel comes back and every [WelcomePanel.rotateEvery] it stays up.
class GreetingPicker {
  GreetingPicker({this.seed = 0});

  final int seed;
  String? _greetedPart;
  int _turn = 0;

  /// The part of the day [time] falls in, with the night that runs past
  /// midnight counted with the evening before it.
  static String partOf(DateTime time) {
    final h = time.hour;
    final part = h >= 5 && h < 12
        ? 'morning'
        : h >= 12 && h < 18
            ? 'afternoon'
            : h >= 18 && h < 23
                ? 'evening'
                : 'night';
    final day = time.subtract(const Duration(hours: 5));
    return '${day.year}-${day.month}-${day.day}-$part';
  }

  /// The index in [WelcomePanel.greetingsFor] to show next at [time].
  int next(DateTime time) {
    final part = partOf(time);
    if (part != _greetedPart) {
      _greetedPart = part;
      return 0;
    }
    _turn++;
    final others = WelcomePanel.greetingsFor(time).length - 1;
    return 1 + (seed + _turn) % others;
  }
}

class _WelcomePanelState extends State<WelcomePanel> {
  Timer? _rotate;
  late int _line;

  /// The search box: while it has text, the recent list turns into what
  /// quick search finds, folders with what is inside them.
  final _search = TextEditingController();
  final _searchFocus = FocusNode();
  int _selected = 0;

  DateTime get _now => widget.now ?? DateTime.now();

  bool get sidebarVisible => widget.sidebarVisible;

  @override
  void initState() {
    super.initState();
    _line = WelcomePanel.picker.next(_now);
    _rotate = Timer.periodic(WelcomePanel.rotateEvery, (_) {
      if (mounted) setState(() => _line = WelcomePanel.picker.next(_now));
    });
  }

  @override
  void dispose() {
    _rotate?.cancel();
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _go(QuickSearchResult r) {
    final app = context.read<AppState>();
    final conn = r.connection;
    if (conn != null) {
      app.openConnection(conn);
    } else {
      app.reveal(r.folder!.id);
    }
  }

  /// Arrows move through the results, Esc empties the box.
  KeyEventResult _onSearchKey(KeyEvent event, int count) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.arrowDown && count > 0) {
      setState(() => _selected = (_selected + 1).clamp(0, count - 1));
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowUp && count > 0) {
      setState(() => _selected = (_selected - 1).clamp(0, count - 1));
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape && _search.text.isNotEmpty) {
      setState(() {
        _search.clear();
        _selected = 0;
      });
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Widget _searchBox(AppPalette palette, int count, List<QuickSearchResult> results) {
    final searching = _search.text.trim().isNotEmpty;
    return Focus(
      onKeyEvent: (_, event) => _onSearchKey(event, count),
      child: SizedBox(
        height: 38,
        child: TextField(
          key: const Key('welcome-search'),
          controller: _search,
          focusNode: _searchFocus,
          style: TextStyle(fontSize: 13.5, color: palette.text),
          decoration: InputDecoration(
            hintText: tr('Search connections, folders or addresses'),
            hintStyle: TextStyle(fontSize: 13.5, color: palette.textDim),
            prefixIcon: Icon(Icons.search, size: 17, color: palette.textDim),
            suffixIcon: searching
                ? IconButton(
                    key: const Key('welcome-search-clear'),
                    tooltip: tr('Clear'),
                    icon: const Icon(Icons.close, size: 15),
                    onPressed: () => setState(() {
                      _search.clear();
                      _selected = 0;
                    }),
                  )
                : null,
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(vertical: 10),
          ),
          onChanged: (_) => setState(() => _selected = 0),
          onSubmitted: (_) {
            if (results.isNotEmpty) _go(results[_selected.clamp(0, results.length - 1)]);
            _searchFocus.requestFocus();
          },
        ),
      ),
    );
  }

  Widget _results(AppPalette palette, Color accent, List<QuickSearchResult> results) {
    return Container(
      key: const Key('welcome-search-results'),
      padding: const EdgeInsets.fromLTRB(8, 12, 8, 8),
      decoration: BoxDecoration(
        color: palette.panel,
        border: Border.all(color: palette.border),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 6, bottom: 6),
            child: Text(
              tr('Results · {n}', {'n': results.length}).toUpperCase(),
              style: TextStyle(fontSize: 11, letterSpacing: 0.8, color: palette.textDim, fontWeight: FontWeight.w500),
            ),
          ),
          if (results.isEmpty)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(
                tr('Nothing found for "{query}".', {'query': _search.text.trim()}),
                style: TextStyle(fontSize: 12.5, color: palette.textDim),
              ),
            )
          else
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 40.0 * 10),
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: results.length,
                itemExtent: 40,
                itemBuilder: (context, i) => QuickSearchRow(
                  result: results[i],
                  selected: i == _selected,
                  accent: accent,
                  palette: palette,
                  keyPrefix: 'welcome-search-',
                  onTap: () => _go(results[i]),
                  onHover: () => setState(() => _selected = i),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// Read at build time, so a change of language shows at once.
  String _greeting() {
    final lines = WelcomePanel.greetingsFor(_now);
    return lines[_line % lines.length];
  }

  static TextStyle _wordmarkStyle(Color color) =>
      TextStyle(fontSize: 40, fontWeight: FontWeight.w700, letterSpacing: -1, color: color);

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final palette = AppPalette.of(context);
    final accent = Theme.of(context).colorScheme.primary;
    final favorites = app.favoriteConnections.take(8).toList();
    final recent = app.recentConnections.take(5).toList();
    final searching = _search.text.trim().isNotEmpty;
    final results = searching ? quickSearch(app, _search.text) : const <QuickSearchResult>[];
    if (_selected >= results.length) _selected = results.isEmpty ? 0 : results.length - 1;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Column(
            key: const Key('welcome-panel'),
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const AppMark(size: 54),
                  const SizedBox(width: 14),
                  Text.rich(
                    key: const Key('welcome-wordmark'),
                    TextSpan(children: [
                      const TextSpan(text: 'Command'),
                      TextSpan(text: 'S', style: TextStyle(color: accent)),
                    ]),
                    style: _wordmarkStyle(palette.text),
                  ),
                  // A terminal's cursor after the name, blinking.
                  WordmarkCursor(style: _wordmarkStyle(accent), animate: WelcomePanel.animate),
                ],
              ),
              const SizedBox(height: 14),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _PulseDot(color: accent),
                  const SizedBox(width: 10),
                  Flexible(
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 350),
                      transitionBuilder: (child, animation) => FadeTransition(opacity: animation, child: child),
                      child: Text(
                        _greeting(),
                        key: ValueKey(_greeting()),
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 16, color: Color.lerp(palette.textDim, palette.text, 0.55)),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              _Stats(app: app, palette: palette),
              const SizedBox(height: 18),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 10,
                runSpacing: 10,
                children: [
                  FilledButton.icon(
                    key: const Key('welcome-new-connection'),
                    onPressed: () => showNewConnectionDialog(context),
                    icon: const Icon(Icons.add, size: 16),
                    label: Text(tr('New Connection')),
                  ),
                  OutlinedButton.icon(
                    key: const Key('welcome-import'),
                    onPressed: () => showImportDialog(context),
                    icon: const Icon(Icons.file_download_outlined, size: 16),
                    label: Text(tr('Import…')),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              _searchBox(palette, results.length, results),
              const SizedBox(height: 14),
              if (searching) _results(palette, accent, results),
              if (!searching && _liveTabs(app).isNotEmpty) ...[
                _OpenSessions(app: app, palette: palette, accent: accent),
                const SizedBox(height: 14),
              ],
              if (!searching && favorites.isNotEmpty) ...[
                Container(
                  key: const Key('welcome-favorites'),
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
                  decoration: BoxDecoration(
                    color: palette.panel,
                    border: Border.all(color: palette.border),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(children: [
                        Icon(Icons.star_rounded, size: 13, color: accent),
                        const SizedBox(width: 5),
                        Text(
                          tr('Favorites').toUpperCase(),
                          style: TextStyle(
                            fontSize: 11,
                            letterSpacing: 0.8,
                            color: palette.textDim,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ]),
                      const SizedBox(height: 6),
                      for (final conn in favorites)
                        _RecentRow(conn: conn, accent: accent, palette: palette, keyPrefix: 'welcome-favorite'),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
              ],
              if (!searching) Container(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
                decoration: BoxDecoration(
                  color: palette.panel,
                  border: Border.all(color: palette.border),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      // Before anything is saved, the box holds the first steps.
                      (recent.isEmpty && app.connections.isEmpty ? tr('Get started') : tr('Recently opened'))
                          .toUpperCase(),
                      key: const Key('welcome-recent-title'),
                      style: TextStyle(fontSize: 11, letterSpacing: 0.8, color: palette.textDim, fontWeight: FontWeight.w500),
                    ),
                    const SizedBox(height: 6),
                    if (recent.isEmpty && app.connections.isEmpty)
                      _FirstSteps(accent: accent, palette: palette)
                    else if (recent.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Text(
                          sidebarVisible
                              ? tr('Pick a saved connection on the left, use quick connect,\nor start a new one.')
                              : tr('Show the sidebar to pick a saved connection,\nor start a new one.'),
                          style: TextStyle(fontSize: 12.5, color: palette.textDim, height: 1.5),
                        ),
                      )
                    else
                      for (final conn in recent)
                        _RecentRow(conn: conn, accent: accent, palette: palette, separateAddress: true),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              _Shortcuts(app: app, palette: palette),
            ],
          ),
        ),
      ),
    );
  }
}

/// One recent connection: a click opens it. On hover the row lights up in
/// the accent colour and an arrow shows, so it reads as clickable.
class _RecentRow extends StatefulWidget {
  const _RecentRow({
    required this.conn,
    required this.accent,
    required this.palette,
    this.keyPrefix = 'welcome-recent',
    this.separateAddress = false,
  });

  final SavedConnection conn;

  /// Keeps the keys apart when a connection is both a favorite and recent.
  final String keyPrefix;
  final bool separateAddress;
  final Color accent;
  final AppPalette palette;

  @override
  State<_RecentRow> createState() => _RecentRowState();
}

class _RecentRowState extends State<_RecentRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final conn = widget.conn;
    final palette = widget.palette;
    final accent = widget.accent;
    final defaultPort = conn.protocol == ConnectionProtocol.rdp ? 3389 : 22;
    final address = conn.port == defaultPort ? conn.host : '${conn.host}:${conn.port}';
    final host = conn.host.toLowerCase();
    final showAddress = widget.separateAddress || !conn.name.toLowerCase().contains(host);
    var displayName = conn.name;
    if (widget.separateAddress) {
      // Move a matching suffix to the address column without changing the saved name.
      final separator = displayName.lastIndexOf(' - ');
      if (separator > 0) {
        final name = displayName.substring(0, separator).trimRight();
        final suffix = displayName.substring(separator + 3).trim().toLowerCase();
        if (name.isNotEmpty && (suffix == host || suffix == address.toLowerCase())) {
          displayName = name;
        }
      }
    }
    // The outermost folder the connection sits in, the customer or site.
    final site = context.read<AppState>().folderNamesOf(conn.folderId).firstOrNull;
    const fast = Duration(milliseconds: 120);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        key: Key('${widget.keyPrefix}-${conn.id}'),
        behavior: HitTestBehavior.opaque,
        onTap: () => context.read<AppState>().openConnection(conn),
        child: AnimatedContainer(
          duration: fast,
          margin: const EdgeInsets.symmetric(vertical: 1),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
          decoration: BoxDecoration(
            color: _hover ? Color.alphaBlend(accent.withValues(alpha: 0.10), palette.panel) : Colors.transparent,
            border: Border.all(color: _hover ? accent.withValues(alpha: 0.35) : Colors.transparent),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              AnimatedContainer(
                duration: fast,
                width: 36,
                padding: const EdgeInsets.symmetric(vertical: 2),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: _hover ? accent.withValues(alpha: 0.18) : palette.panelAlt,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  conn.protocol == ConnectionProtocol.rdp ? 'RDP' : 'SSH',
                  style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w600,
                    color: _hover ? accent : palette.textDim,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              // Name and site take the room left, so the address and the
              // arrow always sit at the row's right edge.
              Expanded(
                child: Row(
                  children: [
                    Flexible(
                      child: Text(
                        displayName,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          color: palette.text,
                          fontWeight: _hover ? FontWeight.w600 : FontWeight.w400,
                        ),
                      ),
                    ),
                    if (site != null) ...[
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          site,
                          key: Key('${widget.keyPrefix}-site-${conn.id}'),
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 11.5, color: palette.textDim.withValues(alpha: 0.75)),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (showAddress) ...[
                const SizedBox(width: 10),
                Text(address, style: TextStyle(fontSize: 11.5, color: palette.textDim, fontFamily: 'Consolas')),
              ],
              AnimatedOpacity(
                duration: fast,
                opacity: _hover ? 1 : 0,
                child: Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: Icon(Icons.arrow_forward_rounded, key: Key('${widget.keyPrefix}-arrow-${conn.id}'), size: 16, color: accent),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The small accent dot before the greeting, slowly fading in and out.
class _PulseDot extends StatefulWidget {
  const _PulseDot({required this.color});

  final Color color;

  @override
  State<_PulseDot> createState() => _PulseDotState();
}

class _PulseDotState extends State<_PulseDot> with SingleTickerProviderStateMixin {
  late final AnimationController _controller =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1000), value: 1);

  @override
  void initState() {
    super.initState();
    if (WelcomePanel.animate) _controller.repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
        opacity: Tween(begin: 0.35, end: 1.0).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut)),
        child: Container(
          key: const Key('welcome-pulse'),
          width: 7,
          height: 7,
          decoration: BoxDecoration(color: widget.color, shape: BoxShape.circle),
        ),
      );
}

/// The numbers under the greeting, each in a small card: saved connections,
/// sessions open now, sessions opened today and folders.
class _Stats extends StatelessWidget {
  const _Stats({required this.app, required this.palette});

  final AppState app;
  final AppPalette palette;

  @override
  Widget build(BuildContext context) {
    Widget card(String key, int value, String label, {Color? color}) => Expanded(
          child: Container(
            key: ValueKey('welcome-stat-$key'),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: palette.panel,
              border: Border.all(color: palette.border),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('$value', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: color ?? palette.text)),
                const SizedBox(height: 2),
                Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11.5, color: palette.textDim)),
              ],
            ),
          ),
        );
    final open = _liveTabs(app).length;
    return Row(
      key: const Key('welcome-stats'),
      children: [
        card('connections', app.connections.length, tr('Connections')),
        const SizedBox(width: 8),
        // Green while something is open, the colour of a live session.
        card('open', open, tr('Open sessions'), color: open > 0 ? const Color(0xFF2EB85C) : null),
        const SizedBox(width: 8),
        card('today', app.openedToday, tr('Opened today')),
        const SizedBox(width: 8),
        card('folders', app.folders.length, tr('Folders')),
      ],
    );
  }
}

/// The indexes of the tabs whose session is connected or still connecting.
/// A tab that could not connect, or whose session ended, stays in the tab bar
/// but is not an open session.
List<int> _liveTabs(AppState app) => [
      for (var i = 0; i < app.tabs.length; i++)
        if (app.tabs[i].controller.status case SessionStatus.running || SessionStatus.starting) i,
    ];

/// The sessions still open behind the welcome screen (shown from the home
/// button): a click goes back to one.
class _OpenSessions extends StatelessWidget {
  const _OpenSessions({required this.app, required this.palette, required this.accent});

  final AppState app;
  final AppPalette palette;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('welcome-open-sessions'),
      padding: const EdgeInsets.fromLTRB(8, 12, 8, 8),
      decoration: BoxDecoration(
        color: palette.panel,
        border: Border.all(color: palette.border),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 6, bottom: 6),
            child: Text(
              tr('Open sessions · {n}', {'n': _liveTabs(app).length}).toUpperCase(),
              style: TextStyle(fontSize: 11, letterSpacing: 0.8, color: palette.textDim, fontWeight: FontWeight.w500),
            ),
          ),
          for (final i in _liveTabs(app)) _openRow(context, i),
        ],
      ),
    );
  }

  Widget _openRow(BuildContext context, int i) {
    final tab = app.tabs[i];
    final c = tab.controller;
    final title = c.tabTitle ?? c.host;
    final color = c.status == SessionStatus.running ? const Color(0xFF2EB85C) : const Color(0xFFE0A526);
    return InkWell(
      key: ValueKey('welcome-open-${tab.id}'),
      borderRadius: BorderRadius.circular(8),
      onTap: () => app.setActiveTab(i),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 7),
        child: Row(
          children: [
            Container(width: 7, height: 7, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
            const SizedBox(width: 10),
            Expanded(
              child: Row(
                children: [
                  Flexible(
                    child: Text(title, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: palette.text)),
                  ),
                  if (title != c.host) ...[
                    const SizedBox(width: 8),
                    Text(c.host, style: TextStyle(fontSize: 12, color: palette.textDim)),
                  ],
                ],
              ),
            ),
            Icon(Icons.arrow_forward_rounded, size: 14, color: palette.textDim),
          ],
        ),
      ),
    );
  }
}

/// What the recent list shows before there is a single saved connection.
class _FirstSteps extends StatelessWidget {
  const _FirstSteps({required this.accent, required this.palette});

  final Color accent;
  final AppPalette palette;

  @override
  Widget build(BuildContext context) {
    Widget step(String key, IconData icon, String label, VoidCallback onTap) => InkWell(
          key: ValueKey('welcome-first-$key'),
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 7),
            child: Row(
              children: [
                Icon(icon, size: 16, color: accent),
                const SizedBox(width: 10),
                Expanded(child: Text(label, style: TextStyle(fontSize: 13, color: palette.text))),
              ],
            ),
          ),
        );
    return Column(
      key: const Key('welcome-first-steps'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        step('add', Icons.add, tr('Add your first connection'), () => showNewConnectionDialog(context)),
        step('import', Icons.file_download_outlined, tr('Import from another app'), () => showImportDialog(context)),
        step('keys', Icons.keyboard_outlined, tr('See the shortcuts'),
            () => showSettings(context, page: SettingsPage.hotkeys)),
      ],
    );
  }
}

/// A line of the shortcuts worth knowing, under everything else: the ones set
/// in Settings > Hotkeys, as they are set now.
class _Shortcuts extends StatelessWidget {
  const _Shortcuts({required this.app, required this.palette});

  final AppState app;
  final AppPalette palette;

  @override
  Widget build(BuildContext context) {
    final items = <(String, List<String>)>[
      if (app.hotkeyFor(AppCommandId.quickSearch) case final key?) (tr('Search'), key.label.split(' + ')),
      if (app.hotkeyFor(AppCommandId.palette) case final key?) (tr('Commands'), key.label.split(' + ')),
      (tr('Find in terminal'), ['Ctrl', 'Shift', 'F']),
    ];
    Widget keyCap(String k) => Container(
          margin: const EdgeInsets.only(right: 3),
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
          decoration: BoxDecoration(
            border: Border.all(color: palette.border),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(k, style: TextStyle(fontSize: 11, color: palette.text)),
        );
    return Wrap(
      key: const Key('welcome-shortcuts'),
      alignment: WrapAlignment.center,
      spacing: 16,
      runSpacing: 8,
      children: [
        for (final (label, keys) in items)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final k in keys) keyCap(k),
              const SizedBox(width: 3),
              Text(label, style: TextStyle(fontSize: 11.5, color: palette.textDim)),
            ],
          ),
      ],
    );
  }
}
