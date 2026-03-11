import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:mlocate_explorer/models/node.dart';

void main() {
  group('Node Serialization', () {
    test('circular serialization of a single node', () {
      final node = Node(
        key: '/etc/passwd',
        label: 'passwd',
        isDir: false,
        modifiedTime: DateTime.utc(2023, 10, 1, 12, 0, 0),
        isOpened: false,
        subFileCount: 0,
        subFolderCount: 0,
        deepFileCount: 0,
        deepFolderCount: 0,
      );

      final json1 = node.toJson();
      final node2 = Node.fromJson(json1);
      final json2 = node2.toJson();

      expect(json1, equals(json2));
      expect(node2.key, equals(node.key));
      expect(node2.label, equals(node.label));
      expect(node2.isDir, equals(node.isDir));
      expect(node2.modifiedTime, equals(node.modifiedTime));
      expect(node2.isOpened, equals(node.isOpened));
      expect(node2.subFileCount, equals(node.subFileCount));
      expect(node2.subFolderCount, equals(node.subFolderCount));
      expect(node2.deepFileCount, equals(node.deepFileCount));
      expect(node2.deepFolderCount, equals(node.deepFolderCount));
    });

    test('circular serialization of a complex tree', () {
      final rootNode = Node(
        key: '/',
        label: '/',
        isDir: true,
        modifiedTime: DateTime.utc(2023, 1, 1, 0, 0, 0),
        isOpened: true,
        subFileCount: 2,
        subFolderCount: 2,
        deepFileCount: 4,
        deepFolderCount: 3,
        children: [
          Node(
            key: '/etc',
            label: 'etc',
            isDir: true,
            modifiedTime: DateTime.utc(2023, 2, 1, 0, 0, 0),
            isOpened: false,
            subFileCount: 2,
            subFolderCount: 0,
            deepFileCount: 2,
            deepFolderCount: 0,
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
            ],
          ),
          Node(
            key: '/usr',
            label: 'usr',
            isDir: true,
            modifiedTime: DateTime.utc(2023, 3, 1, 0, 0, 0),
            isOpened: false,
            subFileCount: 0,
            subFolderCount: 1,
            deepFileCount: 2,
            deepFolderCount: 1,
            children: [
              Node(
                key: '/usr/bin',
                label: 'bin',
                isDir: true,
                subFileCount: 2,
                subFolderCount: 0,
                deepFileCount: 2,
                deepFolderCount: 0,
                children: [
                  Node(
                    key: '/usr/bin/bash',
                    label: 'bash',
                    isDir: false,
                  ),
                  Node(
                    key: '/usr/bin/ls',
                    label: 'ls',
                    isDir: false,
                  ),
                ],
              ),
            ],
          ),
        ],
      );

      final jsonString1 = jsonEncode(rootNode.toJson());

      final Map<String, dynamic> json1 = jsonDecode(jsonString1);
      final node2 = Node.fromJson(json1);
      final json2 = node2.toJson();

      final jsonString2 = jsonEncode(json2);

      expect(jsonString1, equals(jsonString2));
      expect(node2.key, equals(rootNode.key));
      expect(node2.children.length, equals(rootNode.children.length));

      final etcNode2 = node2.children.firstWhere((n) => n.label == 'etc');
      expect(etcNode2.children.length, equals(2));
      expect(etcNode2.children.map((n) => n.label), containsAll(['fstab', 'passwd']));

      final usrNode2 = node2.children.firstWhere((n) => n.label == 'usr');
      expect(usrNode2.children.length, equals(1));

      final usrBinNode2 = usrNode2.children.firstWhere((n) => n.label == 'bin');
      expect(usrBinNode2.children.length, equals(2));
      expect(usrBinNode2.children.map((n) => n.label), containsAll(['bash', 'ls']));
    });
  });
}
