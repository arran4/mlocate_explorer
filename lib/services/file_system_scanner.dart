import 'dart:io';
import '../models/node.dart';

class FileSystemScanner {
  final String rootPath;
  Node? rootNode;
  int _nodeCounter = 0;
  DateTime _lastProgressTime = DateTime.now();
  final List<Map<String, dynamic>> errors = [];
  final void Function(double? progress, String status)? onProgress;

  FileSystemScanner(this.rootPath, {this.onProgress});

  void scan() {
    var dir = Directory(rootPath);
    if (!dir.existsSync()) {
      errors.add({
        'description': 'Directory does not exist: $rootPath',
        'directoryPath': rootPath,
        'offset': 0,
        'percentage': 0.0,
        'hexDump': '',
      });
      return;
    }

    String label = rootPath == '/'
        ? '/'
        : rootPath
            .split('/')
            .lastWhere((e) => e.isNotEmpty, orElse: () => rootPath);

    rootNode = Node(
      key: rootPath,
      label: label,
      isDir: true,
      mlocateIndex: _nodeCounter++,
      children: [],
    );

    _scanDirectory(dir, rootNode!);
  }

  (int deepFiles, int deepFolders) _scanDirectory(
      Directory dir, Node parentNode) {
    if (onProgress != null) {
      final now = DateTime.now();
      if (now.difference(_lastProgressTime).inMilliseconds >= 500) {
        _lastProgressTime = now;
        onProgress!(
          null,
          'Scanning file system ($_nodeCounter nodes found)...',
        );
      }
    }

    int subFiles = 0;
    int subFolders = 0;
    int deepFiles = 0;
    int deepFolders = 0;

    try {
      var entities = dir.listSync(recursive: false, followLinks: false);
      for (var entity in entities) {
        String label = entity.path.split('/').last;
        bool isDir = entity is Directory;

        DateTime? modifiedTime;
        try {
          modifiedTime = entity.statSync().modified;
        } catch (_) {}

        var node = Node(
          key: entity.path,
          label: label,
          isDir: isDir,
          modifiedTime: modifiedTime,
          mlocateIndex: _nodeCounter++,
          children: [],
        );

        parentNode.children.add(node);

        if (isDir) {
          subFolders++;
          deepFolders++;
          var (childDeepFiles, childDeepFolders) =
              _scanDirectory(entity, node);
          deepFiles += childDeepFiles;
          deepFolders += childDeepFolders;
        } else {
          subFiles++;
          deepFiles++;
        }
      }
    } catch (e) {
      errors.add({
        'description': 'Error scanning directory: $e',
        'directoryPath': dir.path,
        'offset': 0,
        'percentage': 0.0,
        'hexDump': '',
      });
    }

    parentNode.subFileCount = subFiles;
    parentNode.subFolderCount = subFolders;
    parentNode.deepFileCount = deepFiles;
    parentNode.deepFolderCount = deepFolders;

    return (deepFiles, deepFolders);
  }
}
