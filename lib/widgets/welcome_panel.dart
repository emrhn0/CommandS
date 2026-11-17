import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../models/models.dart';
import '../providers/app_state.dart';
import '../theme/app_mark.dart';
import '../theme/app_theme.dart';
import 'import_export_dialog.dart';
import 'new_connection_dialog.dart';

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
    super.dispose();
  }

  /// Read at build time, so a change of language shows at once.
  String _greeting() {
    final lines = WelcomePanel.greetingsFor(_now);
    return lines[_line % lines.length];
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final palette = AppPalette.of(context);
    final accent = Theme.of(context).colorScheme.primary;
    final recent = app.recentConnections.take(5).toList();
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
                    style: TextStyle(fontSize: 40, fontWeight: FontWeight.w700, letterSpacing: -1, color: palette.text),
                  ),
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
              const SizedBox(height: 6),
              Text(
                tr('{connections} connections, {folders} folders', {
                  'connections': app.connections.length,
                  'folders': app.folders.length,
                }),
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12.5, color: palette.textDim),
              ),
              const SizedBox(height: 22),
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
              const SizedBox(height: 22),
              Container(
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
                      tr('Recently opened').toUpperCase(),
                      style: TextStyle(fontSize: 11, letterSpacing: 0.8, color: palette.textDim, fontWeight: FontWeight.w500),
                    ),
                    const SizedBox(height: 6),
                    if (recent.isEmpty)
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
                      for (final conn in recent) _RecentRow(conn: conn, accent: accent, palette: palette),
                  ],
                ),
              ),
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
  const _RecentRow({required this.conn, required this.accent, required this.palette});

  final SavedConnection conn;
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
    // Many names already carry the address; it is not repeated beside them.
    final showAddress = !conn.name.toLowerCase().contains(conn.host.toLowerCase());
    // The outermost folder the connection sits in, the customer or site.
    final site = context.read<AppState>().folderNamesOf(conn.folderId).firstOrNull;
    const fast = Duration(milliseconds: 120);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        key: Key('welcome-recent-${conn.id}'),
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
              Flexible(
                child: Text(
                  conn.name,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13, color: palette.text, fontWeight: _hover ? FontWeight.w600 : FontWeight.w400),
                ),
              ),
              if (site != null) ...[
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    site,
                    key: Key('welcome-recent-site-${conn.id}'),
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11.5, color: palette.textDim.withValues(alpha: 0.75)),
                  ),
                ),
              ],
              const Spacer(),
              if (showAddress) ...[
                const SizedBox(width: 10),
                Text(address, style: TextStyle(fontSize: 11.5, color: palette.textDim, fontFamily: 'Consolas')),
              ],
              AnimatedOpacity(
                duration: fast,
                opacity: _hover ? 1 : 0,
                child: Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: Icon(Icons.arrow_forward_rounded, key: Key('welcome-recent-arrow-${conn.id}'), size: 16, color: accent),
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
