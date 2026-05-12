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
class PagedTable {
  /// Common base path; the table owns `<base>.heap`, `<base>.idx`, and
  /// `<base>.meta.json`.
  final String basePath;

  final List<PagedColumn> columns;

  /// Index of the primary-key column in [columns].
  final int primaryKeyIndex;

  PagedColumn get primaryKey => columns[primaryKeyIndex];

  final PagedFile _heapFile;
  final PagedFile _idxFile;
  final PagedHeap _heap;
  final PagedBTree _index;

  PagedTable._(
    this.basePath,
    this.columns,
    this.primaryKeyIndex,
    this._heapFile,
    this._idxFile,
    this._heap,
    this._index,
  );

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
    return _openWith(basePath, meta.columns, meta.pkIndex,
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
    await _writeMeta(basePath, columns, pkIdx);
    return _openWith(basePath, columns, pkIdx,
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
      return _openWith(basePath, meta.columns, meta.pkIndex,
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
    int pkIdx, {
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
    return PagedTable._(
      basePath,
      columns,
      pkIdx,
      heapFile,
      idxFile,
      heap,
      index,
    );
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
    final rowBytes = _encodeRow(row);
    final rowId = await _heap.insert(rowBytes);
    await _index.put(pkBytes, rowId);
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
    final rowBytes = _encodeRow(row);
    await _heap.update(rowId, rowBytes);
  }

  /// Delete the row with primary key [pkVal]. Returns true if it existed.
  Future<bool> delete(Object pkVal) async {
    final pkBytes = _encodePrimaryKey(pkVal);
    final rowId = await _index.get(pkBytes);
    if (rowId == null) return false;
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
  }

  /// Close both backing files. Implicitly commits.
  Future<void> close() async {
    await _heapFile.close();
    await _idxFile.close();
  }

  // ---------------------------------------------------------------------------
  // Metadata
  // ---------------------------------------------------------------------------

  static Future<({List<PagedColumn> columns, int pkIndex})?> _readMeta(
      String basePath) async {
    final f = File('$basePath.meta.json');
    if (!await f.exists()) return null;
    final j = jsonDecode(await f.readAsString()) as Map<String, Object?>;
    final cols = (j['columns'] as List)
        .cast<Map<String, Object?>>()
        .map(PagedColumn.fromJson)
        .toList();
    final pkIdx = (j['pkIndex'] as num).toInt();
    return (columns: cols, pkIndex: pkIdx);
  }

  static Future<void> _writeMeta(
      String basePath, List<PagedColumn> columns, int pkIndex) async {
    final j = jsonEncode({
      'version': 1,
      'columns': [for (final c in columns) c.toJson()],
      'pkIndex': pkIndex,
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
}
