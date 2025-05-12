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
  final String tableName;
  final String? whereColumn;
  final String? whereOperator;
  final String? whereValue;
  SelectCommand(this.tableName,
      {this.whereColumn, this.whereOperator, this.whereValue});
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
