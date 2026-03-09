import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_treeview/flutter_treeview.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'mlocate DB Explorer',
      theme: ThemeData(
        primarySwatch: Colors.blue,
      ),
      home: const FilePickerScreen(),
    );
  }
}

class FilePickerScreen extends StatefulWidget {
  const FilePickerScreen({super.key});

  @override
  State<FilePickerScreen> createState() => _FilePickerScreenState();
}

class _FilePickerScreenState extends State<FilePickerScreen> {
  String? filePath;
  Node? rootNode;

  Future<void> _pickFile() async {
    var result = await FilePicker.platform.pickFiles();
    if (result != null) {
      filePath = result.files.single.path;
      var parser = MlocateDBParser(filePath!);
      await parser.parse();
      setState(() {
        rootNode = parser.rootNode;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('mlocate DB Explorer'),
      ),
      body: Center(
        child: rootNode == null
            ? ElevatedButton(
                onPressed: _pickFile,
                child: const Text('Pick mlocate.db File'),
              )
            : TreeView(
                controller: TreeViewController(
                  children: [rootNode!],
                  selectedKey: rootNode!.key,
                ),
                shrinkWrap: true,
                theme: TreeViewTheme(
                  expanderTheme: const ExpanderThemeData(
                    type: ExpanderType.caret,
                    modifier: ExpanderModifier.none,
                    position: ExpanderPosition.start,
                    color: Colors.blue,
                    size: 20,
                  ),
                  labelStyle: const TextStyle(
                    fontSize: 16,
                    letterSpacing: 0.3,
                  ),
                  parentLabelStyle: TextStyle(
                    fontSize: 16,
                    letterSpacing: 0.3,
                    fontWeight: FontWeight.w800,
                    color: Colors.blue.shade700,
                  ),
                  iconTheme: IconThemeData(
                    size: 18,
                    color: Colors.grey.shade800,
                  ),
                  colorScheme: Theme.of(context).colorScheme,
                ),
              ),
      ),
    );
  }
}

class MlocateDBParser {
  Uint8List magicNumber = Uint8List.fromList('\x00mlocate'.codeUnits);

  final String filePath;
  late RandomAccessFile file;
  Node? rootNode;

  MlocateDBParser(this.filePath);

  Future<void> parse() async {
    file = await File(filePath).open();
    await _parseFileHeader();
    await _parseDirectories();
    await file.close();
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

  Future<void> _parseFileHeader() async {
    var header = Uint8List.fromList(await file.read(8));
    if (!compareUint8Lists(header, magicNumber)) {
      throw const FormatException('Invalid magic number');
    }

    var configBlockSizeBytes = await file.read(4);
    var configBlockSize =
        _bytesToInt32(configBlockSizeBytes, endian: Endian.big);

    await file.readByte(); // formatVersion
    await file.readByte(); // requireVisibilityFlag
    await file.read(2); // padding

    await _parseConfigurationBlock(configBlockSize);

    var rootPath = await _readNullTerminatedString();
    rootNode = Node(key: rootPath, label: rootPath, children: []);
  }

  Future<void> _parseConfigurationBlock(int configBlockSize) async {
    var configBlockData = await file.read(configBlockSize);

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

  Future<void> _parseDirectories() async {
    while (true) {
      try {
        await file.read(8); // dirTimeSecBytes
        await file.read(4); // dirTimeNanoBytes

        await file.read(4); // padding

        var dirPath = await _readNullTerminatedString();
        var directoryNode = Node(key: dirPath, label: dirPath, children: []);
        rootNode!.children.add(directoryNode);

        await _parseDirectoryContents(directoryNode);
      } catch (e) {
        break;
      }
    }
  }

  Future<void> _parseDirectoryContents(Node parentNode) async {
    while (true) {
      var entryType = await file.readByte();
      if (entryType == 2) break; // End of current directory

      var fileName = await _readNullTerminatedString();
      var entryNode = Node(key: fileName, label: fileName, children: []);

      if (entryType == 1) {
        await _parseDirectoryContents(entryNode);
      }

      parentNode.children.add(entryNode);
    }
  }

  Future<String> _readNullTerminatedString() async {
    var bytes = <int>[];
    while (true) {
      var byte = await file.readByte();
      if (byte == 0) break;
      bytes.add(byte);
    }
    return utf8.decode(Uint8List.fromList(bytes));
  }

  int _bytesToInt32(Uint8List bytes, {Endian endian = Endian.big}) {
    var buffer = ByteData.sublistView(bytes);
    return buffer.getInt32(0, endian);
  }
}
