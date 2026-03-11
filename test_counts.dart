import 'dart:io';
import 'lib/models/node.dart';
import 'lib/services/mlocate_db_parser.dart';

void main() {
  var parser = MlocateDBParser('test/assets/test_docker_mlocate.db');
  parser.parse();
  var root = parser.rootNode;
  print('Root: ${root?.key}');
  print('Root Files: ${root?.fileCount}');
  print('Root Folders: ${root?.folderCount}');
}
