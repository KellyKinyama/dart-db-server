// executor2.dart

import 'column.dart';
import 'command2.dart';
import 'table2.dart';

class Database {
  final Map<String, Table> _tables = {};
  final Map<String, Table> _transactionBackup = {};
  bool _inTransaction = false;
  final List<Map<String, Table>> _transactionStack = [];

  // Utility method for consistent type conversion
  dynamic _convert(String val, DataType type) {
    switch (type) {
      case DataType.int:
        final parsed = int.tryParse(val);
        if (parsed == null) {
          throw FormatException('Invalid integer value: $val');
        }
        return parsed;
      case DataType.bool:
        if (val.toLowerCase() == 'true') return true;
        if (val.toLowerCase() == 'false') return false;
        throw FormatException('Invalid boolean value: $val');
      case DataType.string:
      default:
        return val;
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

  void execute(Command command) {
    if (command is CreateTableCommand) {
      _executeCreateTable(command);
    } else if (command is InsertCommand) {
      _executeInsert(command);
    } else if (command is SelectCommand) {
      _executeSelect(command);
    } else if (command is BeginTransactionCommand) {
      _executeBeginTransaction(command);
    } else if (command is CommitTransactionCommand) {
      _executeCommitTransaction(command);
    } else if (command is RollbackTransactionCommand) {
      _executeRollbackTransaction(command);
    } else if (command is DeleteCommand) {
      _executeDelete(command);
    } else if (command is UpdateCommand) {
      _executeUpdate(command);
    } else if (command is DropTableCommand) {
      _executeDropTable(command);
    } else if (command is CreateIndexCommand) {
      _executeCreateIndex(command);
    } else if (command is DropIndexCommand) {
      _executeDropIndex(command);
    } else if (command is JoinCommand) {
      _executeJoinCommand(command);
    } else if (command is AlterTableCommand) {
      _executeAlterTableCommand(command);
    } else {
      throw Exception("Unsupported SQL command: $command");
    }
  }

  void _executeCreateTable(CreateTableCommand command) {
    final columns = List.generate(
      command.columnNames.length,
      (i) =>
          Column(command.columnNames[i], _parseType(command.columnTypes[i])),
    );
    _tables[command.name] = Table(columns);
    print("Table '${command.name}' created.");
  }

  void _executeInsert(InsertCommand command) {
    final table = _tables[command.tableName];
    if (table != null) {
      try {
        if (command.columns.isNotEmpty && command.columns.length != command.values.length) {
          throw Exception("Number of columns specified does not match the number of values.");
        }
        List<dynamic> rowData = List.filled(table.columns.length, null);
        if (command.columns.isEmpty) {
          if (command.values.length != table.columns.length) {
            throw Exception("Number of values does not match the table schema.");
          }
          rowData = command.values.asMap().map((index, value) =>
              MapEntry(index, _convert(value.toString(), table.columns[index].type))).values.toList();
        } else {
          for (int i = 0; i < command.columns.length; i++) {
            final columnName = command.columns[i];
            final value = command.values[i];
            final columnIndex = table.columns.indexWhere((col) => col.name == columnName);
            if (columnIndex == -1) {
              throw Exception("Column '$columnName' not found in table '${command.tableName}'.");
            }
            rowData[columnIndex] = _convert(value.toString(), table.columns[columnIndex].type);
          }
        }
        table.insert(rowData);
        print("Inserted into '${command.tableName}'.");
      } catch (e) {
        print("Error inserting into '${command.tableName}': $e");
      }
    } else {
      print("Error: Table '${command.tableName}' not found.");
    }
  }

  void _executeSelect(SelectCommand command) {
    final table = _tables[command.tableName];
    if (table == null) {
      print("Error: Table '${command.tableName}' not found.");
      return;
    }

    List<List<dynamic>> rows;
    if (command.whereColumn != null &&
        command.whereOperator != null &&
        command.whereValue != null) {
      rows = table.selectWhere(
          command.whereColumn!, command.whereOperator!, command.whereValue!);
    } else {
      rows = table.selectAll();
    }

    if (command.orderBy != null) {
      try {
        rows.sort((a, b) {
          for (final order in command.orderBy!) {
            final columnIndex =
                table.columns.indexWhere((c) => c.name == order.columnName);
            if (columnIndex == -1) {
              throw Exception(
                  "Order by column '${order.columnName}' not found.");
            }
            final comparableA = a[columnIndex] as Comparable;
            final comparableB = b[columnIndex] as Comparable;
            final comparison = comparableA.compareTo(comparableB);
            if (comparison != 0) {
              return order.order == Order.asc ? comparison : -comparison;
            }
          }
          return 0;
        });
      } catch (e) {
        print("Error during ORDER BY: $e");
        return; // Or handle the error as appropriate
      }
    }

    int startIndex = command.offset ?? 0;
    int endIndex = command.limit != null
        ? startIndex + command.limit!
        : rows.length;

    if (startIndex < 0) startIndex = 0;
    if (endIndex > rows.length) endIndex = rows.length;

    final resultRows = rows.sublist(startIndex, endIndex);

    if (command.selectedColumns != null) {
      try {
        final selectedColumnIndices = command.selectedColumns!.map((colName) {
          final index = table.columns.indexWhere((c) => c.name == colName);
          if (index == -1) {
            throw Exception("Selected column '$colName' not found.");
          }
          return index;
        }).toList();

        print(command.selectedColumns!.join('\t'));
        for (final row in resultRows) {
          final selectedRow = selectedColumnIndices.map((index) => row[index]).join('\t');
          print(selectedRow);
        }
      } catch (e) {
        print("Error selecting columns: $e");
      }
    } else {
      for (final row in resultRows) {
        print(row.join('\t'));
      }
    }
  }

  void _executeBeginTransaction(BeginTransactionCommand command) {
    if (_inTransaction) {
      print("Already in a transaction.");
      return;
    }
    _inTransaction = true;
    _transactionBackup.clear();
    for (final entry in _tables.entries) {
      _transactionBackup[entry.key] = Table.from(entry.value);
    }
    print("Transaction started.");
  }

  void _executeCommitTransaction(CommitTransactionCommand command) {
    if (!_inTransaction) {
      print("No transaction in progress.");
      return;
    }
    _transactionBackup.clear();
    _inTransaction = false;
    print("Transaction committed.");
  }

  void _executeRollbackTransaction(RollbackTransactionCommand command) {
    if (!_inTransaction) {
      print("No transaction in progress.");
      return;
    }
    _tables.clear();
    _tables.addAll(_transactionBackup);
    _transactionBackup.clear();
    _inTransaction = false;
    print("Transaction rolled back.");
  }

  void _executeDelete(DeleteCommand command) {
    final table = _tables[command.tableName];
    if (table != null) {
      try {
        final deletedCount = table.deleteWhere(
            command.whereColumn!, command.operator!, command.value!);
        print("$deletedCount row(s) deleted from '${command.tableName}'.");
      } catch (e) {
        print("Error deleting from '${command.tableName}': $e");
      }
    } else {
      print("Error: Table '${command.tableName}' not found.");
    }
  }

  void _executeUpdate(UpdateCommand command) {
    final table = _tables[command.tableName];
    if (table != null) {
      try {
        final updatedCount = table.updateWhere(
            command.whereColumn!, command.operator!, command.value!,
            command.updates);
        print("$updatedCount row(s) updated in '${command.tableName}'.");
      } catch (e) {
        print("Error updating '${command.tableName}': $e");
      }
    } else {
      print("Error: Table '${command.tableName}' not found.");
    }
  }

  void _executeDropTable(DropTableCommand command) {
    if (_tables.containsKey(command.tableName)) {
      _tables.remove(command.tableName);
      print("Table '${command.tableName}' dropped.");
    } else {
      print("Error: Table '${command.tableName}' not found.");
    }
  }

  void _executeCreateIndex(CreateIndexCommand command) {
    final table = _tables[command.tableName];
    if (table != null) {
      table.createIndex(command.columnName, indexName: command.indexName);
      print(
          "Index '${command.indexName}' created on '${command.tableName}(${command
              .columnName})'.");
    } else {
      print("Error: Table '${command.tableName}' not found.");
    }
  }

  void _executeDropIndex(DropIndexCommand command) {
    final table = _tables[command.tableName];
    if (table != null) {
      table.dropIndex(command.indexName);
      print(
          "Index '${command.indexName}' dropped from '${command
              .tableName}'.");
    } else {
      print(
          "Error: Index '${command.indexName}' not found on table '${command
              .tableName}'.");
    }
  }

  void _executeJoinCommand(JoinCommand command) {
    final leftTable = _tables[command.leftTable];
    final rightTable = _tables[command.rightTable];

    if (leftTable == null) {
      print("Error: Left Table '${command.leftTable}' not found");
      return;
    }

    if (rightTable == null) {
      print("Error: Right Table '${command.rightTable}' not found");
      return;
    }

    final leftColumnIndex =
        leftTable.columns.indexWhere((c) => c.name == command.leftColumn);
    final rightColumnIndex =
        rightTable.columns.indexWhere((c) => c.name == command.rightColumn);

    if (leftColumnIndex == -1) {
      throw Exception(
          "Left table '${command.leftTable}' does not contain column '${command
              .leftColumn}'");
    }
    if (rightColumnIndex == -1) {
      throw Exception(
          "Right table '${command.rightTable}' does not contain column '${command
              .rightColumn}'");
    }
    //Perform the join
    List<List<dynamic>> joinedRows = [];
    for (var leftRow in leftTable.rows) {
      for (var rightRow in rightTable.rows) {
        if (leftRow[leftColumnIndex] == rightRow[rightColumnIndex]) {
          joinedRows.add([...leftRow, ...rightRow]);
        }
      }
    }
    //Create new table
    List<Column> joinedColumns = [
      ...leftTable.columns,
      ...rightTable.columns
    ];
    Table joinedTable = Table(joinedColumns);
    joinedTable.rows.addAll(joinedRows);

    _displayTable(joinedTable);
  }

  void _executeAlterTableCommand(AlterTableCommand command) {
    final table = _tables[command.table];
    if (table == null) {
      print("Error: Table '${command.table}' not found.");
      return;
    }
    final columnIndex =
        table.columns.indexWhere((c) => c.name == command.column);
    if (columnIndex == -1) {
      throw Exception(
          "Column '${command.column}' not found in table '${command.table}'");
    }
    //Alter table - for now, just changing the type
    table.columns[columnIndex].type = _parseType(command.type);
    // Consider how to handle existing data conversion and default values more robustly
    print(
        "Table '${command.table}' altered, column '${command
            .column}' is now of type '${command.type}'");
  }

  void _displayTable(Table table) {
    // Print the column names
    print(table.columns.map((c) => c.name).join('\t'));
    // Print the rows
    for (var row in table.rows) {
      print(row.join('\t'));
    }
  }
}