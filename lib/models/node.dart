class Node {
  final String key;
  final String label;
  final List<Node> children;
  bool isDir;
  DateTime? modifiedTime;
  int fileCount = 0;
  int folderCount = 0;

  Node({
    required this.key,
    required this.label,
    this.children = const [],
    this.isDir = false,
    this.modifiedTime,
  });
}
