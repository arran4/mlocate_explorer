import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:mlocate_explorer/services/mlocate_db_parser.dart';
import 'dart:typed_data';

void main() {
  group('Malformed UTF8 parsing', () {
    late String dbPath;

    setUp(() async {
      dbPath = 'test_malformed_utf8.db';
    });

    tearDown(() async {
      final file = File(dbPath);
      if (await file.exists()) {
        await file.delete();
      }
    });

    test('Parses db with malformed utf8', () async {
      final file = File(dbPath);
      final raf = await file.open(mode: FileMode.write);

      try {
        await raf.writeFrom(Uint8List.fromList('\x00mlocate'.codeUnits));
        await raf.writeFrom(Uint8List.fromList([0, 0, 0, 0])); // size
        await raf.writeByte(0);
        await raf.writeByte(0);
        await raf.writeFrom(Uint8List(2));

        await raf.writeFrom(Uint8List.fromList('/'.codeUnits));
        await raf.writeByte(0);

        // dirs
        await raf.writeFrom(Uint8List(8));
        await raf.writeFrom(Uint8List(4));
        await raf.writeFrom(Uint8List(4));
        await raf.writeFrom(Uint8List.fromList('/'.codeUnits));
        await raf.writeByte(0);

        // file
        await raf.writeByte(0);
        // malformed
        await raf.writeFrom([0x69, 0xc1, 0xbf, 0x32]);
        await raf.writeByte(0);

        await raf.writeByte(2); // end
      } finally {
        await raf.close();
      }

      final parser = MlocateDBParser(dbPath);
      parser.parse();

      expect(parser.errors, isEmpty);
      expect(parser.rootNode, isNotNull);
      expect(parser.rootNode!.children, isNotEmpty);
      expect(
        parser.rootNode!.children.first.label.contains('\uFFFD'),
        isTrue,
      ); // Invalid bytes should be replaced with replacement char
    });
  });
}
