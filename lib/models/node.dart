class Node {
  final String key;
  final String label;
  final List<Node> children;
  bool isDir;
  DateTime? modifiedTime;
  bool isOpened;

  int subFileCount;
  int subFolderCount;
  int deepFileCount;
  int deepFolderCount;
  final int mlocateIndex;

  Node({
    required this.key,
    required this.label,
    this.children = const [],
    this.isDir = false,
    this.modifiedTime,
    this.isOpened = false,
    this.subFileCount = 0,
    this.subFolderCount = 0,
    this.deepFileCount = 0,
    this.deepFolderCount = 0,
    this.mlocateIndex = 0,
  });
}
