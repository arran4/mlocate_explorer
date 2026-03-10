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
  sendPort.send({
    'rootNode': parser.rootNode,
    'errors': parser.errors,
  });
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
  List<String> _parseErrors = [];

  ReceivePort? _receivePort;

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
          if (message is Map<String, dynamic>) {
            rootNode = message['rootNode'] as Node?;
            _parseErrors = List<String>.from(message['errors'] ?? []);
          } else {
            rootNode = message as Node?;
            _parseErrors = [];
          }

          if (rootNode != null) {
            _navigationStack.clear();
            _navigationStack.add(rootNode!);
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
      });
    }
  }

  void _navigateTo(Node node) {
    if (node.isDir) {
      setState(() {
        _navigationStack.add(node);
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

  void _showErrorsDialog() {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Parsing Errors & Inconsistencies'),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: _parseErrors.length,
              itemBuilder: (context, index) {
                return ListTile(
                  leading: const Icon(Icons.error, color: Colors.red),
                  title: Text(_parseErrors[index]),
                );
              },
            ),
          ),
          actions: <Widget>[
            TextButton(
              child: const Text('Close'),
              onPressed: () {
                Navigator.of(context).pop();
              },
            ),
          ],
        );
      },
    );
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
          if (_parseErrors.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.warning, color: Colors.orange),
              onPressed: _showErrorsDialog,
              tooltip: 'Show Parsing Errors',
            ),
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
