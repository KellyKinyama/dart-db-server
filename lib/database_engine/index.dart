class Index {
  final String columnName;
  final Map<dynamic, List<int>> map = {};

  Index(this.columnName);

  void add(dynamic key, int rowIndex) {
    map.putIfAbsent(key, () => []).add(rowIndex);
  }

  List<int> lookup(dynamic key) => map[key] ?? [];
}
