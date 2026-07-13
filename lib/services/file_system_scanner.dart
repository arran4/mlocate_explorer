import 'dart:io';
import '../models/node.dart';

class FileSystemScanner {
  final String rootPath;
  Node? rootNode;
  int _nodeCounter = 0;
  int _calculatedNodes = 0;
  DateTime _lastProgressTime = DateTime.now();
  final List<Map<String, dynamic>> errors = [];
  final void Function(double progress, String status)? onProgress;

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

    String label = rootPath == '/' ? '/' : rootPath.split('/').lastWhere((e) => e.isNotEmpty, orElse: () => rootPath);

    rootNode = Node(
      key: rootPath,
      label: label,
      isDir: true,
      mlocateIndex: _nodeCounter++,
    );

    _scanDirectory(dir, rootNode!);

    if (rootNode != null) {
      _calculateCounts(rootNode!);
    }
  }

  void _scanDirectory(Directory dir, Node parentNode) {
    if (onProgress != null) {
      final now = DateTime.now();
      if (now.difference(_lastProgressTime).inMilliseconds >= 500) {
        _lastProgressTime = now;
        onProgress!(
          0.5,
          'Scanning file system ($_nodeCounter nodes found)...',
        );
      }
    }

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
        );

        parentNode.children.add(node);

        if (isDir) {
          _scanDirectory(entity as Directory, node);
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
  }

  void _calculateCounts(Node node) {
    if (onProgress != null) {
      _calculatedNodes++;
      final isLastNode = _calculatedNodes == _nodeCounter;
      if (_calculatedNodes % 1024 == 0 || isLastNode) {
        final now = DateTime.now();
        if (isLastNode ||
            now.difference(_lastProgressTime).inMilliseconds >= 500) {
          _lastProgressTime = now;
          double calculateProgress =
              _nodeCounter > 0 ? (_calculatedNodes / _nodeCounter) : 0.0;
          onProgress!(
            0.9 + (calculateProgress * 0.1),
            'Calculating node statistics ($_calculatedNodes / $_nodeCounter nodes)...',
          );
        }
      }
    }

    if (!node.isDir) return;

    int subFiles = 0;
    int subFolders = 0;
    int deepFiles = 0;
    int deepFolders = 0;

    for (var child in node.children) {
      if (child.isDir) {
        subFolders++;
        deepFolders++;
        _calculateCounts(child);
        deepFiles += child.deepFileCount;
        deepFolders += child.deepFolderCount;
      } else {
        subFiles++;
        deepFiles++;
      }
    }

    node.subFileCount = subFiles;
    node.subFolderCount = subFolders;
    node.deepFileCount = deepFiles;
    node.deepFolderCount = deepFolders;
  }
}
