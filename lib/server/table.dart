/// In-memory table with row storage, ordered indexes (SplayTreeMap), and
/// JSON serialization. Rows are `List<Object?>` aligned with `columns`.
library;

import 'dart:collection';

import 'schema.dart';
import 'table_backend.dart';

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

  /// Full ordered list of indexed columns. For single-column indexes this
  /// is `[column]`; multi-column indexes carry every key column. The
  /// in-memory engine still treats only [column] as the lookup key, but
  /// the extra columns are preserved so they can be round-tripped through
  /// the SQLite file format.
  final List<String> columns;

  /// Per-column collation names ('BINARY' is the default). Currently
  /// honored: 'NOCASE' (case-insensitive string comparison). Length
  /// matches [columns].
  final List<String> collations;

  IndexDef(this.name, this.column,
      {this.unique = false,
      this.whereSql,
      this.exprSql,
      List<String>? columns,
      List<String>? collations})
      : columns = columns ?? [column],
        collations = collations ??
            List<String>.filled((columns ?? [column]).length, 'BINARY');

  /// Apply this index's collation rules to a key value at column position
  /// [pos]. Currently only 'NOCASE' transforms strings (lowercased).
  Object? collate(int pos, Object? value) {
    if (value is String &&
        pos < collations.length &&
        collations[pos].toUpperCase() == 'NOCASE') {
      return value.toLowerCase();
    }
    return value;
  }
}

class Table implements TableBackend {
  String name;
  final List<ColumnDef> columns;
  final List<TableConstraint> constraints;
  final List<List<Object?>> rows;
  final Map<String, IndexDef> indexDefs; // index name -> def
  final Map<String, SplayTreeMap<Object, List<int>>> indexes;

  // --- TableBackend (Phase 0 unification scaffold) ------------------------
  @override
  String get tableName => name;

  @override
  List<String> get columnNames => [for (final c in columns) c.name];

  @override
  TableBackendKind get kind => TableBackendKind.memory;

  /// AUTOINCREMENT counters keyed by column name. Reset by TRUNCATE.
  final Map<String, int> autoInc;

  /// True for `CREATE TABLE ... STRICT`. Type checking rejects mismatched
  /// values instead of coercing.
  bool strict;

  /// True for `CREATE TABLE ... WITHOUT ROWID`. Affects how the table is
  /// serialized into the SQLite file format (stored as an INDEX B-tree
  /// keyed by the PK record, not as a rowid table). The in-memory engine
  /// stores rows the same way regardless.
  bool withoutRowid;

  /// Names of constraints disabled via `ALTER TABLE … DISABLE CONSTRAINT`.
  /// While non-empty the table's FK checks are skipped (deferred-load flow).
  final Set<String> disabledConstraints = <String>{};

  Table(this.name, this.columns,
      {List<TableConstraint>? constraints,
      this.strict = false,
      this.withoutRowid = false})
      : constraints = List<TableConstraint>.from(constraints ?? const []),
        rows = <List<Object?>>[],
        indexDefs = <String, IndexDef>{},
        indexes = <String, SplayTreeMap<Object, List<int>>>{},
        autoInc = <String, int>{};

  Table._raw(this.name, this.columns, this.constraints, this.rows,
      this.indexDefs, this.indexes, this.autoInc,
      {this.strict = false, this.withoutRowid = false});

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
        strict: strict,
        withoutRowid: withoutRowid);
  }

  int columnIndex(String colName) {
    final i = columns
        .indexWhere((c) => c.name.toLowerCase() == colName.toLowerCase());
    if (i == -1) {
      throw StateError('Column "$colName" not found in table "$name"');
    }
    return i;
  }

  /// Build a `column-name -> value` view of [row]. Both bare and `table.col`
  /// keys are populated so qualified expressions resolve.
  Map<String, Object?> rowToMap(List<Object?> row, {String? alias}) {
    // Cache the bare + qualified key strings; rebuilt only when the
    // table is renamed or the column list changes (those paths set
    // [_keysName] back to null).
    if (_keysName != name || _keysCount != columns.length) {
      _keysBare = [for (final c in columns) c.name];
      _keysQualified = [for (final c in columns) '$name.${c.name}'];
      _keysName = name;
      _keysCount = columns.length;
      // A rowid table's INTEGER PRIMARY KEY is the rowid alias; expose it under
      // the `rowid` / `_rowid_` / `oid` pseudo-column names.
      _rowidAliasIdx = withoutRowid
          ? -1
          : columns.indexWhere(
              (c) => c.primaryKey && c.type == DataType.integer);
    }
    final m = <String, Object?>{};
    final n = columns.length;
    if (alias != null) {
      // An alias hides the base table name (SQL scoping), so expose only the
      // bare and alias-qualified keys. Keeping `<table>.col` here would let an
      // aliased relation shadow an outer correlation that shares the base name
      // (e.g. `… FROM s x WHERE x.g = s.g` correlated to an outer `s`).
      for (var i = 0; i < n; i++) {
        m[_keysBare![i]] = row[i];
        m['$alias.${_keysBare![i]}'] = row[i];
      }
      _addRowidAliases(m, row, qualifier: alias);
      return m;
    }
    for (var i = 0; i < n; i++) {
      m[_keysBare![i]] = row[i];
      m[_keysQualified![i]] = row[i];
    }
    _addRowidAliases(m, row, qualifier: name);
    return m;
  }

  /// Adds the `rowid` / `_rowid_` / `oid` pseudo-column entries (bare and
  /// [qualifier]-qualified) for a rowid-alias table, unless a real column
  /// already claims the name (a user column shadows the pseudo-column).
  void _addRowidAliases(Map<String, Object?> m, List<Object?> row,
      {required String qualifier}) {
    // Rowid-alias table: expose the INTEGER PRIMARY KEY under the rowid names.
    if (_rowidAliasIdx != null && _rowidAliasIdx! >= 0) {
      final v = row[_rowidAliasIdx!];
      for (final key in const ['rowid', '_rowid_', 'oid']) {
        m.putIfAbsent(key, () => v);
        m.putIfAbsent('$qualifier.$key', () => v);
      }
      return;
    }
    // Any other rowid table (no integer-PK alias) still has an implicit,
    // always-present rowid pseudo-column in SQLite/Oracle. We don't track the
    // physical row number here, so expose a synthetic non-null token — enough
    // for `WHERE rowid IS NOT NULL` and Oracle's ROWID pseudo-column to resolve.
    if (withoutRowid) return;
    for (final key in const ['rowid', '_rowid_', 'oid']) {
      m.putIfAbsent(key, () => 'AAAAAAAAAA');
      m.putIfAbsent('$qualifier.$key', () => 'AAAAAAAAAA');
    }
  }

  // Cached key strings for [rowToMap]; nulled out by [invalidateKeyCache].
  List<String>? _keysBare;
  List<String>? _keysQualified;
  String? _keysName;
  int _keysCount = -1;

  /// Column index of the INTEGER PRIMARY KEY rowid alias (-1 = none, null =
  /// not yet computed); refreshed with the key-string cache.
  int? _rowidAliasIdx;

  /// Drop cached row-key strings. Call after renaming the table or
  /// mutating the column list so the next [rowToMap] rebuilds them.
  void invalidateKeyCache() {
    _keysBare = null;
    _keysQualified = null;
    _keysName = null;
    _keysCount = -1;
    _rowidAliasIdx = null;
  }

  // Per-column cache of values present in PK / UNIQUE columns. Lets
  // [insertRow] check uniqueness in O(1) instead of scanning every
  // existing row. Built lazily; cleared by [invalidateUniqueCaches]
  // whenever the row store is mutated outside [insertRow]
  // (UPDATE / DELETE / _rebuildIndexes / clone-restore).
  final Map<int, Set<Object>> _uniqueCaches = <int, Set<Object>>{};

  Set<Object>? _uniqueCacheFor(int colIdx) {
    final c = columns[colIdx];
    if (!(c.primaryKey || c.unique)) return null;
    var cache = _uniqueCaches[colIdx];
    if (cache != null) return cache;
    cache = <Object>{};
    for (final r in rows) {
      final v = r[colIdx];
      if (v != null) cache.add(v);
    }
    _uniqueCaches[colIdx] = cache;
    return cache;
  }

  /// Drop the per-column unique-value caches. Call after any mutation
  /// to [rows] that does not go through [insertRow].
  void invalidateUniqueCaches() {
    _uniqueCaches.clear();
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
        final cache = _uniqueCacheFor(i);
        if (cache != null) {
          if (cache.contains(values[i] as Object)) {
            throw StateError(
                'UNIQUE constraint failed: ${c.name}=${values[i]}');
          }
        } else {
          for (final existing in rows) {
            if (existing[i] == values[i]) {
              throw StateError(
                  'UNIQUE constraint failed: ${c.name}=${values[i]}');
            }
          }
        }
      }
    }
    final rowId = rows.length;
    rows.add(values);
    // Record this row's values in the per-column unique caches we built.
    for (final entry in _uniqueCaches.entries) {
      final v = values[entry.key];
      if (v != null) entry.value.add(v);
    }
    // Update indexes — expression / partial indexes are not maintained here
    // (the executor refreshes them via rebuild), so skip them.
    for (final entry in indexDefs.entries) {
      final def = entry.value;
      if (def.exprSql != null || def.whereSql != null) continue;
      final key = _buildIndexKey(def, values);
      if (key == null) continue;
      final tree = indexes[entry.key]!;
      final list = tree.putIfAbsent(key, () => <int>[]);
      if (def.unique && list.isNotEmpty) {
        rows.removeLast();
        throw StateError('UNIQUE index ${entry.key} violation: $key');
      }
      list.add(rowId);
    }
    return rowId;
  }

  /// Build the storage key for [def] from a single row's values. Returns
  /// null when the index should skip this row (any indexed column is
  /// NULL — matching SQLite's default treatment of NULL in indexes).
  Object? buildIndexKey(IndexDef def, List<Object?> values) =>
      _buildIndexKey(def, values);

  /// Build the storage key for [def] from a single row's values. Returns
  /// null when the index should skip this row (any indexed column is
  /// NULL — matching SQLite's default treatment of NULL in indexes).
  Object? _buildIndexKey(IndexDef def, List<Object?> values) {
    if (def.columns.length == 1) {
      final colIdx = columnIndex(def.column);
      return def.collate(0, values[colIdx]);
    }
    final parts = <Object?>[];
    for (var p = 0; p < def.columns.length; p++) {
      final v = values[columnIndex(def.columns[p])];
      if (v == null) return null;
      parts.add(def.collate(p, v));
    }
    return CompositeIndexKey(parts);
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
    for (var i = 0; i < rows.length; i++) {
      final key = _buildIndexKey(def, rows[i]);
      if (key == null) continue;
      final list = tree.putIfAbsent(key, () => <int>[]);
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
    invalidateKeyCache();
    invalidateUniqueCaches();
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
                  if (d.columns.length > 1) 'columns': d.columns,
                  if (d.collations.any((c) => c.toUpperCase() != 'BINARY'))
                    'collations': d.collations,
                  if (d.whereSql != null) 'where': d.whereSql,
                  if (d.exprSql != null) 'expr': d.exprSql,
                })
            .toList(),
        'autoInc': autoInc,
        if (withoutRowid) 'withoutRowid': true,
      };

  static Table fromJson(Map<String, Object?> j) {
    final cols = (j['columns'] as List)
        .map((c) => ColumnDef.fromJson((c as Map).cast<String, Object?>()))
        .toList();
    final cons = ((j['constraints'] as List?) ?? const [])
        .map(
            (c) => TableConstraint.fromJson((c as Map).cast<String, Object?>()))
        .toList();
    final t = Table(j['name'] as String, cols,
        constraints: cons, withoutRowid: j['withoutRowid'] == true);
    for (final r in (j['rows'] as List)) {
      t.rows.add((r as List).map((v) => jsonValueToStorage(v)).toList());
    }
    for (final idx in (j['indexes'] as List? ?? const [])) {
      final m = (idx as Map).cast<String, Object?>();
      final cols = (m['columns'] as List?)?.cast<String>();
      final collations = (m['collations'] as List?)?.cast<String>();
      t.createIndex(IndexDef(m['name'] as String, m['column'] as String,
          unique: m['unique'] == true,
          whereSql: m['where'] as String?,
          exprSql: m['expr'] as String?,
          columns: cols,
          collations: collations));
    }
    final ai = j['autoInc'];
    if (ai is Map) {
      ai.forEach((k, v) => t.autoInc[k as String] = (v as num).toInt());
    }
    return t;
  }

  static int _compareKeys(Object a, Object b) {
    if (a is CompositeIndexKey && b is CompositeIndexKey) {
      return a.compareTo(b);
    }
    if (a is num && b is num) return a.compareTo(b);
    if (a is Comparable && b is Comparable && a.runtimeType == b.runtimeType) {
      return a.compareTo(b);
    }
    return a.toString().compareTo(b.toString());
  }
}

/// Composite key for multi-column indexes. Compares element-by-element
/// using SQLite-ish ordering (NULL < num < text < blob; numbers compared
/// numerically across int/double; strings/blobs lexicographically).
class CompositeIndexKey implements Comparable<CompositeIndexKey> {
  final List<Object?> parts;
  const CompositeIndexKey(this.parts);

  @override
  int compareTo(CompositeIndexKey other) {
    final n =
        parts.length < other.parts.length ? parts.length : other.parts.length;
    for (var i = 0; i < n; i++) {
      final c = compareValues(parts[i], other.parts[i]);
      if (c != 0) return c;
    }
    return parts.length.compareTo(other.parts.length);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! CompositeIndexKey) return false;
    if (other.parts.length != parts.length) return false;
    for (var i = 0; i < parts.length; i++) {
      if (compareValues(parts[i], other.parts[i]) != 0) return false;
    }
    return true;
  }

  @override
  int get hashCode {
    var h = 0;
    for (final p in parts) {
      h = 0x1fffffff & (h * 31 + (p?.hashCode ?? 0));
    }
    return h;
  }

  @override
  String toString() => '(${parts.join(", ")})';

  /// SQLite-ish ordering used for full composite-key ordering and for
  /// prefix matching by the planner. Public so executor code in other
  /// libraries can reuse it.
  static int compareValues(Object? a, Object? b) {
    int rank(Object? v) {
      if (v == null) return 0;
      if (v is num) return 1;
      if (v is String) return 2;
      return 3;
    }

    final ra = rank(a);
    final rb = rank(b);
    if (ra != rb) return ra.compareTo(rb);
    if (a == null) return 0;
    if (a is num && b is num) return a.compareTo(b);
    if (a is String && b is String) return a.compareTo(b);
    return a.toString().compareTo(b.toString());
  }
}
