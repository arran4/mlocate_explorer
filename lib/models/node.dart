class Node {
  final String key;
  final String label;
  final List<Node> children;
  bool isDir;
  DateTime? modifiedTime;
  bool isOpened;

  Node({
    required this.key,
    required this.label,
    this.children = const [],
    this.isDir = false,
    this.modifiedTime,
    this.isOpened = false,
  });
}
