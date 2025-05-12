import 'column.dart';
import 'command.dart';
import 'table.dart';


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
}