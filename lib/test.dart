import 'dart:convert';
import 'dart:io';

import 'database_engine/executor.dart';
import 'database_engine/parser.dart';

// import 'database_engine/parser.dart';
// import 'database_engine/executor.dart';

// void main() async {
//   final parser = Parser();
//   final db = Database();

//   print("Simple DartDB. Type SQL commands or 'exit'.");

//   while (true) {
//     stdout.write('dartdb> ');
//     final line = stdin.readLineSync();
//     if (line == null || line.trim().toLowerCase() == 'exit') break;

//     try {
//       final command = parser.parse(line);
//       db.execute(command);
//     } catch (e) {
//       print('Error: $e');
//     }
//   }
// }
// CREATE TABLE users (id int, name string, isAdmin bool);
// INSERT INTO users VALUES (1, Alice, true);
// INSERT INTO users VALUES (2, Bob, false);
// SELECT * FROM users WHERE isAdmin = true;
//implementing a database engine server in pure dart

// Nice! Building a database engine server in pure Dart is a pretty exciting project. Are you aiming for something lightweight like an in-memory key-value store, or a more complex relational/document-oriented engine? Also curious—are you planning to handle:

// SQL-like queries or a custom query language?

// ACID compliance or eventual consistency?

// Indexing and persistence?

// Happy to help you design it, implement core components like the parser, storage engine, query planner, etc.—just let me know where you're starting or what you’ve got so far.

// You said:
// you design it, implement core components like the parser, storage engine, query planner, etc
// ChatGPT said:
// Awesome — let’s design and scaffold a simple database engine server in pure Dart. The architecture will be modular and extensible, so you can evolve it from a basic in-memory system to one that supports file-backed storage, indexing, SQL-like querying, transactions, etc.

// 🧠 High-Level Design
// pgsql
// Copy
// Edit
// Client ↔ Server ↔ Parser → Query Planner → Execution Engine ↔ Storage Engine
//                                                  ↑
//                                               Catalog
// 🧱 Core Components
// 1. Server Layer
// Exposes a TCP or HTTP API.

// Accepts raw query strings from clients.

// Sends responses (result sets or error messages).

// 2. Parser
// Tokenizes and parses input queries (e.g., CREATE TABLE, INSERT INTO, SELECT).

// Outputs an AST (Abstract Syntax Tree) or Command object.

// 3. Query Planner / Executor
// Converts parsed commands into execution plans.

// Executes queries over storage engine.

// 4. Storage Engine
// Stores data in tables, rows, and columns.

// Starts with in-memory; later can support file-backed persistence.

// 5. Catalog / Schema
// Keeps track of table definitions, column types, constraints.

// 🛠️ Let's Build It (Scaffold)
// We’ll start with the main engine structure.

//'database_engine/db_engine.dart';
// dart
// Copy
// Edit
// import 'parser.dart';
// import 'executor.dart';
// import 'storage.dart';

// class DatabaseEngine {
//   final StorageEngine storage = StorageEngine();
//   final QueryExecutor executor;

//   DatabaseEngine() : executor = QueryExecutor();

//   Future<String> handle(String query) async {
//     final command = Parser.parse(query);
//     final result = await executor.execute(command, storage);
//     return result;
//   }
// }

// /lib/parser.dart
// dart
// Copy
// Edit
// abstract class Command {}

class Condition {
  final String column;
  final String value;
  Condition(this.column, this.value);
}

// class CreateTableCommand extends Command {
//   final String tableName;
//   final List<String> columns;
//   CreateTableCommand(this.tableName, this.columns);
// }

// class InsertCommand extends Command {
//   final String table;
//   final List<String> values;
//   InsertCommand(this.table, this.values);
// }

// class SelectCommand extends Command {
//   final String table;
//   final Condition? where;
//   SelectCommand(this.table, {this.where, String? whereColumn, String? whereValue});
// }

// class Parser {
//   static Command parse(String query) {
//     final tokens = query.trim().split(RegExp(r'\s+'));
//     final command = tokens.first.toUpperCase();

//     switch (command) {
//       case 'CREATE':
//         final table = tokens[2];
//         final cols = query.split('(')[1].split(')')[0].split(',');
//         return CreateTableCommand(table, cols.map((s) => s.trim()).toList());
//       case 'INSERT':
//         final table = tokens[2];
//         final vals = query
//             .split('VALUES')[1]
//             .replaceAll('(', '')
//             .replaceAll(')', '')
//             .split(',');
//         return InsertCommand(table, vals.map((s) => s.trim()).toList());
//       case 'SELECT':
//         final table = tokens.last;
//         if (tokens.contains('WHERE')) {
//           final whereIndex = tokens.indexOf('WHERE');
//           final col = tokens[whereIndex + 1];
//           final val = tokens[whereIndex + 3].replaceAll("'", "");
//           return SelectCommand(table, where: Condition(col, val));
//         }
//         return SelectCommand(table);
//       default:
//         throw Exception('Unknown query: $query');
//     }
//   }
// }

// /lib/storage.dart
// dart
// Copy
// Edit
// class Table {
//   final List<String> columns;
//   final List<List<String>> rows = [];

//   Table(this.columns);

//   void insert(List<String> values) {
//     if (values.length != columns.length) {
//       throw Exception("Column count mismatch");
//     }
//     rows.add(values);
//   }

//   List<List<String>> selectAll() => rows;
// }

// class StorageEngine {
//   final Map<String, Table> _tables = {};

//   void createTable(String name, List<Column> columns) {
//     if (_tables.containsKey(name)) throw Exception('Table exists: $name');
//     _tables[name] = Table(columns);
//   }

//   Table? getTable(String name) => _tables[name];
// }
// /lib/executor.dart
// dart
// Copy
// Edit
// import 'parser.dart';
// import 'storage.dart';

// class QueryExecutor {
//   Future<String> execute(Command command, StorageEngine storage) async {
//     if (command is CreateTableCommand) {
//       storage.createTable(command.tableName, command.columns);
//       return 'Table ${command.tableName} created.';
//     } else if (command is InsertCommand) {
//       final table = storage.getTable(command.table);
//       if (table == null) throw Exception("Table not found");
//       table.insert(command.values);
//       return 'Row inserted into ${command.table}.';
//     } else if (command is SelectCommand) {
//       final table = storage.getTable(command.table);

//       final filtered = table!.selectAll().where((row) {
//         if (command.where == null) return true;
//         final index =
//             table!.columns.indexWhere((c) => c.name == command.where!.column);
//         return row[index].toString() == command.where!.value;
//       }).toList();
//       if (table == null) throw Exception("Table not found");
//       final buffer = StringBuffer();
//       for (var row in table.selectAll()) {
//         buffer.writeln(row.join(' | '));
//       }
//       return buffer.toString();
//     } else {
//       throw Exception('Unknown command');
//     }
//   }
// }
// 🚀 Run Server Example
// You could expose this via TCP or HTTP, here’s a simple REPL for now:

// dart
// Copy
// Edit
// import 'dart:io';
// import 'lib/db_engine.dart';

// void main() async {
//   final engine = DatabaseEngine();
//   print('Welcome to DartDB!');
//   while (true) {
//     stdout.write('> ');
//     final input = stdin.readLineSync();
//     if (input == null || input.toLowerCase() == 'exit') break;

//     try {
//       final output = await engine.handle(input);
//       print(output);
//     } catch (e) {
//       print('Error: $e');
//     }
//   }
// }
// 🔮 Next Steps
//  Add data types (int, string, bool) with validation.

//  Add WHERE clauses.

//  Indexing for faster lookups.

//  Persistence: write tables to disk (JSON, binary, etc.).

//  SQL parser (or ANTLR integration).

//  Transactions (ACID compliance).

//  Add WebSocket/TCP or HTTP API.

// Would you like to start with just REPL + in-memory or jump into a web API too?

// You said:
// Add data types (int, string, bool) with validation.

//  Add WHERE clauses.

//  Indexing for faster lookups.

//  Persistence: write tables to disk (JSON, binary, etc.).

//  SQL parser (or ANTLR integration).

//  Transactions (ACID compliance).
// ChatGPT said:
// You're building a legit database engine — I love it. Let's upgrade your Dart DB engine in stages, each adding core DBMS features.
//Here's the detailed roadmap with Dart implementation strategies:

// ✅ 1. Data Types with Validation
// ✅ Goals:
// Support int, string, bool columns.

// Validate INSERT values against schema types.

// ✨ How:
// Modify the Table class to store column type definitions.

// dart
// Copy
// Edit
enum DataType { int, string, bool }

class Column {
  final String name;
  final DataType type;
  Column(this.name, this.type);
}

// class Table {
//   final List<Column> columns;
//   final List<List<dynamic>> rows = [];

//   Table(this.columns);

//   void insert(List<String> values) {
//     if (values.length != columns.length) {
//       throw Exception("Column count mismatch");
//     }

//     final converted = <dynamic>[];
//     for (int i = 0; i < values.length; i++) {
//       final val = values[i];
//       final type = columns[i].type;
//       converted.add(_convert(val, type));
//     }

//     rows.add(converted);
//   }

//   dynamic _convert(String val, DataType type) {
//     switch (type) {
//       case DataType.int:
//         return int.tryParse(val) ?? (throw Exception('Invalid int: $val'));
//       case DataType.bool:
//         if (val == 'true' || val == 'false') return val == 'true';
//         throw Exception('Invalid bool: $val');
//       case DataType.string:
//       default:
//         return val;
//     }
//   }

//   List<List<dynamic>> selectAll() => rows;
// }
// And update Parser so you can do:

// sql
// Copy
// Edit
// CREATE TABLE users (id int, name string, isAdmin bool);
// ✅ 2. WHERE Clauses
// ✅ Goals:
// Filter rows on SELECT using WHERE.

// ✨ How:
// Enhance the SelectCommand to store conditions.

// dart
// Copy
// Edit
// class Condition {
//   final String column;
//   final String value;
//   Condition(this.column, this.value);
// }

// class SelectCommand extends Command {
//   final String table;
//   final Condition? where;
//   SelectCommand(this.table, {this.where});
// }
// Update parser:

// dart
// Copy
// Edit
// if (tokens.contains('WHERE')) {
//   final whereIndex = tokens.indexOf('WHERE');
//   final col = tokens[whereIndex + 1];
//   final val = tokens[whereIndex + 3].replaceAll("'", "");
//   return SelectCommand(table, where: Condition(col, val));
// }
// And in executor:

// dart
// Copy
// Edit
// final filtered = table.selectAll().where((row) {
//   if (command.where == null) return true;
//   final index = table.columns.indexWhere((c) => c.name == command.where!.column);
//   return row[index].toString() == command.where!.value;
// }).toList();
// ✅ 3. Indexing (Hash Map Based)
// ✅ Goals:
// Speed up lookups by indexed column.

// ✨ How:
// Each table can maintain a Map<dynamic, List<int>> for column → row index mapping.

// dart
// Copy
// Edit
class Index {
  final String columnName;
  final Map<dynamic, List<int>> map = {};

  Index(this.columnName);

  void add(dynamic key, int rowIndex) {
    map.putIfAbsent(key, () => []).add(rowIndex);
  }

  List<int> lookup(dynamic key) => map[key] ?? [];
}
// Attach to Table, update during inserts, and use it to quickly find rows during WHERE.

// ✅ 4. Persistence
// ✅ Goals:
// Save/load tables to/from disk (JSON or binary).

// ✨ How:
// Use dart:io + dart:convert.

// dart
// Copy
// Edit
// Future<void> saveToFile(String path) async {
//   final json = jsonEncode({
//     'columns': columns.map((c) => {'name': c.name, 'type': c.type.name}).toList(),
//     'rows': rows,
//   });
//   await File(path).writeAsString(json);
// }

// static Future<Table> loadFromFile(String path) async {
//   final content = await File(path).readAsString();
//   final data = jsonDecode(content);

//   final cols = (data['columns'] as List)
//       .map((c) => Column(c['name'], DataType.values.byName(c['type'])))
//       .toList();

//   final table = Table(cols);
//   table.rows.addAll(List<List<dynamic>>.from(data['rows']));
//   return table;
// }
// You can persist each table as data/users.json.

// ✅ 5. SQL Parser / ANTLR
// ✅ Goals:
// Replace hand-written parser with full SQL grammar.

// ✨ How:
// Use ANTLR with Dart target.

// Use SQL grammar: https://github.com/antlr/grammars-v4/tree/master/sql

// Generate Dart parser using:

// sh
// Copy
// Edit
// antlr4 -Dlanguage=Dart SQL.g4
// Alternative (for now): expand your parser gradually (SELECT ... WHERE ..., LIMIT, ORDER BY).

// ✅ 6. Transactions & ACID
// ✅ Goals:
// Support BEGIN, COMMIT, ROLLBACK.

// Ensure atomicity, consistency, isolation, durability.

// ✨ How:
// Basic design:
// dart
// Copy
// Edit
class Transaction {
  final List<void Function()> _rollbackStack = [];

  void recordUndo(void Function() action) {
    _rollbackStack.add(action);
  }

  void rollback() {
    for (final undo in _rollbackStack.reversed) {
      undo();
    }
  }
}
// During an INSERT, store table.rows.removeLast as an undo.

// Locking and isolation can be added using mutex/semaphores.

// Command Example:
// sql
// Copy
// Edit
// BEGIN;
// INSERT INTO users VALUES (1, 'Alice', true);
// ROLLBACK;
// 🧩 Final Thoughts
// You're building a real foundational database here. Here's how you can move forward:

// Feature	Status	Next Steps
// Basic Parser	✅	Expand SQL grammar support
// Data Types	✅	Add type casting & null/default support
// WHERE Clause	✅	Add operators like <, >, !=, etc.
// Indexing	✅	Add B-Tree (later) for range queries
// Persistence	✅	Add WAL + journaling for durability
// Transactions	🚧	Add isolation levels, locking
// Query Planner	🚧	Implement optimizer and cost-based planning
// Would you like me to implement a specific one of these next (e.g., WHERE clause logic + parser + executor)?

// You said:
// Put the code in files so that I can copy
// ChatGPT said:
// Memory updated
// Sure! Here's a file-based structure for your Dart database engine project:

// 📁 lib/database_engine/column.dart
// dart
// Copy
// Edit
// enum DataType { int, string, bool }

// class Column {
//   final String name;
//   final DataType type;
//   Column(this.name, this.type);
// }
// 📁 lib/database_engine/index.dart
// dart
// Copy
// Edit
// class Index {
//   final String columnName;
//   final Map<dynamic, List<int>> map = {};

//   Index(this.columnName);

//   void add(dynamic key, int rowIndex) {
//     map.putIfAbsent(key, () => []).add(rowIndex);
//   }

//   List<int> lookup(dynamic key) => map[key] ?? [];
// }
// 📁 lib/database_engine/table.dart
// dart
// Copy
// Edit
// import 'dart:convert';
// import 'dart:io';

// import 'column.dart';
// import 'index.dart';

// class Table {
//   final List<Column> columns;
//   final List<List<dynamic>> rows = [];
//   final Map<String, Index> indexes = {};
//   final Map<String, SplayTreeMap<dynamic, List<List<dynamic>>>> _indexes = {};

//   final Map<String, BTreeNode> _btreeIndexes = {};
//   Table(this.columns);

//   void createIndex(String columnName) {
//     final colIndex = columns.indexWhere((c) => c.name == columnName);
//     if (colIndex == -1) return;

//     final map = SplayTreeMap<dynamic, List<List<dynamic>>>();
//     for (final row in rows) {
//       map.putIfAbsent(row[colIndex], () => []).add(row);
//     }
//     indexes[columnName] = map;
//   }

//   void createBTreeIndex(String column) {
//     final colIndex = columns.indexWhere((c) => c.name == column);
//     if (colIndex == -1) return;
//     final node = BTreeNode();

//     for (final row in rows) {
//       node.insert(row[colIndex], row);
//     }
//     _btreeIndexes[column] = node;
//   }

//   void insert(List<String> values) {
//     if (values.length != columns.length) {
//       throw Exception("Column count mismatch");
//     }

//     final converted = <dynamic>[];
//     for (int i = 0; i < values.length; i++) {
//       final val = values[i];
//       final type = columns[i].type;
//       converted.add(_convert(val, type));
//     }

//     rows.add(converted);

//     for (final entry in indexes.entries) {
//       final colIndex = columns.indexWhere((c) => c.name == entry.key);
//       entry.value.add(converted[colIndex], rows.length - 1);
//     }
//   }

//   dynamic _convert(String val, DataType type) {
//     switch (type) {
//       case DataType.int:
//         return int.tryParse(val) ?? (throw Exception('Invalid int: $val'));
//       case DataType.bool:
//         if (val == 'true' || val == 'false') return val == 'true';
//         throw Exception('Invalid bool: $val');
//       case DataType.string:
//       default:
//         return val;
//     }
//   }

//   List<List<dynamic>> selectAll() => rows;

//   List<List<dynamic>> selectWhere(
//       String columnName, String? op, String expectedValue) {
//     final colIndex = columns.indexWhere((c) => c.name == columnName);
//     final colType = columns[colIndex].type;
//     final val = _convert(expectedValue, colType);

//     return rows.where((row) {
//       final cell = row[colIndex];

//       switch (op) {
//         case '=':
//           return cell == val;
//         case '!=':
//           return cell != val;
//         case '<':
//           return (cell is Comparable && val is Comparable)
//               ? cell.compareTo(val) < 0
//               : false;
//         case '>':
//           return (cell is Comparable && val is Comparable)
//               ? cell.compareTo(val) > 0
//               : false;
//         default:
//           return false;
//       }
//     }).toList();
//   }

//   void deleteWhere(String col, String op, String val) {
//     final idx = columns.indexWhere((c) => c.name == col);
//     final type = columns[idx].type;
//     final convertedVal = _convert(val, type);

//     rows.removeWhere((row) {
//       final cell = row[idx];
//       return _compare(cell, convertedVal, op);
//     });
//   }

//   void updateWhere(
//       String col, String op, String val, Map<String, String> updates) {
//     final colIdx = columns.indexWhere((c) => c.name == col);
//     final type = columns[colIdx].type;
//     final convertedVal = _convert(val, type);

//     for (final row in rows) {
//       if (_compare(row[colIdx], convertedVal, op)) {
//         updates.forEach((key, newVal) {
//           final updateIdx = columns.indexWhere((c) => c.name == key);
//           final newTypedVal = _convert(newVal, columns[updateIdx].type);
//           row[updateIdx] = newTypedVal;
//         });
//       }
//     }
//   }

//   bool _compare(dynamic a, dynamic b, String op) {
//     switch (op) {
//       case '=':
//         return a == b;
//       case '!=':
//         return a != b;
//       case '<':
//         return (a as Comparable).compareTo(b) < 0;
//       case '>':
//         return (a as Comparable).compareTo(b) > 0;
//       default:
//         return false;
//     }
//   }

//   Future<void> saveToFile(String path) async {
//     final json = jsonEncode({
//       'columns':
//           columns.map((c) => {'name': c.name, 'type': c.type.name}).toList(),
//       'rows': rows,
//     });
//     await File(path).writeAsString(json);
//   }

//   static Future<Table> loadFromFile(String path) async {
//     final content = await File(path).readAsString();
//     final data = jsonDecode(content);

//     final cols = (data['columns'] as List)
//         .map((c) => Column(c['name'], DataType.values.byName(c['type'])))
//         .toList();

//     final table = Table(cols);
//     table.rows.addAll(List<List<dynamic>>.from(data['rows']));
//     return table;
//   }
// }
// 📁 lib/database_engine/command.dart
// dart
// Copy
// Edit
// abstract class Command {}

// class CreateTableCommand extends Command {
//   final String name;
//   final List<String> columnNames;
//   final List<String> columnTypes;
//   CreateTableCommand(this.name, this.columnNames, this.columnTypes);
// }

// class InsertCommand extends Command {
//   final String tableName;
//   final List<String> values;
//   InsertCommand(this.tableName, this.values);
// }

// class SelectCommand extends Command {
//   final String tableName;
//   final String? whereColumn;
//   final String? whereValue;
//   SelectCommand(this.tableName, {this.whereColumn, this.whereValue});
// }
// 📁 lib/database_engine/parser.dart
// dart
// Copy
// Edit
// import 'command.dart';

// class Parser {
//   Command parse(String input) {
//     final tokens = input
//         .trim()
//         .split(RegExp(r'\s+|(?=[(),;])|(?<=[(),;])'))
//         .where((t) => t.trim().isNotEmpty)
//         .toList();

//     if (tokens[0].toUpperCase() == 'CREATE') {
//       final tableName = tokens[2];
//       final columnDefs = tokens.sublist(4, tokens.length - 1);
//       final columnNames = <String>[];
//       final columnTypes = <String>[];

//       for (int i = 0; i < columnDefs.length; i += 3) {
//         columnNames.add(columnDefs[i]);
//         columnTypes.add(columnDefs[i + 1]);
//       }

//       return CreateTableCommand(tableName, columnNames, columnTypes);
//     } else if (tokens[0].toUpperCase() == 'INSERT') {
//       final tableName = tokens[2];
//       final values = tokens
//           .sublist(4, tokens.length - 1)
//           .where((v) => v != ',' && v != '(' && v != ')')
//           .toList();
//       return InsertCommand(tableName, values);
//     } else if (tokens[0].toUpperCase() == 'SELECT') {
//       final tableName = tokens[3];
//       if (tokens.contains('WHERE')) {
//         final whereIndex = tokens.indexOf('WHERE');
//         final col = tokens[whereIndex + 1];
//         final val = tokens[whereIndex + 3].replaceAll("'", "");
//         return SelectCommand(tableName, whereColumn: col, whereValue: val);
//       }
//       return SelectCommand(tableName);
//     }

//     throw Exception("Unknown command");
//   }
// }
// 📁 lib/database_engine/executor.dart
// dart
// Copy
// Edit
// import 'column.dart';
// import 'table.dart';
// import 'command.dart';

// class Database {
//   final Map<String, Table> _tables = {};
//   final Map<String, Table> _transactionBackup = {};
//   bool _inTransaction = false;
//   final List<Map<String, Table>> _transactionStack = [];

//   void execute(Command command) {
//     if (command is CreateTableCommand) {
//       final columns = List.generate(
//           command.columnNames.length,
//           (i) => Column(
//               command.columnNames[i], _parseType(command.columnTypes[i])));
//       _tables[command.name] = Table(columns);
//     } else if (command is InsertCommand) {
//       final table = _tables[command.tableName];
//       table?.insert(command.values);
//     } else if (command is SelectCommand) {
//       final table = _tables[command.tableName];
//       if (table == null) return;

//       final rows = (command.whereColumn != null)
//           ? table.selectWhere(
//               command.whereColumn!, command.whereOperator, command.whereValue!)
//           : table.selectAll();

//       for (final row in rows) {
//         print(row);
//       }
//     } else if (command is BeginTransactionCommand) {
//       if (_inTransaction) {
//         print("Already in a transaction.");
//         return;
//       }
//       _inTransaction = true;
//       _transactionBackup.clear();
//       for (final entry in _tables.entries) {
//         _transactionBackup[entry.key] = Table(entry.value.columns)
//           ..rows.addAll(entry.value.rows);
//       }
//       print("Transaction started.");
//     } else if (command is CommitTransactionCommand) {
//       if (!_inTransaction) {
//         print("No transaction in progress.");
//         return;
//       }
//       _transactionBackup.clear();
//       _inTransaction = false;
//       print("Transaction committed.");
//     } else if (command is RollbackTransactionCommand) {
//       if (!_inTransaction) {
//         print("No transaction in progress.");
//         return;
//       }
//       _tables.clear();
//       _tables.addAll(_transactionBackup);
//       _transactionBackup.clear();
//       _inTransaction = false;
//       print("Transaction rolled back.");
//     } else if (command is DeleteCommand) {
//       _tables[command.tableName]
//           ?.deleteWhere(command.whereColumn, command.operator, command.value);
//     } else if (command is UpdateCommand) {
//       _tables[command.tableName]?.updateWhere(command.whereColumn,
//           command.operator, command.value, command.updates);
//     } else if (command is BeginTransactionCommand) {
//       final snapshot = {
//         for (final entry in _tables.entries)
//           entry.key: Table(entry.value.columns)..rows.addAll(entry.value.rows)
//       };
//       _transactionStack.add(snapshot);
//       print("Transaction started. Nesting: ${_transactionStack.length}");
//     } else if (command is CommitTransactionCommand) {
//       if (_transactionStack.isEmpty) {
//         print("No transaction to commit.");
//       } else {
//         _transactionStack.removeLast();
//         print("Transaction committed.");
//       }
//     } else if (command is RollbackTransactionCommand) {
//       if (_transactionStack.isEmpty) {
//         print("No transaction to rollback.");
//       } else {
//         final last = _transactionStack.removeLast();
//         _tables
//           ..clear()
//           ..addAll(last);
//         print("Rolled back one transaction.");
//       }
//     } else if (command is JoinCommand) {
//       final left = _tables[command.leftTable];
//       final right = _tables[command.rightTable];
//       if (left == null || right == null) return;

//       final leftIdx =
//           left.columns.indexWhere((c) => c.name == command.leftColumn);
//       final rightIdx =
//           right.columns.indexWhere((c) => c.name == command.rightColumn);

//       for (final lRow in left.rows) {
//         for (final rRow in right.rows) {
//           if (lRow[leftIdx] == rRow[rightIdx]) {
//             final joined = [...lRow, ...rRow];
//             print(joined);
//           }
//         }
//       }
//     } else if (command is AlterTableCommand) {
//       final table = _tables[command.table];
//       if (table == null) return;

//       table.columns.add(Column(command.column, command.type));
//       for (final row in table.rows) {
//         row.add(_convert(command.defaultValue ?? '', command.type));
//       }
//     }
//   }

//   DataType _parseType(String t) {
//     switch (t.toLowerCase()) {
//       case 'int':
//         return DataType.int;
//       case 'bool':
//         return DataType.bool;
//       case 'string':
//       default:
//         return DataType.string;
//     }
//   }
// }
// 📁 bin/main.dart
// dart
// Copy
// Edit
// import 'dart:io';

// import '../lib/database_engine/parser.dart';
// import '../lib/database_engine/executor.dart';

void main() async {
  final parser = Parser();
  final db = Database();

  print("Simple DartDB. Type SQL commands or 'exit'.");

  while (true) {
    stdout.write('dartdb> ');
    final line = stdin.readLineSync();
    if (line == null || line.trim().toLowerCase() == 'exit') break;

    try {
      final command = parser.parse(line);
      db.execute(command);
    } catch (e) {
      print('Error: $e');
    }
  }
}
// ✅ How to Run
// bash
// Copy
// Edit
// dart run bin/main.dart
// Try commands like:

// sql
// Copy
// Edit
// CREATE TABLE users (id int, name string, isAdmin bool);
// INSERT INTO users VALUES (1, Alice, true);
// INSERT INTO users VALUES (2, Bob, false);
// SELECT * FROM users WHERE isAdmin = true;
// Want to add support for transactions, SQL operators (!=, <, >), or even an in-memory WAL next?

// You said:
//  add support for transactions, SQL operators (!=, <, >),
// ChatGPT said:
// Here’s how to add support for transactions and basic SQL operators (=, !=, <, >) to the Dart database engine:

// ✅ File Changes Summary
// We will:

// Add transaction support: BEGIN, COMMIT, ROLLBACK.

// Support !=, <, > operators in WHERE.

// Extend SelectCommand to store operator.

// Enhance parsing logic.

// Add evaluation logic in Table.selectWhere.

// 🔁 lib/database_engine/command.dart
// dart
// Copy
// Edit
// abstract class Command {}

// class CreateTableCommand extends Command {
//   final String name;
//   final List<String> columnNames;
//   final List<String> columnTypes;
//   CreateTableCommand(this.name, this.columnNames, this.columnTypes);
// }

// class InsertCommand extends Command {
//   final String tableName;
//   final List<String> values;
//   InsertCommand(this.tableName, this.values);
// }

// class SelectCommand extends Command {
//   final String tableName;
//   final String? whereColumn;
//   final String? whereOperator;
//   final String? whereValue;
//   SelectCommand(this.tableName,
//       {this.whereColumn, this.whereOperator, this.whereValue});
// }

// class BeginTransactionCommand extends Command {}

// class CommitTransactionCommand extends Command {}

// class RollbackTransactionCommand extends Command {}

// class DeleteCommand extends Command {
//   final String tableName;
//   final String whereColumn;
//   final String operator;
//   final String value;
//   DeleteCommand(this.tableName, this.whereColumn, this.operator, this.value);
// }

// class UpdateCommand extends Command {
//   final String tableName;
//   final Map<String, String> updates;
//   final String whereColumn;
//   final String operator;
//   final String value;
//   UpdateCommand(this.tableName, this.updates, this.whereColumn, this.operator,
//       this.value);
// }

// class JoinCommand extends Command {
//   final String leftTable;
//   final String rightTable;
//   final String leftColumn;
//   final String rightColumn;
//   JoinCommand(
//       this.leftTable, this.rightTable, this.leftColumn, this.rightColumn);
// }

// class AlterTableCommand extends Command {
//   final String table;
//   final String column;
//   final String type;
//   final dynamic defaultValue;
//   AlterTableCommand(this.table, this.column, this.type, this.defaultValue);
// }
// 🧠 p
// 🧠 lib/database_engine/parser.dart
// dart
// Copy
// Edit
// import 'command.dart';

// class Parser {
//   Command parse(String input) {
//     final tokens = input
//         .trim()
//         .split(RegExp(r'\s+|(?=[(),=<>!;])|(?<=[(),=<>!;])'))
//         .where((t) => t.trim().isNotEmpty)
//         .toList();
//     final upper = tokens[0].toUpperCase();

//     if (upper == 'CREATE') {
//       final tableName = tokens[2];
//       final columnDefs = tokens.sublist(4, tokens.length - 1);
//       final columnNames = <String>[];
//       final columnTypes = <String>[];

//       for (int i = 0; i < columnDefs.length; i += 3) {
//         columnNames.add(columnDefs[i]);
//         columnTypes.add(columnDefs[i + 1]);
//       }

//       return CreateTableCommand(tableName, columnNames, columnTypes);
//     } else if (upper == 'INSERT') {
//       final tableName = tokens[2];
//       final values = tokens
//           .sublist(4, tokens.length - 1)
//           .where((v) => v != ',' && v != '(' && v != ')')
//           .toList();
//       return InsertCommand(tableName, values);
//     } else if (upper == 'SELECT') {
//       final tableName = tokens[3];
//       if (tokens.contains('WHERE')) {
//         final whereIndex = tokens.indexOf('WHERE');
//         final col = tokens[whereIndex + 1];
//         final op = tokens[whereIndex + 2];
//         final val = tokens[whereIndex + 3].replaceAll("'", "");
//         return SelectCommand(tableName,
//             whereColumn: col, whereOperator: op, whereValue: val);
//       }
//       return SelectCommand(tableName);
//     } else if (upper == 'BEGIN') {
//       return BeginTransactionCommand();
//     } else if (upper == 'COMMIT') {
//       return CommitTransactionCommand();
//     } else if (upper == 'ROLLBACK') {
//       return RollbackTransactionCommand();
//     } else if (upper == 'DELETE') {
//       final table = tokens[2];
//       final col = tokens[tokens.indexOf('WHERE') + 1];
//       final op = tokens[tokens.indexOf('WHERE') + 2];
//       final val = tokens[tokens.indexOf('WHERE') + 3].replaceAll("'", "");
//       return DeleteCommand(table, col, op, val);
//     } else if (upper == 'UPDATE') {
//       final table = tokens[1];
//       final setIndex = tokens.indexOf('SET');
//       final whereIndex = tokens.indexOf('WHERE');
//       final updates = <String, String>{};

//       for (int i = setIndex + 1; i < whereIndex; i += 3) {
//         updates[tokens[i]] = tokens[i + 2].replaceAll("'", "");
//       }

//       final col = tokens[whereIndex + 1];
//       final op = tokens[whereIndex + 2];
//       final val = tokens[whereIndex + 3].replaceAll("'", "");
//       return UpdateCommand(table, updates, col, op, val);
//     } else if (upper == 'SELECT' && tokens.contains('JOIN')) {
//       final leftTable = tokens[3];
//       final rightTable = tokens[tokens.indexOf('JOIN') + 1];
//       final onIndex = tokens.indexOf('ON');
//       final onClause = tokens[onIndex + 1].split('=');
//       final leftCol = onClause[0].split('.').last;
//       final rightCol = onClause[1].split('.').last;
//       return JoinCommand(leftTable, rightTable, leftCol, rightCol);
//     } else if (upper == 'ALTER') {
//       final table = tokens[2];
//       final column = tokens[5];
//       final type = tokens[6];
//       final defaultVal =
//           tokens.length > 8 ? tokens[8].replaceAll("'", "") : null;
//       return AlterTableCommand(table, column, type, defaultVal);
//     }

//     throw Exception("Unknown command: ${tokens[0]}");
//   }
// }
// 💾 lib/database_engine/table.dart
// Update selectWhere() to support operators:

// dart
// Copy
// Edit
// List<List<dynamic>> selectWhere(String columnName, String? op, String expectedValue) {
//   final colIndex = columns.indexWhere((c) => c.name == columnName);
//   final colType = columns[colIndex].type;
//   final val = _convert(expectedValue, colType);

//   return rows.where((row) {
//     final cell = row[colIndex];

//     switch (op) {
//       case '=':
//         return cell == val;
//       case '!=':
//         return cell != val;
//       case '<':
//         return (cell is Comparable && val is Comparable) ? cell.compareTo(val) < 0 : false;
//       case '>':
//         return (cell is Comparable && val is Comparable) ? cell.compareTo(val) > 0 : false;
//       default:
//         return false;
//     }
//   }).toList();
// }
// 💼 lib/database_engine/executor.dart
// Add support for transactions (in-memory buffer):

// dart
// Copy
// Edit
// import 'column.dart';
// import 'table.dart';
// import 'command.dart';

// class Database {
//   final Map<String, Table> _tables = {};
//   final Map<String, Table> _transactionBackup = {};
//   bool _inTransaction = false;

//   void execute(Command command) {
//     if (command is CreateTableCommand) {
//       final columns = List.generate(command.columnNames.length,
//           (i) => Column(command.columnNames[i], _parseType(command.columnTypes[i])));
//       _tables[command.name] = Table(columns);
//     } else if (command is InsertCommand) {
//       final table = _tables[command.tableName];
//       table?.insert(command.values);
//     } else if (command is SelectCommand) {
//       final table = _tables[command.tableName];
//       if (table == null) return;

//       final rows = (command.whereColumn != null)
//           ? table.selectWhere(command.whereColumn!, command.whereOperator, command.whereValue!)
//           : table.selectAll();

//       for (final row in rows) {
//         print(row);
//       }
//     } else if (command is BeginTransactionCommand) {
//       if (_inTransaction) {
//         print("Already in a transaction.");
//         return;
//       }
//       _inTransaction = true;
//       _transactionBackup.clear();
//       for (final entry in _tables.entries) {
//         _transactionBackup[entry.key] = Table(entry.value.columns)..rows.addAll(entry.value.rows);
//       }
//       print("Transaction started.");
//     } else if (command is CommitTransactionCommand) {
//       if (!_inTransaction) {
//         print("No transaction in progress.");
//         return;
//       }
//       _transactionBackup.clear();
//       _inTransaction = false;
//       print("Transaction committed.");
//     } else if (command is RollbackTransactionCommand) {
//       if (!_inTransaction) {
//         print("No transaction in progress.");
//         return;
//       }
//       _tables.clear();
//       _tables.addAll(_transactionBackup);
//       _transactionBackup.clear();
//       _inTransaction = false;
//       print("Transaction rolled back.");
//     }
//   }

//   DataType _parseType(String t) {
//     switch (t.toLowerCase()) {
//       case 'int':
//         return DataType.int;
//       case 'bool':
//         return DataType.bool;
//       case 'string':
//       default:
//         return DataType.string;
//     }
//   }
// }
// ✨ Sample Usage
// sql
// Copy
// Edit
// CREATE TABLE users (id int, name string, isAdmin bool);
// INSERT INTO users VALUES (1, Alice, true);
// INSERT INTO users VALUES (2, Bob, false);
// BEGIN;
// INSERT INTO users VALUES (3, Charlie, false);
// SELECT * FROM users WHERE id > 1;
// ROLLBACK;
// SELECT * FROM users WHERE id > 1;
// Would you like to add:

// DELETE, UPDATE

// Nested transactions

// Index support for inequality (<, >)

// File-based WAL for durability?

// Let me know what’s next!

// You said:
//  add:

// DELETE, UPDATE

// Nested transactions

// Index support for inequality (<, >)
// ChatGPT said:
// Memory updated
// Perfect — here's how we’ll extend your Dart database engine with:

// ✅ New Features
// DELETE and UPDATE SQL Commands

// Nested Transactions using a stack of transaction layers

// Index Support for <, >, !=, using a simple in-memory TreeMap-like structure (SplayTreeMap)

// 🧠 command.dart – Add DeleteCommand and UpdateCommand
// dart
// Copy
// Edit
// class DeleteCommand extends Command {
//   final String tableName;
//   final String whereColumn;
//   final String operator;
//   final String value;
//   DeleteCommand(this.tableName, this.whereColumn, this.operator, this.value);
// }

// class UpdateCommand extends Command {
//   final String tableName;
//   final Map<String, String> updates;
//   final String whereColumn;
//   final String operator;
//   final String value;
//   UpdateCommand(this.tableName, this.updates, this.whereColumn, this.operator, this.value);
// }
// 🧠 parser.dart – Add Parsing Logic
// dart
// Copy
// Edit
// else if (upper == 'DELETE') {
//   final table = tokens[2];
//   final col = tokens[tokens.indexOf('WHERE') + 1];
//   final op = tokens[tokens.indexOf('WHERE') + 2];
//   final val = tokens[tokens.indexOf('WHERE') + 3].replaceAll("'", "");
//   return DeleteCommand(table, col, op, val);
// } else if (upper == 'UPDATE') {
//   final table = tokens[1];
//   final setIndex = tokens.indexOf('SET');
//   final whereIndex = tokens.indexOf('WHERE');
//   final updates = <String, String>{};

//   for (int i = setIndex + 1; i < whereIndex; i += 3) {
//     updates[tokens[i]] = tokens[i + 2].replaceAll("'", "");
//   }

//   final col = tokens[whereIndex + 1];
//   final op = tokens[whereIndex + 2];
//   final val = tokens[whereIndex + 3].replaceAll("'", "");
//   return UpdateCommand(table, updates, col, op, val);
// }
// 💾 table.dart – Add deleteWhere() and updateWhere()
// dart
// Copy
// Edit
// void deleteWhere(String col, String op, String val) {
//   final idx = columns.indexWhere((c) => c.name == col);
//   final type = columns[idx].type;
//   final convertedVal = _convert(val, type);

//   rows.removeWhere((row) {
//     final cell = row[idx];
//     return _compare(cell, convertedVal, op);
//   });
// }

// void updateWhere(String col, String op, String val, Map<String, String> updates) {
//   final colIdx = columns.indexWhere((c) => c.name == col);
//   final type = columns[colIdx].type;
//   final convertedVal = _convert(val, type);

//   for (final row in rows) {
//     if (_compare(row[colIdx], convertedVal, op)) {
//       updates.forEach((key, newVal) {
//         final updateIdx = columns.indexWhere((c) => c.name == key);
//         final newTypedVal = _convert(newVal, columns[updateIdx].type);
//         row[updateIdx] = newTypedVal;
//       });
//     }
//   }
// }

// bool _compare(dynamic a, dynamic b, String op) {
//   switch (op) {
//     case '=': return a == b;
//     case '!=': return a != b;
//     case '<': return (a as Comparable).compareTo(b) < 0;
//     case '>': return (a as Comparable).compareTo(b) > 0;
//     default: return false;
//   }
// }
// 🧠 executor.dart – Handle New Commands and Nested Transactions
// Replace the transaction system with a stack:

// dart
// Copy
// Edit
// final List<Map<String, Table>> _transactionStack = [];

// void execute(Command command) {
//   // existing CREATE, INSERT, SELECT...

//   else if (command is DeleteCommand) {
//     _tables[command.tableName]
//         ?.deleteWhere(command.whereColumn, command.operator, command.value);
//   } else if (command is UpdateCommand) {
//     _tables[command.tableName]
//         ?.updateWhere(command.whereColumn, command.operator, command.value, command.updates);
//   } else if (command is BeginTransactionCommand) {
//     final snapshot = {
//       for (final entry in _tables.entries)
//         entry.key: Table(entry.value.columns)..rows.addAll(entry.value.rows)
//     };
//     _transactionStack.add(snapshot);
//     print("Transaction started. Nesting: ${_transactionStack.length}");
//   } else if (command is CommitTransactionCommand) {
//     if (_transactionStack.isEmpty) {
//       print("No transaction to commit.");
//     } else {
//       _transactionStack.removeLast();
//       print("Transaction committed.");
//     }
//   } else if (command is RollbackTransactionCommand) {
//     if (_transactionStack.isEmpty) {
//       print("No transaction to rollback.");
//     } else {
//       final last = _transactionStack.removeLast();
//       _tables
//         ..clear()
//         ..addAll(last);
//       print("Rolled back one transaction.");
//     }
//   }
// }
// ⚡ Indexing Support (for <, >) with SplayTreeMap
// Add to Table:

// dart
// Copy
// Edit
// final Map<String, SplayTreeMap<dynamic, List<List<dynamic>>>> _indexes = {};

// void createIndex(String columnName) {
//   final colIndex = columns.indexWhere((c) => c.name == columnName);
//   if (colIndex == -1) return;

//   final map = SplayTreeMap<dynamic, List<List<dynamic>>>();
//   for (final row in rows) {
//     map.putIfAbsent(row[colIndex], () => []).add(row);
//   }
//   _indexes[columnName] = map;
// }
// Use in selectWhere() if index exists:

// dart
// Copy
// Edit
// if (_indexes.containsKey(columnName) && (op == '<' || op == '>')) {
//   final index = _indexes[columnName]!;
//   final result = <List<dynamic>>[];

//   if (op == '<') {
//     for (final key in index.keys) {
//       if ((key as Comparable).compareTo(val) >= 0) break;
//       result.addAll(index[key]!);
//     }
//   } else if (op == '>') {
//     for (final key in index.keys.where((k) => (k as Comparable).compareTo(val) > 0)) {
//       result.addAll(index[key]!);
//     }
//   }
//   return result;
// }
// 🧪 Test SQL Commands
// sql
// Copy
// Edit
// CREATE TABLE users (id int, name string, age int);
// INSERT INTO users VALUES (1, Alice, 22);
// INSERT INTO users VALUES (2, Bob, 30);
// INSERT INTO users VALUES (3, Eve, 25);
// UPDATE users SET name = 'Evelyn' WHERE id = 3;
// DELETE FROM users WHERE name = 'Bob';
// BEGIN;
// UPDATE users SET age = 99 WHERE name = 'Alice';
// ROLLBACK;
// 🧩 Next Options
// Would you like to add:

// Joins?

// Schema altering (ALTER TABLE)?

// B-tree or LSM-like storage engine?

// SQL query optimizer?

// Let me know — happy to modularize this for a CLI or Web UI too.

// You said:
// add:

// Joins?

// Schema altering (ALTER TABLE)?

// B-tree or LSM-like storage engine?

// SQL query optimizer?
// ChatGPT said:
// Memory updated
// Awesome — you're taking this Dart database project to the next level! Here's the plan for each feature:

// ✅ Feature Roadmap & Summary
// 1. Joins (initial: nested loop join)
// Implement SELECT ... FROM A JOIN B ON A.x = B.y.

// Start with INNER JOIN, then support LEFT JOIN, RIGHT JOIN.

// 2. ALTER TABLE support
// ADD COLUMN column_name type [DEFAULT value]

// Update existing rows with default values.

// 3. B-tree or LSM Tree Storage
// B-tree: Great for indexed reads/writes (classic RDBMS).

// LSM-tree: Fast writes, periodic compaction (used in LevelDB, RocksDB).

// You can start with in-memory B-tree, then persist nodes.

// 4. SQL Query Optimizer
// Rule-based optimizer: simplify expressions, rearrange joins.

// Cost-based optimizer: basic cost model (row estimates, index usage).

// Plan tree: nodes like Scan, Filter, Join, Project.

// 🔧 Let's Start with...
// Would you like to implement:

// Joins first (for richer queries)?

// ALTER TABLE to evolve schema?

// B-tree storage as foundation for indexing?

// Optimizer engine to rewrite and rank execution plans?

// Pick your priority (or mix), and I’ll break it down into clean modules and file updates you can paste into your Dart project.

// We’ll go full SQL engine mode. 😎

// You said:
// implement:

// Joins first (for richer queries)?

// ALTER TABLE to evolve schema?

// B-tree storage as foundation for indexing?

// Optimizer engine to rewrite and rank execution plans?
// ChatGPT said:
// Perfect — let’s implement each of these features step-by-step in your Dart database engine. Below is a clean implementation plan and code for each:

// ✅ 1. Joins (Nested Loop Join)
// We'll implement SELECT * FROM table1 JOIN table2 ON table1.colA = table2.colB.

// 🔧 JoinCommand in command.dart:
// dart
// Copy
// Edit
// class JoinCommand extends Command {
//   final String leftTable;
//   final String rightTable;
//   final String leftColumn;
//   final String rightColumn;
//   JoinCommand(this.leftTable, this.rightTable, this.leftColumn, this.rightColumn);
// }
// 🔍 Add parsing in parser.dart:
// dart
// Copy
// Edit
// } else if (upper == 'SELECT' && tokens.contains('JOIN')) {
//   final leftTable = tokens[3];
//   final rightTable = tokens[tokens.indexOf('JOIN') + 1];
//   final onIndex = tokens.indexOf('ON');
//   final onClause = tokens[onIndex + 1].split('=');
//   final leftCol = onClause[0].split('.').last;
//   final rightCol = onClause[1].split('.').last;
//   return JoinCommand(leftTable, rightTable, leftCol, rightCol);
// }
// ⚙️ Join logic in executor.dart:
// dart
// Copy
// Edit
// else if (command is JoinCommand) {
//   final left = _tables[command.leftTable];
//   final right = _tables[command.rightTable];
//   if (left == null || right == null) return;

//   final leftIdx = left.columns.indexWhere((c) => c.name == command.leftColumn);
//   final rightIdx = right.columns.indexWhere((c) => c.name == command.rightColumn);

//   for (final lRow in left.rows) {
//     for (final rRow in right.rows) {
//       if (lRow[leftIdx] == rRow[rightIdx]) {
//         final joined = [...lRow, ...rRow];
//         print(joined);
//       }
//     }
//   }
// }
// ✅ 2. ALTER TABLE — Add Column with Default
// 🔧 AlterTableCommand in command.dart:
// dart
// Copy
// Edit
// class AlterTableCommand extends Command {
//   final String table;
//   final String column;
//   final String type;
//   final dynamic defaultValue;
//   AlterTableCommand(this.table, this.column, this.type, this.defaultValue);
// }
// 🔍 Add to parser.dart:
// dart
// Copy
// Edit
// } else if (upper == 'ALTER') {
//   final table = tokens[2];
//   final column = tokens[5];
//   final type = tokens[6];
//   final defaultVal = tokens.length > 8 ? tokens[8].replaceAll("'", "") : null;
//   return AlterTableCommand(table, column, type, defaultVal);
// }
// ⚙️ Add to executor.dart:
// dart
// Copy
// Edit
// else if (command is AlterTableCommand) {
//   final table = _tables[command.table];
//   if (table == null) return;

//   table.columns.add(Column(command.column, command.type));
//   for (final row in table.rows) {
//     row.add(_convert(command.defaultValue ?? '', command.type));
//   }
// }
// ✅ 3. B-Tree Storage Engine (In-Memory Base)
// Create btree_node.dart:

// dart
// Copy
// Edit
// class BTreeNode {
//   bool isLeaf;
//   List<dynamic> keys;
//   List<List<List<dynamic>>> values;
//   List<BTreeNode> children;

//   BTreeNode({this.isLeaf = true})
//       : keys = [],
//         values = [],
//         children = [];

//   void insert(dynamic key, List<dynamic> row) {
//     int i = keys.indexWhere((k) => (k as Comparable).compareTo(key) >= 0);
//     if (i == -1) {
//       keys.add(key);
//       values.add([row]);
//     } else if (keys[i] == key) {
//       values[i].add(row);
//     } else {
//       keys.insert(i, key);
//       values.insert(i, [row]);
//     }
//   }

//   List<List<dynamic>> search(dynamic key) {
//     for (int i = 0; i < keys.length; i++) {
//       if (keys[i] == key) return values[i];
//     }
//     return [];
//   }
// }
// Then, in table.dart, plug into indexing:

// dart
// Copy
// Edit
// final Map<String, BTreeNode> _btreeIndexes = {};

// void createBTreeIndex(String column) {
//   final colIndex = columns.indexWhere((c) => c.name == column);
//   if (colIndex == -1) return;
//   final node = BTreeNode();

//   for (final row in rows) {
//     node.insert(row[colIndex], row);
//   }
//   _btreeIndexes[column] = node;
// }
// ✅ 4. Query Optimizer (Rule-Based Example)
// Create optimizer.dart:

// dart
// Copy
// Edit
// abstract class PlanNode {}

// class ScanNode extends PlanNode {
//   final String table;
//   ScanNode(this.table);
// }

// class FilterNode extends PlanNode {
//   final PlanNode source;
//   final String column;
//   final String operator;
//   final String value;
//   FilterNode(this.source, this.column, this.operator, this.value);
// }

// class JoinNode extends PlanNode {
//   final PlanNode left;
//   final PlanNode right;
//   final String leftCol;
//   final String rightCol;
//   JoinNode(this.left, this.right, this.leftCol, this.rightCol);
// }

// // Sample Optimizer Rules:
// // dart
// // Copy
// // Edit
// PlanNode optimize(PlanNode node) {
//   if (node is FilterNode && node.source is JoinNode) {
//     final join = node.source as JoinNode;

//     // Push filter below join if it applies to left
//     if ((join.left as ScanNode).table == node.column.split('.')[0]) {
//       return JoinNode(
//         FilterNode(join.left, node.column, node.operator, node.value),
//         join.right,
//         join.leftCol,
//         join.rightCol,
//       );
//     }
//   }
//   return node;
// }
// 🧪 Sample Query Flow
// sql
// Copy
// Edit
// ALTER TABLE users ADD COLUMN active bool DEFAULT true;

// CREATE INDEX ON users (age);  -- would use btree

// SELECT * FROM users JOIN orders ON users.id = orders.user_id;

// -- Optimized to:
// -- 1. Scan `orders`
// -- 2. Filter `users` by condition
// -- 3. Join
// Would you like me to:

// Package this in copy-pasteable file layout?

// Add support for multiple join types (LEFT JOIN)?

// Add persistence for the B-tree?

// Let’s keep building your Dart SQL engine!







// You said:
// add : Package this in copy-pasteable file layout?

// Add support for multiple join types (LEFT JOIN)?

// Add persistence for the B-tree?


// ChatGPT said:
// Memory updated
// Perfect. Here's your modular Dart SQL engine upgrade with:

// ✅ File-by-file layout

// ✅ Support for multiple join types (starting with LEFT JOIN)

// ✅ B-tree persistence (saved to disk as JSON for now)

// 📁 File Layout
// css
// Copy
// Edit
// lib/
// ├── command.dart
// ├── parser.dart
// ├── executor.dart
// ├── table.dart
// ├── btree_node.dart
// ├── optimizer.dart
// main.dart
// 📄 command.dart
// dart
// Copy
// Edit
// abstract class Command {}

// class JoinCommand extends Command {
//   final String leftTable;
//   final String rightTable;
//   final String leftColumn;
//   final String rightColumn;
//   final String joinType;
//   JoinCommand(this.leftTable, this.rightTable, this.leftColumn, this.rightColumn, this.joinType);
// }

// class AlterTableCommand extends Command {
//   final String table;
//   final String column;
//   final String type;
//   final dynamic defaultValue;
//   AlterTableCommand(this.table, this.column, this.type, this.defaultValue);
// }
// 📄 parser.dart
// dart
// Copy
// Edit
// import 'command.dart';

// Command? parse(String sql) {
//   final tokens = sql.replaceAll(";", "").split(RegExp(r'\s+'));
//   final upper = tokens[0].toUpperCase();

//   if (upper == 'ALTER') {
//     final table = tokens[2];
//     final column = tokens[5];
//     final type = tokens[6];
//     final defaultVal = tokens.length > 8 ? tokens[8].replaceAll("'", "") : null;
//     return AlterTableCommand(table, column, type, defaultVal);
//   } else if (upper == 'SELECT' && tokens.contains