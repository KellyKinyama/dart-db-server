/// In-memory table with row storage, ordered indexes (SplayTreeMap), and
/// JSON serialization. Rows are `List<Object?>` aligned with `columns`.
library;

import 'dart:collection';

import 'schema.dart';

/// Definition of an index attached to a table.
class IndexDef {
  final String name;
  final String column; // for expression indexes, holds the SQL text
  final bool unique;

  /// Optional WHERE predicate (SQL text) for partial indexes.
  final String? whereSql;

  /// Optional indexed-expression source (SQL text). When non-null the index
  /// is on this expression rather than a base column.
  final String? exprSql;
  IndexDef(this.name, this.column,
      {this.unique = false, this.whereSql, this.exprSql});
}

class Table {
  String name;
  final List<ColumnDef> columns;
  final List<TableConstraint> constraints;
  final List<List<Object?>> rows;
  final Map<String, IndexDef> indexDefs; // index name -> def
  final Map<String, SplayTreeMap<Object, List<int>>> indexes;

  /// AUTOINCREMENT counters keyed by column name. Reset by TRUNCATE.
  final Map<String, int> autoInc;

  /// True for `CREATE TABLE ... STRICT`. Type checking rejects mismatched
  /// values instead of coercing.
  bool strict;

  Table(this.name, this.columns,
      {List<TableConstraint>? constraints, this.strict = false})
      : constraints = List<TableConstraint>.from(constraints ?? const []),
        rows = <List<Object?>>[],
        indexDefs = <String, IndexDef>{},
        indexes = <String, SplayTreeMap<Object, List<int>>>{},
        autoInc = <String, int>{};

  Table._raw(this.name, this.columns, this.constraints, this.rows,
      this.indexDefs, this.indexes, this.autoInc,
      {this.strict = false});

  /// Deep clone (used for transaction snapshots).
  Table clone() {
    final clonedRows = rows.map((r) => List<Object?>.from(r)).toList();
    final clonedDefs = Map<String, IndexDef>.from(indexDefs);
    final clonedIdx = <String, SplayTreeMap<Object, List<int>>>{};
    for (final e in indexes.entries) {
      final m = SplayTreeMap<Object, List<int>>(_compareKeys);
      for (final kv in e.value.entries) {
        m[kv.key] = List<int>.from(kv.value);
      }
      clonedIdx[e.key] = m;
    }
    return Table._raw(
        name,
        List<ColumnDef>.from(columns),
        List<TableConstraint>.from(constraints),
        clonedRows,
        clonedDefs,
        clonedIdx,
        Map<String, int>.from(autoInc),
        strict: strict);
  }

  int columnIndex(String colName) {
    final i = columns
        .indexWhere((c) => c.name.toLowerCase() == colName.toLowerCase());
    if (i == -1)
      throw StateError('Column "$colName" not found in table "$name"');
    return i;
  }

  /// Build a `column-name -> value` view of [row]. Both bare and `table.col`
  /// keys are populated so qualified expressions resolve.
  Map<String, Object?> rowToMap(List<Object?> row, {String? alias}) {
    final m = <String, Object?>{};
    for (var i = 0; i < columns.length; i++) {
      m[columns[i].name] = row[i];
      m['$name.${columns[i].name}'] = row[i];
      if (alias != null) m['$alias.${columns[i].name}'] = row[i];
    }
    return m;
  }

  /// Insert a single row. Values must already be coerced to the column types.
  /// Returns the new row id (index into [rows]).
  int insertRow(List<Object?> values) {
    if (values.length != columns.length) {
      throw StateError(
          'Expected ${columns.length} values, got ${values.length}');
    }
    // NOT NULL check
    for (var i = 0; i < columns.length; i++) {
      if (values[i] == null && columns[i].notNull) {
        throw FormatException('Column "${columns[i].name}" cannot be NULL');
      }
    }
    // UNIQUE / PRIMARY KEY check
    for (var i = 0; i < columns.length; i++) {
      final c = columns[i];
      if ((c.unique || c.primaryKey) && values[i] != null) {
        for (final existing in rows) {
          if (existing[i] == values[i]) {
            throw StateError(
                'UNIQUE constraint failed: ${c.name}=${values[i]}');
          }
        }
      }
    }
    final rowId = rows.length;
    rows.add(values);
    // Update indexes — expression / partial indexes are not maintained here
    // (the executor refreshes them via rebuild), so skip them.
    for (final entry in indexDefs.entries) {
      final def = entry.value;
      if (def.exprSql != null || def.whereSql != null) continue;
      final colIdx = columnIndex(def.column);
      final key = values[colIdx];
      if (key == null) continue;
      final tree = indexes[entry.key]!;
      final list = tree.putIfAbsent(key as Object, () => <int>[]);
      if (def.unique && list.isNotEmpty) {
        rows.removeLast();
        throw StateError('UNIQUE index ${entry.key} violation: $key');
      }
      list.add(rowId);
    }
    return rowId;
  }

  void createIndex(IndexDef def) {
    if (indexDefs.containsKey(def.name)) {
      throw StateError('Index ${def.name} already exists');
    }
    final tree = SplayTreeMap<Object, List<int>>(_compareKeys);
    // For expression / partial indexes the engine fills in lazily — just
    // record the def. The Database executor maintains them.
    if (def.exprSql != null || def.whereSql != null) {
      indexDefs[def.name] = def;
      indexes[def.name] = tree;
      return;
    }
    final colIdx = columnIndex(def.column);
    for (var i = 0; i < rows.length; i++) {
      final key = rows[i][colIdx];
      if (key == null) continue;
      final list = tree.putIfAbsent(key as Object, () => <int>[]);
      if (def.unique && list.isNotEmpty) {
        throw StateError(
            'Cannot build UNIQUE index ${def.name}: duplicate key $key');
      }
      list.add(i);
    }
    indexDefs[def.name] = def;
    indexes[def.name] = tree;
  }

  void dropIndex(String name) {
    indexDefs.remove(name);
    indexes.remove(name);
  }

  /// Add a new column with the given default for existing rows.
  void addColumn(ColumnDef col) {
    if (columns.any((c) => c.name.toLowerCase() == col.name.toLowerCase())) {
      throw StateError('Column ${col.name} already exists');
    }
    final fill =
        col.defaultValue == null ? null : coerce(col.defaultValue, col.type);
    columns.add(col);
    for (final r in rows) {
      r.add(fill);
    }
  }

  // --- Serialization -------------------------------------------------------
  Map<String, Object?> toJson() => {
        'name': name,
        'columns': columns.map((c) => c.toJson()).toList(),
        'constraints': constraints.map((c) => c.toJson()).toList(),
        'rows': rows.map((r) => r.map(storageToJsonValue).toList()).toList(),
        'indexes': indexDefs.values
            .map((d) => {
                  'name': d.name,
                  'column': d.column,
                  'unique': d.unique,
                  if (d.whereSql != null) 'where': d.whereSql,
                  if (d.exprSql != null) 'expr': d.exprSql,
                })
            .toList(),
        'autoInc': autoInc,
      };

  static Table fromJson(Map<String, Object?> j) {
    final cols = (j['columns'] as List)
        .map((c) => ColumnDef.fromJson((c as Map).cast<String, Object?>()))
        .toList();
    final cons = ((j['constraints'] as List?) ?? const [])
        .map(
            (c) => TableConstraint.fromJson((c as Map).cast<String, Object?>()))
        .toList();
    final t = Table(j['name'] as String, cols, constraints: cons);
    for (final r in (j['rows'] as List)) {
      t.rows.add((r as List).map((v) => jsonValueToStorage(v)).toList());
    }
    for (final idx in (j['indexes'] as List? ?? const [])) {
      final m = (idx as Map).cast<String, Object?>();
      t.createIndex(IndexDef(m['name'] as String, m['column'] as String,
          unique: m['unique'] == true,
          whereSql: m['where'] as String?,
          exprSql: m['expr'] as String?));
    }
    final ai = j['autoInc'];
    if (ai is Map) {
      ai.forEach((k, v) => t.autoInc[k as String] = (v as num).toInt());
    }
    return t;
  }

  static int _compareKeys(Object a, Object b) {
    if (a is num && b is num) return a.compareTo(b);
    if (a is Comparable && b is Comparable && a.runtimeType == b.runtimeType) {
      return a.compareTo(b);
    }
    return a.toString().compareTo(b.toString());
  }
}
