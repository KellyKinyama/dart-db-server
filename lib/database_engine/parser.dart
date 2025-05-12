import 'command.dart';

class Parser {
  Command parse(String input) {
    String cleaned = input.trim().replaceAll(RegExp(r'\s+'), ' ');
    cleaned = input.trim().replaceAll(RegExp(r';$'), '');

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
      throw Exception("Unsupported SQL command");
    }
  }

  CreateTableCommand _parseCreateTable(String input) {
    final regex =
        RegExp(r'CREATE TABLE (\w+)\s*\((.+)\)', caseSensitive: false);
    final match = regex.firstMatch(input);
    if (match == null) throw Exception('Invalid CREATE TABLE syntax');

    final tableName = match.group(1)!;
    final columnDefs = match.group(2)!;

    final names = <String>[];
    final types = <String>[];

    for (final part in columnDefs.split(',')) {
      final pieces = part.trim().split(RegExp(r'\s+'));
      if (pieces.length != 2) {
        throw Exception('Invalid column definition: $part');
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
    if (match == null) throw Exception("Invalid INSERT syntax");

    final tableName = match.group(1)!;
    final columns = _splitCommaSeparated(match.group(2)!);
    final rawValues = _splitCommaSeparated(match.group(3)!);
    final values = rawValues.map(_parseLiteral).toList();

    return InsertCommand(tableName, columns, values);
  }

  SelectCommand _parseSelect(String input) {
    final whereRegex = RegExp(
        r'SELECT \* FROM (\w+)\s+WHERE\s+(\w+)\s*([=<>!]+)\s*(.+)',
        caseSensitive: false);
    final simpleRegex = RegExp(r'SELECT \* FROM (\w+)', caseSensitive: false);

    final whereMatch = whereRegex.firstMatch(input);
    if (whereMatch != null) {
      return SelectCommand(
        whereMatch.group(1)!,
        whereColumn: whereMatch.group(2),
        whereOperator: whereMatch.group(3),
        whereValue: whereMatch.group(4),
      );
    }

    final simpleMatch = simpleRegex.firstMatch(input);
    if (simpleMatch != null) {
      return SelectCommand(simpleMatch.group(1)!);
    }

    throw Exception("Invalid SELECT syntax");
  }

  DeleteCommand _parseDelete(String input) {
    final regex = RegExp(
      r'DELETE FROM (\w+)\s+WHERE\s+(\w+)\s*([=<>!]+)\s*(.+)',
      caseSensitive: false,
    );
    final match = regex.firstMatch(input);
    if (match == null) throw Exception("Invalid DELETE syntax");

    return DeleteCommand(
      match.group(1)!,
      match.group(2)!,
      match.group(3)!,
      match.group(4)!,
    );
  }

  UpdateCommand _parseUpdate(String input) {
    final regex = RegExp(
      r'UPDATE (\w+)\s+SET\s+(.+?)\s+WHERE\s+(\w+)\s*([=<>!]+)\s*(.+)',
      caseSensitive: false,
    );
    final match = regex.firstMatch(input);
    if (match == null) throw Exception("Invalid UPDATE syntax");

    final tableName = match.group(1)!;
    final setClause = match.group(2)!;
    final whereColumn = match.group(3)!;
    final operator = match.group(4)!;
    final value = match.group(5)!;

    final updates = <String, String>{};
    for (var pair in setClause.split(',')) {
      final parts = pair.trim().split('=');
      if (parts.length != 2) throw Exception('Invalid SET clause');
      updates[parts[0].trim()] = parts[1].trim();
    }

    return UpdateCommand(tableName, updates, whereColumn, operator, value);
  }

  AlterTableCommand _parseAlterTable(String input) {
    final regex = RegExp(
      r'ALTER TABLE (\w+)\s+ADD\s+(\w+)\s+(\w+)(?:\s+DEFAULT\s+(.+))?',
      caseSensitive: false,
    );
    final match = regex.firstMatch(input);
    if (match == null) throw Exception('Invalid ALTER TABLE syntax');

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
    if (val == 'true') return true;
    if (val == 'false') return false;
    final intVal = int.tryParse(val);
    if (intVal != null) return intVal;
    return val.replaceAll("'", "").replaceAll('"', '');
  }
}
