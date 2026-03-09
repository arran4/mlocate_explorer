import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:mlocate_explorer/main.dart'; // Adjust import according to your package structure

import 'test_db_generator.dart';

void main() {
  group('MlocateDBParser', () {
    late String dbPath;

    setUp(() async {
      dbPath = 'test_mlocate.db';
    });

    tearDown(() async {
      final file = File(dbPath);
      if (await file.exists()) {
        await file.delete();
      }
    });

    test('Parses custom DB with common UNIX locations correctly', () async {
      // 1. Generate a synthetic DB based on mlocate-db.txt spec
      final generator = TestDbGenerator(
        outputPath: dbPath,
        directories: [
          '/',
          '/etc',
          '/usr',
          '/usr/bin',
        ],
        directoryContents: {
          '/': ['etc/', 'usr/'],
          '/etc': ['fstab', 'passwd'],
          '/usr': ['bin/'],
          '/usr/bin': ['bash', 'ls'],
        },
      );

      await generator.generate();

      // 2. Parse the generated DB
      final parser = MlocateDBParser(dbPath);
      await parser.parse();

      // 3. Verify the parsed output matches our input structure
      expect(parser.rootNode, isNotNull);
      expect(parser.rootNode!.key, '/');
      expect(parser.rootNode!.label, '/');

      // The root node (/) should contain etc and usr
      final rootDirs = parser.rootNode!.children.map((n) => n.label).toList();
      expect(rootDirs, containsAll(['etc', 'usr']));

      // Now verify contents of specific directories

      // Check /etc
      final etcNode =
          parser.rootNode!.children.firstWhere((n) => n.label == 'etc');
      final etcContents = etcNode.children.map((n) => n.label).toList();
      expect(etcContents, containsAll(['fstab', 'passwd']));

      // Check /usr
      final usrNode =
          parser.rootNode!.children.firstWhere((n) => n.label == 'usr');
      expect(usrNode.children.map((n) => n.label), contains('bin'));

      // Check /usr/bin
      final usrBinNode = usrNode.children.firstWhere((n) => n.label == 'bin');
      final usrBinContents = usrBinNode.children.map((n) => n.label).toList();
      expect(usrBinContents, containsAll(['bash', 'ls']));
    });
  });
}
