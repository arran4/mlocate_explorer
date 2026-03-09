import 'dart:isolate';

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
          rootNode = message as Node?;
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('mlocate DB Explorer'),
      ),
      body: Center(
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
            : rootNode == null
                ? ElevatedButton(
                    onPressed: _pickFile,
                    child: const Text('Pick mlocate.db File'),
                  )
                : ListView.builder(
                    itemCount: rootNode!.children.length,
                    itemBuilder: (context, index) {
                      final node = rootNode!.children[index];
                      return ListTile(
                        title: Text(node.label),
                      );
                    },
                  ),
      ),
    );
  }
}
