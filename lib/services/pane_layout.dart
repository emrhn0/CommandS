import 'package:flutter/widgets.dart' show Axis, Offset, Rect, Size;

/// A node in the tab area's tiling tree — either one visible session
/// ([PaneLeaf]) or a divider between two sub-trees ([PaneSplit]). Layouts are
/// built from a [SplitPreset] in the Split view dialog; closing the tab on
/// either side of a split collapses it back to its sibling, same as any tiling
/// window manager.
sealed class PaneNode {
  const PaneNode();
}

class PaneLeaf extends PaneNode {
  const PaneLeaf(this.tabId);
  final String tabId;
}

class PaneSplit extends PaneNode {
  PaneSplit({required this.axis, required this.first, required this.second, this.ratio = 0.5});
  final Axis axis; // horizontal = side by side; vertical = stacked
  PaneNode first;
  PaneNode second;
  double ratio;
}

/// The layouts offered by Split view. Slots are numbered in reading order
/// (left to right, then top to bottom), which is also the order the dialog
/// draws them in.
enum SplitPreset {
  single(1, 'Single'),
  sideBySide(2, 'Side by side'),
  stacked(2, 'Stacked'),
  oneLeftTwoRight(3, 'One + two'),
  threeColumns(3, 'Three columns'),
  grid(4, 'Grid');

  const SplitPreset(this.slots, this.label);
  final int slots;
  final String label;
}

/// Builds the tiling tree for [preset] with [slots] (tab ids, null for an
/// empty slot) placed in reading order. Empty slots are dropped and whatever
/// they would have split collapses onto its sibling, so a half-filled grid is
/// a smaller layout rather than a hole. Null if nothing was placed.
PaneNode? buildLayout(SplitPreset preset, List<String?> slots) {
  PaneNode? leaf(int i) => i < slots.length && slots[i] != null ? PaneLeaf(slots[i]!) : null;

  PaneNode? split(Axis axis, PaneNode? a, PaneNode? b, {double ratio = 0.5}) {
    if (a == null) return b;
    if (b == null) return a;
    return PaneSplit(axis: axis, first: a, second: b, ratio: ratio);
  }

  switch (preset) {
    case SplitPreset.single:
      return leaf(0);
    case SplitPreset.sideBySide:
      return split(Axis.horizontal, leaf(0), leaf(1));
    case SplitPreset.stacked:
      return split(Axis.vertical, leaf(0), leaf(1));
    case SplitPreset.oneLeftTwoRight:
      return split(Axis.horizontal, leaf(0), split(Axis.vertical, leaf(1), leaf(2)));
    case SplitPreset.threeColumns:
      final left = leaf(0);
      final rest = split(Axis.horizontal, leaf(1), leaf(2));
      // Two columns' worth on the right, so all three come out equal.
      final restIsTwo = rest is PaneSplit;
      return split(Axis.horizontal, left, rest, ratio: restIsTwo ? 1 / 3 : 0.5);
    case SplitPreset.grid:
      return split(
        Axis.vertical,
        split(Axis.horizontal, leaf(0), leaf(1)),
        split(Axis.horizontal, leaf(2), leaf(3)),
      );
  }
}

/// Removes every leaf referencing [tabId], collapsing any split left with
/// only one side remaining. Returns null if the whole tree emptied out.
PaneNode? removeFromLayout(PaneNode? node, String tabId) {
  if (node == null) return null;
  if (node is PaneLeaf) return node.tabId == tabId ? null : node;
  final split = node as PaneSplit;
  final first = removeFromLayout(split.first, tabId);
  final second = removeFromLayout(split.second, tabId);
  if (first == null) return second;
  if (second == null) return first;
  split.first = first;
  split.second = second;
  return split;
}

/// All tab ids currently occupying a pane in this layout, in reading order.
List<String> tabIdsInLayoutOrdered(PaneNode? node) {
  if (node == null) return const [];
  if (node is PaneLeaf) return [node.tabId];
  final split = node as PaneSplit;
  return [...tabIdsInLayoutOrdered(split.first), ...tabIdsInLayoutOrdered(split.second)];
}

/// All tab ids currently occupying a pane in this layout.
Set<String> tabIdsInLayout(PaneNode? node) => tabIdsInLayoutOrdered(node).toSet();

/// The most panes the tab area is split into, which is also what the Split
/// view dialog can show.
const int maxSplitPanes = 4;

/// Which side of a pane a dragged tab would land on.
enum PaneSide { left, right, top, bottom }

/// The side of a pane of [size] that a drag at [position] points to: the
/// nearest edge, within the outer [edgeBand] of the pane. Null in the middle,
/// where a drop should do nothing.
PaneSide? paneSideAt(Size size, Offset position, {double edgeBand = 0.35}) {
  if (size.isEmpty) return null;
  final x = position.dx / size.width;
  final y = position.dy / size.height;
  final distances = {
    PaneSide.left: x,
    PaneSide.right: 1 - x,
    PaneSide.top: y,
    PaneSide.bottom: 1 - y,
  };
  final nearest = distances.entries.reduce((a, b) => b.value < a.value ? b : a);
  return nearest.value < edgeBand ? nearest.key : null;
}

/// The part of a pane (as fractions of it) that a tab dropped on [side] takes.
Rect paneSideRect(PaneSide side) => switch (side) {
  PaneSide.left => const Rect.fromLTRB(0, 0, 0.5, 1),
  PaneSide.right => const Rect.fromLTRB(0.5, 0, 1, 1),
  PaneSide.top => const Rect.fromLTRB(0, 0, 1, 0.5),
  PaneSide.bottom => const Rect.fromLTRB(0, 0.5, 1, 1),
};

/// A copy of the tree with the pane showing [targetTabId] split in two, and
/// [newTabId] on [side] of it. Other splits keep their dragged dividers.
PaneNode insertBeside(PaneNode node, String targetTabId, String newTabId, PaneSide side) {
  if (node is PaneLeaf) {
    if (node.tabId != targetTabId) return node;
    final added = PaneLeaf(newTabId);
    final addedFirst = side == PaneSide.left || side == PaneSide.top;
    return PaneSplit(
      axis: side == PaneSide.left || side == PaneSide.right ? Axis.horizontal : Axis.vertical,
      first: addedFirst ? added : node,
      second: addedFirst ? node : added,
    );
  }
  final split = node as PaneSplit;
  return PaneSplit(
    axis: split.axis,
    ratio: split.ratio,
    first: insertBeside(split.first, targetTabId, newTabId, side),
    second: insertBeside(split.second, targetTabId, newTabId, side),
  );
}

/// Where each slot of [preset] sits, as fractions of the tab area, in the
/// same reading order as [buildLayout].
List<Rect> presetSlotRects(SplitPreset preset) => switch (preset) {
  SplitPreset.single => const [Rect.fromLTRB(0, 0, 1, 1)],
  SplitPreset.sideBySide => const [Rect.fromLTRB(0, 0, 0.5, 1), Rect.fromLTRB(0.5, 0, 1, 1)],
  SplitPreset.stacked => const [Rect.fromLTRB(0, 0, 1, 0.5), Rect.fromLTRB(0, 0.5, 1, 1)],
  SplitPreset.oneLeftTwoRight => const [
    Rect.fromLTRB(0, 0, 0.5, 1),
    Rect.fromLTRB(0.5, 0, 1, 0.5),
    Rect.fromLTRB(0.5, 0.5, 1, 1),
  ],
  SplitPreset.threeColumns => const [
    Rect.fromLTRB(0, 0, 1 / 3, 1),
    Rect.fromLTRB(1 / 3, 0, 2 / 3, 1),
    Rect.fromLTRB(2 / 3, 0, 1, 1),
  ],
  SplitPreset.grid => const [
    Rect.fromLTRB(0, 0, 0.5, 0.5),
    Rect.fromLTRB(0.5, 0, 1, 0.5),
    Rect.fromLTRB(0, 0.5, 0.5, 1),
    Rect.fromLTRB(0.5, 0.5, 1, 1),
  ],
};
