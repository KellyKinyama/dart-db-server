class BTreeNode {
  bool isLeaf;
  List<dynamic> keys;
  List<List<List<dynamic>>> values;
  List<BTreeNode> children;

  BTreeNode({this.isLeaf = true})
      : keys = [],
        values = [],
        children = [];

  void insert(dynamic key, List<dynamic> row) {
    int i = keys.indexWhere((k) => (k as Comparable).compareTo(key) >= 0);
    if (i == -1) {
      keys.add(key);
      values.add([row]);
    } else if (keys[i] == key) {
      values[i].add(row);
    } else {
      keys.insert(i, key);
      values.insert(i, [row]);
    }
  }

  List<List<dynamic>> search(dynamic key) {
    for (int i = 0; i < keys.length; i++) {
      if (keys[i] == key) return values[i];
    }
    return [];
  }
}
