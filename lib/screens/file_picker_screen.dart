import 'dart:isolate';

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';

import '../models/node.dart';
import '../services/mlocate_db_parser.dart';

void _parseIsolateEntry(Map<String, dynamic> args) {
  SendPort sendPort = args['sendPort'];
  String filePath = args['filePath'];

  var parser = MlocateDBParser(filePath);
  parser.parse();
  sendPort.send(parser.rootNode);
}

enum SortOption { nameAsc, nameDesc, typeDirFirst, typeFileFirst }

class FilePickerScreen extends StatefulWidget {
  const FilePickerScreen({super.key});

  @override
  State<FilePickerScreen> createState() => _FilePickerScreenState();
}

class _FilePickerScreenState extends State<FilePickerScreen> {
  String? filePath;
  String _searchQuery = '';
  SortOption _sortOption = SortOption.typeDirFirst;
  final TextEditingController _searchController = TextEditingController();
  Node? rootNode;
  bool _isLoading = false;
  Isolate? _isolate;

  final List<Node> _navigationStack = [];

  ReceivePort? _receivePort;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _pickFile() async {
    var result = await FilePicker.platform.pickFiles();
    if (result != null) {
      setState(() {
        filePath = result.files.single.path;
        _isLoading = true;
      });

      _receivePort = ReceivePort();
      _isolate = await Isolate.spawn(_parseIsolateEntry, {
        'sendPort': _receivePort!.sendPort,
        'filePath': filePath!,
      });

      _receivePort!.listen((message) {
        setState(() {
          rootNode = message as Node?;
          if (rootNode != null) {
            _navigationStack.clear();
            _navigationStack.add(rootNode!);
          }
          _isLoading = false;
          _searchQuery = '';
          _searchController.text = '';
        });
        _receivePort?.close();
        _receivePort = null;
        _isolate?.kill(priority: Isolate.immediate);
        _isolate = null;
      });
    }
  }

  void _cancelLoading() {
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _receivePort?.close();
    _receivePort = null;
    setState(() {
      _isLoading = false;
    });
  }

  void _navigateUp() {
    if (_navigationStack.length > 1) {
      setState(() {
        _navigationStack.removeLast();
        _searchQuery = '';
        _searchController.text = '';
      });
    }
  }

  void _navigateTo(Node node) {
    if (node.isDir) {
      setState(() {
        _navigationStack.add(node);
        _searchQuery = '';
        _searchController.text = '';
      });
    }
  }

  Future<void> _exportDirectory(Node node) async {
    final savePath = await FilePicker.platform.saveFile(
      dialogTitle: 'Export Directory',
      fileName: 'directory_export.txt',
    );

    if (savePath != null) {
      final buffer = StringBuffer();
      for (final child in node.children) {
        buffer.writeln(child.key);
      }
      await File(savePath).writeAsString(buffer.toString());
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Exported to $savePath')),
        );
      }
    }
  }

  void _collectTree(Node node, StringBuffer buffer) {
    buffer.writeln(node.key);
    for (final child in node.children) {
      _collectTree(child, buffer);
    }
  }

  Future<void> _exportDirectoryTree(Node node) async {
    final savePath = await FilePicker.platform.saveFile(
      dialogTitle: 'Export Directory Tree',
      fileName: 'directory_tree_export.txt',
    );

    if (savePath != null) {
      final buffer = StringBuffer();
      for (final child in node.children) {
        _collectTree(child, buffer);
      }
      await File(savePath).writeAsString(buffer.toString());
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Exported tree to $savePath')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final currentNode = _navigationStack.isNotEmpty ? _navigationStack.last : null;

    List<Node> displayedChildren = [];
    if (currentNode != null) {
      displayedChildren = currentNode.children.where((node) {
        return node.label.toLowerCase().contains(_searchQuery.toLowerCase());
      }).toList();

      displayedChildren.sort((a, b) {
        switch (_sortOption) {
          case SortOption.nameAsc:
            return a.label.compareTo(b.label);
          case SortOption.nameDesc:
            return b.label.compareTo(a.label);
          case SortOption.typeDirFirst:
            if (a.isDir && !b.isDir) return -1;
            if (!a.isDir && b.isDir) return 1;
            return a.label.compareTo(b.label);
          case SortOption.typeFileFirst:
            if (a.isDir && !b.isDir) return 1;
            if (!a.isDir && b.isDir) return -1;
            return a.label.compareTo(b.label);
        }
      });
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('mlocate DB Explorer'),
        leading: _navigationStack.length > 1
            ? IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: _navigateUp,
              )
            : null,
        actions: [
          if (currentNode != null)
            PopupMenuButton<String>(
              onSelected: (value) {
                if (value == 'export_dir') {
                  _exportDirectory(currentNode);
                } else if (value == 'export_tree') {
                  _exportDirectoryTree(currentNode);
                }
              },
              itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
                const PopupMenuItem<String>(
                  value: 'export_dir',
                  child: Text('Export Directory'),
                ),
                const PopupMenuItem<String>(
                  value: 'export_tree',
                  child: Text('Export Directory Tree'),
                ),
              ],
            ),
        ],
      ),
      body: Column(
        children: [
          if (currentNode != null)
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: Text(
                'Current Path: ${currentNode.key}',
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
              ),
            ),
          if (currentNode != null && !_isLoading)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _searchController,
                      decoration: const InputDecoration(
                        prefixIcon: Icon(Icons.search),
                        hintText: 'Filter...',
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                      onChanged: (value) {
                        setState(() {
                          _searchQuery = value;
                        });
                      },
                    ),
                  ),
                  const SizedBox(width: 8.0),
                  DropdownButton<SortOption>(
                    value: _sortOption,
                    onChanged: (SortOption? newValue) {
                      if (newValue != null) {
                        setState(() {
                          _sortOption = newValue;
                        });
                      }
                    },
                    items: const [
                      DropdownMenuItem(
                        value: SortOption.nameAsc,
                        child: Text('Name (A-Z)'),
                      ),
                      DropdownMenuItem(
                        value: SortOption.nameDesc,
                        child: Text('Name (Z-A)'),
                      ),
                      DropdownMenuItem(
                        value: SortOption.typeDirFirst,
                        child: Text('Dirs First'),
                      ),
                      DropdownMenuItem(
                        value: SortOption.typeFileFirst,
                        child: Text('Files First'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          Expanded(
            child: Center(
              child: _isLoading
                  ? Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const CircularProgressIndicator(),
                        const SizedBox(height: 20),
                        ElevatedButton(
                          onPressed: _cancelLoading,
                          child: const Text('Cancel'),
                        ),
                      ],
                    )
                  : currentNode == null
                      ? ElevatedButton(
                          onPressed: _pickFile,
                          child: const Text('Pick mlocate.db File'),
                        )
                      : ListView.builder(
                          itemCount: displayedChildren.length,
                          itemBuilder: (context, index) {
                            final node = displayedChildren[index];
                            return ListTile(
                              leading: Icon(
                                node.isDir ? Icons.folder : Icons.insert_drive_file,
                                color: node.isDir ? Colors.blue : Colors.grey,
                              ),
                              title: Text(node.label),
                              subtitle: node.modifiedTime != null
                                  ? Text('Modified: ${node.modifiedTime!.toLocal().toString()}')
                                  : null,
                              onTap: () => _navigateTo(node),
                            );
                          },
                        ),
            ),
          ),
        ],
      ),
    );
  }
}
