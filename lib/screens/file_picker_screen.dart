import 'dart:isolate';

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

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
  final List<int> _indexStack = [];
  int _selectedIndex = 0;

  final ItemScrollController _itemScrollController = ItemScrollController();
  final FocusNode _focusNode = FocusNode();

  ReceivePort? _receivePort;

  @override
  void dispose() {
    _focusNode.dispose();
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

  void _scrollToSelected() {
    if (_itemScrollController.isAttached) {
      _itemScrollController.scrollTo(
        index: _selectedIndex,
        duration: const Duration(milliseconds: 100),
        alignment: 0.5,
      );
    }
  }

  void _navigateUp() {
    if (_navigationStack.length > 1) {
      setState(() {
        _navigationStack.removeLast();
        if (_indexStack.isNotEmpty) {
          _selectedIndex = _indexStack.removeLast();
        } else {
          _selectedIndex = 0;
        }
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollToSelected();
      });
    }
  }

  void _navigateTo(Node node) {
    if (node.isDir) {
      setState(() {
        _navigationStack.add(node);
        _indexStack.add(_selectedIndex);
        _selectedIndex = 0;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollToSelected();
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
                      : Focus(
                          autofocus: true,
                          focusNode: _focusNode,
                          onKeyEvent: (FocusNode node, KeyEvent event) {
                            if (event is KeyDownEvent || event is KeyRepeatEvent) {
                              final int maxIndex = currentNode.children.length - 1;
                              if (maxIndex < 0) return KeyEventResult.ignored;

                              if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
                                setState(() {
                                  _selectedIndex = (_selectedIndex + 1).clamp(0, maxIndex);
                                });
                                _scrollToSelected();
                                return KeyEventResult.handled;
                              } else if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
                                setState(() {
                                  _selectedIndex = (_selectedIndex - 1).clamp(0, maxIndex);
                                });
                                _scrollToSelected();
                                return KeyEventResult.handled;
                              } else if (event.logicalKey == LogicalKeyboardKey.pageDown) {
                                setState(() {
                                  _selectedIndex = (_selectedIndex + 10).clamp(0, maxIndex);
                                });
                                _scrollToSelected();
                                return KeyEventResult.handled;
                              } else if (event.logicalKey == LogicalKeyboardKey.pageUp) {
                                setState(() {
                                  _selectedIndex = (_selectedIndex - 10).clamp(0, maxIndex);
                                });
                                _scrollToSelected();
                                return KeyEventResult.handled;
                              } else if (event.logicalKey == LogicalKeyboardKey.home) {
                                setState(() {
                                  _selectedIndex = 0;
                                });
                                _scrollToSelected();
                                return KeyEventResult.handled;
                              } else if (event.logicalKey == LogicalKeyboardKey.end) {
                                setState(() {
                                  _selectedIndex = maxIndex;
                                });
                                _scrollToSelected();
                                return KeyEventResult.handled;
                              } else if (event.logicalKey == LogicalKeyboardKey.arrowRight ||
                                         event.logicalKey == LogicalKeyboardKey.enter) {
                                final selectedNode = currentNode.children[_selectedIndex];
                                if (selectedNode.isDir) {
                                  _navigateTo(selectedNode);
                                }
                                return KeyEventResult.handled;
                              } else if (event.logicalKey == LogicalKeyboardKey.arrowLeft ||
                                         event.logicalKey == LogicalKeyboardKey.backspace) {
                                _navigateUp();
                                return KeyEventResult.handled;
                              }
                            }
                            return KeyEventResult.ignored;
                          },
                          child: ScrollablePositionedList.builder(
                            itemScrollController: _itemScrollController,
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
                                selected: index == _selectedIndex,
                                onTap: () {
                                  setState(() {
                                    _selectedIndex = index;
                                  });
                                  _navigateTo(node);
                                  _focusNode.requestFocus();
                                },
                              );
                            },
                          ),
                        ),
            ),
          ),
        ],
      ),
    );
  }
}
