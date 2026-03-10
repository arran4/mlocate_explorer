class Node {
  final String key;
  final String label;
  final List<Node> children;

  Node({required this.key, required this.label, this.children = const []});
}
