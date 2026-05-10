/// Pure-Dart reader/writer for a useful subset of the SQLite 3 file
/// format. Production code MUST NOT depend on this — it's a
/// compatibility shim used by tests and ad-hoc tooling so dart-db-server
/// can ingest and emit `.sqlite` files for the simple shapes it cares
/// about.
///
/// **Supported** (reader and writer):
///   * 100-byte database header (magic, page size, text encoding UTF-8).
///   * Single-file databases (no WAL, no journal).
///   * Schema parsing from `sqlite_schema` (table/index/view/trigger rows).
///   * Table B-tree traversal: interior (page type 0x05) and leaf (0x0d).
///   * Record decoding for serial types 0..9 and 12+/13+ (NULL, ints,
///     real, text, blob).
///   * UTF-8 text encoding only.
///
/// **NOT supported** (yet):
///   * Index B-trees (page types 0x02, 0x0a) and their key decoding.
///   * Overflow pages — the writer rejects records larger than will fit
///     in a single leaf cell, and the reader throws if it sees a record
///     payload that spills onto an overflow page.
///   * Freelist pages, autovacuum, incremental vacuum, change counters.
///   * UTF-16 encoding, application-id headers, schema cookie semantics
///     beyond just round-tripping the bytes.
///   * WITHOUT ROWID tables (which use a slightly different on-disk
///     layout for table B-trees).
///
/// The supported subset is enough to round-trip every table that the
/// rest of the dart-db-server engine produces today, and to ingest the
/// table data of typical fixture `.sqlite` files (no overflow, no
/// indexes that the reader cares about — indexes can simply be ignored
/// when reading rows by table B-tree).
library;

import 'dart:convert';
import 'dart:typed_data';

// ---------------------------------------------------------------------------
// Header
// ---------------------------------------------------------------------------

/// The 100-byte SQLite file header, decoded.
class SqliteHeader {
  static const List<int> magic = [
    0x53, 0x51, 0x4c, 0x69, 0x74, 0x65, 0x20, 0x66,
    0x6f, 0x72, 0x6d, 0x61, 0x74, 0x20, 0x33, 0x00, // "SQLite format 3\0"
  ];

  final int pageSize; // bytes per page (power of 2, 512..65536; 1 means 65536)
  final int fileFormatWrite; // legacy=1, WAL=2
  final int fileFormatRead;
  final int reservedSpace; // unused bytes at the end of each page
  final int textEncoding; // 1=UTF-8, 2=UTF-16le, 3=UTF-16be
  final int schemaCookie;
  final int schemaFormat;
  final int userVersion;
  final int applicationId;
  final int dbSizeInPages; // page count

  const SqliteHeader({
    required this.pageSize,
    required this.fileFormatWrite,
    required this.fileFormatRead,
    required this.reservedSpace,
    required this.textEncoding,
    required this.schemaCookie,
    required this.schemaFormat,
    required this.userVersion,
    required this.applicationId,
    required this.dbSizeInPages,
  });

  /// Parse the 100-byte header. Throws [FormatException] on bad magic
  /// or unsupported text encoding.
  factory SqliteHeader.parse(Uint8List bytes) {
    if (bytes.length < 100) {
      throw FormatException('SQLite file too small (${bytes.length} bytes)');
    }
    for (var i = 0; i < magic.length; i++) {
      if (bytes[i] != magic[i]) {
        throw FormatException('Not a SQLite database (bad magic)');
      }
    }
    final bd = ByteData.sublistView(bytes, 0, 100);
    var pageSize = bd.getUint16(16);
    if (pageSize == 1) pageSize = 65536;
    final encoding = bd.getUint32(56);
    if (encoding != 1) {
      throw FormatException(
          'Unsupported text encoding $encoding (only UTF-8 is supported)');
    }
    return SqliteHeader(
      pageSize: pageSize,
      fileFormatWrite: bd.getUint8(18),
      fileFormatRead: bd.getUint8(19),
      reservedSpace: bd.getUint8(20),
      textEncoding: encoding,
      schemaCookie: bd.getUint32(40),
      schemaFormat: bd.getUint32(44),
      userVersion: bd.getUint32(60),
      applicationId: bd.getUint32(68),
      dbSizeInPages: bd.getUint32(28),
    );
  }

  /// Encode this header into a fresh 100-byte buffer.
  Uint8List encode() {
    final out = Uint8List(100);
    out.setRange(0, 16, magic);
    final bd = ByteData.sublistView(out);
    bd.setUint16(16, pageSize == 65536 ? 1 : pageSize);
    bd.setUint8(18, fileFormatWrite);
    bd.setUint8(19, fileFormatRead);
    bd.setUint8(20, reservedSpace);
    // Bytes 21..23 are fixed magic constants required by SQLite.
    bd.setUint8(21, 64); // max embedded payload fraction
    bd.setUint8(22, 32); // min embedded payload fraction
    bd.setUint8(23, 32); // leaf payload fraction
    bd.setUint32(24, 0); // file change counter
    bd.setUint32(28, dbSizeInPages);
    bd.setUint32(32, 0); // first freelist trunk
    bd.setUint32(36, 0); // total freelist pages
    bd.setUint32(40, schemaCookie);
    bd.setUint32(44, schemaFormat);
    bd.setUint32(48, 0); // default page cache size
    bd.setUint32(52, 0); // largest root b-tree page (autovacuum)
    bd.setUint32(56, textEncoding);
    bd.setUint32(60, userVersion);
    bd.setUint32(64, 0); // incremental-vacuum mode
    bd.setUint32(68, applicationId);
    // Bytes 72..91 are reserved; left as zero.
    bd.setUint32(92, 0); // version-valid-for number
    bd.setUint32(96, 3045000); // SQLite version (3.45.0) — informational.
    return out;
  }
}

// ---------------------------------------------------------------------------
// Varints
// ---------------------------------------------------------------------------

/// Result of a varint decode: the decoded value and the number of bytes
/// consumed. SQLite varints are big-endian, 1..9 bytes; bytes 1..8 use
/// the high bit as a continuation flag, byte 9 contributes all 8 bits.
class _Varint {
  final int value;
  final int bytes;
  const _Varint(this.value, this.bytes);
}

_Varint _readVarint(Uint8List buf, int off) {
  var result = 0;
  for (var i = 0; i < 8; i++) {
    final b = buf[off + i];
    result = (result << 7) | (b & 0x7f);
    if ((b & 0x80) == 0) {
      return _Varint(result, i + 1);
    }
  }
  // 9th byte: take all 8 bits.
  result = (result << 8) | buf[off + 8];
  return _Varint(result, 9);
}

/// Encode an int (>=0) as a SQLite varint. Returns the bytes.
Uint8List _writeVarint(int v) {
  if (v < 0) {
    // SQLite varints are unsigned 64-bit on the wire; negative ints in
    // serial-type land are encoded by the serial-type itself, not here.
    throw ArgumentError('varint must be non-negative, got $v');
  }
  if (v <= 0x7f) return Uint8List.fromList([v]);
  // Collect 7-bit groups, MSB first.
  final groups = <int>[];
  var x = v;
  while (x > 0) {
    groups.insert(0, x & 0x7f);
    x >>= 7;
  }
  // Set continuation bit on every group except the last.
  for (var i = 0; i < groups.length - 1; i++) {
    groups[i] |= 0x80;
  }
  return Uint8List.fromList(groups);
}

// ---------------------------------------------------------------------------
// Records
// ---------------------------------------------------------------------------

/// Decode a record (SQLite 4-style "record format") from [payload].
/// Returns the list of column values in order. Serial types:
///   0  -> NULL
///   1..6 -> big-endian signed integers (1,2,3,4,6,8 bytes)
///   7  -> 8-byte IEEE 754 double
///   8  -> integer 0
///   9  -> integer 1
///   10..11 -> reserved
///   N>=12 even -> BLOB of (N-12)/2 bytes
///   N>=13 odd  -> TEXT of (N-13)/2 bytes (UTF-8)
List<Object?> _decodeRecord(Uint8List payload) {
  final hdrLen = _readVarint(payload, 0);
  final headerEnd = hdrLen.value;
  var off = hdrLen.bytes;
  final serials = <int>[];
  while (off < headerEnd) {
    final v = _readVarint(payload, off);
    serials.add(v.value);
    off += v.bytes;
  }
  final values = <Object?>[];
  var body = headerEnd;
  for (final st in serials) {
    if (st == 0) {
      values.add(null);
    } else if (st >= 1 && st <= 6) {
      final size = const [0, 1, 2, 3, 4, 6, 8][st];
      values.add(_readSignedBE(payload, body, size));
      body += size;
    } else if (st == 7) {
      final bd = ByteData.sublistView(payload, body, body + 8);
      values.add(bd.getFloat64(0));
      body += 8;
    } else if (st == 8) {
      values.add(0);
    } else if (st == 9) {
      values.add(1);
    } else if (st >= 12 && st.isEven) {
      final size = (st - 12) ~/ 2;
      values.add(Uint8List.sublistView(payload, body, body + size));
      body += size;
    } else if (st >= 13 && st.isOdd) {
      final size = (st - 13) ~/ 2;
      values.add(utf8.decode(Uint8List.sublistView(payload, body, body + size),
          allowMalformed: true));
      body += size;
    } else {
      throw FormatException('Unsupported serial type $st');
    }
  }
  return values;
}

int _readSignedBE(Uint8List buf, int off, int size) {
  // 1..6 bytes, big-endian, sign-extend from the high bit.
  var v = 0;
  for (var i = 0; i < size; i++) {
    v = (v << 8) | buf[off + i];
  }
  // Sign extend.
  final signBit = 1 << (size * 8 - 1);
  if ((v & signBit) != 0) {
    v -= 1 << (size * 8);
  }
  return v;
}

/// Encode a list of column values as a SQLite record. Returns the
/// bytes ready to be placed in a table-leaf cell payload.
Uint8List _encodeRecord(List<Object?> values) {
  // Pass 1: figure out the serial type and body bytes per value.
  final serialBytes = <Uint8List>[];
  final bodyParts = <Uint8List>[];
  for (final v in values) {
    final (s, b) = _encodeOneValue(v);
    serialBytes.add(_writeVarint(s));
    bodyParts.add(b);
  }
  // The header includes its own length varint. We compute it iteratively
  // because the header-length varint length depends on its own value.
  var headerBodyLen = serialBytes.fold<int>(0, (a, b) => a + b.length);
  var hdrLenVarint = _writeVarint(headerBodyLen + 1);
  while (
      hdrLenVarint.length + headerBodyLen != _decodeHeaderTotal(hdrLenVarint)) {
    hdrLenVarint = _writeVarint(headerBodyLen + hdrLenVarint.length);
  }
  final out = BytesBuilder(copy: false);
  out.add(hdrLenVarint);
  for (final s in serialBytes) {
    out.add(s);
  }
  for (final b in bodyParts) {
    out.add(b);
  }
  return out.toBytes();
}

int _decodeHeaderTotal(Uint8List varint) => _readVarint(varint, 0).value;

(int, Uint8List) _encodeOneValue(Object? v) {
  if (v == null) return (0, Uint8List(0));
  if (v is bool) v = v ? 1 : 0;
  if (v is int) {
    if (v == 0) return (8, Uint8List(0));
    if (v == 1) return (9, Uint8List(0));
    // Smallest signed-int encoding that fits.
    if (v >= -0x80 && v <= 0x7f) return (1, _intBE(v, 1));
    if (v >= -0x8000 && v <= 0x7fff) return (2, _intBE(v, 2));
    if (v >= -0x800000 && v <= 0x7fffff) return (3, _intBE(v, 3));
    if (v >= -0x80000000 && v <= 0x7fffffff) return (4, _intBE(v, 4));
    if (v >= -0x800000000000 && v <= 0x7fffffffffff) return (5, _intBE(v, 6));
    return (6, _intBE(v, 8));
  }
  if (v is double) {
    final bd = ByteData(8);
    bd.setFloat64(0, v);
    return (7, bd.buffer.asUint8List());
  }
  if (v is String) {
    final bytes = utf8.encode(v);
    return (13 + bytes.length * 2, Uint8List.fromList(bytes));
  }
  if (v is List<int>) {
    final bytes = v is Uint8List ? v : Uint8List.fromList(v);
    return (12 + bytes.length * 2, bytes);
  }
  // Fallback: stringify.
  final bytes = utf8.encode(v.toString());
  return (13 + bytes.length * 2, Uint8List.fromList(bytes));
}

Uint8List _intBE(int v, int size) {
  final out = Uint8List(size);
  var x = v;
  for (var i = size - 1; i >= 0; i--) {
    out[i] = x & 0xff;
    x >>= 8;
  }
  return out;
}

// ---------------------------------------------------------------------------
// Reader
// ---------------------------------------------------------------------------

/// One row read from a table B-tree: rowid + the decoded record values.
class SqliteRow {
  final int rowid;
  final List<Object?> values;
  const SqliteRow(this.rowid, this.values);

  @override
  String toString() => 'SqliteRow(rowid=$rowid, $values)';
}

/// One row from `sqlite_schema`.
class SqliteSchemaRow {
  /// 'table', 'index', 'view', or 'trigger'.
  final String type;
  final String name;
  final String tblName;
  final int rootPage;
  final String? sql;

  const SqliteSchemaRow({
    required this.type,
    required this.name,
    required this.tblName,
    required this.rootPage,
    required this.sql,
  });

  @override
  String toString() =>
      'SqliteSchemaRow($type $name on $tblName, rootPage=$rootPage)';
}

/// Reader for a SQLite file held entirely in memory. Use
/// [SqliteFile.fromBytes] to construct.
class SqliteFile {
  final Uint8List bytes;
  final SqliteHeader header;

  SqliteFile._(this.bytes, this.header);

  factory SqliteFile.fromBytes(Uint8List bytes) {
    final hdr = SqliteHeader.parse(bytes);
    return SqliteFile._(bytes, hdr);
  }

  /// 1-based page accessor.
  Uint8List page(int pageNumber) {
    if (pageNumber < 1 || pageNumber > header.dbSizeInPages) {
      throw RangeError('page $pageNumber out of range '
          '(1..${header.dbSizeInPages})');
    }
    final start = (pageNumber - 1) * header.pageSize;
    return Uint8List.sublistView(bytes, start, start + header.pageSize);
  }

  /// Read every row of `sqlite_schema` (page 1).
  List<SqliteSchemaRow> readSchema() {
    final rows = <SqliteSchemaRow>[];
    for (final r in _walkTableBTree(1, isPage1: true)) {
      // sqlite_schema has columns: type, name, tbl_name, rootpage, sql.
      if (r.values.length < 5) continue;
      rows.add(SqliteSchemaRow(
        type: r.values[0] as String? ?? '',
        name: r.values[1] as String? ?? '',
        tblName: r.values[2] as String? ?? '',
        rootPage: (r.values[3] as int?) ?? 0,
        sql: r.values[4] as String?,
      ));
    }
    return rows;
  }

  /// Read every row of the named user table.
  List<SqliteRow> readTable(String tableName) {
    SqliteSchemaRow? schema;
    for (final s in readSchema()) {
      if (s.type == 'table' && s.name == tableName) {
        schema = s;
        break;
      }
    }
    if (schema == null) {
      throw StateError('No such table: $tableName');
    }
    return _walkTableBTree(schema.rootPage).toList();
  }

  /// Walk a table B-tree rooted at [rootPage] (yields rowid-keyed rows).
  /// When [isPage1] is true the page header starts at offset 100, not 0.
  Iterable<SqliteRow> _walkTableBTree(int rootPage,
      {bool isPage1 = false}) sync* {
    final stack = <(int, bool)>[(rootPage, isPage1)];
    while (stack.isNotEmpty) {
      final (pageNo, page1) = stack.removeLast();
      final page = this.page(pageNo);
      final headerOff = page1 && pageNo == 1 ? 100 : 0;
      final pageType = page[headerOff];
      final cellCount =
          ByteData.sublistView(page, headerOff + 3, headerOff + 5).getUint16(0);
      final cellPointersOff = headerOff + (pageType == 0x05 ? 12 : 8);
      final cellPointers = <int>[];
      for (var i = 0; i < cellCount; i++) {
        cellPointers.add(ByteData.sublistView(
                page, cellPointersOff + i * 2, cellPointersOff + i * 2 + 2)
            .getUint16(0));
      }
      if (pageType == 0x05) {
        // Table interior: each cell is (left child page no, rowid varint).
        // We push children right-to-left so iteration order matches rowid
        // order; we also follow the rightmost-pointer at the end of the
        // page header.
        final rightmost =
            ByteData.sublistView(page, headerOff + 8, headerOff + 12)
                .getUint32(0);
        final children = <int>[];
        for (final cp in cellPointers) {
          final left = ByteData.sublistView(page, cp, cp + 4).getUint32(0);
          children.add(left);
        }
        children.add(rightmost);
        // Push in reverse so we visit them in ascending order.
        for (var i = children.length - 1; i >= 0; i--) {
          stack.add((children[i], false));
        }
      } else if (pageType == 0x0d) {
        // Table leaf: each cell is (payload size varint, rowid varint,
        // payload bytes [, overflow page if spilled]).
        for (final cp in cellPointers) {
          var off = cp;
          final payloadLen = _readVarint(page, off);
          off += payloadLen.bytes;
          final rowid = _readVarint(page, off);
          off += rowid.bytes;
          // Compute "usable size" ~ pageSize - reserved.
          final usable = header.pageSize - header.reservedSpace;
          // Per SQLite spec for table-leaf: max local payload =
          //   U-35 where U=usable size. If payload <= maxLocal, fully
          //   in-page; else overflow.
          final maxLocal = usable - 35;
          if (payloadLen.value > maxLocal) {
            throw UnimplementedError(
                'Overflow pages are not supported by this reader '
                '(payload=${payloadLen.value}, maxLocal=$maxLocal on page $pageNo)');
          }
          final payload =
              Uint8List.sublistView(page, off, off + payloadLen.value);
          yield SqliteRow(rowid.value, _decodeRecord(payload));
        }
      } else if (pageType == 0x02 || pageType == 0x0a) {
        // Index B-tree pages — ignored: callers reading rows by table
        // name traverse only table B-trees.
        continue;
      } else {
        throw FormatException(
            'Unsupported page type 0x${pageType.toRadixString(16)} '
            'on page $pageNo');
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Writer
// ---------------------------------------------------------------------------

/// A logical table to write into a SQLite file.
class SqliteWriteTable {
  /// CREATE TABLE statement string. Stored verbatim in `sqlite_schema.sql`.
  final String createSql;
  final String name;
  final List<List<Object?>> rows;

  /// Optional explicit rowids; when null, rowids are assigned 1..N.
  final List<int>? rowids;

  SqliteWriteTable({
    required this.name,
    required this.createSql,
    required this.rows,
    this.rowids,
  });
}

/// Build a complete SQLite file from a set of tables. Each table gets
/// exactly one leaf page (no interior nodes, no overflow), so all rows
/// for a table must collectively fit in one page minus header/cell-
/// pointer overhead. The default page size is 4096 bytes.
///
/// Throws [StateError] if a table's rows don't fit in one page.
Uint8List writeSqliteFile(
  List<SqliteWriteTable> tables, {
  int pageSize = 4096,
}) {
  if (pageSize < 512 || pageSize > 65536 || (pageSize & (pageSize - 1)) != 0) {
    throw ArgumentError(
        'pageSize must be a power of two between 512 and 65536');
  }

  // Page layout plan:
  //   page 1  -> sqlite_schema (table-leaf, header at offset 100)
  //   page 2..N+1 -> one leaf page per table
  final pageCount = 1 + tables.length;
  final out = Uint8List(pageSize * pageCount);

  // Allocate root page numbers up front so the schema rows can reference them.
  final rootPages = <int>[];
  for (var i = 0; i < tables.length; i++) {
    rootPages.add(2 + i);
  }

  // Write header.
  final hdr = SqliteHeader(
    pageSize: pageSize,
    fileFormatWrite: 1,
    fileFormatRead: 1,
    reservedSpace: 0,
    textEncoding: 1,
    schemaCookie: 1,
    schemaFormat: 4,
    userVersion: 0,
    applicationId: 0,
    dbSizeInPages: pageCount,
  );
  out.setRange(0, 100, hdr.encode());

  // Build the schema rows.
  final schemaRows = <List<Object?>>[];
  for (var i = 0; i < tables.length; i++) {
    final t = tables[i];
    schemaRows.add([
      'table',
      t.name,
      t.name,
      rootPages[i],
      t.createSql,
    ]);
  }

  _writeTableLeafPage(
    out,
    pageOffset: 0,
    pageSize: pageSize,
    headerInsetOffset: 100, // page 1 header starts after the file header
    cells: [
      for (var i = 0; i < schemaRows.length; i++)
        _LeafCell(rowid: i + 1, payload: _encodeRecord(schemaRows[i])),
    ],
  );

  // Write each user table's leaf page.
  for (var i = 0; i < tables.length; i++) {
    final t = tables[i];
    final cells = <_LeafCell>[];
    for (var r = 0; r < t.rows.length; r++) {
      final rowid = t.rowids != null ? t.rowids![r] : (r + 1);
      cells.add(_LeafCell(rowid: rowid, payload: _encodeRecord(t.rows[r])));
    }
    _writeTableLeafPage(
      out,
      pageOffset: rootPages[i] * pageSize - pageSize,
      pageSize: pageSize,
      headerInsetOffset: 0,
      cells: cells,
    );
  }

  return out;
}

class _LeafCell {
  final int rowid;
  final Uint8List payload;
  _LeafCell({required this.rowid, required this.payload});
}

void _writeTableLeafPage(
  Uint8List file, {
  required int pageOffset,
  required int pageSize,
  required int headerInsetOffset,
  required List<_LeafCell> cells,
}) {
  // Page-header layout for a table leaf (8 bytes):
  //   0:1 page type (0x0d)
  //   1:2 first freeblock (0 = none)
  //   3:2 cell count
  //   5:2 cell content area start
  //   7:1 number of fragmented free bytes
  // Then a cell-pointer array (2 bytes per cell) immediately after the
  // page header. Cells are written from the end of the page going down.

  // Build cell bytes: each cell = payloadLenVarint || rowidVarint || payload.
  // (No overflow.)
  final cellBytes = <Uint8List>[];
  var totalCellBytes = 0;
  for (final c in cells) {
    final payloadLen = _writeVarint(c.payload.length);
    final rowidVarint = _writeVarint(c.rowid);
    final size = payloadLen.length + rowidVarint.length + c.payload.length;
    final cb = Uint8List(size);
    var off = 0;
    cb.setRange(off, off + payloadLen.length, payloadLen);
    off += payloadLen.length;
    cb.setRange(off, off + rowidVarint.length, rowidVarint);
    off += rowidVarint.length;
    cb.setRange(off, off + c.payload.length, c.payload);
    cellBytes.add(cb);
    totalCellBytes += size;
  }

  final pageHeaderSize = 8;
  final pointerArraySize = cells.length * 2;
  final overhead = headerInsetOffset + pageHeaderSize + pointerArraySize;
  if (overhead + totalCellBytes > pageSize) {
    throw StateError('Page contents do not fit in one ${pageSize}-byte page '
        '(need ${overhead + totalCellBytes} bytes). '
        'Multi-page writes are not supported by this writer.');
  }

  // Write page header.
  final ph = headerInsetOffset;
  file[pageOffset + ph + 0] = 0x0d; // page type: table leaf
  file[pageOffset + ph + 1] = 0;
  file[pageOffset + ph + 2] = 0;
  ByteData.sublistView(file).setUint16(pageOffset + ph + 3, cells.length);
  // Cells are placed contiguously starting at the end of the page.
  var cursor = pageSize;
  // We must place cells in reverse order so the cell-pointer array
  // ends up sorted ascending by rowid → SQLite expects this, but for
  // the table-leaf B-tree it actually expects ascending rowid order in
  // pointers. Sort cells by rowid first so writing left-to-right yields
  // the right order.
  final indexed = List<int>.generate(cells.length, (i) => i);
  indexed.sort((a, b) => cells[a].rowid.compareTo(cells[b].rowid));

  // Place cell bytes from the end of the page. Iterate reverse-index so
  // the *largest* rowid lands deepest in the page (pointers are stored
  // ascending, cells descending physically).
  final pointers = List<int>.filled(cells.length, 0);
  for (var i = indexed.length - 1; i >= 0; i--) {
    final origIdx = indexed[i];
    final cb = cellBytes[origIdx];
    cursor -= cb.length;
    file.setRange(pageOffset + cursor, pageOffset + cursor + cb.length, cb);
    pointers[i] = cursor;
  }
  ByteData.sublistView(file).setUint16(pageOffset + ph + 5, cursor);
  file[pageOffset + ph + 7] = 0;
  // Cell pointer array.
  final paStart = ph + pageHeaderSize;
  for (var i = 0; i < pointers.length; i++) {
    ByteData.sublistView(file)
        .setUint16(pageOffset + paStart + i * 2, pointers[i]);
  }
}
