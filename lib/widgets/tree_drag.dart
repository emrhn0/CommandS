/// What is dragged out of the connection list: folders, connections and
/// saved layouts, by id. The list moves them between folders; an empty pane
/// of a split opens a single connection dropped on it.
class TreeDragItems {
  const TreeDragItems({required this.folderIds, required this.connectionIds, required this.layoutIds});
  final List<String> folderIds;
  final List<String> connectionIds;
  final List<String> layoutIds;

  /// The one connection dragged on its own, or null.
  String? get singleConnection =>
      connectionIds.length == 1 && folderIds.isEmpty && layoutIds.isEmpty ? connectionIds.single : null;
}
