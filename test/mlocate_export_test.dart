import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:mlocate_explorer/models/node.dart';
import 'package:mlocate_explorer/services/mlocate_db_parser.dart';
import 'package:mlocate_explorer/services/mlocate_db_writer.dart';
import 'package:path/path.dart' as p;
import 'package:archive/archive.dart';

void main() {
  group('Mlocate Export', () {
    test('Exports and parses a mock directory tree correctly', () async {
      // Create a mock directory structure
      final rootNode = Node(
        key: '/mock_root',
        label: 'mock_root',
        isDir: true,
        children: [
          Node(
            key: '/mock_root/folder1',
            label: 'folder1',
            isDir: true,
            children: [
              Node(
                key: '/mock_root/folder1/file1.txt',
                label: 'file1.txt',
                isDir: false,
              ),
              Node(
                key: '/mock_root/folder1/file2.txt',
                label: 'file2.txt',
                isDir: false,
              ),
            ],
          ),
          Node(
            key: '/mock_root/file3.txt',
            label: 'file3.txt',
            isDir: false,
          ),
        ],
      );

      // Create a temporary file path
      final tempDir = Directory.systemTemp.createTempSync('mlocate_test');
      final dbPath = p.join(tempDir.path, 'exported.db');

      // Export using MlocateDBWriter
      final writer = MlocateDBWriter(dbPath, rootNode);
      writer.write();

      // Verify the file was created
      final exportedFile = File(dbPath);
      expect(exportedFile.existsSync(), true);

      // Parse the exported file
      final parser = MlocateDBParser(
        dbPath,
        onProgress: (progress, status) {},
      );

      parser.parse();
      final parsedRoot = parser.rootNode;

      // Assertions to verify data integrity
      expect(parsedRoot, isNotNull);
      expect(parsedRoot?.label, '/mock_root');
      expect(parsedRoot?.children.length, 2);

      final folder1 =
          parsedRoot?.children.firstWhere((n) => n.label == 'folder1');
      expect(folder1?.isDir, true);
      expect(folder1?.children.length, 2);
      expect(folder1?.children.any((n) => n.label == 'file1.txt'), true);
      expect(folder1?.children.any((n) => n.label == 'file2.txt'), true);

      final file3 =
          parsedRoot?.children.firstWhere((n) => n.label == 'file3.txt');
      expect(file3?.isDir, false);
      expect(file3?.children, isEmpty);

      // Clean up
      tempDir.deleteSync(recursive: true);
    });

    test('Exports directory tree as TAR with empty files', () async {
      final rootNode = Node(
        key: '/mock_root',
        label: 'mock_root',
        isDir: true,
        children: [
          Node(
            key: '/mock_root/folder1',
            label: 'folder1',
            isDir: true,
            children: [
              Node(
                key: '/mock_root/folder1/file1.txt',
                label: 'file1.txt',
                isDir: false,
              ),
            ],
          ),
        ],
      );

      final archive = Archive();
      void addNodeToArchive(Node n, String basePath) {
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

      for (final child in rootNode.children) {
          addNodeToArchive(child, '');
      }

      final tarData = TarEncoder().encode(archive);
      final decodedArchive = TarDecoder().decodeBytes(tarData);

      expect(decodedArchive.length, 2);
      expect(decodedArchive[0].name, 'folder1/');
      expect(decodedArchive[0].size, 0);
      expect(decodedArchive[1].name, 'folder1/file1.txt');
      expect(decodedArchive[1].size, 0);
    });

    test('Exports directory tree as ZIP with empty files', () async {
      final rootNode = Node(
        key: '/mock_root',
        label: 'mock_root',
        isDir: true,
        children: [
          Node(
            key: '/mock_root/folder2',
            label: 'folder2',
            isDir: true,
            children: [
              Node(
                key: '/mock_root/folder2/file2.txt',
                label: 'file2.txt',
                isDir: false,
              ),
            ],
          ),
        ],
      );

      final archive = Archive();
      void addNodeToArchive(Node n, String basePath) {
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

      for (final child in rootNode.children) {
          addNodeToArchive(child, '');
      }

      final zipData = ZipEncoder().encode(archive);
      final decodedArchive = ZipDecoder().decodeBytes(zipData);

      expect(decodedArchive.length, 2);
      expect(decodedArchive[0].name, 'folder2/');
      expect(decodedArchive[0].size, 0);
      expect(decodedArchive[1].name, 'folder2/file2.txt');
      expect(decodedArchive[1].size, 0);
    });
  });
}
