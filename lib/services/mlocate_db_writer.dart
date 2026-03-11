import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../models/node.dart';

class MlocateDBWriter {
  Uint8List magicNumber = Uint8List.fromList('\x00mlocate'.codeUnits);

  final String filePath;
  late RandomAccessFile file;
  final Node rootNode;

  MlocateDBWriter(this.filePath, this.rootNode);

  void write() {
    file = File(filePath).openSync(mode: FileMode.write);
    _writeFileHeader();
    _writeDirectories(rootNode);
    file.closeSync();
  }

  void _writeFileHeader() {
    file.writeFromSync(magicNumber);

    // Configuration Block
    var configBlock = utf8.encode('prunepaths\x00/tmp /var/spool\x00');
    var configBlockSize = configBlock.length;

    _writeInt32(configBlockSize, endian: Endian.big);

    file.writeByteSync(0); // formatVersion
    file.writeByteSync(0); // requireVisibilityFlag
    file.writeFromSync([0, 0]); // padding

    _writeNullTerminatedString(rootNode.key);
    file.writeFromSync(configBlock);
  }

  void _writeDirectories(Node node) {
    if (node.isDir) {
      _writeDirectoryHeaderAndContents(node);
      for (var child in node.children) {
        if (child.isDir) {
          _writeDirectories(child);
        }
      }
    }
  }

  void _writeDirectoryHeaderAndContents(Node node) {
    var modifiedTimeSeconds = node.modifiedTime != null
        ? (node.modifiedTime!.millisecondsSinceEpoch ~/ 1000)
        : 0;

    _writeInt64(modifiedTimeSeconds, endian: Endian.big);
    _writeInt32(0, endian: Endian.big); // dirTimeNanoBytes
    file.writeFromSync([0, 0, 0, 0]); // padding

    _writeNullTerminatedString(node.key);

    for (var child in node.children) {
      file.writeByteSync(child.isDir ? 1 : 0);
      _writeNullTerminatedString(child.label);
    }

    file.writeByteSync(2); // End of directory marker
  }

  void _writeNullTerminatedString(String value) {
    file.writeFromSync(utf8.encode(value));
    file.writeByteSync(0);
  }

  void _writeInt32(int value, {Endian endian = Endian.big}) {
    var data = ByteData(4);
    data.setInt32(0, value, endian);
    file.writeFromSync(data.buffer.asUint8List());
  }

  void _writeInt64(int value, {Endian endian = Endian.big}) {
    var data = ByteData(8);
    data.setInt64(0, value, endian);
    file.writeFromSync(data.buffer.asUint8List());
  }
}
