import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../models/node.dart';

class MlocateDBParser {
  Uint8List magicNumber = Uint8List.fromList('\x00mlocate'.codeUnits);

  final String filePath;
  late RandomAccessFile file;
  Node? rootNode;

  MlocateDBParser(this.filePath);

  void parse() {
    file = File(filePath).openSync();
    _parseFileHeader();
    _parseDirectories();
    file.closeSync();
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
      throw const FormatException('Invalid magic number');
    }

    var configBlockSizeBytes = file.readSync(4);
    var configBlockSize =
        _bytesToInt32(configBlockSizeBytes, endian: Endian.big);

    file.readByteSync(); // formatVersion
    file.readByteSync(); // requireVisibilityFlag
    file.readSync(2); // padding

    // DEBUG:
    var rootPath = _readNullTerminatedString();
    rootNode = Node(key: rootPath, label: rootPath, children: []);

    _parseConfigurationBlock(configBlockSize);
  }

  // Helper to find a node by its full path from the root
  Node? _findNodeByPath(String path) {
    if (rootNode == null) return null;
    if (rootNode!.key == path || path == '/') return rootNode;

    // A simple linear search for now, assuming the directories
    // were added to rootNode's children (or we can flatten the structure).
    // The previous implementation added flat directories directly to rootNode!.children
    for (var node in rootNode!.children) {
      if (node.key == path) return node;
    }
    return null;
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
        var secBytes = file.readSync(8); // dirTimeSecBytes
        if (secBytes.length < 8) break; // EOF reached

        file.readSync(4); // dirTimeNanoBytes
        file.readSync(4); // padding

        var dirPath = _readNullTerminatedString();

        // Find existing node or create one
        var directoryNode = _findNodeByPath(dirPath);
        if (directoryNode == null) {
          directoryNode = Node(key: dirPath, label: dirPath, children: []);
          rootNode!.children.add(directoryNode);
        }

        _parseDirectoryContents(directoryNode, dirPath);
      } catch (e) {
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
      var entryNode = Node(key: fullPath, label: fileName, children: []);
      parentNode.children.add(entryNode);

      // We do NOT recurse here. The spec says mlocate.db is just a
      // list of directories. The subdirectories will be defined in their
      // own directory header later in the file.
      if (entryType == 1) {
        // If it's a subdirectory, we can pre-add it to the root's list of
        // directories so it can just be found later, or we let the next
        // header create it if it doesn't exist.
        rootNode!.children.add(entryNode);
      }
    }
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
}
