/// Self-contained out-of-core typed table built on [PagedHeap] +
/// [PagedBTree].
///
/// A [PagedTable] is a primary-keyed, column-typed table whose rows
/// live in a paged heap on disk and whose primary-key index lives in
/// a paged B+-tree. Both files use the LRU page cache from
/// [PagedFile], so a table whose total size dwarfs RAM stays bounded
/// by the configured `cacheCapacity`.
///
/// **This API is intentionally separate from the SQL executor.** The
/// in-memory `Database` / `Table` classes in [database.dart] are
/// untouched; this is a parallel storage layer that callers can use
/// directly when they need true out-of-core behaviour. A future
/// refactor may wire it behind `CREATE TABLE … USING paged(…)`.
///
/// ## On-disk layout
///
/// Three sibling files share a common base path `<base>`:
///   * `<base>.heap`     — row storage ([PagedHeap])
///   * `<base>.idx`      — primary-key index ([PagedBTree])
///   * `<base>.meta.json`— schema (column names + types + PK column)
///
/// Each `.heap` and `.idx` file owns its own `<…>.journal` for crash
/// safety. The schema file is rewritten atomically (`.tmp` + rename)
/// via the same protocol used elsewhere in the engine.
///
/// ## Row encoding
///
/// Rows are encoded into a compact length-prefixed binary format:
///
/// ```
///   [u8 columnCount]
///   for each column, in declared order:
///     [u8 typeTag]
///     value bytes (depends on tag)
/// ```
///
/// Type tags: `0` = NULL (no payload), `1` = INT (8 bytes little-endian
/// signed), `2` = REAL (8 bytes IEEE 754), `3` = TEXT (u32 utf8-byte
/// length + bytes), `4` = BLOB (u32 length + bytes), `5` = BOOL (1 byte
/// 0/1).
///
/// ## Primary key
///
/// Exactly one column is the primary key. The PK is serialised the
/// same way as row values *but without the type tag* (so it sorts
/// purely on its bytes); ints are written as 8-byte big-endian with
/// the sign bit flipped so negative values sort before positives, and
/// reals as the IEEE 754 bit pattern with the same flip. This matches
/// the bytewise lexicographic order used by [PagedBTree].
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'paged_btree.dart';
import 'paged_file.dart';
import 'paged_heap.dart';
import 'table_backend.dart';

/// Column types supported by a [PagedTable].
enum PagedColumnType { intType, realType, textType, blobType, boolType }

/// A column declaration.
class PagedColumn {
  final String name;
  final PagedColumnType type;
  const PagedColumn(this.name, this.type);

  Map<String, Object?> toJson() => {'name': name, 'type': type.name};
  static PagedColumn fromJson(Map<String, Object?> j) => PagedColumn(
        j['name'] as String,
        PagedColumnType.values.firstWhere((t) => t.name == j['type']),
      );
}

/// Self-contained out-of-core typed table.
class PagedTable implements TableBackend {
  /// Common base path; the table owns `<base>.heap`, `<base>.idx`, and
  /// `<base>.meta.json`.
  final String basePath;

  final List<PagedColumn> columns;

  /// Index of the primary-key column in [columns].
  final int primaryKeyIndex;

  PagedColumn get primaryKey => columns[primaryKeyIndex];

  /// User-visible table name as known to the SQL layer. Set by
  /// [Database] when the table is registered. Falls back to the final
  /// path component of [basePath] when used standalone (the lower-level
  /// PagedTable API doesn't otherwise know the SQL name).
  String? _tableName;

  // --- TableBackend (Phase 0 unification scaffold) ------------------------
  @override
  String get tableName {
    final n = _tableName;
    if (n != null) return n;
    // Strip directory + any extension from basePath.
    final sep = basePath.lastIndexOf(RegExp(r'[\\/]'));
    final base = sep < 0 ? basePath : basePath.substring(sep + 1);
    final dot = base.indexOf('.');
    return dot < 0 ? base : base.substring(0, dot);
  }

  /// Set by [Database] when this table is registered under a SQL name.
  set tableName(String value) => _tableName = value;

  @override
  List<String> get columnNames => [for (final c in columns) c.name];

  @override
  TableBackendKind get kind => TableBackendKind.paged;

  final PagedFile _heapFile;
  final PagedFile _idxFile;
  final PagedHeap _heap;
  final PagedBTree _index;

  /// Open secondary indexes, keyed by user-visible index name. Each
  /// entry owns its own [PagedFile] (`<base>.idx_<name>`) and
  /// [PagedBTree]. Empty for tables that have no secondary indexes.
  final Map<String, _SecondaryIndex> _secondary = {};

  PagedTable._(
    this.basePath,
    this.columns,
    this.primaryKeyIndex,
    this._heapFile,
    this._idxFile,
    this._heap,
    this._index,
  );

  /// Names of every secondary index on this table. Order is the order
  /// they were registered.
  List<String> get secondaryIndexNames => _secondary.keys.toList();

  /// First (leading) column name of secondary index [indexName], or
  /// null when there is no such index. Kept for the single-column
  /// callers that pre-date composite indexes; prefer [indexColumns].
  String? indexColumn(String indexName) => _secondary[indexName]?.column;

  /// All indexed column names (in order) for secondary index
  /// [indexName], or null when there is no such index.
  List<String>? indexColumns(String indexName) {
    final si = _secondary[indexName];
    if (si == null) return null;
    return List.unmodifiable(si.columns);
  }

  /// True iff the secondary index [indexName] was declared UNIQUE.
  /// Returns false for non-unique indexes and for unknown names.
  bool isIndexUnique(String indexName) =>
      _secondary[indexName]?.unique ?? false;

  /// If a UNIQUE secondary index exists whose column list is exactly
  /// [columnNames] (case-insensitive, order-sensitive), return its
  /// name. Used by INSERT … ON CONFLICT (cols) to resolve the
  /// conflict target to a unique constraint.
  String? findUniqueIndexByColumns(List<String> columnNames) {
    final lower = [for (final c in columnNames) c.toLowerCase()];
    for (final si in _secondary.values) {
      if (!si.unique) continue;
      if (si.columns.length != lower.length) continue;
      var match = true;
      for (var i = 0; i < lower.length; i++) {
        if (si.columns[i].toLowerCase() != lower[i]) {
          match = false;
          break;
        }
      }
      if (match) return si.name;
    }
    return null;
  }

  /// Look up the (single) row that conflicts with [row] on the UNIQUE
  /// secondary index named [indexName]. Returns the existing row's
  /// PK value, or null when there is no conflict (including when any
  /// indexed component of [row] is NULL).
  Future<Object?> findConflictByUniqueIndex(
      String indexName, Map<String, Object?> row) async {
    final si = _secondary[indexName];
    if (si == null || !si.unique) return null;
    final prefix = _encodeSecondaryPrefix(si, row);
    if (prefix == null) return null;
    final upper = _bumpPrefix(prefix);
    await for (final e
        in si.btree.range(lower: prefix, lowerInclusive: true, upper: upper)) {
      final bytes = await _heap.get(e.value);
      if (bytes == null) continue;
      final r = _decodeRow(bytes);
      return r[primaryKey.name];
    }
    return null;
  }

  /// Open an existing paged table from `<basePath>.meta.json`. Throws
  /// if the metadata file does not exist.
  static Future<PagedTable> open(
    String basePath, {
    int pageSize = 4096,
    int cacheCapacity = 64,
  }) async {
    final meta = await _readMeta(basePath);
    if (meta == null) {
      throw StateError('PagedTable: no metadata at $basePath.meta.json');
    }
    return _openWith(basePath, meta.columns, meta.pkIndex, meta.indexes,
        pageSize: pageSize, cacheCapacity: cacheCapacity);
  }

  /// Create a brand-new paged table. Refuses to overwrite an existing
  /// `<basePath>.meta.json`.
  static Future<PagedTable> create(
    String basePath, {
    required List<PagedColumn> columns,
    required String primaryKey,
    int pageSize = 4096,
    int cacheCapacity = 64,
  }) async {
    final pkIdx = columns.indexWhere((c) => c.name == primaryKey);
    if (pkIdx < 0) {
      throw ArgumentError.value(
          primaryKey, 'primaryKey', 'not found in columns');
    }
    final metaFile = File('$basePath.meta.json');
    if (await metaFile.exists()) {
      throw StateError(
          'PagedTable: metadata already exists at ${metaFile.path}');
    }
    // Write schema first so a crash before any heap/index writes leaves
    // a recoverable empty table.
    await _writeMeta(basePath, columns, pkIdx, const []);
    return _openWith(basePath, columns, pkIdx, const [],
        pageSize: pageSize, cacheCapacity: cacheCapacity);
  }

  /// Open an existing table or create one if `<basePath>.meta.json`
  /// is missing. The schema is only consulted when creating.
  static Future<PagedTable> openOrCreate(
    String basePath, {
    required List<PagedColumn> columns,
    required String primaryKey,
    int pageSize = 4096,
    int cacheCapacity = 64,
  }) async {
    final meta = await _readMeta(basePath);
    if (meta != null) {
      return _openWith(basePath, meta.columns, meta.pkIndex, meta.indexes,
          pageSize: pageSize, cacheCapacity: cacheCapacity);
    }
    return create(basePath,
        columns: columns,
        primaryKey: primaryKey,
        pageSize: pageSize,
        cacheCapacity: cacheCapacity);
  }

  static Future<PagedTable> _openWith(
    String basePath,
    List<PagedColumn> columns,
    int pkIdx,
    List<({String name, List<String> columns, bool unique})> indexes, {
    required int pageSize,
    required int cacheCapacity,
  }) async {
    // Split cache budget roughly 3:1 between heap and index — heap
    // pages tend to be hotter under scans.
    final heapCap = (cacheCapacity * 3 ~/ 4).clamp(1, cacheCapacity);
    final idxCap = (cacheCapacity - heapCap).clamp(1, cacheCapacity);
    final heapFile = await PagedFile.open(
      '$basePath.heap',
      pageSize: pageSize,
      cacheCapacity: heapCap,
    );
    final idxFile = await PagedFile.open(
      '$basePath.idx',
      pageSize: pageSize,
      cacheCapacity: idxCap,
    );
    final heap = await PagedHeap.open(heapFile);
    final index = await PagedBTree.open(idxFile);
    final pt = PagedTable._(
      basePath,
      columns,
      pkIdx,
      heapFile,
      idxFile,
      heap,
      index,
    );
    // Re-open secondary indexes. Each one gets a small per-index
    // cache; under heavy mixed reads the OS page cache and the
    // primary heap cache absorb most of the cost.
    for (final ent in indexes) {
      final types = <PagedColumnType>[];
      for (final cn in ent.columns) {
        final col = columns.firstWhere(
          (c) => c.name == cn,
          orElse: () => throw StateError(
              'PagedTable: index ${ent.name} references unknown column $cn'),
        );
        types.add(col.type);
      }
      final f = await PagedFile.open(
        '$basePath.idx_${ent.name}',
        pageSize: pageSize,
        cacheCapacity: 8,
      );
      final b = await PagedBTree.open(f);
      pt._secondary[ent.name] = _SecondaryIndex(
        name: ent.name,
        columns: List<String>.from(ent.columns),
        columnTypes: types,
        file: f,
        btree: b,
        unique: ent.unique,
      );
    }
    return pt;
  }

  /// Number of rows currently in the table.
  int get length => _index.length;

  /// Insert a row. The map's keys must be a subset of the column names;
  /// missing columns are stored as NULL. Throws if a row with the same
  /// PK already exists.
  Future<void> insert(Map<String, Object?> row) async {
    final pkVal = row[primaryKey.name];
    if (pkVal == null) {
      throw ArgumentError('PagedTable.insert: primary-key value is null');
    }
    final pkBytes = _encodePrimaryKey(pkVal);
    if ((await _index.get(pkBytes)) != null) {
      throw StateError(
          'PagedTable.insert: duplicate primary key ${jsonEncode(pkVal)}');
    }
    // Uniqueness pre-check on every UNIQUE secondary index.
    for (final si in _secondary.values) {
      if (!si.unique) continue;
      final prefix = _encodeSecondaryPrefix(si, row);
      if (prefix == null) continue; // NULL components don't constrain
      if (await _uniqueConflict(si, prefix, null)) {
        throw StateError('PagedTable.insert: UNIQUE constraint violated on '
            'index ${si.name} (${si.columns.join(", ")})');
      }
    }
    final rowBytes = _encodeRow(row);
    final rowId = await _heap.insert(rowBytes);
    await _index.put(pkBytes, rowId);
    // Maintain every secondary index. Composite indexes are skipped
    // entirely when ANY component is NULL (SQL-ish: NULLs don't index).
    for (final si in _secondary.values) {
      final key = _encodeSecondaryKey(si, row, pkBytes);
      if (key == null) continue;
      await si.btree.put(key, rowId);
    }
  }

  /// SQLite `INSERT OR IGNORE`: if the row would conflict with the
  /// PK or any UNIQUE secondary index, skip the insert and return
  /// `false`. Returns `true` if the row was inserted.
  Future<bool> insertOrIgnore(Map<String, Object?> row) async {
    final pkVal = row[primaryKey.name];
    if (pkVal == null) {
      throw ArgumentError(
          'PagedTable.insertOrIgnore: primary-key value is null');
    }
    final pkBytes = _encodePrimaryKey(pkVal);
    if ((await _index.get(pkBytes)) != null) return false;
    for (final si in _secondary.values) {
      if (!si.unique) continue;
      final prefix = _encodeSecondaryPrefix(si, row);
      if (prefix == null) continue;
      if (await _uniqueConflict(si, prefix, null)) return false;
    }
    final rowBytes = _encodeRow(row);
    final rowId = await _heap.insert(rowBytes);
    await _index.put(pkBytes, rowId);
    for (final si in _secondary.values) {
      final key = _encodeSecondaryKey(si, row, pkBytes);
      if (key == null) continue;
      await si.btree.put(key, rowId);
    }
    return true;
  }

  /// SQLite `INSERT OR REPLACE`: delete every existing row that would
  /// conflict (PK match or any UNIQUE-index match), then insert the
  /// new row. Returns the number of rows deleted in service of the
  /// insert (0 when no conflict existed).
  Future<int> insertOrReplace(Map<String, Object?> row) async {
    final pkVal = row[primaryKey.name];
    if (pkVal == null) {
      throw ArgumentError(
          'PagedTable.insertOrReplace: primary-key value is null');
    }
    final pkBytes = _encodePrimaryKey(pkVal);
    // Collect distinct PK values that need to be evicted. The set is
    // keyed by the JSON-encoded PK so int/string/etc. dedup correctly.
    final toDelete = <String, Object>{};
    if ((await _index.get(pkBytes)) != null) {
      toDelete[jsonEncode(pkVal)] = pkVal;
    }
    for (final si in _secondary.values) {
      if (!si.unique) continue;
      final prefix = _encodeSecondaryPrefix(si, row);
      if (prefix == null) continue;
      final upper = _bumpPrefix(prefix);
      // Buffer rowIds first to avoid mutating the tree mid-iteration.
      final rowIds = <int>[];
      await for (final e in si.btree
          .range(lower: prefix, lowerInclusive: true, upper: upper)) {
        rowIds.add(e.value);
      }
      for (final rid in rowIds) {
        final bytes = await _heap.get(rid);
        if (bytes == null) continue;
        final r = _decodeRow(bytes);
        final pk = r[primaryKey.name];
        if (pk == null) continue;
        toDelete[jsonEncode(pk)] = pk;
      }
    }
    for (final pk in toDelete.values) {
      await delete(pk);
    }
    await insert(row);
    return toDelete.length;
  }

  /// Look up a row by primary key. Returns null if absent.
  Future<Map<String, Object?>?> get(Object pkVal) async {
    final pkBytes = _encodePrimaryKey(pkVal);
    final rowId = await _index.get(pkBytes);
    if (rowId == null) return null;
    final bytes = await _heap.get(rowId);
    if (bytes == null) return null;
    return _decodeRow(bytes);
  }

  /// Replace an existing row. Throws if the PK doesn't exist. The
  /// primary-key value in [row] must equal [pkVal] (we don't allow
  /// PK rewrites here — do delete + insert if you need that).
  Future<void> update(Object pkVal, Map<String, Object?> row) async {
    final pkBytes = _encodePrimaryKey(pkVal);
    final rowId = await _index.get(pkBytes);
    if (rowId == null) {
      throw StateError(
          'PagedTable.update: no row with primary key ${jsonEncode(pkVal)}');
    }
    final newPk = row[primaryKey.name];
    if (newPk == null) {
      throw ArgumentError('PagedTable.update: primary-key value is null');
    }
    if (_compareBytes(_encodePrimaryKey(newPk), pkBytes) != 0) {
      throw ArgumentError(
          'PagedTable.update: cannot rewrite primary key (delete + insert instead)');
    }
    // Refresh secondary-index entries: compare the old vs new tuple
    // of indexed-column values; only rewrite indexes whose tuple
    // changed. NULL-containing tuples have no index entry.
    if (_secondary.isNotEmpty) {
      final oldBytes = await _heap.get(rowId);
      if (oldBytes != null) {
        final oldRow = _decodeRow(oldBytes);
        // Uniqueness pre-check before any mutation.
        for (final si in _secondary.values) {
          if (!si.unique) continue;
          final newPrefix = _encodeSecondaryPrefix(si, row);
          if (newPrefix == null) continue;
          final oldPrefix = _encodeSecondaryPrefix(si, oldRow);
          if (oldPrefix != null && _compareBytes(oldPrefix, newPrefix) == 0) {
            continue; // unchanged prefix, no conflict possible
          }
          if (await _uniqueConflict(si, newPrefix, pkBytes)) {
            throw StateError('PagedTable.update: UNIQUE constraint violated on '
                'index ${si.name} (${si.columns.join(", ")})');
          }
        }
        for (final si in _secondary.values) {
          final oldKey = _encodeSecondaryKey(si, oldRow, pkBytes);
          final newKey = _encodeSecondaryKey(si, row, pkBytes);
          if (oldKey == null && newKey == null) continue;
          if (oldKey != null &&
              newKey != null &&
              _compareBytes(oldKey, newKey) == 0) {
            continue;
          }
          if (oldKey != null) await si.btree.remove(oldKey);
          if (newKey != null) await si.btree.put(newKey, rowId);
        }
      }
    }
    final rowBytes = _encodeRow(row);
    await _heap.update(rowId, rowBytes);
  }

  /// Replace the row at primary key [oldPkVal] with [row], possibly
  /// rewriting the primary key. The new PK value (read from
  /// `row[primaryKey.name]`) must not already belong to a different
  /// row; UNIQUE secondary indexes are checked against the new row
  /// before any mutation, so a conflict leaves the table untouched.
  /// Equivalent to [delete] + [insert] but atomic w.r.t. uniqueness
  /// probing.
  Future<void> reassignPrimaryKey(
      Object oldPkVal, Map<String, Object?> row) async {
    final newPk = row[primaryKey.name];
    if (newPk == null) {
      throw ArgumentError(
          'PagedTable.reassignPrimaryKey: new primary key is null');
    }
    final oldPkBytes = _encodePrimaryKey(oldPkVal);
    if ((await _index.get(oldPkBytes)) == null) {
      throw StateError('PagedTable.reassignPrimaryKey: no row with primary key '
          '${jsonEncode(oldPkVal)}');
    }
    final newPkBytes = _encodePrimaryKey(newPk);
    final samePk = _compareBytes(oldPkBytes, newPkBytes) == 0;
    if (!samePk && (await _index.get(newPkBytes)) != null) {
      throw StateError('PagedTable.reassignPrimaryKey: primary key '
          '${jsonEncode(newPk)} already exists');
    }
    // Probe every UNIQUE secondary index for a non-self conflict.
    // [_uniqueConflict] excludes the row currently at oldPkBytes via
    // the self-PK tail trick.
    for (final si in _secondary.values) {
      if (!si.unique) continue;
      final prefix = _encodeSecondaryPrefix(si, row);
      if (prefix == null) continue;
      if (await _uniqueConflict(si, prefix, oldPkBytes)) {
        throw StateError(
            'PagedTable.reassignPrimaryKey: UNIQUE constraint violated '
            'on index ${si.name} (${si.columns.join(", ")})');
      }
    }
    // All checks passed — delete the old row, insert the new one.
    await delete(oldPkVal);
    await insert(row);
  }

  /// Delete the row with primary key [pkVal]. Returns true if it existed.
  Future<bool> delete(Object pkVal) async {
    final pkBytes = _encodePrimaryKey(pkVal);
    final rowId = await _index.get(pkBytes);
    if (rowId == null) return false;
    if (_secondary.isNotEmpty) {
      final oldBytes = await _heap.get(rowId);
      if (oldBytes != null) {
        final oldRow = _decodeRow(oldBytes);
        for (final si in _secondary.values) {
          final key = _encodeSecondaryKey(si, oldRow, pkBytes);
          if (key == null) continue;
          await si.btree.remove(key);
        }
      }
    }
    await _heap.delete(rowId);
    await _index.remove(pkBytes);
    return true;
  }

  /// Stream every row in primary-key order. One heap page resident at
  /// a time.
  Stream<Map<String, Object?>> scan() async* {
    await for (final entry in _index.scan()) {
      final bytes = await _heap.get(entry.value);
      if (bytes == null) continue; // index/heap drift: skip
      yield _decodeRow(bytes);
    }
  }

  /// Stream every row whose PK falls in `[lower?, upper?)`.
  Stream<Map<String, Object?>> range({
    Object? lower,
    bool lowerInclusive = true,
    Object? upper,
    bool upperInclusive = false,
  }) async* {
    final lo = lower == null ? null : _encodePrimaryKey(lower);
    final hi = upper == null ? null : _encodePrimaryKey(upper);
    await for (final entry in _index.range(
      lower: lo,
      lowerInclusive: lowerInclusive,
      upper: hi,
      upperInclusive: upperInclusive,
    )) {
      final bytes = await _heap.get(entry.value);
      if (bytes == null) continue;
      yield _decodeRow(bytes);
    }
  }

  /// Commit pending mutations on both files.
  Future<void> commit() async {
    await _heap.commit();
    await _index.commit();
    for (final si in _secondary.values) {
      await si.btree.commit();
    }
  }

  /// Discard pending mutations on every backing file (heap, primary
  /// B+-tree, and any open secondary indexes). After this call the
  /// table reflects the on-disk state as of the last [commit].
  Future<void> rollback() async {
    await _heap.rollback();
    await _index.rollback();
    for (final si in _secondary.values) {
      await si.btree.rollback();
    }
  }

  /// Close both backing files. Implicitly commits.
  Future<void> close() async {
    await _heapFile.close();
    await _idxFile.close();
    for (final si in _secondary.values) {
      await si.file.close();
    }
    _secondary.clear();
  }

  // ---------------------------------------------------------------------------
  // Secondary indexes (equality lookup)
  // ---------------------------------------------------------------------------

  /// Build a new secondary index [name] over column [columnName]. Walks
  /// every existing row, populates the index, commits everything, and
  /// rewrites `meta.json` so the index survives reopen. Throws when
  /// [name] is already taken or [columnName] is unknown.
  ///
  /// Index names must match `^[A-Za-z0-9_]+$` so they can become a
  /// safe filename suffix (`<base>.idx_<name>`).
  /// Create a secondary index named [name] on [columnNames] (one or
  /// more). The new index is built by backfilling every existing row.
  /// Rejects: invalid name, duplicate, unknown column, the PK column,
  /// or an empty/duplicate column list. NULLs in any indexed component
  /// cause that row to be omitted from the index (SQL-ish semantics).
  ///
  /// When [unique] is true, two rows with the same indexed-column
  /// tuple are rejected (the build fails with a [StateError] and the
  /// half-built index file is removed). NULL-containing tuples never
  /// participate in the uniqueness check — matching SQLite semantics.
  Future<void> createIndex(String name, List<String> columnNames,
      {bool unique = false}) async {
    if (!RegExp(r'^[A-Za-z0-9_]+$').hasMatch(name)) {
      throw ArgumentError.value(
          name, 'name', 'index name must match [A-Za-z0-9_]+');
    }
    if (_secondary.containsKey(name)) {
      throw StateError('PagedTable: index $name already exists');
    }
    if (columnNames.isEmpty) {
      throw ArgumentError('PagedTable.createIndex: no columns');
    }
    final seen = <String>{};
    final cols = <PagedColumn>[];
    for (final cn in columnNames) {
      final lower = cn.toLowerCase();
      if (!seen.add(lower)) {
        throw ArgumentError(
            'PagedTable.createIndex: duplicate column $cn in index $name');
      }
      final col = columns.firstWhere(
        (c) => c.name == cn,
        orElse: () =>
            throw ArgumentError.value(cn, 'columnName', 'no such column'),
      );
      if (cn == primaryKey.name) {
        throw ArgumentError(
            'PagedTable: column $cn is already the primary key');
      }
      cols.add(col);
    }
    final f = await PagedFile.open(
      '$basePath.idx_$name',
      pageSize: _heapFile.pageSize,
      cacheCapacity: 8,
    );
    final b = await PagedBTree.open(f);
    final si = _SecondaryIndex(
      name: name,
      columns: [for (final c in cols) c.name],
      columnTypes: [for (final c in cols) c.type],
      file: f,
      btree: b,
      unique: unique,
    );
    // Backfill: walk every existing row through the primary index and
    // populate the new tree. Tuples containing any NULL are skipped.
    // For UNIQUE indexes we additionally track the prefix bytes we've
    // already inserted and reject a second occurrence.
    final seenPrefixes = unique ? <String>{} : null;
    try {
      await for (final entry in _index.scan()) {
        final bytes = await _heap.get(entry.value);
        if (bytes == null) continue;
        final row = _decodeRow(bytes);
        final key = _encodeSecondaryKey(si, row, entry.key);
        if (key == null) continue;
        if (seenPrefixes != null) {
          final prefix = _encodeSecondaryPrefix(si, row)!;
          final tag = base64Encode(prefix);
          if (!seenPrefixes.add(tag)) {
            throw StateError(
                'CREATE UNIQUE INDEX $name on ${cols.map((c) => c.name).join(", ")}: '
                'duplicate value in existing rows');
          }
        }
        await b.put(key, entry.value);
      }
    } catch (e) {
      // Tear down the half-built file so the next open doesn't see a
      // ghost index — meta.json hasn't been updated yet, so the file
      // is "orphan" in the same sense as any failed createIndex.
      await f.close();
      for (final ext in const ['', '.journal']) {
        final junk = File('$basePath.idx_$name$ext');
        if (await junk.exists()) {
          try {
            await junk.delete();
          } catch (_) {/* best-effort */}
        }
      }
      rethrow;
    }
    await b.commit();
    _secondary[name] = si;
    // Persist the schema change *after* the backfilled index is on disk;
    // a crash before this point leaves an orphan file the next open will
    // ignore (since meta.json doesn't list it).
    await _writeMeta(basePath, columns, primaryKeyIndex, _indexDescriptors());
  }

  /// Drop secondary index [name]. Removes the on-disk files and
  /// rewrites `meta.json`. Idempotent — returns false if the index
  /// didn't exist.
  Future<bool> dropIndex(String name) async {
    final si = _secondary.remove(name);
    if (si == null) return false;
    await si.file.close();
    // Persist schema first so a crash mid-delete still removes the
    // index from the next opener's view.
    await _writeMeta(basePath, columns, primaryKeyIndex, _indexDescriptors());
    for (final ext in const ['', '.journal']) {
      final f = File('$basePath.idx_$name$ext');
      if (await f.exists()) {
        try {
          await f.delete();
        } catch (_) {/* best-effort */}
      }
    }
    return true;
  }

  /// Stream every row that matches the leading prefix `[values]` of
  /// the indexed columns. For a single-column index, `values` has one
  /// entry — this is point equality. For a composite index, you may
  /// supply fewer values than the index has columns to do a prefix
  /// probe (e.g. `[country]` against an `(country, city)` index).
  ///
  /// Returns an empty stream when no such index exists, when any
  /// supplied value is null (NULLs aren't indexed), or when nothing
  /// matches.
  Stream<Map<String, Object?>> indexLookup(
      String indexName, List<Object?> values) async* {
    final si = _secondary[indexName];
    if (si == null) return;
    if (values.isEmpty || values.length > si.columns.length) return;
    final bb = BytesBuilder(copy: false);
    for (var i = 0; i < values.length; i++) {
      final v = values[i];
      if (v == null) return;
      bb.add(_encodeIndexValue(v, si.columnTypes[i]));
    }
    final prefix = bb.toBytes();
    final upper = _bumpPrefix(prefix);
    await for (final entry in si.btree.range(
      lower: prefix,
      lowerInclusive: true,
      upper: upper,
      upperInclusive: false,
    )) {
      final bytes = await _heap.get(entry.value);
      if (bytes == null) continue;
      yield _decodeRow(bytes);
    }
  }

  /// Range-scan a secondary index. [equalPrefix] (optional) pins
  /// leading columns by equality; [lower] / [upper] then apply to the
  /// next column after that prefix. For a single-column index, pass
  /// an empty [equalPrefix] and bounds on the only column. The encoded
  /// value-keys are byte-order-preserving, so SQL semantics carry
  /// through.
  ///
  /// Returns rows in index order: ascending by indexed-column tuple,
  /// ties broken by encoded primary key. Yields nothing when the index
  /// does not exist or any prefix value is null.
  Stream<Map<String, Object?>> indexRange(
    String indexName, {
    List<Object?> equalPrefix = const [],
    Object? lower,
    bool lowerInclusive = true,
    Object? upper,
    bool upperInclusive = false,
  }) async* {
    final si = _secondary[indexName];
    if (si == null) return;
    if (equalPrefix.length >= si.columns.length &&
        lower == null &&
        upper == null) {
      // Pure prefix-equality = lookup.
      yield* indexLookup(indexName, equalPrefix);
      return;
    }
    // Build the fixed prefix from equalPrefix values.
    final bb = BytesBuilder(copy: false);
    for (var i = 0; i < equalPrefix.length; i++) {
      final v = equalPrefix[i];
      if (v == null) return;
      bb.add(_encodeIndexValue(v, si.columnTypes[i]));
    }
    final fixed = bb.toBytes();
    final rangeColIdx = equalPrefix.length;
    Uint8List? lo;
    Uint8List? hi;
    if (rangeColIdx >= si.columns.length) {
      // No range column available — bounds must be null. Fall back to
      // prefix-only range scan.
      lo = fixed;
      hi = _bumpPrefix(fixed);
    } else {
      final t = si.columnTypes[rangeColIdx];
      if (lower != null) {
        final l = _encodeIndexValue(lower, t);
        final combined = Uint8List(fixed.length + l.length)
          ..setRange(0, fixed.length, fixed)
          ..setRange(fixed.length, fixed.length + l.length, l);
        lo = lowerInclusive ? combined : _bumpPrefix(combined);
      } else if (fixed.isNotEmpty) {
        lo = fixed;
      }
      if (upper != null) {
        final u = _encodeIndexValue(upper, t);
        final combined = Uint8List(fixed.length + u.length)
          ..setRange(0, fixed.length, fixed)
          ..setRange(fixed.length, fixed.length + u.length, u);
        hi = upperInclusive ? _bumpPrefix(combined) : combined;
      } else if (fixed.isNotEmpty) {
        hi = _bumpPrefix(fixed);
      }
    }
    if (lo == null && hi == null) {
      await for (final entry in si.btree.scan()) {
        final bytes = await _heap.get(entry.value);
        if (bytes == null) continue;
        yield _decodeRow(bytes);
      }
      return;
    }
    await for (final entry in si.btree.range(
      lower: lo,
      lowerInclusive: true,
      upper: hi,
      upperInclusive: false,
    )) {
      final bytes = await _heap.get(entry.value);
      if (bytes == null) continue;
      yield _decodeRow(bytes);
    }
  }

  List<({String name, List<String> columns, bool unique})>
      _indexDescriptors() => [
            for (final si in _secondary.values)
              (
                name: si.name,
                columns: List<String>.from(si.columns),
                unique: si.unique,
              ),
          ];

  // ---------------------------------------------------------------------------
  // Metadata
  // ---------------------------------------------------------------------------

  static Future<
      ({
        List<PagedColumn> columns,
        int pkIndex,
        List<({String name, List<String> columns, bool unique})> indexes,
      })?> _readMeta(String basePath) async {
    final f = File('$basePath.meta.json');
    if (!await f.exists()) return null;
    final j = jsonDecode(await f.readAsString()) as Map<String, Object?>;
    final cols = (j['columns'] as List)
        .cast<Map<String, Object?>>()
        .map(PagedColumn.fromJson)
        .toList();
    final pkIdx = (j['pkIndex'] as num).toInt();
    final rawIdx = j['indexes'];
    final indexes = <({String name, List<String> columns, bool unique})>[];
    if (rawIdx is List) {
      for (final raw in rawIdx) {
        if (raw is Map) {
          final n = raw['name'] as String;
          final uniq = raw['unique'] == true;
          // Accept both the new "columns" array AND the legacy single
          // "column" field for forward-compat with step-8 sidecars.
          final colsField = raw['columns'];
          if (colsField is List) {
            indexes.add((
              name: n,
              columns: colsField.map((e) => e as String).toList(),
              unique: uniq,
            ));
          } else if (raw['column'] is String) {
            indexes.add((
              name: n,
              columns: [raw['column'] as String],
              unique: uniq,
            ));
          }
        }
      }
    }
    return (columns: cols, pkIndex: pkIdx, indexes: indexes);
  }

  static Future<void> _writeMeta(
      String basePath,
      List<PagedColumn> columns,
      int pkIndex,
      List<({String name, List<String> columns, bool unique})> indexes) async {
    final j = jsonEncode({
      'version': 1,
      'columns': [for (final c in columns) c.toJson()],
      'pkIndex': pkIndex,
      'indexes': [
        for (final ent in indexes)
          {
            'name': ent.name,
            'columns': ent.columns,
            if (ent.unique) 'unique': true,
          },
      ],
    });
    final dest = '$basePath.meta.json';
    final tmp = '$dest.tmp';
    final raf = await File(tmp).open(mode: FileMode.write);
    try {
      await raf.writeFrom(utf8.encode(j));
      await raf.flush();
    } finally {
      await raf.close();
    }
    if (Platform.isWindows) {
      final destFile = File(dest);
      if (await destFile.exists()) {
        try {
          await destFile.delete();
        } catch (_) {/* best-effort */}
      }
    }
    await File(tmp).rename(dest);
  }

  // ---------------------------------------------------------------------------
  // Row codec
  // ---------------------------------------------------------------------------
  static const int _tagNull = 0;
  static const int _tagInt = 1;
  static const int _tagReal = 2;
  static const int _tagText = 3;
  static const int _tagBlob = 4;
  static const int _tagBool = 5;

  Uint8List _encodeRow(Map<String, Object?> row) {
    final buf = BytesBuilder();
    buf.addByte(columns.length);
    for (final col in columns) {
      _encodeValue(buf, row[col.name], col.type);
    }
    return buf.toBytes();
  }

  Map<String, Object?> _decodeRow(Uint8List bytes) {
    final out = <String, Object?>{};
    var off = 1; // skip column count (we trust the schema)
    for (final col in columns) {
      final res = _decodeValue(bytes, off);
      out[col.name] = res.value;
      off = res.next;
    }
    return out;
  }

  void _encodeValue(BytesBuilder buf, Object? v, PagedColumnType declaredType) {
    if (v == null) {
      buf.addByte(_tagNull);
      return;
    }
    switch (declaredType) {
      case PagedColumnType.intType:
        buf.addByte(_tagInt);
        final bd = ByteData(8)..setInt64(0, (v as num).toInt(), Endian.little);
        buf.add(bd.buffer.asUint8List());
        break;
      case PagedColumnType.realType:
        buf.addByte(_tagReal);
        final bd = ByteData(8)
          ..setFloat64(0, (v as num).toDouble(), Endian.little);
        buf.add(bd.buffer.asUint8List());
        break;
      case PagedColumnType.textType:
        final s = v as String;
        final enc = utf8.encode(s);
        buf.addByte(_tagText);
        final lb = ByteData(4)..setUint32(0, enc.length, Endian.little);
        buf.add(lb.buffer.asUint8List());
        buf.add(enc);
        break;
      case PagedColumnType.blobType:
        final b = v as List<int>;
        buf.addByte(_tagBlob);
        final lb = ByteData(4)..setUint32(0, b.length, Endian.little);
        buf.add(lb.buffer.asUint8List());
        buf.add(b);
        break;
      case PagedColumnType.boolType:
        buf.addByte(_tagBool);
        buf.addByte((v == true || v == 1) ? 1 : 0);
        break;
    }
  }

  ({Object? value, int next}) _decodeValue(Uint8List bytes, int off) {
    final tag = bytes[off++];
    switch (tag) {
      case _tagNull:
        return (value: null, next: off);
      case _tagInt:
        final v = ByteData.sublistView(bytes, off, off + 8)
            .getInt64(0, Endian.little);
        return (value: v, next: off + 8);
      case _tagReal:
        final v = ByteData.sublistView(bytes, off, off + 8)
            .getFloat64(0, Endian.little);
        return (value: v, next: off + 8);
      case _tagText:
        final len = ByteData.sublistView(bytes, off, off + 4)
            .getUint32(0, Endian.little);
        off += 4;
        final s = utf8.decode(Uint8List.sublistView(bytes, off, off + len));
        return (value: s, next: off + len);
      case _tagBlob:
        final len = ByteData.sublistView(bytes, off, off + 4)
            .getUint32(0, Endian.little);
        off += 4;
        final b =
            Uint8List.fromList(Uint8List.sublistView(bytes, off, off + len));
        return (value: b, next: off + len);
      case _tagBool:
        final b = bytes[off] != 0;
        return (value: b, next: off + 1);
      default:
        throw StateError(
            'PagedTable: unknown type tag $tag at offset ${off - 1}');
    }
  }

  // ---------------------------------------------------------------------------
  // Primary-key codec — order-preserving so PagedBTree's lexicographic
  // byte order matches the natural numeric / string order.
  // ---------------------------------------------------------------------------
  Uint8List _encodePrimaryKey(Object value) {
    final type = primaryKey.type;
    switch (type) {
      case PagedColumnType.intType:
        // 8-byte big-endian, sign-bit flipped so -1 < 0 < 1 in lex order.
        final n = (value as num).toInt();
        final flipped = n ^ 0x8000000000000000;
        final bd = ByteData(8)..setUint64(0, flipped, Endian.big);
        return bd.buffer.asUint8List();
      case PagedColumnType.realType:
        // IEEE 754 with sign-flip + bit-twiddle so doubles sort by value.
        final d = (value as num).toDouble();
        final bd = ByteData(8)..setFloat64(0, d, Endian.big);
        var bits = bd.getUint64(0, Endian.big);
        if ((bits & 0x8000000000000000) != 0) {
          bits = ~bits & 0xFFFFFFFFFFFFFFFF;
        } else {
          bits ^= 0x8000000000000000;
        }
        final out = ByteData(8)..setUint64(0, bits, Endian.big);
        return out.buffer.asUint8List();
      case PagedColumnType.textType:
        // Raw UTF-8 bytes — lex order matches code-point order.
        return Uint8List.fromList(utf8.encode(value as String));
      case PagedColumnType.blobType:
        return Uint8List.fromList(value as List<int>);
      case PagedColumnType.boolType:
        return Uint8List.fromList([(value == true || value == 1) ? 1 : 0]);
    }
  }

  static int _compareBytes(Uint8List a, Uint8List b) {
    final n = a.length < b.length ? a.length : b.length;
    for (var i = 0; i < n; i++) {
      final d = a[i] - b[i];
      if (d != 0) return d;
    }
    return a.length - b.length;
  }

  // ---------------------------------------------------------------------------
  // Secondary-index codec — equality-only.
  //
  // A secondary key is `[u32 valLen][valBytes][pkBytes]`. The length
  // prefix groups by length first, then by raw value bytes within a
  // length, then by primary key for disambiguation. This is NOT a
  // byte-wise-order-preserving encoding across different value
  // lengths, so we expose only equality lookups (no `WHERE col < 'x'`
  // index ranges). A point lookup translates to a prefix range:
  //   lower = `[len][val]`  (inclusive)
  //   upper = bumpPrefix(lower)  (exclusive)
  // which captures exactly the keys whose value half equals `val`.
  // ---------------------------------------------------------------------------

  /// Encode just the value part of a secondary-index key in a
  /// **byte-order-preserving** form. Two encoded values compare as
  /// `Uint8List` in the same order as the original values compare in
  /// SQL semantics. Critically, no encoded value is a prefix of any
  /// other distinct encoded value, so concatenating a PK suffix yields
  /// unambiguous composite keys (the PK boundary is always recoverable
  /// implicitly from the value type).
  ///
  /// - Fixed-width types (int / real / bool) reuse [_encodeValueOnly];
  ///   each value has a constant length so there is nothing to escape.
  /// - Variable-length types (text / blob) escape every `0x00` byte as
  ///   `0x00 0x01` and append `0x00 0x00` as a terminator. This keeps
  ///   lexicographic order intact while making boundaries unambiguous.
  static Uint8List _encodeIndexValue(Object value, PagedColumnType type) {
    switch (type) {
      case PagedColumnType.intType:
      case PagedColumnType.realType:
      case PagedColumnType.boolType:
        return _encodeValueOnly(value, type);
      case PagedColumnType.textType:
      case PagedColumnType.blobType:
        final raw = _encodeValueOnly(value, type);
        // Worst case every byte is 0x00 → doubles. Plus 2-byte terminator.
        final out = BytesBuilder(copy: false);
        for (final b in raw) {
          if (b == 0x00) {
            out.addByte(0x00);
            out.addByte(0x01);
          } else {
            out.addByte(b);
          }
        }
        out.addByte(0x00);
        out.addByte(0x00);
        return out.toBytes();
    }
  }

  /// Composite secondary-index key: byte-order-preserving encoding of
  /// each indexed column (concatenated) plus the already-encoded PK
  /// bytes as a tie-breaker. Returns null when ANY indexed value in
  /// [row] is NULL, signalling "do not index this row".
  static Uint8List? _encodeSecondaryKey(
      _SecondaryIndex si, Map<String, Object?> row, Uint8List pkBytes) {
    final bb = BytesBuilder(copy: false);
    for (var i = 0; i < si.columns.length; i++) {
      final v = row[si.columns[i]];
      if (v == null) return null;
      bb.add(_encodeIndexValue(v, si.columnTypes[i]));
    }
    bb.add(pkBytes);
    return bb.toBytes();
  }

  /// Just the indexed-column portion of a secondary-index key — no
  /// PK tie-breaker. Used for uniqueness probing: two rows collide
  /// on a UNIQUE index iff their prefixes match exactly, regardless
  /// of their (different) PKs. Returns null if any indexed value is
  /// NULL.
  static Uint8List? _encodeSecondaryPrefix(
      _SecondaryIndex si, Map<String, Object?> row) {
    final bb = BytesBuilder(copy: false);
    for (var i = 0; i < si.columns.length; i++) {
      final v = row[si.columns[i]];
      if (v == null) return null;
      bb.add(_encodeIndexValue(v, si.columnTypes[i]));
    }
    return bb.toBytes();
  }

  /// Return true when [si] (declared UNIQUE) already has an entry
  /// whose indexed-column bytes equal [prefix], excluding the
  /// optional [selfPkBytes] (the row currently being updated, so its
  /// own pre-existing entry doesn't count as a conflict). Probes the
  /// B-tree with a `[prefix, bumpPrefix(prefix))` range and walks
  /// until a non-self entry is found.
  Future<bool> _uniqueConflict(
      _SecondaryIndex si, Uint8List prefix, Uint8List? selfPkBytes) async {
    final upper = _bumpPrefix(prefix);
    await for (final e
        in si.btree.range(lower: prefix, lowerInclusive: true, upper: upper)) {
      if (selfPkBytes == null) return true;
      // Entry key is `prefix + pkBytes`. Extract the tail and
      // compare to selfPkBytes; an equal tail means "this is my own
      // entry", which is not a conflict.
      if (e.key.length <= prefix.length) return true; // shouldn't happen
      final tail = Uint8List.sublistView(e.key, prefix.length);
      if (_compareBytes(tail, selfPkBytes) != 0) return true;
    }
    return false;
  }

  /// Raw value bytes for a single column value, without length prefix
  /// or type tag. Used by the secondary-index codec.
  static Uint8List _encodeValueOnly(Object value, PagedColumnType type) {
    switch (type) {
      case PagedColumnType.intType:
        final n = (value as num).toInt();
        final flipped = n ^ 0x8000000000000000;
        final bd = ByteData(8)..setUint64(0, flipped, Endian.big);
        return bd.buffer.asUint8List();
      case PagedColumnType.realType:
        final d = (value as num).toDouble();
        final bd = ByteData(8)..setFloat64(0, d, Endian.big);
        var bits = bd.getUint64(0, Endian.big);
        if ((bits & 0x8000000000000000) != 0) {
          bits = ~bits & 0xFFFFFFFFFFFFFFFF;
        } else {
          bits ^= 0x8000000000000000;
        }
        final out = ByteData(8)..setUint64(0, bits, Endian.big);
        return out.buffer.asUint8List();
      case PagedColumnType.textType:
        return Uint8List.fromList(utf8.encode(value as String));
      case PagedColumnType.blobType:
        return Uint8List.fromList(value as List<int>);
      case PagedColumnType.boolType:
        return Uint8List.fromList([(value == true || value == 1) ? 1 : 0]);
    }
  }

  /// Smallest byte sequence that's strictly greater than [p] and shares
  /// no prefix with it: increment the last non-`0xFF` byte and drop
  /// everything after it. Returns null when every byte is 0xFF (no
  /// upper bound exists in the 256-symbol alphabet).
  static Uint8List? _bumpPrefix(Uint8List p) {
    for (var i = p.length - 1; i >= 0; i--) {
      if (p[i] != 0xFF) {
        final out = Uint8List(i + 1);
        out.setRange(0, i + 1, p);
        out[i]++;
        return out;
      }
    }
    return null;
  }
}

/// Runtime state for one open secondary index.
class _SecondaryIndex {
  final String name;
  final List<String> columns;
  final List<PagedColumnType> columnTypes;
  final PagedFile file;
  final PagedBTree btree;

  /// When true, the engine refuses any insert/update that would
  /// create two index entries sharing the same indexed-column
  /// tuple (excluding the PK tie-breaker). NULL-containing tuples
  /// are still skipped entirely — SQLite-compatible: `NULL != NULL`
  /// in unique constraints.
  final bool unique;

  _SecondaryIndex({
    required this.name,
    required this.columns,
    required this.columnTypes,
    required this.file,
    required this.btree,
    this.unique = false,
  });

  /// Convenience: first indexed column (the common single-column case).
  String get column => columns.first;
  PagedColumnType get columnType => columnTypes.first;
}
