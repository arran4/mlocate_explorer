class Node {
  String key;
  String label;
  final List<Node> children;
  bool isDir;
  DateTime? modifiedTime;
  bool isOpened;

  int subFileCount;
  int subFolderCount;
  int deepFileCount;
  int deepFolderCount;
  final int mlocateIndex;
  int? sizeOverride;

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
    this.sizeOverride,
  });

  Map<String, dynamic> toJson() {
    return {
      'key': key,
      'label': label,
      'children': children.map((child) => child.toJson()).toList(),
      'isDir': isDir,
      'modifiedTime': modifiedTime?.toIso8601String(),
      'isOpened': isOpened,
      'subFileCount': subFileCount,
      'subFolderCount': subFolderCount,
      'deepFileCount': deepFileCount,
      'deepFolderCount': deepFolderCount,
      if (sizeOverride != null) 'sizeOverride': sizeOverride,
    };
  }

  factory Node.fromJson(Map<String, dynamic> json) {
    return Node(
      key: json['key'] as String,
      label: json['label'] as String,
      children: (json['children'] as List<dynamic>?)
              ?.map((e) => Node.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
      isDir: json['isDir'] as bool? ?? false,
      modifiedTime: json['modifiedTime'] != null
          ? DateTime.parse(json['modifiedTime'] as String)
          : null,
      isOpened: json['isOpened'] as bool? ?? false,
      subFileCount: json['subFileCount'] as int? ?? 0,
      subFolderCount: json['subFolderCount'] as int? ?? 0,
      deepFileCount: json['deepFileCount'] as int? ?? 0,
      deepFolderCount: json['deepFolderCount'] as int? ?? 0,
      sizeOverride: json['sizeOverride'] as int?,
    );
  }
}
