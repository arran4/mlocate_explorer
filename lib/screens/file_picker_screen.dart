import 'dart:convert';
import 'dart:isolate';

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:glob/glob.dart';
import 'package:archive/archive.dart';

import '../models/node.dart';
import '../services/mlocate_db_parser.dart';
import '../services/mlocate_db_writer.dart';

import '../widgets/modify_node_dialog.dart';

List<int>? _encodeArchive(List<dynamic> args) {
  final archive = args[0] as Archive;
  final format = args[1] as String;
  if (format == 'tar') {
    return TarEncoder().encode(archive);
  } else {
    return ZipEncoder().encode(archive);
  }
}

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

enum LocateSearchMode { infix, prefix, suffix, exact, regex, glob }

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

  Future<void> _createNewNode(Node targetDir, bool isDir) async {
    final nameController = TextEditingController();
    try {
      final name = await showDialog<String>(
        context: context,
        builder: (context) {
          return AlertDialog(
            title: Text(isDir ? 'Create Folder' : 'Create File'),
            content: TextField(
              controller: nameController,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Name',
                hintText: 'Enter name',
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.of(context).pop(nameController.text),
                child: const Text('Create'),
              ),
            ],
          );
        },
      );

      if (name != null && name.trim().isNotEmpty) {
        final trimmedName = name.trim();

        // Validate name does not contain path separators
        if (trimmedName.contains('/')) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Name cannot contain "/"')),
            );
          }
          return;
        }

        // Check for duplicates
        final exists =
            targetDir.children.any((child) => child.label == trimmedName);
        if (exists) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                  content:
                      Text('An item named "$trimmedName" already exists.')),
            );
          }
          return;
        }

        final newKey = targetDir.key == '/'
            ? '/$trimmedName'
            : '${targetDir.key}/$trimmedName';
        final newNode = Node(
          key: newKey,
          label: trimmedName,
          isDir: isDir,
          modifiedTime: DateTime.now(),
        );

        setState(() {
          targetDir.children.add(newNode);
          _searchIndex.clear();
          _hiddenKeys.clear();
          if (rootNode != null) {
            final ancestors = _findStackToPath(rootNode!, targetDir.key, []);
            if (ancestors != null) {
              for (final ancestor in ancestors) {
                if (isDir) {
                  ancestor.deepFolderCount += 1;
                } else {
                  ancestor.deepFileCount += 1;
                }
              }
            }
            if (isDir) {
              targetDir.subFolderCount += 1;
            } else {
              targetDir.subFileCount += 1;
            }
          }
        });
      }
    } finally {
      nameController.dispose();
    }
  }

  // Locate state
  bool _isLocateMode = false;
  final TextEditingController _locateController = TextEditingController();

  // Hidden files toggle
  bool _showHiddenFiles = false;
  final Set<String> _localShowHiddenFolders = {};
  List<Node> _locateResults = [];
  bool _isLocating = false;
  bool _cancelLocateRequested = false;
  LocateSearchMode _locateSearchMode = LocateSearchMode.infix;
  final List<Node> _searchIndex = [];
  final Set<String> _hiddenKeys = {};

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

  Future<void> _openSystemDb() async {
    final possiblePaths = [
      '/var/lib/mlocate/mlocate.db',
      '/var/lib/plocate/plocate.db',
    ];

    String? foundPath;
    String? errorMessage;
    for (final p in possiblePaths) {
      final file = File(p);
      try {
        if (await file.exists()) {
          final openedFile = await file.open(mode: FileMode.read);
          await openedFile.close();
          foundPath = p;
          break;
        }
      } on FileSystemException catch (e) {
        errorMessage = "Permission denied or error reading $p: ${e.message}";
      }
    }

    if (foundPath != null) {
      setState(() {
        filePath = foundPath;
        _isLoading = true;
        _loadingProgress = null;
        _loadingStatus = 'Opening...';
      });
      _parseDatabase();
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(errorMessage ??
                'Could not find system database (/var/lib/mlocate/mlocate.db or plocate.db)'),
          ),
        );
      }
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
      _searchIndex.clear();
      _hiddenKeys.clear();
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

    final trimmedQuery = query.trim();

    setState(() {
      _isLocateMode = true;
      _locateResults.clear();
      _isLocating = true;
      _cancelLocateRequested = false;
      _selectedIndex = 0;
    });

    if (trimmedQuery.isEmpty) {
      setState(() {
        _isLocating = false;
      });
      return;
    }

    if (_searchIndex.isEmpty) {
      _hiddenKeys.clear();
      List<(Node, bool)> queue = [(rootNode!, false)];
      int iterations = 0;
      while (queue.isNotEmpty) {
        if (!mounted || rootNode == null) {
          _searchIndex.clear();
          _hiddenKeys.clear();
          return;
        }
        final (current, isParentHidden) = queue.removeLast();
        final isCurrentHidden = isParentHidden ||
            (current.label.startsWith('.') &&
                current.label != '.' &&
                current.label != '..');
        if (isCurrentHidden) {
          _hiddenKeys.add(current.key);
        }
        _searchIndex.add(current);
        for (int i = current.children.length - 1; i >= 0; i--) {
          queue.add((current.children[i], isCurrentHidden));
        }
        iterations++;
        if (iterations % 10000 == 0) {
          await Future.delayed(Duration.zero);
        }
      }
    }

    List<Node> results = [];
    int searchIterations = 0;

    RegExp? regexPattern;
    Glob? globPattern;
    final lowercaseQuery = trimmedQuery.toLowerCase();

    if (_locateSearchMode == LocateSearchMode.regex) {
      try {
        regexPattern = RegExp(trimmedQuery);
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Invalid Regular Expression: $e')),
          );
          setState(() {
            _isLocating = false;
          });
        }
        return;
      }
    } else if (_locateSearchMode == LocateSearchMode.glob) {
      try {
        globPattern = Glob(trimmedQuery);
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Invalid Glob Pattern: $e')),
          );
          setState(() {
            _isLocating = false;
          });
        }
        return;
      }
    }

    for (int i = 0; i < _searchIndex.length; i++) {
      if (_cancelLocateRequested) {
        break;
      }

      Node current = _searchIndex[i];

      if (!_showHiddenFiles && current != rootNode) {
        if (_hiddenKeys.contains(current.key)) {
          continue;
        }
      }

      bool match = false;
      switch (_locateSearchMode) {
        case LocateSearchMode.infix:
          match = current.key.toLowerCase().contains(lowercaseQuery);
          break;
        case LocateSearchMode.prefix:
          match = current.key.toLowerCase().startsWith(lowercaseQuery);
          break;
        case LocateSearchMode.suffix:
          match = current.key.toLowerCase().endsWith(lowercaseQuery);
          break;
        case LocateSearchMode.exact:
          match = current.key.toLowerCase() == lowercaseQuery;
          break;
        case LocateSearchMode.regex:
          match = regexPattern?.hasMatch(current.key) ?? false;
          break;
        case LocateSearchMode.glob:
          match = globPattern?.matches(current.key) ?? false;
          break;
      }

      if (match) {
        results.add(current);
      }

      searchIterations++;
      if (searchIterations % 10000 == 0) {
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

  Future<void> _exportWholeDb() async {
    if (rootNode == null) return;

    final format = await _showExportFormatDialog(true);
    if (format == null) {
      return;
    }

    final ext = format == 'json'
        ? 'json'
        : format == 'mlocate'
            ? 'db'
            : format == 'tar'
                ? 'tar'
                : format == 'zip'
                    ? 'zip'
                    : 'txt';

    final savePath = await FilePicker.platform.saveFile(
      dialogTitle: 'Export Whole DB',
      fileName: 'exported.$ext',
    );

    if (savePath != null) {
      if (format == 'mlocate') {
        try {
          // Direct export using rootNode without filtering
          final writer = MlocateDBWriter(savePath, rootNode!);
          await Isolate.run(() => writer.write());

          if (mounted && context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Exported database to $savePath'),
              ),
            );
          }
        } catch (e) {
          if (mounted && context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Failed to export database: $e'),
                backgroundColor: Colors.red,
              ),
            );
          }
        }
      } else if (format == 'tar' || format == 'zip') {
        final archive = Archive();
        final showHidden = _showHiddenFiles;

        void addNodeToArchive(Node n, String basePath) {
          if (!showHidden &&
              n.label.startsWith('.') &&
              n.label != '.' &&
              n.label != '..') {
            return;
          }
          final path = basePath.isEmpty ? n.label : '$basePath/${n.label}';
          final finalPath = path + (n.isDir ? '/' : '');

          final file = ArchiveFile(finalPath, 0, <int>[]);
          if (n.modifiedTime != null) {
            file.lastModTime = n.modifiedTime!.millisecondsSinceEpoch ~/ 1000;
          }
          archive.addFile(file);

          for (final child in n.children) {
            addNodeToArchive(child, path);
          }
        }

        for (final child in rootNode!.children) {
          addNodeToArchive(child, '');
        }

        try {
          final archiveData = await Isolate.run<List<int>?>(
            () => _encodeArchive([archive, format]),
          );
          if (archiveData == null) {
            throw Exception('Encoder returned empty data');
          }
          await File(savePath).writeAsBytes(archiveData);
          if (mounted && context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Exported database to $savePath'),
              ),
            );
          }
        } catch (e) {
          if (mounted && context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Failed to export database: $e'),
                backgroundColor: Colors.red,
              ),
            );
          }
        }
      } else if (format == 'json') {
        Map<String, dynamic> serializeNode(Node n) {
          final childrenList = <Map<String, dynamic>>[];
          for (final child in n.children) {
            if (!_showHiddenFiles &&
                child.label.startsWith('.') &&
                child.label != '.' &&
                child.label != '..') {
              continue;
            }
            childrenList.add(serializeNode(child));
          }
          return {
            'key': n.key,
            'label': n.label,
            'isDir': n.isDir,
            'modifiedTime': n.modifiedTime?.toIso8601String(),
            'isOpened': n.isOpened,
            'subFileCount': n.subFileCount,
            'subFolderCount': n.subFolderCount,
            'deepFileCount': n.deepFileCount,
            'deepFolderCount': n.deepFolderCount,
            'children': childrenList,
          };
        }

        final Map<String, dynamic> data = serializeNode(rootNode!);
        await File(savePath).writeAsString(jsonEncode(data));
        if (mounted && context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Exported database to $savePath')),
          );
        }
      } else {
        final buffer = StringBuffer();
        if (format == 'ascii') {
          _collectTreeAscii(rootNode!, buffer, "", true, true);
        } else {
          for (final child in rootNode!.children) {
            _collectTree(child, buffer);
          }
        }
        await File(savePath).writeAsString(buffer.toString());
        if (mounted && context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Exported database to $savePath')),
          );
        }
      }
    }
  }

  Future<String?> _showExportFormatDialog(bool isTree) async {
    return showDialog<String>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Select Export Format'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                title: const Text('Raw Paths'),
                subtitle: const Text('A flat list of file paths'),
                onTap: () => Navigator.of(context).pop('raw'),
              ),
              if (!isTree)
                ListTile(
                  title: const Text('ls-like'),
                  subtitle: const Text('A basic list of file names'),
                  onTap: () => Navigator.of(context).pop('ls'),
                ),
              if (isTree)
                ListTile(
                  title: const Text('ASCII Tree'),
                  subtitle: const Text('A visual tree representation'),
                  onTap: () => Navigator.of(context).pop('ascii'),
                ),
              ListTile(
                title: const Text('JSON'),
                subtitle: const Text('Structured JSON data'),
                onTap: () => Navigator.of(context).pop('json'),
              ),
              ListTile(
                title: const Text('mlocate.db'),
                subtitle: const Text('Binary mlocate database format'),
                onTap: () => Navigator.of(context).pop('mlocate'),
              ),
              ListTile(
                title: const Text('tar (empty files)'),
                subtitle: const Text(
                    'Tar archive preserving directory structure with empty files'),
                onTap: () => Navigator.of(context).pop('tar'),
              ),
              ListTile(
                title: const Text('zip (empty files)'),
                subtitle: const Text(
                    'Zip archive preserving directory structure with empty files'),
                onTap: () => Navigator.of(context).pop('zip'),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _exportDirectory(Node node) async {
    final format = await _showExportFormatDialog(false);
    if (format == null) {
      return;
    }

    final ext = format == 'json'
        ? 'json'
        : format == 'mlocate'
            ? 'db'
            : format == 'tar'
                ? 'tar'
                : format == 'zip'
                    ? 'zip'
                    : 'txt';
    final savePath = await FilePicker.platform.saveFile(
      dialogTitle: 'Export Directory',
      fileName: 'directory_export.$ext',
    );

    if (savePath != null) {
      if (format == 'mlocate') {
        final clonedNode = Node(
          key: node.key,
          label: node.label,
          isDir: node.isDir,
          modifiedTime: node.modifiedTime,
          isOpened: node.isOpened,
          subFileCount: node.subFileCount,
          subFolderCount: node.subFolderCount,
          deepFileCount: node.deepFileCount,
          deepFolderCount: node.deepFolderCount,
          mlocateIndex: node.mlocateIndex,
          sizeOverride: node.sizeOverride,
          children: node.children
              .where((child) {
                if (_showHiddenFiles) return true;
                final label = child.label;
                return !label.startsWith('.') || label == '.' || label == '..';
              })
              .map((child) => Node(
                    key: child.key,
                    label: child.label,
                    isDir: child.isDir,
                    modifiedTime: child.modifiedTime,
                    isOpened: child.isOpened,
                    subFileCount: child.subFileCount,
                    subFolderCount: child.subFolderCount,
                    deepFileCount: child.deepFileCount,
                    deepFolderCount: child.deepFolderCount,
                    mlocateIndex: child.mlocateIndex,
                    sizeOverride: child.sizeOverride,
                    children: const [], // shallow export
                  ))
              .toList(),
        );

        try {
          final writer = MlocateDBWriter(savePath, clonedNode);
          await Isolate.run(() => writer.write());
        } catch (e) {
          if (mounted && context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Failed to export directory: $e'),
                backgroundColor: Colors.red,
              ),
            );
          }
          return;
        }
      } else if (format == 'tar' || format == 'zip') {
        final archive = Archive();
        final showHidden = _showHiddenFiles;
        for (final child in node.children) {
          if (!showHidden &&
              child.label.startsWith('.') &&
              child.label != '.' &&
              child.label != '..') {
            continue;
          }
          final path = child.label + (child.isDir ? '/' : '');
          final file = ArchiveFile(path, 0, <int>[]);
          if (child.modifiedTime != null) {
            file.lastModTime =
                child.modifiedTime!.millisecondsSinceEpoch ~/ 1000;
          }
          archive.addFile(file);
        }

        try {
          final archiveData = await Isolate.run<List<int>?>(
            () => _encodeArchive([archive, format]),
          );
          if (archiveData == null) {
            throw Exception('Encoder returned empty data');
          }
          await File(savePath).writeAsBytes(archiveData);
        } catch (e) {
          if (mounted && context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Failed to export directory: $e'),
                backgroundColor: Colors.red,
              ),
            );
          }
          return;
        }
      } else if (format == 'json') {
        Map<String, dynamic> toMapFlat(Node n) {
          return {
            'key': n.key,
            'label': n.label,
            'isDir': n.isDir,
            'modifiedTime': n.modifiedTime?.toIso8601String(),
            'isOpened': n.isOpened,
            'subFileCount': n.subFileCount,
            'subFolderCount': n.subFolderCount,
            'deepFileCount': n.deepFileCount,
            'deepFolderCount': n.deepFolderCount,
            'children': const <Map<String, dynamic>>[],
          };
        }

        final Map<String, dynamic> data = toMapFlat(node);
        data['children'] = node.children
            .where((child) {
              if (_showHiddenFiles) return true;
              final label = child.label;
              return !label.startsWith('.') || label == '.' || label == '..';
            })
            .map(toMapFlat)
            .toList();
        await File(savePath).writeAsString(jsonEncode(data));
      } else {
        final buffer = StringBuffer();
        for (final child in node.children) {
          if (!_showHiddenFiles &&
              child.label.startsWith('.') &&
              child.label != '.' &&
              child.label != '..') {
            continue;
          }
          if (format == 'ls') {
            buffer.writeln(child.label + (child.isDir ? '/' : ''));
          } else {
            buffer.writeln(child.key);
          }
        }
        await File(savePath).writeAsString(buffer.toString());
      }
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Exported to $savePath')));
      }
    }
  }

  void _collectTreeAscii(
      Node node, StringBuffer buffer, String prefix, bool isTail, bool isRoot) {
    if (!_showHiddenFiles &&
        node.label.startsWith('.') &&
        node.label != '.' &&
        node.label != '..') {
      return;
    }

    if (isRoot) {
      buffer.writeln(node.label);
    } else {
      buffer.write(prefix);
      buffer.write(isTail ? '└── ' : '├── ');
      buffer.writeln(node.label);
    }

    final validChildren = _showHiddenFiles
        ? node.children
        : node.children
            .where((c) =>
                !c.label.startsWith('.') || c.label == '.' || c.label == '..')
            .toList();

    for (var i = 0; i < validChildren.length; i++) {
      final child = validChildren[i];
      final isLast = i == validChildren.length - 1;
      _collectTreeAscii(child, buffer,
          isRoot ? prefix : prefix + (isTail ? '    ' : '│   '), isLast, false);
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
    final format = await _showExportFormatDialog(true);
    if (format == null) {
      return;
    }

    final ext = format == 'json'
        ? 'json'
        : format == 'mlocate'
            ? 'db'
            : format == 'tar'
                ? 'tar'
                : format == 'zip'
                    ? 'zip'
                    : 'txt';
    final savePath = await FilePicker.platform.saveFile(
      dialogTitle: 'Export Directory Tree',
      fileName: 'directory_tree_export.$ext',
    );

    if (savePath != null) {
      if (format == 'mlocate') {
        Node cloneTree(Node n) {
          final childrenList = <Node>[];
          for (final child in n.children) {
            if (!_showHiddenFiles &&
                child.label.startsWith('.') &&
                child.label != '.' &&
                child.label != '..') {
              continue;
            }
            childrenList.add(cloneTree(child));
          }
          return Node(
            key: n.key,
            label: n.label,
            isDir: n.isDir,
            modifiedTime: n.modifiedTime,
            isOpened: n.isOpened,
            subFileCount: n.subFileCount,
            subFolderCount: n.subFolderCount,
            deepFileCount: n.deepFileCount,
            deepFolderCount: n.deepFolderCount,
            mlocateIndex: n.mlocateIndex,
            sizeOverride: n.sizeOverride,
            children: childrenList,
          );
        }

        try {
          final writer = MlocateDBWriter(savePath, cloneTree(node));
          await Isolate.run(() => writer.write());
        } catch (e) {
          if (mounted && context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Failed to export directory tree: $e'),
                backgroundColor: Colors.red,
              ),
            );
          }
          return;
        }
      } else if (format == 'tar' || format == 'zip') {
        final archive = Archive();
        final showHidden = _showHiddenFiles;

        void addNodeToArchive(Node n, String basePath) {
          if (!showHidden &&
              n.label.startsWith('.') &&
              n.label != '.' &&
              n.label != '..') {
            return;
          }
          final path = basePath.isEmpty ? n.label : '$basePath/${n.label}';
          final finalPath = path + (n.isDir ? '/' : '');

          final file = ArchiveFile(finalPath, 0, <int>[]);
          if (n.modifiedTime != null) {
            file.lastModTime = n.modifiedTime!.millisecondsSinceEpoch ~/ 1000;
          }
          archive.addFile(file);

          for (final child in n.children) {
            addNodeToArchive(child, path);
          }
        }

        for (final child in node.children) {
          addNodeToArchive(child, '');
        }

        try {
          final archiveData = await Isolate.run<List<int>?>(
            () => _encodeArchive([archive, format]),
          );
          if (archiveData == null) {
            throw Exception('Encoder returned empty data');
          }
          await File(savePath).writeAsBytes(archiveData);
        } catch (e) {
          if (mounted && context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Failed to export directory tree: $e'),
                backgroundColor: Colors.red,
              ),
            );
          }
          return;
        }
      } else if (format == 'json') {
        Map<String, dynamic> serializeNode(Node n) {
          final childrenList = <Map<String, dynamic>>[];
          for (final child in n.children) {
            if (!_showHiddenFiles &&
                child.label.startsWith('.') &&
                child.label != '.' &&
                child.label != '..') {
              continue;
            }
            childrenList.add(serializeNode(child));
          }
          return {
            'key': n.key,
            'label': n.label,
            'isDir': n.isDir,
            'modifiedTime': n.modifiedTime?.toIso8601String(),
            'isOpened': n.isOpened,
            'subFileCount': n.subFileCount,
            'subFolderCount': n.subFolderCount,
            'deepFileCount': n.deepFileCount,
            'deepFolderCount': n.deepFolderCount,
            'children': childrenList,
          };
        }

        final Map<String, dynamic> data = serializeNode(node);
        await File(savePath).writeAsString(jsonEncode(data));
      } else {
        final buffer = StringBuffer();
        if (format == 'ascii') {
          _collectTreeAscii(node, buffer, "", true, true);
        } else {
          for (final child in node.children) {
            _collectTree(child, buffer);
          }
        }
        await File(savePath).writeAsString(buffer.toString());
      }
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
    int hiddenCount = 0;
    bool effectivelyShowHidden = _showHiddenFiles;

    if (currentNode != null) {
      hiddenCount = currentNode.children.where((node) {
        return node.label.startsWith('.') &&
            node.label != '.' &&
            node.label != '..' &&
            node.label.toLowerCase().contains(_searchQuery.toLowerCase());
      }).length;

      effectivelyShowHidden =
          _showHiddenFiles || _localShowHiddenFolders.contains(currentNode.key);

      displayedChildren = currentNode.children.where((node) {
        if (!effectivelyShowHidden &&
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

    bool showHiddenToggleItem = !_showHiddenFiles && hiddenCount > 0;
    int totalItems = displayedChildren.length;

    // Centralized clamping
    if (_selectedIndex >= totalItems) {
      _selectedIndex = totalItems > 0 ? totalItems - 1 : 0;
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
                if (value == 'create_file') {
                  _createNewNode(currentNode, false);
                } else if (value == 'create_folder') {
                  _createNewNode(currentNode, true);
                } else if (value == 'export_dir') {
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
                } else if (value == 'export_whole_db') {
                  _exportWholeDb();
                } else if (value == 'open_system_db') {
                  _openSystemDb();
                }
              },
              itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
                const PopupMenuItem<String>(
                  value: 'create_file',
                  child: Text('Create File'),
                ),
                const PopupMenuItem<String>(
                  value: 'create_folder',
                  child: Text('Create Folder'),
                ),
                const PopupMenuDivider(),
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
                  value: 'export_whole_db',
                  child: Text('Export Whole DB'),
                ),
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
                  value: 'open_system_db',
                  child: Text('Open System DB'),
                ),
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
                        DropdownButton<LocateSearchMode>(
                          value: _locateSearchMode,
                          items: const [
                            DropdownMenuItem(
                              value: LocateSearchMode.infix,
                              child: Text('Infix'),
                            ),
                            DropdownMenuItem(
                              value: LocateSearchMode.prefix,
                              child: Text('Prefix'),
                            ),
                            DropdownMenuItem(
                              value: LocateSearchMode.suffix,
                              child: Text('Suffix'),
                            ),
                            DropdownMenuItem(
                              value: LocateSearchMode.exact,
                              child: Text('Exact'),
                            ),
                            DropdownMenuItem(
                              value: LocateSearchMode.regex,
                              child: Text('RegExp'),
                            ),
                            DropdownMenuItem(
                              value: LocateSearchMode.glob,
                              child: Text('Glob'),
                            ),
                          ],
                          onChanged: _isLocating
                              ? null
                              : (LocateSearchMode? newValue) {
                                  if (newValue != null) {
                                    setState(() {
                                      _locateSearchMode = newValue;
                                    });
                                  }
                                },
                        ),
                        const SizedBox(width: 8),
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
          if (currentNode != null &&
              showHiddenToggleItem &&
              !_isLoading &&
              !_isLocateMode)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8.0),
              child: Row(
                children: [
                  const Icon(Icons.info_outline, size: 16, color: Colors.grey),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${_localShowHiddenFolders.contains(currentNode.key) ? "Showing" : "Hiding"} $hiddenCount hidden items.',
                      style: const TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                  ),
                  TextButton(
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 0),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    onPressed: () {
                      setState(() {
                        if (_localShowHiddenFolders.contains(currentNode.key)) {
                          _localShowHiddenFolders.remove(currentNode.key);
                        } else {
                          _localShowHiddenFolders.add(currentNode.key);
                        }
                      });
                    },
                    child: Text(
                      _localShowHiddenFolders.contains(currentNode.key)
                          ? 'Hide'
                          : 'Show',
                      style: const TextStyle(fontSize: 12),
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
                      ? Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            ElevatedButton(
                              onPressed: _pickFile,
                              child: const Text('Pick mlocate.db File'),
                            ),
                            const SizedBox(height: 16),
                            ElevatedButton(
                              onPressed: _openSystemDb,
                              child: const Text('Open System DB'),
                            ),
                          ],
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
                                        subtitle: _NodeSubtitle(node: node),
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
                                    if (_selectedIndex < totalItems - 1) {
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
                                    if (totalItems == 0) {
                                      return KeyEventResult.ignored;
                                    }
                                    setState(() {
                                      _selectedIndex = (_selectedIndex + 10)
                                          .clamp(0, totalItems - 1)
                                          .toInt();
                                      _scrollToSelectedIndex();
                                    });
                                    return KeyEventResult.handled;
                                  } else if (event.logicalKey ==
                                      LogicalKeyboardKey.pageUp) {
                                    if (totalItems == 0) {
                                      return KeyEventResult.ignored;
                                    }
                                    setState(() {
                                      _selectedIndex = (_selectedIndex - 10)
                                          .clamp(0, totalItems - 1)
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
                                    if (totalItems > 0 &&
                                        _selectedIndex >= 0 &&
                                        _selectedIndex < totalItems) {
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
                                itemCount: totalItems,
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
                                        items: <PopupMenuEntry<String>>[
                                          PopupMenuItem<String>(
                                            value: 'toggle_opened',
                                            child: Text(
                                              listNode.isOpened
                                                  ? 'Mark as Unopened'
                                                  : 'Mark as Opened',
                                            ),
                                          ),
                                          const PopupMenuItem<String>(
                                            value: 'copy_path',
                                            child: Text('Copy Full Path'),
                                          ),
                                          const PopupMenuDivider(),
                                          const PopupMenuItem<String>(
                                            value: 'modify',
                                            child: Text('Modify / Delete'),
                                          ),
                                          if (listNode.isDir) ...[
                                            const PopupMenuDivider(),
                                            const PopupMenuItem<String>(
                                              value: 'create_file_inside',
                                              child: Text('Create File Inside'),
                                            ),
                                            const PopupMenuItem<String>(
                                              value: 'create_folder_inside',
                                              child:
                                                  Text('Create Folder Inside'),
                                            ),
                                            const PopupMenuDivider(),
                                            const PopupMenuItem<String>(
                                              value: 'export_dir',
                                              child: Text('Export Directory'),
                                            ),
                                            const PopupMenuItem<String>(
                                              value: 'export_tree',
                                              child:
                                                  Text('Export Directory Tree'),
                                            ),
                                          ],
                                        ],
                                      ).then((value) {
                                        if (!mounted) return;
                                        if (value == 'create_file_inside') {
                                          _createNewNode(listNode, false);
                                        } else if (value ==
                                            'create_folder_inside') {
                                          _createNewNode(listNode, true);
                                        } else if (value == 'toggle_opened') {
                                          setState(() {
                                            listNode.isOpened =
                                                !listNode.isOpened;
                                          });
                                        } else if (value == 'modify') {
                                          if (!context.mounted) return;
                                          showDialog(
                                            context: context,
                                            builder: (context) =>
                                                ModifyNodeDialog(
                                              node: listNode,
                                              onModified: (modifiedNode) {
                                                setState(() {
                                                  _searchIndex.clear();
                                                  _hiddenKeys.clear();
                                                });
                                              },
                                              onDeleted: (deletedNode) {
                                                setState(() {
                                                  _searchIndex.clear();
                                                  _hiddenKeys.clear();
                                                  bool removeRecursively(
                                                      Node current) {
                                                    int initialLen =
                                                        current.children.length;
                                                    current.children
                                                        .removeWhere((n) =>
                                                            n.key ==
                                                            deletedNode.key);
                                                    if (current
                                                            .children.length <
                                                        initialLen) {
                                                      return true;
                                                    }
                                                    for (var child
                                                        in current.children) {
                                                      if (child.isDir) {
                                                        if (removeRecursively(
                                                            child)) {
                                                          return true;
                                                        }
                                                      }
                                                    }
                                                    return false;
                                                  }

                                                  if (rootNode != null) {
                                                    removeRecursively(
                                                        rootNode!);
                                                    _recalculateCounts(
                                                        rootNode!);
                                                  }
                                                });
                                              },
                                            ),
                                          );
                                        } else if (value == 'export_dir') {
                                          _exportDirectory(listNode);
                                        } else if (value == 'export_tree') {
                                          _exportDirectoryTree(listNode);
                                        } else if (value == 'copy_path') {
                                          Clipboard.setData(
                                            ClipboardData(text: listNode.key),
                                          ).then((_) {
                                            if (mounted && context.mounted) {
                                              ScaffoldMessenger.of(context)
                                                  .showSnackBar(
                                                const SnackBar(
                                                  content: Text(
                                                    'Copied path to clipboard',
                                                  ),
                                                ),
                                              );
                                            }
                                          });
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
                                      subtitle: _NodeSubtitle(node: listNode),
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

  void _recalculateCounts(Node node) {
    if (!node.isDir) return;
    int subFiles = 0;
    int subFolders = 0;
    int deepFiles = 0;
    int deepFolders = 0;

    for (var child in node.children) {
      if (child.isDir) {
        subFolders++;
        deepFolders++;
        _recalculateCounts(child);
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

class _NodeSubtitle extends StatefulWidget {
  final Node node;

  const _NodeSubtitle({required this.node});

  @override
  _NodeSubtitleState createState() => _NodeSubtitleState();
}

class _NodeSubtitleState extends State<_NodeSubtitle> {
  FileStat? _stat;

  @override
  void initState() {
    super.initState();
    _fetchStat();
  }

  @override
  void didUpdateWidget(_NodeSubtitle oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.node.key != widget.node.key) {
      _fetchStat();
    }
  }

  void _fetchStat() {
    _stat = null;
    final currentKey = widget.node.key;
    FileStat.stat(currentKey).then((stat) {
      if (mounted && widget.node.key == currentKey) {
        setState(() {
          if (stat.type != FileSystemEntityType.notFound) {
            _stat = stat;
          }
        });
      }
    }).catchError((_) {
      // Ignore errors silently
    });
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) {
      return '$bytes B';
    }
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  @override
  Widget build(BuildContext context) {
    final node = widget.node;
    final timeToDisplay = node.modifiedTime;
    final sizeToDisplay = node.sizeOverride ?? _stat?.size;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (node.isDir)
          Text(
            'Sub: ${node.subFileCount} files, ${node.subFolderCount} dirs | Deep: ${node.deepFileCount} files, ${node.deepFolderCount} dirs',
            style: const TextStyle(fontSize: 12),
          ),
        if (timeToDisplay != null)
          Text('Modified: ${timeToDisplay.toLocal().toString()}',
              style: const TextStyle(fontSize: 12)),
        if (sizeToDisplay != null && !node.isDir)
          Text('Size: ${_formatBytes(sizeToDisplay)}',
              style: const TextStyle(fontSize: 12)),
      ],
    );
  }
}
