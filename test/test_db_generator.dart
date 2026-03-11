import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Generates a synthetic mlocate.db file according to the mlocate-db.txt spec.
class TestDbGenerator {
  final String outputPath;
  final List<String> directories;
  final Map<String, List<String>> directoryContents;

  TestDbGenerator({
    required this.outputPath,
    required this.directories,
    required this.directoryContents,
  });

  Future<void> generate() async {
    final file = File(outputPath);
    final raf = await file.open(mode: FileMode.write);

    try {
      // 1. Write Header
      await raf.writeFrom(
        Uint8List.fromList('\x00mlocate'.codeUnits),
      ); // Magic number

      // Config block size (big endian, 4 bytes)
      final configBlock = _createConfigBlock();
      await raf.writeFrom(_int32ToBytes(configBlock.length));

      await raf.writeByte(0); // version (0)
      await raf.writeByte(0); // require visibility flag (0)
      await raf.writeFrom(Uint8List(2)); // padding (2 bytes)

      // root of database
      await _writeNullTerminatedString(raf, '/');

      // 2. Write Configuration block
      await raf.writeFrom(configBlock);

      // 3. Write Directories
      for (final dir in directories) {
        // Directory Header
        await raf.writeFrom(
          _int64ToBytes(1672531200),
        ); // dir time sec (arbitrary: 2023-01-01)
        await raf.writeFrom(_int32ToBytes(0)); // dir time nano (0)
        await raf.writeFrom(Uint8List(4)); // padding (4 bytes)
        await _writeNullTerminatedString(raf, dir); // dir path

        // Directory Contents
        final contents = directoryContents[dir] ?? [];
        // Sort contents according to mlocate behavior
        contents.sort();

        for (final entry in contents) {
          final isDir = entry.endsWith('/');
          final name = isDir ? entry.substring(0, entry.length - 1) : entry;

          await raf.writeByte(isDir ? 1 : 0); // Type: 0 = file, 1 = subdir
          await _writeNullTerminatedString(raf, name);
        }

        // End of directory marker
        await raf.writeByte(2);
      }
    } finally {
      await raf.close();
    }
  }

  Uint8List _createConfigBlock() {
    final builder = BytesBuilder();
    // Example format: PRUNEPATHS\0/tmp /var/tmp\0
    // For test simplicity, we'll keep it very small or empty if possible
    builder.add(utf8.encode('prune_bind_mounts\x001\x00'));
    builder.add(utf8.encode('prunefs\x00NFS\x00'));
    builder.add([
      0,
    ]); // Spec: "The value list is terminated by one more NUL character."
    return builder.toBytes();
  }

  Uint8List _int32ToBytes(int value) {
    var buffer = Uint8List(4);
    var byteData = ByteData.view(buffer.buffer);
    byteData.setInt32(0, value, Endian.big);
    return buffer;
  }

  Uint8List _int64ToBytes(int value) {
    var buffer = Uint8List(8);
    var byteData = ByteData.view(buffer.buffer);
    byteData.setInt64(0, value, Endian.big);
    return buffer;
  }

  Future<void> _writeNullTerminatedString(
    RandomAccessFile raf,
    String str,
  ) async {
    await raf.writeFrom(utf8.encode(str));
    await raf.writeByte(0); // NUL terminator
  }
}
