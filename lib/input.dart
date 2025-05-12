import 'dart:convert';
import 'dart:io';

import 'dart:collection';

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

enum DataType { int, string, bool }

class Column {
  final String name;
  final DataType type;
  Column(this.name, this.type);
}

abstract class Command {}

class CreateTableCommand extends Command {
  final String name;
  final List<String> columnNames;
  final List<String> columnTypes;
  CreateTableCommand(this.name, this.columnNames, this.columnTypes);
}

class InsertCommand extends Command {
  final String tableName;
  final List<String> columns;
  final List<dynamic> values;

  InsertCommand(this.tableName, this.columns, this.values);
}

class SelectCommand extends Command {
  final List<String>? selectColumns;
  final String tableName;
  final String? whereColumn;
  final String? whereOperator;
  final String? whereValue;
  final String? orderByColumn;
  final String? groupByColumn;
  // final List<String>? aggregateFunctions; // Placeholder
  final String? joinTable;
  final String? joinOnLeft;
  final String? joinOnRight;

  SelectCommand(
    this.tableName, {
    this.selectColumns,
    this.whereColumn,
    this.whereOperator,
    this.whereValue,
    this.orderByColumn,
    this.groupByColumn,
    this.joinTable,
    this.joinOnLeft,
    this.joinOnRight,
  });
}

class BeginTransactionCommand extends Command {}

class CommitTransactionCommand extends Command {}

class RollbackTransactionCommand extends Command {}

class DeleteCommand extends Command {
  final String tableName;
  final String whereColumn;
  final String operator;
  final String value;
  DeleteCommand(this.tableName, this.whereColumn, this.operator, this.value);
}

class UpdateCommand extends Command {
  final String tableName;
  final Map<String, String> updates;
  final String whereColumn;
  final String operator;
  final String value;
  UpdateCommand(this.tableName, this.updates, this.whereColumn, this.operator,
      this.value);
}

class JoinCommand extends Command {
  final String leftTable;
  final String rightTable;
  final String leftColumn;
  final String rightColumn;
  JoinCommand(
      this.leftTable, this.rightTable, this.leftColumn, this.rightColumn);
}

class AlterTableCommand extends Command {
  final String table;
  final String column;
  final String type;
  final dynamic defaultValue;
  AlterTableCommand(this.table, this.column, this.type, this.defaultValue);
}

class Database {
  final Map<String, Table> _tables = {};
  final Map<String, Table> _transactionBackup = {};
  bool _inTransaction = false;
  final List<Map<String, Table>> _transactionStack = [];

  dynamic _convert(String val, DataType type) {
    switch (type) {
      case DataType.int:
        return int.tryParse(val) ?? (throw Exception('Invalid int: $val'));
      case DataType.bool:
        if (val == 'true' || val == 'false') return val == 'true';
        throw Exception('Invalid bool: $val');
      case DataType.string:
      default:
        return val;
    }
  }

  void execute(Command command) {
    if (command is CreateTableCommand) {
      final columns = List.generate(
          command.columnNames.length,
          (i) => Column(
              command.columnNames[i], _parseType(command.columnTypes[i])));
      _tables[command.name] = Table(columns);
    } else if (command is InsertCommand) {
      final table = _tables[command.tableName];
      table?.insert(command.values.map((e) => e.toString()).toList());
    } else if (command is SelectCommand) {
      final table = _tables[command.tableName];
      if (table == null) return;

      final rows = (command.whereColumn != null)
          ? table.selectWhere(
              command.whereColumn!, command.whereOperator, command.whereValue!)
          : table.selectAll();

      for (final row in rows) {
        print(row);
      }
    } else if (command is BeginTransactionCommand) {
      if (_inTransaction) {
        print("Already in a transaction.");
        return;
      }
      _inTransaction = true;
      _transactionBackup.clear();
      for (final entry in _tables.entries) {
        _transactionBackup[entry.key] = Table(entry.value.columns)
          ..rows.addAll(entry.value.rows);
      }
      print("Transaction started.");
    } else if (command is CommitTransactionCommand) {
      if (!_inTransaction) {
        print("No transaction in progress.");
        return;
      }
      _transactionBackup.clear();
      _inTransaction = false;
      print("Transaction committed.");
    } else if (command is RollbackTransactionCommand) {
      if (!_inTransaction) {
        print("No transaction in progress.");
        return;
      }
      _tables.clear();
      _tables.addAll(_transactionBackup);
      _transactionBackup.clear();
      _inTransaction = false;
      print("Transaction rolled back.");
    } else if (command is DeleteCommand) {
      _tables[command.tableName]
          ?.deleteWhere(command.whereColumn, command.operator, command.value);
    } else if (command is UpdateCommand) {
      _tables[command.tableName]?.updateWhere(command.whereColumn,
          command.operator, command.value, command.updates);
    } else if (command is BeginTransactionCommand) {
      final snapshot = {
        for (final entry in _tables.entries)
          entry.key: Table(entry.value.columns)..rows.addAll(entry.value.rows)
      };
      _transactionStack.add(snapshot);
      print("Transaction started. Nesting: ${_transactionStack.length}");
    } else if (command is CommitTransactionCommand) {
      if (_transactionStack.isEmpty) {
        print("No transaction to commit.");
      } else {
        _transactionStack.removeLast();
        print("Transaction committed.");
      }
    } else if (command is RollbackTransactionCommand) {
      if (_transactionStack.isEmpty) {
        print("No transaction to rollback.");
      } else {
        final last = _transactionStack.removeLast();
        _tables
          ..clear()
          ..addAll(last);
        print("Rolled back one transaction.");
      }
    } else if (command is JoinCommand) {
      final left = _tables[command.leftTable];
      final right = _tables[command.rightTable];
      if (left == null || right == null) return;

      final leftIdx =
          left.columns.indexWhere((c) => c.name == command.leftColumn);
      final rightIdx =
          right.columns.indexWhere((c) => c.name == command.rightColumn);

      for (final lRow in left.rows) {
        for (final rRow in right.rows) {
          if (lRow[leftIdx] == rRow[rightIdx]) {
            final joined = [...lRow, ...rRow];
            print(joined);
          }
        }
      }
    } else if (command is AlterTableCommand) {
      final table = _tables[command.table];
      if (table == null) return;

      table.columns.add(Column(command.column, _parseType(command.type)));
      for (final row in table.rows) {
        row.add(_convert(command.defaultValue ?? '', _parseType(command.type)));
      }
    }
  }

  DataType _parseType(String t) {
    switch (t.toLowerCase()) {
      case 'int':
        return DataType.int;
      case 'bool':
        return DataType.bool;
      case 'string':
      default:
        return DataType.string;
    }
  }

  // --- New methods for saving and loading the entire database ---

  Future<void> saveToFile(String path) async {
    final Map<String, dynamic> databaseData = {};
    for (final entry in _tables.entries) {
      final table = entry.value;
      databaseData[entry.key] = {
        'columns': table.columns
            .map((c) => {'name': c.name, 'type': c.type.name})
            .toList(),
        'rows': table.rows,
      };
    }
    final json = jsonEncode(databaseData);
    await File(path).writeAsString(json);
    print('Database saved to $path');
  }

  Future<void> loadFromFile(String path) async {
    final file = File(path);
    if (await file.exists()) {
      final content = await file.readAsString();
      final Map<String, dynamic> databaseData = jsonDecode(content);
      _tables.clear();
      for (final tableName in databaseData.keys) {
        final tableData = databaseData[tableName] as Map<String, dynamic>;
        final colsData = tableData['columns'] as List;
        final rowData = tableData['rows'] as List<dynamic>;

        final columns = colsData
            .map((c) => Column(c['name'], DataType.values.byName(c['type'])))
            .toList();
        final table = Table(columns);
        table.rows.addAll(rowData.cast<List<dynamic>>()); // Explicit cast

        _tables[tableName] = table;
      }
      print('Database loaded from $path');
    } else {
      print(
          'Database file not found at $path. Starting with an empty database.');
    }
  }
}

class Index {
  final String columnName;
  final Map<dynamic, List<int>> map = {};

  Index(this.columnName);

  void add(dynamic key, int rowIndex) {
    map.putIfAbsent(key, () => []).add(rowIndex);
  }

  List<int> lookup(dynamic key) => map[key] ?? [];
}

abstract class PlanNode {}

class ScanNode extends PlanNode {
  final String table;
  ScanNode(this.table);
}

class FilterNode extends PlanNode {
  final PlanNode source;
  final String column;
  final String operator;
  final String value;
  FilterNode(this.source, this.column, this.operator, this.value);
}

class JoinNode extends PlanNode {
  final PlanNode left;
  final PlanNode right;
  final String leftCol;
  final String rightCol;
  JoinNode(this.left, this.right, this.leftCol, this.rightCol);
}

// Edit
PlanNode optimize(PlanNode node) {
  if (node is FilterNode && node.source is JoinNode) {
    final join = node.source as JoinNode;

    // Push filter below join if it applies to left
    if ((join.left as ScanNode).table == node.column.split('.')[0]) {
      return JoinNode(
        FilterNode(join.left, node.column, node.operator, node.value),
        join.right,
        join.leftCol,
        join.rightCol,
      );
    }
  }
  return node;
}

class ColumnDefinition {
  final String name;
  final String type;

  ColumnDefinition(this.name, this.type);
}

class Parser {
  Command parse(String input) {
    String cleaned = input.trim().replaceAll(RegExp(r'\s+'), ' ');
    cleaned = cleaned.trim().replaceAll(RegExp(r';$'), '');

    if (cleaned.toUpperCase().startsWith('CREATE TABLE')) {
      return _parseCreateTable(cleaned);
    } else if (cleaned.toUpperCase().startsWith('INSERT INTO')) {
      return _parseInsert(cleaned);
    } else if (cleaned.toUpperCase().startsWith('SELECT')) {
      return _parseSelect(cleaned);
    } else if (cleaned.toUpperCase().startsWith('DELETE FROM')) {
      return _parseDelete(cleaned);
    } else if (cleaned.toUpperCase().startsWith('UPDATE')) {
      return _parseUpdate(cleaned);
    } else if (cleaned.toUpperCase().startsWith('ALTER TABLE')) {
      return _parseAlterTable(cleaned);
    } else {
      throw Exception("Unsupported SQL command: $cleaned");
    }
  }

  CreateTableCommand _parseCreateTable(String input) {
    final regex =
        RegExp(r'CREATE TABLE (\w+)\s*\((.+)\)', caseSensitive: false);
    final match = regex.firstMatch(input);
    if (match == null) throw Exception('Invalid CREATE TABLE syntax: $input');

    final tableName = match.group(1)!;
    final columnDefs = match.group(2)!;

    final names = <String>[];
    final types = <String>[];

    for (final part in columnDefs.split(',')) {
      final pieces = part.trim().split(RegExp(r'\s+'));
      if (pieces.length != 2) {
        throw Exception('Invalid column definition: $part in $input');
      }
      names.add(pieces[0]);
      types.add(pieces[1]);
    }

    return CreateTableCommand(tableName, names, types);
  }

  InsertCommand _parseInsert(String input) {
    final regex = RegExp(
      r"INSERT INTO (\w+)\s*\((.+?)\)\s*VALUES\s*\((.+?)\)",
      caseSensitive: false,
    );
    final match = regex.firstMatch(input);
    if (match == null) throw Exception("Invalid INSERT syntax: $input");

    final tableName = match.group(1)!;
    final columns = _splitCommaSeparated(match.group(2)!);
    final rawValues = _splitCommaSeparated(match.group(3)!);
    final values = rawValues.map(_parseLiteral).toList();

    return InsertCommand(tableName, columns, values);
  }

  SelectCommand _parseSelect(String input) {
    final regex = RegExp(
      r'SELECT\s+(.+?)\s+FROM\s+(\w+)(?:\s+WHERE\s+(.+?))?(?:\s+ORDER BY\s+(\w+))?(?:\s+GROUP BY\s+(\w+))?(?:\s+JOIN\s+(\w+)\s+ON\s+(\w+)\s*=\s*(\w+))?',
      caseSensitive: false,
    );
    final match = regex.firstMatch(input);
    if (match == null) throw Exception("Invalid SELECT syntax: $input");

    final selectClause = match.group(1)!;
    final tableName = match.group(2)!;
    final whereClause = match.group(3);
    final orderByClause = match.group(4);
    final groupByClause = match.group(5);
    final joinTable = match.group(6);
    final joinOnLeft = match.group(7);
    final joinOnRight = match.group(8);

    List<String>? selectColumns;
    if (selectClause.trim() != '*') {
      selectColumns = _splitCommaSeparated(selectClause);
    }

    String? whereColumn;
    String? whereOperator;
    String? whereValue;

    if (whereClause != null) {
      final whereParts = whereClause.trim().split(RegExp(r'\s+'));
      if (whereParts.length >= 3) {
        whereColumn = whereParts[0];
        whereOperator = whereParts[1];
        whereValue = whereParts.sublist(2).join(' ');
        // Basic validation of operator
        if (!['=', '!=', '<', '>', '<=', '>='].contains(whereOperator)) {
          throw Exception("Invalid WHERE operator: $whereOperator in $input");
        }
        whereValue = _stripQuotesIfPresent(whereValue);
      } else {
        throw Exception("Invalid WHERE clause: $whereClause in $input");
      }
    }

    return SelectCommand(
      tableName,
      selectColumns: selectColumns,
      whereColumn: whereColumn,
      whereOperator: whereOperator,
      whereValue: whereValue,
      orderByColumn: orderByClause,
      groupByColumn: groupByClause,
      joinTable: joinTable,
      joinOnLeft: joinOnLeft,
      joinOnRight: joinOnRight,
    );
  }

  DeleteCommand _parseDelete(String input) {
    final regex = RegExp(
      r'DELETE FROM (\w+)\s+WHERE\s+(\w+)\s*([=<>!]+)\s*(.+)',
      caseSensitive: false,
    );
    final match = regex.firstMatch(input);
    if (match == null) throw Exception("Invalid DELETE syntax: $input");

    return DeleteCommand(
      match.group(1)!,
      match.group(2)!,
      match.group(3)!,
      _stripQuotesIfPresent(match.group(4)!),
    );
  }

  UpdateCommand _parseUpdate(String input) {
    final regex = RegExp(
      r'UPDATE (\w+)\s+SET\s+(.+?)\s+WHERE\s+(\w+)\s*([=<>!]+)\s*(.+)',
      caseSensitive: false,
    );
    final match = regex.firstMatch(input);
    if (match == null) throw Exception("Invalid UPDATE syntax: $input");

    final tableName = match.group(1)!;
    final setClause = match.group(2)!;
    final whereColumn = match.group(3)!;
    final operator = match.group(4)!;
    final value = _stripQuotesIfPresent(match.group(5)!);

    final updates = <String, String>{};
    for (var pair in setClause.split(',')) {
      final parts = pair.trim().split('=');
      if (parts.length != 2) throw Exception('Invalid SET clause in $input');
      updates[parts[0].trim()] = _stripQuotesIfPresent(parts[1].trim());
    }

    return UpdateCommand(tableName, updates, whereColumn, operator, value);
  }

  AlterTableCommand _parseAlterTable(String input) {
    final regex = RegExp(
      r'ALTER TABLE (\w+)\s+ADD\s+(\w+)\s+(\w+)(?:\s+DEFAULT\s+(.+))?',
      caseSensitive: false,
    );
    final match = regex.firstMatch(input);
    if (match == null) throw Exception('Invalid ALTER TABLE syntax: $input');

    final tableName = match.group(1)!;
    final columnName = match.group(2)!;
    final type = match.group(3)!;
    final defaultValue = match.group(4); // optional

    return AlterTableCommand(tableName, columnName, type, defaultValue);
  }

  List<String> _splitCommaSeparated(String input) {
    return input.split(',').map((e) => e.trim()).toList();
  }

  dynamic _parseLiteral(String val) {
    if (val.toUpperCase() == 'TRUE') return true;
    if (val.toUpperCase() == 'FALSE') return false;
    final intVal = int.tryParse(val);
    if (intVal != null) return intVal;
    return _stripQuotesIfPresent(val);
  }

  String _stripQuotesIfPresent(String val) {
    if (val.startsWith("'") && val.endsWith("'")) {
      return val.substring(1, val.length - 1);
    }
    if (val.startsWith('"') && val.endsWith('"')) {
      return val.substring(1, val.length - 1);
    }
    return val;
  }
}

class Table {
  final List<Column> columns;
  final List<List<dynamic>> rows = [];
  final Map<String, SplayTreeMap<dynamic, List<List<dynamic>>>> indexes = {};

  // final Map<String, BTreeNode> _btreeIndexes = {};
  Table(this.columns);

  void createIndex(String columnName) {
    final colIndex = columns.indexWhere((c) => c.name == columnName);
    if (colIndex == -1) return;

    final map = SplayTreeMap<dynamic, List<List<dynamic>>>();
    for (final row in rows) {
      map.putIfAbsent(row[colIndex], () => []).add(row);
    }
    indexes[columnName] = map;
  }

  void createBTreeIndex(String column) {
    final colIndex = columns.indexWhere((c) => c.name == column);
    if (colIndex == -1) return;
    final node = BTreeNode();

    for (final row in rows) {
      node.insert(row[colIndex], row);
    }
    // _btreeIndexes[column] = node;
  }

  void insert(List<String> values) {
    if (values.length != columns.length) {
      throw Exception("Column count mismatch");
    }

    final converted = <dynamic>[];
    for (int i = 0; i < values.length; i++) {
      final val = values[i];
      final type = columns[i].type;
      converted.add(_convert(val, type));
    }

    rows.add(converted);

    for (final entry in indexes.entries) {
      final colIndex = columns.indexWhere((c) => c.name == entry.key);
      entry.value.putIfAbsent(converted[colIndex], () => []).add(rows.last);
    }
  }

  dynamic _convert(String val, DataType type) {
    if (val.endsWith(';')) {
      val = val.substring(0, val.length - 1); // Remove trailing semicolon
    }
    print('Converting value: $val to type: $type');
    switch (type) {
      case DataType.int:
        return int.tryParse(val) ?? (throw Exception('Invalid int: $val'));
      case DataType.bool:
        if (val.toLowerCase() == 'true' || val.toLowerCase() == 'false')
          return val.toLowerCase() == 'true';
        throw Exception('Invalid bool: $val');
      case DataType.string:
      default:
        return val;
    }
  }

  List<List<dynamic>> selectAll() => rows;

  List<List<dynamic>> selectWhere(
      String columnName, String? op, String expectedValue) {
    final colIndex = columns.indexWhere((c) => c.name == columnName);
    if (colIndex == -1) return [];
    final colType = columns[colIndex].type;
    final val = _convert(expectedValue, colType);

    return rows.where((row) {
      final cell = row[colIndex];
      return _compare(cell, val, op);
    }).toList();
  }

  void deleteWhere(String col, String op, String val) {
    final idx = columns.indexWhere((c) => c.name == col);
    if (idx == -1) return;
    final type = columns[idx].type;
    final convertedVal = _convert(val, type);

    rows.removeWhere((row) {
      final cell = row[idx];
      return _compare(cell, convertedVal, op);
    });
  }

  void updateWhere(
      String col, String op, String val, Map<String, String> updates) {
    final colIdx = columns.indexWhere((c) => c.name == col);
    if (colIdx == -1) {
      throw Exception("Column not found: $col");
    }
    final type = columns[colIdx].type;
    final convertedVal = _convert(val, type);
    print(
        'Trying to update column $col with value $convertedVal using operator $op');

    for (final row in rows) {
      print('Checking row: $row');
      if (_compare(row[colIdx], convertedVal, op)) {
        print('Condition matched for row: $row');
        updates.forEach((key, newVal) {
          final updateIdx = columns.indexWhere((c) => c.name == key);
          if (updateIdx == -1) {
            throw Exception("Column not found: $key");
          }
          final newTypedVal = _convert(newVal, columns[updateIdx].type);
          print('Updating $key to $newTypedVal');
          row[updateIdx] = newTypedVal;
        });
      }
    }
  }

  bool _compare(dynamic a, dynamic b, String? op) {
    if (op == null) return false;
    print('Comparing "$a" $op "$b"');
    switch (op) {
      case '=':
        return a == b;
      case '!=':
        return a != b;
      case '<':
        if (a is Comparable && b is Comparable) return a.compareTo(b) < 0;
        return false;
      case '>':
        if (a is Comparable && b is Comparable) return a.compareTo(b) > 0;
        return false;
      case '<=':
        if (a is Comparable && b is Comparable) return a.compareTo(b) <= 0;
        return false;
      case '>=':
        if (a is Comparable && b is Comparable) return a.compareTo(b) >= 0;
        return false;
      default:
        return false;
    }
  }

  Future<void> saveToFile(String path) async {
    final json = jsonEncode({
      'columns':
          columns.map((c) => {'name': c.name, 'type': c.type.name}).toList(),
      'rows': rows,
    });
    await File(path).writeAsString(json);
  }

  static Future<Table> loadFromFile(String path) async {
    final content = await File(path).readAsString();
    final data = jsonDecode(content);

    final cols = (data['columns'] as List)
        .map((c) => Column(c['name'], DataType.values.byName(c['type'])))
        .toList();

    final table = Table(cols);
    table.rows.addAll(List<List<dynamic>>.from(data['rows']));
    return table;
  }
}
// void main() {
//   final parser = Parser();
//   final db = Database();

//   final commands = [
//     // CREATE TABLE
//     "CREATE TABLE users (id INT, name TEXT, age INT);",

//     // INSERT
//     "INSERT INTO users (id, name, age) VALUES (1, 'Alice', 30);",
//     "INSERT INTO users (id, name, age) VALUES (2, 'Bob', 25);",
//     "INSERT INTO users (id, name, age) VALUES (3, 'Charlie', 35);",

//     // SELECT
//     "SELECT * FROM users;",

//     // UPDATE
//     "UPDATE users SET age = 31 WHERE name = 'Alice';",

//     // SELECT after update
//     "SELECT * FROM users WHERE name = 'Alice';",

//     // DELETE
//     "DELETE FROM users WHERE id = 2;",

//     // SELECT after delete
//     "SELECT * FROM users;"
//   ];

//   for (final commandText in commands) {
//     print("\nCommand: $commandText");
//     // try {
//     final command = parser.parse(commandText);
//     final result = db.execute(command);
//     // if (result != null) {
//     //   print("Result: $result");
//     // }
//     // } catch (e) {
//     //   print("Error: $e");
//     //  }
//   }
// }

void main() async {
  final parser = Parser();
  final db = Database();
  const databaseFilePath = 'mydatabase.json'; // Define the file path

  // Load the database if it exists
  await db.loadFromFile(databaseFilePath);

  final commands = [
    "CREATE TABLE users (id INT, name TEXT, age INT);",
    "INSERT INTO users (id, name, age) VALUES (1, 'Alice', 30);",
    "INSERT INTO users (id, name, age) VALUES (2, 'Bob', 25);",
    "SELECT * FROM users;",
    "UPDATE users SET age = 31 WHERE name = 'Alice';",
    "SELECT * FROM users WHERE name = 'Alice';",
    "DELETE FROM users WHERE id = 2;",
    "SELECT * FROM users;"
  ];

  for (final commandText in commands) {
    print("\nCommand: $commandText");
    try {
      final command = parser.parse(commandText);
      db.execute(command);
    } catch (e) {
      print("Error: $e");
    }
  }

  // Save the database to disk when the program finishes (or at specific points)
  await db.saveToFile(databaseFilePath);
}
