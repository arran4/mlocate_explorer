import 'dart:isolate';

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
  final ScrollController _scrollController = ScrollController();
  final Map<String, double> _scrollPositions = {};

  ReceivePort? _receivePort;

  @override
  void dispose() {
    _scrollController.dispose();
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
      final currentNode = _navigationStack.last;
      _scrollPositions[currentNode.key] = 0.0; // Reset scroll for current node when navigating up
      setState(() {
        _navigationStack.removeLast();
      });

      final parentNode = _navigationStack.last;
      final savedScrollPosition = _scrollPositions[parentNode.key] ?? 0.0;

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollController.hasClients) {
          _scrollController.jumpTo(savedScrollPosition);
        }
      });
    }
  }

  void _navigateTo(Node node) {
    if (node.isDir) {
      node.isOpened = true;
      final currentNode = _navigationStack.last;
      if (_scrollController.hasClients) {
        _scrollPositions[currentNode.key] = _scrollController.offset;
      }
      setState(() {
        _navigationStack.add(node);
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollController.hasClients) {
          _scrollController.jumpTo(0.0);
        }
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
                          controller: _scrollController,
                          itemCount: currentNode.children.length,
                          itemBuilder: (context, index) {
                            final node = currentNode.children[index];
                            final isUnvisitedFolder = node.isDir && !node.isOpened;
                            return GestureDetector(
                              onSecondaryTapDown: (TapDownDetails details) {
                                showMenu(
                                  context: context,
                                  position: RelativeRect.fromLTRB(
                                    details.globalPosition.dx,
                                    details.globalPosition.dy,
                                    details.globalPosition.dx,
                                    details.globalPosition.dy,
                                  ),
                                  items: [
                                    PopupMenuItem(
                                      value: 'toggle_opened',
                                      child: Text(node.isOpened ? 'Mark as Unopened' : 'Mark as Opened'),
                                    ),
                                    const PopupMenuItem(
                                      value: 'copy_path',
                                      child: Text('Copy Full Path'),
                                    ),
                                  ],
                                ).then((value) {
                                  if (value == 'toggle_opened') {
                                    setState(() {
                                      node.isOpened = !node.isOpened;
                                    });
                                  } else if (value == 'copy_path') {
                                    Clipboard.setData(ClipboardData(text: node.key));
                                    if (context.mounted) {
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        const SnackBar(content: Text('Copied path to clipboard')),
                                      );
                                    }
                                  }
                                });
                              },
                              child: ListTile(
                                leading: Icon(
                                  node.isDir ? Icons.folder : Icons.insert_drive_file,
                                  color: node.isDir ? Colors.blue : Colors.grey,
                                ),
                                title: Text(
                                  node.label,
                                  style: TextStyle(
                                    fontWeight: isUnvisitedFolder ? FontWeight.bold : FontWeight.normal,
                                  ),
                                ),
                                subtitle: node.modifiedTime != null
                                    ? Text('Modified: ${node.modifiedTime!.toLocal().toString()}')
                                    : null,
                                onTap: () => _navigateTo(node),
                              ),
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
