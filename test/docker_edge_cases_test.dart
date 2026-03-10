import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:mlocate_explorer/services/mlocate_db_parser.dart';

void main() {
  group('MlocateDBParser Edge Cases with Docker DB', () {
    test('Parses db with edge cases (spaces, special chars) successfully', () {
      const dbPath = 'test/assets/test_docker_mlocate.db';
      final file = File(dbPath);

      if (!file.existsSync()) {
        // Skip test if we can't find the db
        // ignore: avoid_print
        print('Warning: test_docker_mlocate.db not found, skipping edge cases test.');
        return;
      }

      final parser = MlocateDBParser(dbPath);
      parser.parse();

      expect(parser.rootNode, isNotNull);
      expect(parser.rootNode!.key, '/testdir');

      // We expect exactly 5 children inside /testdir (no duplicates):
      // - large_dir
      // - normal_dir
      // - spaces in name
      // - special_chars
      // - ñandú
      expect(parser.rootNode!.children.length, 5);

      var childNames = parser.rootNode!.children.map((n) => n.label).toList();
      expect(childNames, containsAll([
        'large_dir',
        'normal_dir',
        'spaces in name',
        'special_chars',
        'ñandú',
      ]));

      // Check the contents of 'spaces in name'
      var spacesDir = parser.rootNode!.children.firstWhere((n) => n.label == 'spaces in name');
      expect(spacesDir.children.length, 1);
      expect(spacesDir.children.first.label, 'file with spaces.txt');

      // Check the contents of 'special_chars'
      var specialCharsDir = parser.rootNode!.children.firstWhere((n) => n.label == 'special_chars');
      expect(specialCharsDir.children.length, 2);
      var specialFiles = specialCharsDir.children.map((n) => n.label).toList();
      expect(specialFiles, contains('file_\n_newline.txt'));
      expect(specialFiles, contains('file_"_quotes.txt'));

      // Check the contents of 'ñandú'
      var nanduDir = parser.rootNode!.children.firstWhere((n) => n.label == 'ñandú');
      expect(nanduDir.children.length, 1);
      expect(nanduDir.children.first.label, 'archivo.txt');

      // Check 'large_dir'
      var largeDir = parser.rootNode!.children.firstWhere((n) => n.label == 'large_dir');
      expect(largeDir.children.length, 100);
      for (int i = 1; i <= 100; i++) {
        expect(largeDir.children.map((n) => n.label), contains('file_$i.txt'));
      }
    });
  });
}
