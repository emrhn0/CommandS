import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/app_state.dart';
import '../services/mac_rdp_session.dart';
import '../services/pane_layout.dart';
import '../services/rdp_session.dart';

/// Opens the Split view dialog: pick a layout, then drag open tabs into its
/// panes.
///
/// This replaced splitting by dragging a tab chip onto an edge of a pane,
/// which could never work with RDP: the session is a native window drawn over
/// its pane, so Flutter never saw a drag that crossed it, and a tab could not
/// be dropped next to a remote desktop. A dialog is a route, which makes every
/// embedded session step aside while it is open (see `RdpModalObserver`), so
/// here the whole arrangement is visible and droppable regardless of what is
/// in each pane.
Future<void> showSplitViewDialog(BuildContext context) {
  return showDialog<void>(context: context, builder: (_) => const _SplitViewDialog());
}

class _SplitViewDialog extends StatefulWidget {
  const _SplitViewDialog();

  @override
  State<_SplitViewDialog> createState() => _SplitViewDialogState();
}

class _SplitViewDialogState extends State<_SplitViewDialog> {
  late SplitPreset _preset;

  /// Tab id per slot of [_preset], in reading order; null = empty.
  late List<String?> _slots;

  @override
  void initState() {
    super.initState();
    final app = context.read<AppState>();
    final onScreen = tabIdsInLayoutOrdered(app.paneLayout);
    // Start from what is on screen, so opening the dialog and pressing Apply
    // changes nothing, and adjusting one pane is one drag.
    _preset = switch (onScreen.length) {
      <= 1 => app.tabs.length >= 2 ? SplitPreset.sideBySide : SplitPreset.single,
      2 => SplitPreset.sideBySide,
      3 => SplitPreset.oneLeftTwoRight,
      _ => SplitPreset.grid,
    };
    _slots = List<String?>.filled(_preset.slots, null);
    final order = [...onScreen, ...app.tabs.map((t) => t.id).where((id) => !onScreen.contains(id))];
    for (var i = 0; i < _slots.length && i < order.length; i++) {
      _slots[i] = order[i];
    }
  }

  void _choosePreset(SplitPreset preset) {
    setState(() {
      final placed = _slots.whereType<String>().toList();
      _preset = preset;
      _slots = List<String?>.filled(preset.slots, null);
      for (var i = 0; i < _slots.length && i < placed.length; i++) {
        _slots[i] = placed[i];
      }
    });
  }

  /// Puts [tabId] in [slot]. A tab can only be in one pane, so if it was
  /// already placed elsewhere the two panes swap.
  void _place(String tabId, int slot) {
    setState(() {
      final from = _slots.indexOf(tabId);
      final displaced = _slots[slot];
      _slots[slot] = tabId;
      if (from != -1 && from != slot) _slots[from] = displaced;
    });
  }

  void _clear(int slot) => setState(() => _slots[slot] = null);

  /// Click instead of drag: the first empty pane.
  void _placeInFirstEmpty(String tabId) {
    if (_slots.contains(tabId)) return;
    final empty = _slots.indexOf(null);
    if (empty != -1) _place(tabId, empty);
  }

  void _apply() {
    context.read<AppState>().applyLayout(buildLayout(_preset, _slots));
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final theme = Theme.of(context);
    final dim = theme.textTheme.bodySmall?.color;
    final tabsById = {for (final t in app.tabs) t.id: t};
    // A tab closed while the dialog is open must not stay in a pane.
    for (var i = 0; i < _slots.length; i++) {
      if (_slots[i] != null && !tabsById.containsKey(_slots[i])) _slots[i] = null;
    }
    final anyPlaced = _slots.any((s) => s != null);

    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 820, maxHeight: 720),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 22, 24, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('Split view', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
              const SizedBox(height: 18),
              Text('1. Choose a layout', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: dim)),
              const SizedBox(height: 10),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  for (final p in SplitPreset.values)
                    _PresetThumb(preset: p, selected: p == _preset, onTap: () => _choosePreset(p)),
                ],
              ),
              const SizedBox(height: 22),
              Text(
                '2. Drag tabs into the panes',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: dim),
              ),
              const SizedBox(height: 10),
              Flexible(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 180, maxHeight: 320),
                  child: AspectRatio(
                    aspectRatio: 16 / 7,
                    child: _PresetGeometry(
                      preset: _preset,
                      gap: 8,
                      slot: (i) => _SlotTarget(
                        index: i,
                        tab: _slots[i] == null ? null : tabsById[_slots[i]],
                        onAccept: (id) => _place(id, i),
                        onClear: () => _clear(i),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text('Open tabs', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: dim)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final t in app.tabs)
                    _DraggableTab(
                      tab: t,
                      placedIn: _slots.indexOf(t.id),
                      onTap: () => _placeInFirstEmpty(t.id),
                    ),
                ],
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Empty panes are left out. Click a tab to put it in the first empty pane.',
                      style: TextStyle(fontSize: 11, color: dim),
                    ),
                  ),
                  TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
                  const SizedBox(width: 8),
                  ElevatedButton(onPressed: anyPlaced ? _apply : null, child: const Text('Apply')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Lays out [preset]'s panes with [slot] building each one, in the same
/// geometry the tab area will use. Shared by the thumbnails and the big
/// preview so the two can never disagree.
class _PresetGeometry extends StatelessWidget {
  const _PresetGeometry({required this.preset, required this.slot, required this.gap});
  final SplitPreset preset;
  final Widget Function(int index) slot;
  final double gap;

  @override
  Widget build(BuildContext context) {
    Widget row(List<Widget> children) => Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: _withGaps(children, SizedBox(width: gap)),
        );
    Widget col(List<Widget> children) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: _withGaps(children, SizedBox(height: gap)),
        );
    Widget s(int i) => Expanded(child: slot(i));

    return switch (preset) {
      SplitPreset.single => row([s(0)]),
      SplitPreset.sideBySide => row([s(0), s(1)]),
      SplitPreset.stacked => col([s(0), s(1)]),
      SplitPreset.oneLeftTwoRight => row([s(0), Expanded(child: col([s(1), s(2)]))]),
      SplitPreset.threeColumns => row([s(0), s(1), s(2)]),
      SplitPreset.grid => col([
          Expanded(child: row([s(0), s(1)])),
          Expanded(child: row([s(2), s(3)])),
        ]),
    };
  }

  static List<Widget> _withGaps(List<Widget> items, Widget gap) {
    final out = <Widget>[];
    for (var i = 0; i < items.length; i++) {
      if (i > 0) out.add(gap);
      out.add(items[i]);
    }
    return out;
  }
}

class _PresetThumb extends StatelessWidget {
  const _PresetThumb({required this.preset, required this.selected, required this.onTap});
  final SplitPreset preset;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;
    return Tooltip(
      message: preset.label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Container(
          width: 92,
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            border: Border.all(color: selected ? accent : theme.dividerColor, width: selected ? 2 : 1),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Column(
            children: [
              SizedBox(
                height: 44,
                child: _PresetGeometry(
                  preset: preset,
                  gap: 3,
                  slot: (_) => Container(
                    decoration: BoxDecoration(
                      color: accent.withValues(alpha: selected ? 0.35 : 0.15),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                preset.label,
                style: TextStyle(fontSize: 10, fontWeight: selected ? FontWeight.w700 : FontWeight.w400),
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

bool _isRdp(OpenTab t) => t.controller is RdpSessionController || t.controller is MacRdpSessionController;

String _title(OpenTab t) => t.controller.tabTitle ?? t.controller.host;

class _SlotTarget extends StatelessWidget {
  const _SlotTarget({
    required this.index,
    required this.tab,
    required this.onAccept,
    required this.onClear,
  });

  final int index;
  final OpenTab? tab;
  final ValueChanged<String> onAccept;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;
    final dim = theme.textTheme.bodySmall?.color;
    return DragTarget<String>(
      onWillAcceptWithDetails: (d) => d.data != tab?.id,
      onAcceptWithDetails: (d) => onAccept(d.data),
      builder: (context, candidates, _) {
        final hovering = candidates.isNotEmpty;
        final t = tab;
        final content = t == null
            ? Center(
                child: Text(
                  hovering ? 'Drop here' : 'Drop a tab here',
                  style: TextStyle(fontSize: 12, color: dim),
                ),
              )
            : Stack(
                children: [
                  Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(_isRdp(t) ? Icons.desktop_windows_outlined : Icons.terminal, size: 22),
                          const SizedBox(height: 6),
                          Text(
                            _title(t),
                            textAlign: TextAlign.center,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(height: 2),
                          Text(_isRdp(t) ? 'RDP' : 'SSH', style: TextStyle(fontSize: 10, color: dim)),
                        ],
                      ),
                    ),
                  ),
                  Positioned(
                    top: 2,
                    right: 2,
                    child: IconButton(
                      tooltip: 'Empty this pane',
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.close, size: 14),
                      onPressed: onClear,
                    ),
                  ),
                ],
              );
        final box = AnimatedContainer(
          duration: const Duration(milliseconds: 100),
          decoration: BoxDecoration(
            color: hovering
                ? accent.withValues(alpha: 0.16)
                : (t == null ? Colors.transparent : accent.withValues(alpha: 0.06)),
            border: Border.all(
              color: hovering ? accent : theme.dividerColor,
              width: hovering ? 2 : 1,
            ),
            borderRadius: BorderRadius.circular(6),
          ),
          child: content,
        );
        // A placed tab can itself be dragged to another pane (they swap).
        if (t == null) return box;
        return Draggable<String>(
          data: t.id,
          feedback: _TabChipFeedback(tab: t),
          childWhenDragging: Opacity(opacity: 0.4, child: box),
          child: box,
        );
      },
    );
  }
}

class _DraggableTab extends StatelessWidget {
  const _DraggableTab({required this.tab, required this.placedIn, required this.onTap});
  final OpenTab tab;
  final int placedIn;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final placed = placedIn != -1;
    final chip = Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: placed ? theme.colorScheme.primary.withValues(alpha: 0.08) : theme.colorScheme.surface,
        border: Border.all(color: theme.dividerColor),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(_isRdp(tab) ? Icons.desktop_windows_outlined : Icons.terminal, size: 14),
          const SizedBox(width: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 200),
            child: Text(_title(tab), overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
          ),
          if (placed) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: theme.colorScheme.primary,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                '${placedIn + 1}',
                style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: theme.colorScheme.onPrimary),
              ),
            ),
          ],
        ],
      ),
    );
    return MouseRegion(
      cursor: SystemMouseCursors.grab,
      child: Draggable<String>(
        data: tab.id,
        feedback: _TabChipFeedback(tab: tab),
        childWhenDragging: Opacity(opacity: 0.4, child: chip),
        child: GestureDetector(onTap: onTap, child: chip),
      ),
    );
  }
}

class _TabChipFeedback extends StatelessWidget {
  const _TabChipFeedback({required this.tab});
  final OpenTab tab;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      elevation: 6,
      borderRadius: BorderRadius.circular(5),
      color: theme.colorScheme.surface,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(_isRdp(tab) ? Icons.desktop_windows_outlined : Icons.terminal, size: 14),
            const SizedBox(width: 6),
            Text(_title(tab), style: const TextStyle(fontSize: 12)),
          ],
        ),
      ),
    );
  }
}
