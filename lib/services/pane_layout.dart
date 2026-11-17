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

// ---- Layout shapes and custom layouts ----

/// The shape of a layout without any tabs in it: zones split in two, side by
/// side or stacked, at a ratio. Built-in presets and the layouts people draw
/// themselves (Split view > Custom) are both shapes. Zones are numbered in
/// tree order (first side before second), which is reading order for every
/// preset.
sealed class ZoneNode {
  const ZoneNode();

  Map<String, Object?> toJson();

  static ZoneNode fromJson(Object? json, {int depth = 0}) {
    if (depth > 16 || json is! Map) return const ZoneLeaf();
    if (json['split'] == null) return const ZoneLeaf();
    final ratio = (json['ratio'] as num?)?.toDouble() ?? 0.5;
    return ZoneSplit(
      axis: json['split'] == 'vertical' ? Axis.vertical : Axis.horizontal,
      ratio: ratio.clamp(minZoneRatio, 1 - minZoneRatio),
      first: fromJson(json['first'], depth: depth + 1),
      second: fromJson(json['second'], depth: depth + 1),
    );
  }
}

class ZoneLeaf extends ZoneNode {
  const ZoneLeaf();

  @override
  Map<String, Object?> toJson() => const {};
}

class ZoneSplit extends ZoneNode {
  const ZoneSplit({required this.axis, required this.first, required this.second, this.ratio = 0.5});
  final Axis axis; // horizontal = side by side; vertical = stacked
  final ZoneNode first;
  final ZoneNode second;
  final double ratio;

  @override
  Map<String, Object?> toJson() => {
    'split': axis == Axis.vertical ? 'vertical' : 'horizontal',
    'ratio': ratio,
    'first': first.toJson(),
    'second': second.toJson(),
  };
}

/// No zone thinner than this share of its split, so every pane stays usable.
const double minZoneRatio = 0.1;

/// The most zones a custom layout can have.
const int maxCustomZones = 8;

/// How many zones (panes) [shape] has.
int zoneCount(ZoneNode shape) =>
    shape is ZoneSplit ? zoneCount(shape.first) + zoneCount(shape.second) : 1;

/// Where each zone sits, as fractions of the whole, in zone order.
List<Rect> zoneRects(ZoneNode shape, [Rect area = const Rect.fromLTRB(0, 0, 1, 1)]) {
  if (shape is! ZoneSplit) return [area];
  final Rect a, b;
  if (shape.axis == Axis.horizontal) {
    final x = area.left + area.width * shape.ratio;
    a = Rect.fromLTRB(area.left, area.top, x, area.bottom);
    b = Rect.fromLTRB(x, area.top, area.right, area.bottom);
  } else {
    final y = area.top + area.height * shape.ratio;
    a = Rect.fromLTRB(area.left, area.top, area.right, y);
    b = Rect.fromLTRB(area.left, y, area.right, area.bottom);
  }
  return [...zoneRects(shape.first, a), ...zoneRects(shape.second, b)];
}

/// [preset] as a shape, with the same splits and ratios as [buildLayout].
ZoneNode presetShape(SplitPreset preset) {
  const z = ZoneLeaf();
  ZoneSplit h(ZoneNode a, ZoneNode b, [double ratio = 0.5]) =>
      ZoneSplit(axis: Axis.horizontal, first: a, second: b, ratio: ratio);
  ZoneSplit v(ZoneNode a, ZoneNode b) => ZoneSplit(axis: Axis.vertical, first: a, second: b);
  return switch (preset) {
    SplitPreset.single => z,
    SplitPreset.sideBySide => h(z, z),
    SplitPreset.stacked => v(z, z),
    SplitPreset.oneLeftTwoRight => h(z, v(z, z)),
    SplitPreset.threeColumns => h(z, h(z, z), 1 / 3),
    SplitPreset.grid => v(h(z, z), h(z, z)),
  };
}

/// The tiling tree for [shape] with [slots] (tab ids, null for an empty
/// zone) in zone order. As with [buildLayout], an empty zone is left out and
/// its split collapses onto the other side. Null if nothing was placed.
PaneNode? buildFromShape(ZoneNode shape, List<String?> slots) {
  var next = 0;
  PaneNode? walk(ZoneNode node) {
    if (node is ZoneSplit) {
      final a = walk(node.first);
      final b = walk(node.second);
      if (a == null) return b;
      if (b == null) return a;
      return PaneSplit(axis: node.axis, first: a, second: b, ratio: node.ratio);
    }
    final i = next++;
    return i < slots.length && slots[i] != null ? PaneLeaf(slots[i]!) : null;
  }

  return walk(shape);
}

/// [shape] with zone [index] split in two along [axis] at [ratio] of the
/// zone: the zone becomes its first part and a new zone its second.
ZoneNode splitZone(ZoneNode shape, int index, Axis axis, {double ratio = 0.5}) {
  var at = 0;
  final r = ratio.clamp(minZoneRatio, 1 - minZoneRatio);
  ZoneNode walk(ZoneNode node) {
    if (node is ZoneSplit) {
      return ZoneSplit(axis: node.axis, ratio: node.ratio, first: walk(node.first), second: walk(node.second));
    }
    return at++ == index ? ZoneSplit(axis: axis, first: const ZoneLeaf(), second: const ZoneLeaf(), ratio: r) : node;
  }

  return walk(shape);
}

/// [shape] without zone [index]: the other side of its split takes the room.
/// The last zone cannot be removed.
ZoneNode removeZone(ZoneNode shape, int index) {
  var at = 0;
  ZoneNode? walk(ZoneNode node) {
    if (node is ZoneSplit) {
      final a = walk(node.first);
      final b = walk(node.second);
      if (a == null) return b;
      if (b == null) return a;
      return ZoneSplit(axis: node.axis, ratio: node.ratio, first: a, second: b);
    }
    return at++ == index ? null : node;
  }

  return walk(shape) ?? shape;
}

/// [shape] with the split at [path] (false = first side, true = second, from
/// the top) moved to [ratio].
ZoneNode setZoneRatio(ZoneNode shape, List<bool> path, double ratio) {
  if (shape is! ZoneSplit) return shape;
  if (path.isEmpty) {
    return ZoneSplit(
      axis: shape.axis,
      first: shape.first,
      second: shape.second,
      ratio: ratio.clamp(minZoneRatio, 1 - minZoneRatio),
    );
  }
  final rest = path.sublist(1);
  return ZoneSplit(
    axis: shape.axis,
    ratio: shape.ratio,
    first: path.first ? shape.first : setZoneRatio(shape.first, rest, ratio),
    second: path.first ? setZoneRatio(shape.second, rest, ratio) : shape.second,
  );
}

/// A layout someone drew in Split view > Custom, kept with its name.
class CustomLayout {
  CustomLayout({required this.id, required this.name, required this.shape});
  final String id;
  String name;
  ZoneNode shape;

  Map<String, Object?> toJson() => {'id': id, 'name': name, 'shape': shape.toJson()};

  static CustomLayout? fromJson(Object? json) {
    if (json is! Map || json['id'] is! String) return null;
    final name = (json['name'] as String?)?.trim();
    return CustomLayout(
      id: json['id'] as String,
      name: name == null || name.isEmpty ? 'Custom' : name,
      shape: ZoneNode.fromJson(json['shape']),
    );
  }
}
