enum DataType { int, string, bool }

class Column {
  final String name;
  final DataType type;
  Column(this.name, this.type);
}
