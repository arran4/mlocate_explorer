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
  sendPort.send({
    'rootNode': parser.rootNode,
    'errors': parser.errors,
  });
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
  final ScrollController _scrollController = ScrollController();
  final Map<String, double> _scrollPositions = {};

  ReceivePort? _receivePort;

  List<String> _parseErrors = [];

  ReceivePort? _receivePort;

  final TextEditingController _pathController = TextEditingController();

  @override
  void dispose() {
    _pathController.dispose();
    _searchController.dispose();
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
            _pathController.text = rootNode!.key;
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
      final currentNode = _navigationStack.last;
      _scrollPositions[currentNode.key] = 0.0; // Reset scroll for current node when navigating up
      setState(() {
        _navigationStack.removeLast();
        _searchQuery = '';
        _searchController.text = '';
        _pathController.text = _navigationStack.last.key;
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
        _searchQuery = '';
        _searchController.text = '';
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
                                dense: true,
                                visualDensity: const VisualDensity(horizontal: 0, vertical: -4),
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
