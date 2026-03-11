import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../models/node.dart';

class MlocateDBParser {
  Uint8List magicNumber = Uint8List.fromList('\x00mlocate'.codeUnits);

  final String filePath;
  late RandomAccessFile file;
  Node? rootNode;

  // Maps a full path to its corresponding Node for O(1) lookups
  final Map<String, Node> _nodeMap = {};
  final List<String> errors = [];
  int _nodeCounter = 0;

  MlocateDBParser(this.filePath);

  void parse() {
    file = File(filePath).openSync();
    _parseFileHeader();
    _parseDirectories();
    if (rootNode != null) {
      _calculateCounts(rootNode!);
    }
    file.closeSync();
  }

  void _calculateCounts(Node node) {
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

  bool compareUint8Lists(Uint8List list1, Uint8List list2) {
    // Check if lists have same length
    if (list1.length != list2.length) {
      return false;
    }

    // Compare each element of the lists
    for (int i = 0; i < list1.length; i++) {
      if (list1[i] != list2[i]) {
        return false;
      }
    }

    // Lists are equal
    return true;
  }

  void _parseFileHeader() {
    var header = Uint8List.fromList(file.readSync(8));
    if (!compareUint8Lists(header, magicNumber)) {
      errors.add('Invalid magic number');
    }

    var configBlockSizeBytes = file.readSync(4);
    var configBlockSize =
        _bytesToInt32(configBlockSizeBytes, endian: Endian.big);

    file.readByteSync(); // formatVersion
    file.readByteSync(); // requireVisibilityFlag
    file.readSync(2); // padding

    // DEBUG:
    var rootPath = _readNullTerminatedString();
    rootNode = Node(key: rootPath, label: rootPath, children: [], isDir: true, mlocateIndex: _nodeCounter++);
    _nodeMap[rootPath] = rootNode!;

    _parseConfigurationBlock(configBlockSize);
  }

  // Helper to find a node by its full path from the root
  Node? _findNodeByPath(String path) {
    if (rootNode == null) return null;
    if (rootNode!.key == path || path == '/') return rootNode;

    return _nodeMap[path];
  }

  void _parseConfigurationBlock(int configBlockSize) {
    var configBlockData = file.readSync(configBlockSize);

    var configBlock = utf8.decode(configBlockData);
    var configVariables = configBlock.split('\x00');

    var variables = {};
    String? currentVar;
    for (var value in configVariables) {
      if (currentVar == null) {
        currentVar = value;
      } else {
        variables[currentVar] = value;
        currentVar = null;
      }
    }
  }

  void _parseDirectories() {
    while (true) {
      try {
        var secBytes = Uint8List.fromList(file.readSync(8)); // dirTimeSecBytes
        if (secBytes.length < 8) break; // EOF reached

        var modifiedTimeSeconds = _bytesToInt64(secBytes, endian: Endian.big);
        var modifiedTime = DateTime.fromMillisecondsSinceEpoch(modifiedTimeSeconds * 1000, isUtc: true);

        file.readSync(4); // dirTimeNanoBytes
        file.readSync(4); // padding

        var dirPath = _readNullTerminatedString();

        // Find existing node or create one
        var directoryNode = _findNodeByPath(dirPath);
        if (directoryNode == null) {
          // If we haven't seen this directory yet, create it and attach it to its parent
          var parentPath = _getParentPath(dirPath);
          var parentNode = _findNodeByPath(parentPath);

          directoryNode = Node(key: dirPath, label: _getLabel(dirPath), children: [], isDir: true, modifiedTime: modifiedTime, mlocateIndex: _nodeCounter++);
          _nodeMap[dirPath] = directoryNode;

          if (parentNode != null) {
            parentNode.children.add(directoryNode);
          } else {
            // Fallback: attach to root if parent is mysteriously missing
            errors.add('Missing parent node for directory: $dirPath');
            rootNode!.children.add(directoryNode);
          }
        } else {
          directoryNode.isDir = true;
          directoryNode.modifiedTime = modifiedTime;
        }

        _parseDirectoryContents(directoryNode, dirPath);
      } catch (e) {
        errors.add('Error parsing directories: $e');
        break;
      }
    }
  }

  void _parseDirectoryContents(
      Node parentNode, String parentPath) {
    while (true) {
      var entryType = file.readByteSync();
      if (entryType == 2 || entryType == -1) break; // End of current directory or EOF

      var fileName = _readNullTerminatedString();

      var fullPath = parentPath == '/' ? '/$fileName' : '$parentPath/$fileName';
      var entryNode = Node(key: fullPath, label: fileName, children: [], isDir: entryType == 1, mlocateIndex: _nodeCounter++);
      parentNode.children.add(entryNode);

      // We do NOT recurse here. The spec says mlocate.db is just a
      // list of directories. The subdirectories will be defined in their
      // own directory header later in the file.
      if (entryType == 1) {
        // If it's a subdirectory, register it in the map so we can find it
        // when its directory header is encountered later.
        _nodeMap[fullPath] = entryNode;
      }
    }
  }

  String _getParentPath(String path) {
    if (path == '/') return '/';
    var lastSlash = path.lastIndexOf('/');
    if (lastSlash == 0) return '/';
    if (lastSlash == -1) return '/'; // Shouldn't happen for absolute paths
    return path.substring(0, lastSlash);
  }

  String _getLabel(String path) {
    if (path == '/') return '/';
    var lastSlash = path.lastIndexOf('/');
    if (lastSlash == -1) return path;
    return path.substring(lastSlash + 1);
  }

  String _readNullTerminatedString() {
    var bytes = <int>[];
    while (true) {
      var byte = file.readByteSync();
      if (byte == -1) break; // EOF
      if (byte == 0) break;
      bytes.add(byte);
    }
    return utf8.decode(Uint8List.fromList(bytes));
  }

  int _bytesToInt32(Uint8List bytes, {Endian endian = Endian.big}) {
    if (bytes.length < 4) return 0;
    var buffer = ByteData.sublistView(bytes);
    return buffer.getInt32(0, endian);
  }

  int _bytesToInt64(Uint8List bytes, {Endian endian = Endian.big}) {
    if (bytes.length < 8) return 0;
    var buffer = ByteData.sublistView(bytes);
    return buffer.getInt64(0, endian);
  }
}
