import 'dart:convert';
import 'dart:io';

import 'btree_node.dart';
import 'column.dart';

import 'dart:collection';

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
        if (val == 'true' || val == 'false') return val == 'true';
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
    final colType = columns[colIndex].type;
    final val = _convert(expectedValue, colType);

    return rows.where((row) {
      final cell = row[colIndex];

      switch (op) {
        case '=':
          return cell == val;
        case '!=':
          return cell != val;
        case '<':
          return (cell is Comparable && val is Comparable)
              ? cell.compareTo(val) < 0
              : false;
        case '>':
          return (cell is Comparable && val is Comparable)
              ? cell.compareTo(val) > 0
              : false;
        default:
          return false;
      }
    }).toList();
  }

  void deleteWhere(String col, String op, String val) {
    final idx = columns.indexWhere((c) => c.name == col);
    final type = columns[idx].type;
    final convertedVal = _convert(val, type);

    rows.removeWhere((row) {
      final cell = row[idx];
      return _compare(cell, convertedVal, op);
    });
  }

  // void updateWhere(
  //     String col, String op, String val, Map<String, String> updates) {
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

  void updateWhere(
      String col, String op, String val, Map<String, String> updates) {
    final colIdx = columns.indexWhere((c) => c.name == col);
    if (colIdx == -1) {
      throw Exception("Column not found: $col");
    }
    final type = columns[colIdx].type;
    final convertedVal =
        _convert(val, type); // Convert the value for comparison
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
          final newTypedVal =
              _convert(newVal, columns[updateIdx].type); // Convert new value
          print('Updating $key to $newTypedVal');
          row[updateIdx] = newTypedVal;
        });
      }
    }
  }

  bool _compare(dynamic a, dynamic b, String op) {
    // Remove any surrounding quotes from strings before comparing
    if (a is String) {
      a = a.replaceAll("'", "");
    }
    if (b is String) {
      b = b.replaceAll("'", "");
    }

    print('Comparing "$a" $op "$b"'); // Added quotes to see exact string values
    switch (op) {
      case '=':
        return a == b; // Direct comparison (should work for strings)
      case '!=':
        return a != b; // Direct comparison (should work for strings)
      case '<':
        if (a is Comparable && b is Comparable) {
          return a.compareTo(b) < 0;
        }
        return false;
      case '>':
        if (a is Comparable && b is Comparable) {
          return a.compareTo(b) > 0;
        }
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
