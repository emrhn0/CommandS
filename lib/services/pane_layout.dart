import 'package:flutter/widgets.dart' show Axis;

enum SplitEdge { left, right, top, bottom }

/// A node in the tab area's tiling tree — either one visible session
/// ([PaneLeaf]) or a divider between two sub-trees ([PaneSplit]). Dragging a
/// tab chip onto an edge of an existing pane turns that pane into a split;
/// closing the tab on either side of a split collapses it back to its
/// sibling, same as any tiling window manager.
sealed class PaneNode {
  const PaneNode();
}

class PaneLeaf extends PaneNode {
  const PaneLeaf(this.tabId);
  final String tabId;
}

class PaneSplit extends PaneNode {
  PaneSplit({required this.axis, required this.first, required this.second, this.ratio = 0.5});
  final Axis axis; // horizontal = side-by-side halves (left/right drop); vertical = stacked (top/bottom drop)
  PaneNode first;
  PaneNode second;
  double ratio;
}

/// Rebuilds [node] with [draggedTabId] inserted as a new sibling of the leaf
/// holding [targetTabId], on the side given by [edge]. Returns the
/// (possibly unchanged) tree; null in is null out.
PaneNode? insertSplit(PaneNode? node, {required String draggedTabId, required String targetTabId, required SplitEdge edge}) {
  if (node == null) return PaneLeaf(draggedTabId);
  if (node is PaneLeaf) {
    if (node.tabId != targetTabId) return node;
    final axis = (edge == SplitEdge.left || edge == SplitEdge.right) ? Axis.horizontal : Axis.vertical;
    final draggedFirst = edge == SplitEdge.left || edge == SplitEdge.top;
    final draggedLeaf = PaneLeaf(draggedTabId);
    return PaneSplit(
      axis: axis,
      first: draggedFirst ? draggedLeaf : node,
      second: draggedFirst ? node : draggedLeaf,
    );
  }
  final split = node as PaneSplit;
  split.first = insertSplit(split.first, draggedTabId: draggedTabId, targetTabId: targetTabId, edge: edge) ?? split.first;
  split.second = insertSplit(split.second, draggedTabId: draggedTabId, targetTabId: targetTabId, edge: edge) ?? split.second;
  return split;
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

/// All tab ids currently occupying a pane in this layout.
Set<String> tabIdsInLayout(PaneNode? node) {
  if (node == null) return {};
  if (node is PaneLeaf) return {node.tabId};
  final split = node as PaneSplit;
  return {...tabIdsInLayout(split.first), ...tabIdsInLayout(split.second)};
}
