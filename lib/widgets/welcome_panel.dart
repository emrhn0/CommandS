import 'dart:async';
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

  /// Which line of [greetingsFor] the panel shows, for this run of the app.
  static final picker = GreetingPicker(seed: launchSeed);

  @override
  State<WelcomePanel> createState() => _WelcomePanelState();
}

/// Picks the greeting: the plain one ("Good morning") the first time in each
/// part of the day, then the lighter lines in turn, a new one each time the
/// panel comes back and each hour it stays up.
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
  Timer? _hourly;
  late int _line;

  DateTime get _now => widget.now ?? DateTime.now();

  bool get sidebarVisible => widget.sidebarVisible;

  @override
  void initState() {
    super.initState();
    _line = WelcomePanel.picker.next(_now);
    _scheduleNextHour();
  }

  /// Redraws at the top of the next hour, for the next line.
  void _scheduleNextHour() {
    if (widget.now != null) return;
    final now = DateTime.now();
    final next = DateTime(now.year, now.month, now.day, now.hour + 1);
    _hourly = Timer(next.difference(now), () {
      if (!mounted) return;
      setState(() => _line = WelcomePanel.picker.next(_now));
      _scheduleNextHour();
    });
  }

  @override
  void dispose() {
    _hourly?.cancel();
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
                children: [
                  const AppMark(size: 60),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _greeting(),
                          style: TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.w600,
                            letterSpacing: -0.4,
                            color: palette.text,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          tr('{connections} connections, {folders} folders', {
                            'connections': app.connections.length,
                            'folders': app.folders.length,
                          }),
                          style: TextStyle(fontSize: 13, color: palette.textDim),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 22),
              Wrap(
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

class _RecentRow extends StatelessWidget {
  const _RecentRow({required this.conn, required this.accent, required this.palette});

  final SavedConnection conn;
  final Color accent;
  final AppPalette palette;

  @override
  Widget build(BuildContext context) {
    final defaultPort = conn.protocol == ConnectionProtocol.rdp ? 3389 : 22;
    final address = conn.port == defaultPort ? conn.host : '${conn.host}:${conn.port}';
    return InkWell(
      key: Key('welcome-recent-${conn.id}'),
      borderRadius: BorderRadius.circular(6),
      onTap: () => context.read<AppState>().openConnection(conn),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 7),
        child: Row(
          children: [
            Container(
              width: 36,
              padding: const EdgeInsets.symmetric(vertical: 2),
              alignment: Alignment.center,
              decoration: BoxDecoration(color: palette.panelAlt, borderRadius: BorderRadius.circular(4)),
              child: Text(
                conn.protocol == ConnectionProtocol.rdp ? 'RDP' : 'SSH',
                style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w600, color: palette.textDim),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(conn.name, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: palette.text)),
            ),
            const SizedBox(width: 10),
            Text(address, style: TextStyle(fontSize: 11.5, color: palette.textDim, fontFamily: 'Consolas')),
          ],
        ),
      ),
    );
  }
}
