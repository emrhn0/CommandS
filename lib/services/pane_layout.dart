import 'package:flutter/widgets.dart' show Axis;

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
