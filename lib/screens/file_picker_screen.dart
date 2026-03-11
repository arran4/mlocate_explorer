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

  var parser = MlocateDBParser(
    filePath,
    onProgress: (progress, status) {
      sendPort.send({
        'type': 'progress',
        'progress': progress,
        'status': status,
      });
    },
  );
  parser.parse();
  sendPort.send({
    'type': 'done',
    'rootNode': parser.rootNode,
    'errors': parser.errors,
  });
}

enum GroupOption { dirsFirst, filesFirst, none }

enum SortOption { nameAsc, nameDesc, modifiedAsc, modifiedDesc, mlocateOrder }

class FilePickerScreen extends StatefulWidget {
  const FilePickerScreen({super.key});

  @override
  State<FilePickerScreen> createState() => _FilePickerScreenState();
}

class _FilePickerScreenState extends State<FilePickerScreen> {
  String? filePath;
  String _searchQuery = '';
  GroupOption _groupOption = GroupOption.dirsFirst;
  SortOption _sortOption = SortOption.nameAsc;
  final TextEditingController _searchController = TextEditingController();
  Node? rootNode;
  bool _isLoading = false;
  double? _loadingProgress;
  String? _loadingStatus;
  Isolate? _isolate;

  final List<Node> _navigationStack = [];
  final ScrollController _scrollController = ScrollController();
  final Map<String, double> _scrollPositions = {};
  int _selectedIndex = 0;

  ReceivePort? _receivePort;

  List<Map<String, dynamic>> _parseErrors = [];

  final TextEditingController _pathController = TextEditingController();

  // Locate state
  bool _isLocateMode = false;
  final TextEditingController _locateController = TextEditingController();

  // Hidden files toggle
  bool _showHiddenFiles = false;
  List<Node> _locateResults = [];
  bool _isLocating = false;
  bool _cancelLocateRequested = false;

  @override
  void dispose() {
    _pathController.dispose();
    _searchController.dispose();
    _scrollController.dispose();
    _locateController.dispose();
    super.dispose();
  }

  Future<void> _pickFile() async {
    var result = await FilePicker.platform.pickFiles();
    if (result != null) {
      setState(() {
        filePath = result.files.single.path;
        _isLoading = true;
        _loadingProgress = null;
        _loadingStatus = 'Opening...';
      });

      _parseDatabase();
    }
  }

  void _closeDatabase() {
    setState(() {
      rootNode = null;
      _navigationStack.clear();
      filePath = null;
      _searchQuery = '';
      _searchController.text = '';
      _pathController.text = '';
      _parseErrors.clear();
      _selectedIndex = 0;

      _isLocateMode = false;
      _locateController.text = '';
      _locateResults.clear();
    });
  }

  void _cancelLocate() {
    setState(() {
      _cancelLocateRequested = true;
      _isLocating = false;
    });
  }

  Future<void> _performLocate(String query) async {
    if (rootNode == null) return;
    if (_isLocating) return;

    query = query.trim().toLowerCase();

    setState(() {
      _isLocateMode = true;
      _locateResults.clear();
      _isLocating = true;
      _cancelLocateRequested = false;
      _selectedIndex = 0;
    });

    if (query.isEmpty) {
      setState(() {
        _isLocating = false;
      });
      return;
    }

    List<Node> results = [];
    List<Node> queue = [rootNode!];
    int iterations = 0;

    while (queue.isNotEmpty) {
      if (_cancelLocateRequested) {
        break;
      }

      Node current = queue.removeLast();

      if (!_showHiddenFiles && current != rootNode) {
        if (current.label.isNotEmpty &&
            current.label.startsWith('.') &&
            current.label != '.' &&
            current.label != '..') {
          continue;
        }
      }

      // Basic locate logic: full path contains query string case-insensitively
      if (current.key.toLowerCase().contains(query)) {
        results.add(current);
      }

      // Iterate backwards to process children in correct order when popping from end
      for (int i = current.children.length - 1; i >= 0; i--) {
        queue.add(current.children[i]);
      }

      iterations++;
      // Yield to the event loop every 10000 iterations to avoid blocking UI thread
      if (iterations % 10000 == 0) {
        if (mounted) {
          setState(() {
            _locateResults = List.from(results);
          });
        }
        await Future.delayed(Duration.zero);
      }
    }

    if (mounted) {
      setState(() {
        if (!_cancelLocateRequested) {
          _locateResults = results;
        }
        _isLocating = false;
      });
    }
  }

  void _reloadDatabase() {
    if (filePath != null) {
      setState(() {
        _isLoading = true;
        _loadingProgress = null;
        _loadingStatus = 'Reloading...';
        _navigationStack.clear();
        _pathController.text = '';
        _selectedIndex = 0;
      });
      _parseDatabase();
    }
  }

  Future<void> _parseDatabase() async {
    if (filePath == null) return;

    _receivePort = ReceivePort();
    _isolate = await Isolate.spawn(_parseIsolateEntry, {
      'sendPort': _receivePort!.sendPort,
      'filePath': filePath!,
    });

    _receivePort!.listen((message) {
      if (message is Map<String, dynamic>) {
        if (message['type'] == 'progress') {
          setState(() {
            _loadingProgress = message['progress'] as double?;
            _loadingStatus = message['status'] as String?;
          });
          return;
        } else if (message['type'] == 'done') {
          setState(() {
            rootNode = message['rootNode'] as Node?;
            _parseErrors = List<Map<String, dynamic>>.from(
              message['errors'] ?? [],
            );

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
          return;
        }
      }

      // Fallback for unexpected messages (shouldn't happen with current protocol)
      setState(() {
        if (message is Map<String, dynamic>) {
          rootNode = message['rootNode'] as Node?;
          _parseErrors = List<Map<String, dynamic>>.from(
            message['errors'] ?? [],
          );
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
      _scrollPositions[currentNode.key] =
          0.0; // Reset scroll for current node when navigating up
      setState(() {
        _navigationStack.removeLast();
        _searchQuery = '';
        _searchController.text = '';
        _pathController.text = _navigationStack.last.key;
        _selectedIndex = 0;
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
        _selectedIndex = 0;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollController.hasClients) {
          _scrollController.jumpTo(0.0);
        }
      });
    }
  }

  List<Node>? _findStackToPath(
    Node current,
    String targetPath,
    List<Node> currentStack,
  ) {
    currentStack.add(current);

    if (current.key == targetPath) {
      return currentStack;
    }

    if (targetPath.startsWith(
      current.key == '/' ? current.key : '${current.key}/',
    )) {
      for (final child in current.children) {
        if (child.isDir) {
          final result = _findStackToPath(
            child,
            targetPath,
            List.from(currentStack),
          );
          if (result != null) {
            return result;
          }
        }
      }
    }

    return null;
  }

  void _jumpToLocateResult(Node node) {
    if (rootNode == null) return;

    // Switch out of locate mode
    setState(() {
      _isLocateMode = false;
    });

    // If it's a directory, we can jump straight to it.
    // If it's a file, we want to jump to its parent directory.
    String targetPath = node.isDir ? node.key : _getParentPath(node.key);

    // Use the same logic as path submission to jump
    final newStack = _findStackToPath(rootNode!, targetPath, []);

    if (newStack != null) {
      setState(() {
        _navigationStack.clear();
        _navigationStack.addAll(newStack);
        _pathController.text = targetPath;
        _selectedIndex = 0;

        // Optionally, if jumping to a file, set the search query to highlight/filter it
        if (!node.isDir) {
          _searchQuery = node.label;
          _searchController.text = node.label;
        } else {
          _searchQuery = '';
          _searchController.text = '';
        }
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollController.hasClients) {
          _scrollController.jumpTo(0.0);
        }
      });
    }
  }

  String _getParentPath(String path) {
    if (path == '/') return '/';
    var lastSlash = path.lastIndexOf('/');
    if (lastSlash == 0) return '/';
    if (lastSlash == -1) return '/'; // Shouldn't happen for absolute paths
    return path.substring(0, lastSlash);
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
        _selectedIndex = 0;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollController.hasClients) {
          _scrollController.jumpTo(0.0);
        }
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
        if (!_showHiddenFiles &&
            child.label.startsWith('.') &&
            child.label != '.' &&
            child.label != '..') {
          continue;
        }
        buffer.writeln(child.key);
      }
      await File(savePath).writeAsString(buffer.toString());
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Exported to $savePath')));
      }
    }
  }

  void _collectTree(Node node, StringBuffer buffer) {
    if (!_showHiddenFiles &&
        node.label.startsWith('.') &&
        node.label != '.' &&
        node.label != '..') {
      return;
    }
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
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Exported tree to $savePath')));
      }
    }
  }

  void _showErrorDetails(Map<String, dynamic> error) {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Error Details'),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Description: ${error['description']}'),
                Text(
                  'Offset: ${error['offset']} (${error['percentage'].toStringAsFixed(2)}%)',
                ),
                Text('Directory: ${error['directoryPath']}'),
                const SizedBox(height: 10),
                const Text('Hex Dump:'),
                Container(
                  padding: const EdgeInsets.all(8),
                  color: Colors.grey[200],
                  child: SelectableText(
                    error['hexDump'] ?? 'No hex dump available.',
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                Clipboard.setData(
                  ClipboardData(
                    text: 'Description: ${error['description']}\n'
                        'Offset: ${error['offset']} (${error['percentage'].toStringAsFixed(2)}%)\n'
                        'Directory: ${error['directoryPath']}\n\n'
                        'Hex Dump:\n${error['hexDump']}',
                  ),
                );
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Error details copied to clipboard'),
                  ),
                );
              },
              child: const Text('Copy to Clipboard'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Close'),
            ),
          ],
        );
      },
    );
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
                  title: Text(_parseErrors[index]['description']),
                  subtitle: Text(
                    'Offset: ${_parseErrors[index]['offset']} (${_parseErrors[index]['percentage'].toStringAsFixed(2)}%) in ${_parseErrors[index]['directoryPath']}',
                  ),
                  onTap: () => _showErrorDetails(_parseErrors[index]),
                  trailing: IconButton(
                    icon: const Icon(Icons.copy),
                    onPressed: () {
                      Clipboard.setData(
                        ClipboardData(
                          text:
                              'Description: ${_parseErrors[index]['description']}\n'
                              'Offset: ${_parseErrors[index]['offset']} (${_parseErrors[index]['percentage'].toStringAsFixed(2)}%)\n'
                              'Directory: ${_parseErrors[index]['directoryPath']}\n\n'
                              'Hex Dump:\n${_parseErrors[index]['hexDump']}',
                        ),
                      );
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Error details copied to clipboard'),
                        ),
                      );
                    },
                  ),
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
    final currentNode =
        _navigationStack.isNotEmpty ? _navigationStack.last : null;

    List<Node> displayedChildren = [];
    if (currentNode != null) {
      displayedChildren = currentNode.children.where((node) {
        if (!_showHiddenFiles &&
            node.label.startsWith('.') &&
            node.label != '.' &&
            node.label != '..') {
          return false;
        }
        return node.label.toLowerCase().contains(_searchQuery.toLowerCase());
      }).toList();

      displayedChildren.sort((a, b) {
        int groupCompare = 0;
        if (_groupOption == GroupOption.dirsFirst) {
          if (a.isDir && !b.isDir) {
            groupCompare = -1;
          } else if (!a.isDir && b.isDir) {
            groupCompare = 1;
          }
        } else if (_groupOption == GroupOption.filesFirst) {
          if (a.isDir && !b.isDir) {
            groupCompare = 1;
          } else if (!a.isDir && b.isDir) {
            groupCompare = -1;
          }
        }

        if (groupCompare != 0) return groupCompare;

        switch (_sortOption) {
          case SortOption.nameAsc:
            return a.label.compareTo(b.label);
          case SortOption.nameDesc:
            return b.label.compareTo(a.label);
          case SortOption.modifiedAsc:
            final aTime = a.modifiedTime?.millisecondsSinceEpoch ?? 0;
            final bTime = b.modifiedTime?.millisecondsSinceEpoch ?? 0;
            if (aTime == bTime) return a.label.compareTo(b.label);
            return aTime.compareTo(bTime);
          case SortOption.modifiedDesc:
            final aTime = a.modifiedTime?.millisecondsSinceEpoch ?? 0;
            final bTime = b.modifiedTime?.millisecondsSinceEpoch ?? 0;
            if (aTime == bTime) return a.label.compareTo(b.label);
            return bTime.compareTo(aTime);
          case SortOption.mlocateOrder:
            return a.mlocateIndex.compareTo(b.mlocateIndex);
        }
      });
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('mlocate DB Explorer'),
        leading: _isLocateMode || _navigationStack.length > 1
            ? IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () {
                  if (_isLocateMode) {
                    if (_isLocating) {
                      _cancelLocate();
                    } else {
                      setState(() {
                        _isLocateMode = false;
                        _locateController.text = '';
                        _locateResults.clear();
                      });
                    }
                  } else {
                    _navigateUp();
                  }
                },
              )
            : null,
        actions: [
          if (currentNode != null)
            IconButton(
              icon: Icon(_isLocateMode ? Icons.folder : Icons.search_rounded),
              onPressed: () {
                if (_isLocating) {
                  _cancelLocate();
                } else {
                  setState(() {
                    _isLocateMode = !_isLocateMode;
                    if (!_isLocateMode) {
                      _locateController.text = '';
                      _locateResults.clear();
                    }
                  });
                }
              },
              tooltip: _isLocateMode ? 'Browse Mode' : 'Locate Search',
            ),
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
                } else if (value == 'reload_db') {
                  _reloadDatabase();
                } else if (value == 'close_db') {
                  _closeDatabase();
                } else if (value == 'toggle_hidden') {
                  setState(() {
                    _showHiddenFiles = !_showHiddenFiles;
                  });
                }
              },
              itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
                PopupMenuItem<String>(
                  value: 'toggle_hidden',
                  child: Text(
                    _showHiddenFiles
                        ? 'Hide Hidden Files'
                        : 'Show Hidden Files',
                  ),
                ),
                const PopupMenuDivider(),
                const PopupMenuItem<String>(
                  value: 'export_dir',
                  child: Text('Export Directory'),
                ),
                const PopupMenuItem<String>(
                  value: 'export_tree',
                  child: Text('Export Directory Tree'),
                ),
                const PopupMenuDivider(),
                const PopupMenuItem<String>(
                  value: 'reload_db',
                  child: Text('Reload Database'),
                ),
                const PopupMenuItem<String>(
                  value: 'close_db',
                  child: Text('Close Database'),
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
              child: _isLocateMode
                  ? Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _locateController,
                            onSubmitted: _performLocate,
                            decoration: InputDecoration(
                              prefixIcon: const Icon(Icons.search_rounded),
                              suffixIcon: _isLocating
                                  ? IconButton(
                                      icon: const Icon(Icons.close),
                                      onPressed: _cancelLocate,
                                      tooltip: 'Cancel Search',
                                    )
                                  : null,
                              hintText: 'Enter locate query...',
                              isDense: true,
                              border: const OutlineInputBorder(),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        ElevatedButton(
                          onPressed: _isLocating
                              ? null
                              : () => _performLocate(_locateController.text),
                          child: const Text('Locate'),
                        ),
                      ],
                    )
                  : Row(
                      children: [
                        const Text(
                          'Current Path: ',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                        ),
                        Expanded(
                          child: TextField(
                            controller: _pathController,
                            onSubmitted: _onPathSubmitted,
                            decoration: const InputDecoration(
                              isDense: true,
                              contentPadding: EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 8,
                              ),
                              border: OutlineInputBorder(),
                            ),
                          ),
                        ),
                      ],
                    ),
            ),
          if (currentNode != null && !_isLoading && !_isLocateMode)
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: 8.0,
                vertical: 4.0,
              ),
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
                          _selectedIndex = 0;
                        });
                      },
                    ),
                  ),
                  const SizedBox(width: 8.0),
                  DropdownButton<GroupOption>(
                    value: _groupOption,
                    onChanged: (GroupOption? newValue) {
                      if (newValue != null) {
                        setState(() {
                          _groupOption = newValue;
                        });
                      }
                    },
                    items: const [
                      DropdownMenuItem(
                        value: GroupOption.dirsFirst,
                        child: Text('Dirs First'),
                      ),
                      DropdownMenuItem(
                        value: GroupOption.filesFirst,
                        child: Text('Files First'),
                      ),
                      DropdownMenuItem(
                        value: GroupOption.none,
                        child: Text('No Grouping'),
                      ),
                    ],
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
                        value: SortOption.modifiedAsc,
                        child: Text('Modified (Oldest)'),
                      ),
                      DropdownMenuItem(
                        value: SortOption.modifiedDesc,
                        child: Text('Modified (Newest)'),
                      ),
                      DropdownMenuItem(
                        value: SortOption.mlocateOrder,
                        child: Text('mlocate Order'),
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
                        CircularProgressIndicator(value: _loadingProgress),
                        const SizedBox(height: 20),
                        if (_loadingStatus != null)
                          Text(
                            _loadingStatus!,
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
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
                      : _isLocateMode
                          ? Column(
                              children: [
                                if (_isLocating)
                                  const LinearProgressIndicator(),
                                Expanded(
                                  child: ListView.builder(
                                    itemCount: _locateResults.length,
                                    itemBuilder: (context, index) {
                                      final node = _locateResults[index];
                                      return ListTile(
                                        dense: true,
                                        visualDensity: const VisualDensity(
                                          horizontal: 0,
                                          vertical: -4,
                                        ),
                                        leading: Icon(
                                          node.isDir
                                              ? Icons.folder
                                              : Icons.insert_drive_file,
                                          color: node.isDir
                                              ? Colors.blue
                                              : Colors.grey,
                                        ),
                                        title: Text(node.key),
                                        onTap: () => _jumpToLocateResult(node),
                                      );
                                    },
                                  ),
                                ),
                              ],
                            )
                          : Focus(
                              autofocus: true,
                              onKeyEvent: (node, event) {
                                if (event is KeyDownEvent ||
                                    event is KeyRepeatEvent) {
                                  if (event.logicalKey ==
                                      LogicalKeyboardKey.arrowDown) {
                                    if (_selectedIndex <
                                        displayedChildren.length - 1) {
                                      setState(() {
                                        _selectedIndex++;
                                        _scrollToSelectedIndex();
                                      });
                                    }
                                    return KeyEventResult.handled;
                                  } else if (event.logicalKey ==
                                      LogicalKeyboardKey.arrowUp) {
                                    if (HardwareKeyboard
                                        .instance.isAltPressed) {
                                      _navigateUp();
                                    } else if (_selectedIndex > 0) {
                                      setState(() {
                                        _selectedIndex--;
                                        _scrollToSelectedIndex();
                                      });
                                    }
                                    return KeyEventResult.handled;
                                  } else if (event.logicalKey ==
                                      LogicalKeyboardKey.pageDown) {
                                    if (displayedChildren.isEmpty)
                                      return KeyEventResult.ignored;
                                    setState(() {
                                      _selectedIndex = (_selectedIndex + 10)
                                          .clamp(
                                              0, displayedChildren.length - 1)
                                          .toInt();
                                      _scrollToSelectedIndex();
                                    });
                                    return KeyEventResult.handled;
                                  } else if (event.logicalKey ==
                                      LogicalKeyboardKey.pageUp) {
                                    if (displayedChildren.isEmpty)
                                      return KeyEventResult.ignored;
                                    setState(() {
                                      _selectedIndex = (_selectedIndex - 10)
                                          .clamp(
                                              0, displayedChildren.length - 1)
                                          .toInt();
                                      _scrollToSelectedIndex();
                                    });
                                    return KeyEventResult.handled;
                                  } else if (event.logicalKey ==
                                      LogicalKeyboardKey.backspace) {
                                    _navigateUp();
                                    return KeyEventResult.handled;
                                  } else if (event.logicalKey ==
                                      LogicalKeyboardKey.enter) {
                                    if (displayedChildren.isNotEmpty &&
                                        _selectedIndex >= 0 &&
                                        _selectedIndex <
                                            displayedChildren.length) {
                                      _navigateTo(
                                          displayedChildren[_selectedIndex]);
                                    }
                                    return KeyEventResult.handled;
                                  }
                                }
                                return KeyEventResult.ignored;
                              },
                              child: ListView.builder(
                                controller: _scrollController,
                                itemCount: displayedChildren.length,
                                itemBuilder: (context, index) {
                                  final listNode = displayedChildren[index];
                                  final isUnvisitedFolder =
                                      listNode.isDir && !listNode.isOpened;
                                  return GestureDetector(
                                    onSecondaryTapDown:
                                        (TapDownDetails details) {
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
                                            child: Text(
                                              listNode.isOpened
                                                  ? 'Mark as Unopened'
                                                  : 'Mark as Opened',
                                            ),
                                          ),
                                          const PopupMenuItem(
                                            value: 'copy_path',
                                            child: Text('Copy Full Path'),
                                          ),
                                        ],
                                      ).then((value) {
                                        if (value == 'toggle_opened') {
                                          setState(() {
                                            listNode.isOpened =
                                                !listNode.isOpened;
                                          });
                                        } else if (value == 'copy_path') {
                                          Clipboard.setData(
                                            ClipboardData(text: listNode.key),
                                          );
                                          if (context.mounted) {
                                            ScaffoldMessenger.of(context)
                                                .showSnackBar(
                                              const SnackBar(
                                                content: Text(
                                                  'Copied path to clipboard',
                                                ),
                                              ),
                                            );
                                          }
                                        }
                                      });
                                    },
                                    child: ListTile(
                                      dense: true,
                                      selected: index == _selectedIndex,
                                      selectedTileColor:
                                          Colors.blue.withAlpha(25),
                                      visualDensity: const VisualDensity(
                                        horizontal: 0,
                                        vertical: -4,
                                      ),
                                      leading: Icon(
                                        listNode.isDir
                                            ? Icons.folder
                                            : Icons.insert_drive_file,
                                        color: listNode.isDir
                                            ? Colors.blue
                                            : Colors.grey,
                                      ),
                                      title: Text(
                                        listNode.label,
                                        style: TextStyle(
                                          fontWeight: isUnvisitedFolder
                                              ? FontWeight.bold
                                              : FontWeight.normal,
                                        ),
                                      ),
                                      subtitle: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          if (listNode.isDir)
                                            Text(
                                              'Sub: ${listNode.subFileCount} files, ${listNode.subFolderCount} dirs | Deep: ${listNode.deepFileCount} files, ${listNode.deepFolderCount} dirs',
                                              style:
                                                  const TextStyle(fontSize: 12),
                                            ),
                                          if (listNode.modifiedTime != null)
                                            Text(
                                              'Modified: ${listNode.modifiedTime!.toLocal().toString()}',
                                            ),
                                        ],
                                      ),
                                      onTap: () {
                                        setState(() {
                                          _selectedIndex = index;
                                        });
                                        _navigateTo(listNode);
                                      },
                                    ),
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

  void _scrollToSelectedIndex() {
    if (!_scrollController.hasClients) return;

    // Approximate item height based on ListTile with visualDensity(horizontal: 0, vertical: -4) and dense: true
    // Standard subtitle with 2 lines is about ~20-25px more. Let's use 50.0 as an approximate average item height.
    const itemHeight = 56.0;

    final targetOffset = _selectedIndex * itemHeight;
    final currentOffset = _scrollController.offset;
    final viewportHeight = _scrollController.position.viewportDimension;

    if (targetOffset < currentOffset) {
      // Scroll up to show item
      _scrollController.jumpTo(targetOffset);
    } else if (targetOffset + itemHeight > currentOffset + viewportHeight) {
      // Scroll down to show item
      _scrollController.jumpTo(targetOffset + itemHeight - viewportHeight);
    }
  }
}
