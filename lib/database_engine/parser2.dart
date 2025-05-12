import 'command2.dart';

class Parser {
  Command parse(String input) {
    String cleaned = input.trim().replaceAll(RegExp(r'\s+'), ' ');
    cleaned = cleaned.replaceAll(RegExp(r';$'), '');

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
    } else if (cleaned.toUpperCase().startsWith('DROP TABLE')) {
      return _parseDropTable(cleaned);
    } else if (cleaned.toUpperCase().startsWith('CREATE INDEX')) {
      return _parseCreateIndex(cleaned);
    } else if (cleaned.toUpperCase().startsWith('DROP INDEX')) {
      return _parseDropIndex(cleaned);
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
      r'SELECT\s+(.+?)\s+FROM\s+(\w+)(?:\s+WHERE\s+(.+?))?(?:\s+ORDER BY\s+(.+?))?(?:\s+LIMIT\s+(\d+))?(?:\s+OFFSET\s+(\d+))?',
      caseSensitive: false,
    );
    final match = regex.firstMatch(input);
    if (match == null) throw Exception("Invalid SELECT syntax: $input");

    final selectClause = match.group(1)!;
    final tableName = match.group(2)!;
    final whereClause = match.group(3);
    final orderByClause = match.group(4);
    final limitClause = match.group(5);
    final offsetClause = match.group(6);

    List<String>? selectedColumns;
    if (selectClause.trim() != '*') {
      selectedColumns = _splitCommaSeparated(selectClause);
    }

    String? whereColumn;
    String? whereOperator;
    String? whereValue;
    if (whereClause != null) {
      final whereParts = whereClause.trim().split(RegExp(r'\s*([=<>!]+)\s*'));
      if (whereParts.length == 2) {
        whereColumn = whereParts[0].trim();
        final operatorMatch =
            RegExp(r'([=<>!]+)').firstMatch(whereClause.trim());
        whereOperator = operatorMatch?.group(0);
        whereValue = _parseLiteral(whereParts[1].trim()).toString();
      } else {
        // More complex WHERE clauses can be handled later
        print("Warning: Complex WHERE clause not fully parsed: $whereClause");
      }
    }

    List<OrderBy>? orderBy;
    if (orderByClause != null) {
      orderBy = orderByClause.split(',').map((part) {
        final parts = part.trim().split(RegExp(r'\s+'));
        final columnName = parts[0];
        final order = parts.length > 1 && parts[1].toUpperCase() == 'DESC'
            ? Order.desc
            : Order.asc;
        return OrderBy(columnName, order);
      }).toList();
    }

    int? limit = limitClause != null ? int.tryParse(limitClause) : null;
    int? offset = offsetClause != null ? int.tryParse(offsetClause) : null;

    return SelectCommand(
      tableName,
      selectedColumns: selectedColumns,
      whereColumn: whereColumn,
      whereOperator: whereOperator,
      whereValue: whereValue,
      orderBy: orderBy,
      limit: limit,
      offset: offset,
    );
  }

  DeleteCommand _parseDelete(String input) {
    final regex = RegExp(
      r'DELETE FROM (\w+)(?:\s+WHERE\s+(\w+)\s*([=<>!]+)\s*(.+))?',
      caseSensitive: false,
    );
    final match = regex.firstMatch(input);
    if (match == null) throw Exception("Invalid DELETE syntax: $input");

    final tableName = match.group(1)!;
    final whereColumn = match.group(2);
    final operator = match.group(3);
    final value = match.group(4);

    return DeleteCommand(tableName,
        whereColumn: whereColumn, operator: operator, value: value);
  }

  UpdateCommand _parseUpdate(String input) {
    final regex = RegExp(
      r'UPDATE (\w+)\s+SET\s+(.+?)(?:\s+WHERE\s+(\w+)\s*([=<>!]+)\s*(.+))?',
      caseSensitive: false,
    );
    final match = regex.firstMatch(input);
    if (match == null) throw Exception("Invalid UPDATE syntax: $input");

    final tableName = match.group(1)!;
    final setClause = match.group(2)!;
    final whereColumn = match.group(3);
    final operator = match.group(4);
    final value = match.group(5);

    final updates = <String, String>{};
    for (var pair in setClause.split(',')) {
      final parts = pair.trim().split('=');
      if (parts.length != 2) throw Exception('Invalid SET clause in $input');
      updates[parts[0].trim()] = _parseLiteral(parts[1].trim()).toString();
    }

    return UpdateCommand(tableName,
        updates: updates,
        whereColumn: whereColumn,
        operator: operator,
        value: value);
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
    final defaultValue =
        match.group(4) != null ? _parseLiteral(match.group(4)!.trim()) : null;

    return AlterTableCommand(tableName, columnName, type, defaultValue);
  }

  DropTableCommand _parseDropTable(String input) {
    final regex = RegExp(r'DROP TABLE (\w+)', caseSensitive: false);
    final match = regex.firstMatch(input);
    if (match == null) throw Exception('Invalid DROP TABLE syntax: $input');
    return DropTableCommand(match.group(1)!);
  }

  CreateIndexCommand _parseCreateIndex(String input) {
    final regex = RegExp(r'CREATE INDEX (\w+)\s+ON\s+(\w+)\s*\((.+?)\)',
        caseSensitive: false);
    final match = regex.firstMatch(input);
    if (match == null) throw Exception('Invalid CREATE INDEX syntax: $input');

    final indexName = match.group(1)!;
    final tableName = match.group(2)!;
    final columnName = match.group(3)!.trim(); // Simple single column for now

    return CreateIndexCommand(indexName, tableName, columnName);
  }

  DropIndexCommand _parseDropIndex(String input) {
    final regex = RegExp(r'DROP INDEX (\w+)', caseSensitive: false);
    final match = regex.firstMatch(input);
    if (match == null) throw Exception('Invalid DROP INDEX syntax: $input');
    return DropIndexCommand(match.group(1)!);
  }

  List<String> _splitCommaSeparated(String input) {
    return input.split(',').map((e) => e.trim()).toList();
  }

  dynamic _parseLiteral(String val) {
    final trimmedVal = val.trim();
    if (trimmedVal.toUpperCase() == 'TRUE') return true;
    if (trimmedVal.toUpperCase() == 'FALSE') return false;
    final intVal = int.tryParse(trimmedVal);
    if (intVal != null) return intVal;
    // Attempt to parse as double in case of floating-point numbers (optional)
    final doubleVal = double.tryParse(trimmedVal);
    if (doubleVal != null) return doubleVal;
    // Remove surrounding quotes for strings
    if (trimmedVal.startsWith("'") && trimmedVal.endsWith("'")) {
      return trimmedVal.substring(1, trimmedVal.length - 1);
    }
    if (trimmedVal.startsWith('"') && trimmedVal.endsWith('"')) {
      return trimmedVal.substring(1, trimmedVal.length - 1);
    }
    return trimmedVal;
  }
}
