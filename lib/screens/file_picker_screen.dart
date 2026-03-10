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

class FilePickerScreen extends StatefulWidget {
  const FilePickerScreen({super.key});

  @override
  State<FilePickerScreen> createState() => _FilePickerScreenState();
}

class _FilePickerScreenState extends State<FilePickerScreen> {
  String? filePath;
  Node? rootNode;
  bool _isLoading = false;
  Isolate? _isolate;

  final List<Node> _navigationStack = [];

  ReceivePort? _receivePort;

  final TextEditingController _pathController = TextEditingController();

  @override
  void dispose() {
    _pathController.dispose();
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
            _pathController.text = rootNode!.key;
          }
          _isLoading = false;
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
        _pathController.text = _navigationStack.last.key;
      });
    }
  }

  void _navigateTo(Node node) {
    if (node.isDir) {
      setState(() {
        _navigationStack.add(node);
        _pathController.text = node.key;
      });
    }
  }

  List<Node>? _findStackToPath(Node current, String targetPath, List<Node> currentStack) {
    currentStack.add(current);

    if (current.key == targetPath) {
      return currentStack;
    }

    if (targetPath.startsWith(current.key == '/' ? current.key : '${current.key}/')) {
      for (final child in current.children) {
        if (child.isDir) {
          final result = _findStackToPath(child, targetPath, List.from(currentStack));
          if (result != null) {
            return result;
          }
        }
      }
    }

    return null;
  }

  void _onPathSubmitted(String submittedPath) {
    if (rootNode == null) return;

    var path = submittedPath.trim();
    if (path.isEmpty) {
       setState(() {
        _pathController.text = _navigationStack.last.key;
      });
      return;
    }
    if (path.length > 1 && path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }

    final newStack = _findStackToPath(rootNode!, path, []);

    if (newStack != null) {
      setState(() {
        _navigationStack.clear();
        _navigationStack.addAll(newStack);
        _pathController.text = path;
      });
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Path not found or is not a directory: $path')),
      );
      setState(() {
        _pathController.text = _navigationStack.last.key;
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
              child: Row(
                children: [
                  const Text(
                    'Current Path: ',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                  ),
                  Expanded(
                    child: TextField(
                      controller: _pathController,
                      onSubmitted: _onPathSubmitted,
                      decoration: const InputDecoration(
                        isDense: true,
                        contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                        border: OutlineInputBorder(),
                      ),
                    ),
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
                          itemCount: currentNode.children.length,
                          itemBuilder: (context, index) {
                            final node = currentNode.children[index];
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
