import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mlocate_explorer/models/node.dart';
import 'package:mlocate_explorer/services/mlocate_db_parser.dart';
import 'package:mlocate_explorer/services/mlocate_db_writer.dart';

void main() {
  group('MlocateDBWriter', () {
    late String dbPath;

    setUp(() async {
      dbPath = 'test_mlocate_write.db';
    });

    tearDown(() async {
      final file = File(dbPath);
      if (await file.exists()) {
        await file.delete();
      }
    });

    test('writes and parses perfectly (circular check)', () async {
      // Create a test tree
      final rootNode = Node(
        key: '/',
        label: '/',
        isDir: true,
        modifiedTime: DateTime.utc(2023, 1, 1, 0, 0, 0),
        children: [
          Node(
            key: '/etc',
            label: 'etc',
            isDir: true,
            modifiedTime: DateTime.utc(2023, 2, 1, 0, 0, 0),
            children: [
              Node(
                key: '/etc/fstab',
                label: 'fstab',
                isDir: false,
              ),
              Node(
                key: '/etc/passwd',
                label: 'passwd',
                isDir: false,
              ),
              // adding CJK test folder inside etc
              Node(
                  key: '/etc/测试',
                  label: '测试',
                  isDir: true,
                  modifiedTime: DateTime.utc(2023, 2, 2, 0, 0, 0),
                  children: [
                    Node(
                      key: '/etc/测试/文件.txt',
                      label: '文件.txt',
                      isDir: false,
                    )
                  ])
            ],
          ),
          Node(
            key: '/usr',
            label: 'usr',
            isDir: true,
            modifiedTime: DateTime.utc(2023, 3, 1, 0, 0, 0),
            children: [
              Node(
                key: '/usr/bin',
                label: 'bin',
                isDir: true,
                modifiedTime: DateTime.utc(2023, 4, 1, 0, 0, 0),
                children: [
                  Node(
                    key: '/usr/bin/bash',
                    label: 'bash',
                    isDir: false,
                  ),
                ],
              ),
            ],
          ),
        ],
      );

      // Write
      final writer = MlocateDBWriter(dbPath, rootNode);
      writer.write();

      // Read
      final parser = MlocateDBParser(dbPath);
      parser.parse();

      final parsedRoot = parser.rootNode;
      expect(parsedRoot, isNotNull);

      // Verify keys and structure
      expect(parsedRoot!.key, rootNode.key);
      expect(parsedRoot.label, rootNode.label);
      expect(parsedRoot.isDir, rootNode.isDir);

      final rootDirs = parsedRoot.children.map((e) => e.label).toList();
      expect(rootDirs, containsAll(['etc', 'usr']));

      final etcNode = parsedRoot.children.firstWhere((e) => e.label == 'etc');
      expect(etcNode.children.map((e) => e.label).toList(),
          containsAll(['fstab', 'passwd', '测试']));
      expect(etcNode.modifiedTime,
          rootNode.children.firstWhere((e) => e.label == 'etc').modifiedTime);

      final cjkFolder = etcNode.children.firstWhere((e) => e.label == '测试');
      expect(cjkFolder.children.map((e) => e.label).toList(),
          containsAll(['文件.txt']));
      expect(cjkFolder.isDir, true);

      final usrNode = parsedRoot.children.firstWhere((e) => e.label == 'usr');
      final binNode = usrNode.children.firstWhere((e) => e.label == 'bin');
      expect(
          binNode.children.map((e) => e.label).toList(), containsAll(['bash']));
    });
  });
}
