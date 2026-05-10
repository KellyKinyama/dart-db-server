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
///   * Table B-tree writing: arbitrary depth (interior + leaf pages).
///   * Index B-tree traversal (page types 0x02 interior, 0x0a leaf) for
///     reading: each cell yields a record containing the index key
///     columns followed by the integer rowid that the SQLite engine
///     stores as the last column.
///   * Index B-tree writing: arbitrary depth (interior + leaf pages).
///   * Overflow pages on read and write (table-leaf, index-leaf, and
///     index-interior separator cells).
///   * Record decoding for serial types 0..9 and 12+/13+ (NULL, ints,
///     real, text, blob).
///   * UTF-8 text encoding only.
///
/// **NOT supported** (yet):
///   * Schema bigger than one leaf page (extremely rare in practice).
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
///
/// When the database is in WAL journal mode there will be a companion
/// `<name>-wal` file that may contain newer page versions than the main
/// database. Use [SqliteFile.fromBytesWithWal] to parse both at once;
/// any page that has a committed WAL frame transparently overrides the
/// version baked into the main file.
class SqliteFile {
  final Uint8List bytes;
  final SqliteHeader header;

  /// Page number → page bytes for pages that have a newer WAL frame.
  /// Empty when there is no WAL or no committed frames.
  final Map<int, Uint8List> _walOverrides;

  /// Total number of pages in the logical database (after applying any
  /// WAL commit). For a no-WAL file this is just `header.dbSizeInPages`.
  final int _logicalPageCount;

  SqliteFile._(this.bytes, this.header,
      {Map<int, Uint8List>? walOverrides, int? logicalPageCount})
      : _walOverrides = walOverrides ?? const {},
        _logicalPageCount = logicalPageCount ?? header.dbSizeInPages;

  factory SqliteFile.fromBytes(Uint8List bytes) {
    final hdr = SqliteHeader.parse(bytes);
    return SqliteFile._(bytes, hdr);
  }

  /// Parse a database together with its WAL companion. Frames in [walBytes]
  /// are validated by checksum and salt; any committed frames override the
  /// pages in [dbBytes]. If the WAL has no valid commit (or [walBytes] is
  /// null/empty) the result is identical to [SqliteFile.fromBytes].
  ///
  /// Throws [FormatException] if the WAL header is malformed or its
  /// page-size disagrees with the database header.
  factory SqliteFile.fromBytesWithWal(Uint8List dbBytes, Uint8List? walBytes) {
    final hdr = SqliteHeader.parse(dbBytes);
    if (walBytes == null || walBytes.length < _walHeaderSize) {
      return SqliteFile._(dbBytes, hdr);
    }
    final wal = _parseWal(walBytes, hdr.pageSize);
    if (wal == null) return SqliteFile._(dbBytes, hdr);
    return SqliteFile._(
      dbBytes,
      hdr,
      walOverrides: wal.pages,
      logicalPageCount: wal.dbSizeInPages,
    );
  }

  /// 1-based page accessor. Returns the WAL-overridden version when one
  /// exists, otherwise reads the page out of the main file.
  Uint8List page(int pageNumber) {
    if (pageNumber < 1 || pageNumber > _logicalPageCount) {
      throw RangeError('page $pageNumber out of range '
          '(1..$_logicalPageCount)');
    }
    final overridden = _walOverrides[pageNumber];
    if (overridden != null) return overridden;
    if (pageNumber > header.dbSizeInPages) {
      // The WAL extended the file but didn't supply this page (corrupt
      // WAL or our caller asked for a page beyond the commit frame).
      throw RangeError('page $pageNumber not present in db or WAL');
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

  /// Read every row of the named user table. Both rowid tables and
  /// `WITHOUT ROWID` tables are supported. For a rowid table the row's
  /// `rowid` is the primary key alias; for a WITHOUT ROWID table the
  /// returned `rowid` is always 0 (rows are keyed by their own columns).
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
    // A WITHOUT ROWID table is stored as an INDEX B-tree (page types
    // 0x02/0x0a) whose cells carry the full row record. Detect that by
    // peeking the root page's type.
    final rootPage = page(schema.rootPage);
    final rootType = rootPage[schema.rootPage == 1 ? 100 : 0];
    if (rootType == 0x02 || rootType == 0x0a) {
      // Each entry IS the row record. rowid is unused (set to 0).
      return [
        for (final entry in _walkIndexBTree(schema.rootPage))
          SqliteRow(0, entry),
      ];
    }
    return _walkTableBTree(schema.rootPage).toList();
  }

  /// True when the table at [tableName] is stored as a `WITHOUT ROWID`
  /// B-tree (root page is an index page). Returns false for ordinary
  /// rowid tables and throws if the table is unknown.
  bool isWithoutRowid(String tableName) {
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
    final rootPage = page(schema.rootPage);
    final rootType = rootPage[schema.rootPage == 1 ? 100 : 0];
    return rootType == 0x02 || rootType == 0x0a;
  }

  /// Read every entry of the named index. Each returned record is the
  /// list of key-column values followed by the integer rowid (as SQLite
  /// stores it). Entries are returned in B-tree order, which for a
  /// well-formed index is ascending key order.
  List<List<Object?>> readIndex(String indexName) {
    SqliteSchemaRow? schema;
    for (final s in readSchema()) {
      if (s.type == 'index' && s.name == indexName) {
        schema = s;
        break;
      }
    }
    if (schema == null) {
      throw StateError('No such index: $indexName');
    }
    return _walkIndexBTree(schema.rootPage).toList();
  }

  /// Walk an index B-tree rooted at [rootPage] in ascending key order.
  /// Index pages use page types 0x02 (interior) and 0x0a (leaf) and
  /// store the key as a record in each cell — there is no separate
  /// rowid varint (the rowid is the last column of the key record).
  Iterable<List<Object?>> _walkIndexBTree(int rootPage) sync* {
    yield* _walkIndexPage(rootPage);
  }

  Iterable<List<Object?>> _walkIndexPage(int pageNo) sync* {
    final page = this.page(pageNo);
    const headerOff = 0;
    final pageType = page[headerOff];
    final cellCount =
        ByteData.sublistView(page, headerOff + 3, headerOff + 5).getUint16(0);
    final cellPointersOff = headerOff + (pageType == 0x02 ? 12 : 8);
    final cellPointers = <int>[];
    for (var i = 0; i < cellCount; i++) {
      cellPointers.add(ByteData.sublistView(
              page, cellPointersOff + i * 2, cellPointersOff + i * 2 + 2)
          .getUint16(0));
    }
    if (pageType == 0x02) {
      final rightmost =
          ByteData.sublistView(page, headerOff + 8, headerOff + 12)
              .getUint32(0);
      for (final cp in cellPointers) {
        var off = cp;
        final left = ByteData.sublistView(page, off, off + 4).getUint32(0);
        off += 4;
        final payloadLen = _readVarint(page, off);
        off += payloadLen.bytes;
        final payload =
            _readPayload(page, off, payloadLen.value, indexBranch: true);
        yield* _walkIndexPage(left);
        yield _decodeRecord(payload);
      }
      yield* _walkIndexPage(rightmost);
    } else if (pageType == 0x0a) {
      for (final cp in cellPointers) {
        var off = cp;
        final payloadLen = _readVarint(page, off);
        off += payloadLen.bytes;
        final payload =
            _readPayload(page, off, payloadLen.value, indexBranch: true);
        yield _decodeRecord(payload);
      }
    } else {
      throw FormatException(
          'Unsupported index page type 0x${pageType.toRadixString(16)} '
          'on page $pageNo');
    }
  }

  /// Read a payload starting at [start] of length [payloadLen], walking
  /// any overflow chain. [indexBranch] selects the index spill formula
  /// instead of the table-leaf formula.
  Uint8List _readPayload(Uint8List page, int start, int payloadLen,
      {required bool indexBranch}) {
    final usable = header.pageSize - header.reservedSpace;
    final maxLocal =
        indexBranch ? (((usable - 12) * 64 ~/ 255) - 23) : (usable - 35);
    final minLocal = ((usable - 12) * 32 ~/ 255) - 23;
    int localSize;
    if (payloadLen <= maxLocal) {
      localSize = payloadLen;
    } else {
      final m = minLocal + ((payloadLen - minLocal) % (usable - 4));
      localSize = m <= maxLocal ? m : minLocal;
    }
    final localBytes = Uint8List.sublistView(page, start, start + localSize);
    if (localSize == payloadLen) return localBytes;
    final firstOverflow =
        ByteData.sublistView(page, start + localSize, start + localSize + 4)
            .getUint32(0);
    final builder = BytesBuilder(copy: false);
    builder.add(localBytes);
    var nextPage = firstOverflow;
    var remaining = payloadLen - localSize;
    while (remaining > 0) {
      if (nextPage == 0) {
        throw FormatException(
            'Overflow chain ended early (missing $remaining bytes)');
      }
      final ov = this.page(nextPage);
      final next = ByteData.sublistView(ov, 0, 4).getUint32(0);
      final take = remaining < (usable - 4) ? remaining : (usable - 4);
      builder.add(Uint8List.sublistView(ov, 4, 4 + take));
      remaining -= take;
      nextPage = next;
    }
    return builder.toBytes();
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
        // payload bytes [, 4-byte first-overflow-page if spilled]).
        for (final cp in cellPointers) {
          var off = cp;
          final payloadLen = _readVarint(page, off);
          off += payloadLen.bytes;
          final rowid = _readVarint(page, off);
          off += rowid.bytes;
          final usable = header.pageSize - header.reservedSpace;
          // Per SQLite spec, table-leaf:
          //   maxLocal = U - 35
          //   minLocal = ((U-12)*32/255) - 23
          //   M = minLocal + ((P - minLocal) % (U - 4))
          //   localSize = M <= maxLocal ? M : minLocal
          final maxLocal = usable - 35;
          final p = payloadLen.value;
          int localSize;
          if (p <= maxLocal) {
            localSize = p;
          } else {
            final minLocal = ((usable - 12) * 32 ~/ 255) - 23;
            final m = minLocal + ((p - minLocal) % (usable - 4));
            localSize = m <= maxLocal ? m : minLocal;
          }
          final localBytes = Uint8List.sublistView(page, off, off + localSize);
          off += localSize;
          Uint8List payload;
          if (localSize == p) {
            payload = localBytes;
          } else {
            // Read the first overflow page number, then walk the chain
            // accumulating (U-4) bytes per page until we have P total.
            final firstOverflow =
                ByteData.sublistView(page, off, off + 4).getUint32(0);
            final builder = BytesBuilder(copy: false);
            builder.add(localBytes);
            var nextPage = firstOverflow;
            var remaining = p - localSize;
            while (remaining > 0) {
              if (nextPage == 0) {
                throw FormatException(
                    'Overflow chain ended early on page $pageNo '
                    '(missing $remaining bytes)');
              }
              final ov = this.page(nextPage);
              final next = ByteData.sublistView(ov, 0, 4).getUint32(0);
              final take = remaining < (usable - 4) ? remaining : (usable - 4);
              builder.add(Uint8List.sublistView(ov, 4, 4 + take));
              remaining -= take;
              nextPage = next;
            }
            payload = builder.toBytes();
          }
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
// Write-Ahead Log (WAL) reader
// ---------------------------------------------------------------------------

const int _walHeaderSize = 32;
const int _walFrameHeaderSize = 24;

/// Magic value 0x377f0682 → little-endian checksums; 0x377f0683 → big-endian.
const int _walMagicLE = 0x377f0682;
const int _walMagicBE = 0x377f0683;

/// Result of parsing a WAL: the page-number → page-bytes overrides
/// implied by the latest valid commit, plus the size of the database
/// after that commit (in pages).
class _WalParseResult {
  final Map<int, Uint8List> pages;
  final int dbSizeInPages;
  _WalParseResult(this.pages, this.dbSizeInPages);
}

/// Parse a WAL byte buffer. Returns null when the WAL contains no
/// valid commit frames (e.g. brand-new WAL with no transactions yet).
///
/// Validation:
///   * Magic + page-size in the WAL header must match [dbPageSize].
///   * Each frame's salt must equal the WAL header's salt-1/2.
///   * Each frame's cksum must match a running Fibonacci-style sum.
/// Anything past the first invalid frame is ignored.
_WalParseResult? _parseWal(Uint8List bytes, int dbPageSize) {
  final bd = ByteData.sublistView(bytes);
  final magic = bd.getUint32(0);
  final bigEndianCk = magic == _walMagicBE;
  if (!bigEndianCk && magic != _walMagicLE) {
    throw FormatException(
        'Not a SQLite WAL (bad magic 0x${magic.toRadixString(16)})');
  }
  final pageSize = bd.getUint32(8);
  if (pageSize != dbPageSize) {
    throw FormatException('WAL page size $pageSize does not match db '
        'page size $dbPageSize');
  }
  final salt1 = bd.getUint32(16);
  final salt2 = bd.getUint32(20);
  final hdrCk1 = bd.getUint32(24);
  final hdrCk2 = bd.getUint32(28);

  // Verify the WAL header's own checksum (cumulative over header[0..23]).
  var (ck1, ck2) = _walChecksum(0, 0, bytes, 0, 24, bigEndianCk);
  if (ck1 != hdrCk1 || ck2 != hdrCk2) {
    // A WAL with a corrupt header has no usable frames.
    return null;
  }

  // Iterate frames, accumulating the overlay map but only committing
  // it at commit-marker boundaries.
  final pending = <int, Uint8List>{};
  final committed = <int, Uint8List>{};
  var dbSize = 0; // updated at each successful commit
  var seenAnyCommit = false;

  var off = _walHeaderSize;
  while (off + _walFrameHeaderSize + pageSize <= bytes.length) {
    final fbd = ByteData.sublistView(bytes, off, off + _walFrameHeaderSize);
    final pageNo = fbd.getUint32(0);
    final commit = fbd.getUint32(4);
    final fSalt1 = fbd.getUint32(8);
    final fSalt2 = fbd.getUint32(12);
    final fCk1 = fbd.getUint32(16);
    final fCk2 = fbd.getUint32(20);
    if (fSalt1 != salt1 || fSalt2 != salt2) break;
    // Checksum input: first 8 bytes of the frame header, then the page bytes.
    var (newCk1, newCk2) = _walChecksum(ck1, ck2, bytes, off, 8, bigEndianCk);
    (newCk1, newCk2) = _walChecksum(newCk1, newCk2, bytes,
        off + _walFrameHeaderSize, pageSize, bigEndianCk);
    if (newCk1 != fCk1 || newCk2 != fCk2) break;
    ck1 = newCk1;
    ck2 = newCk2;
    final pageBytes = Uint8List.sublistView(
        bytes, off + _walFrameHeaderSize, off + _walFrameHeaderSize + pageSize);
    pending[pageNo] = pageBytes;
    if (commit != 0) {
      // Promote pending frames into the committed map and remember
      // the new db size.
      committed.addAll(pending);
      pending.clear();
      dbSize = commit;
      seenAnyCommit = true;
    }
    off += _walFrameHeaderSize + pageSize;
  }

  if (!seenAnyCommit) return null;
  return _WalParseResult(committed, dbSize);
}

/// SQLite's Fibonacci-style WAL checksum. Processes [length] bytes
/// starting at [start] of [bytes] in 8-byte (two-u32) chunks. Length
/// must be a multiple of 8.
(int, int) _walChecksum(
    int s0, int s1, Uint8List bytes, int start, int length, bool bigEndian) {
  if (length & 7 != 0) {
    throw StateError(
        'WAL checksum length must be 8-byte aligned (got $length)');
  }
  final bd = ByteData.sublistView(bytes, start, start + length);
  const mask = 0xffffffff;
  for (var i = 0; i < length; i += 8) {
    final a = bigEndian ? bd.getUint32(i) : bd.getUint32(i, Endian.little);
    final b =
        bigEndian ? bd.getUint32(i + 4) : bd.getUint32(i + 4, Endian.little);
    s0 = (s0 + a + s1) & mask;
    s1 = (s1 + b + s0) & mask;
  }
  return (s0, s1);
}

/// Build a SQLite WAL file containing a single committed transaction
/// that overrides the given pages.
///
/// * [pageSize] must equal the database's page size.
/// * [pageOverrides] maps 1-based page numbers → fully-formed page bytes
///   (each must be exactly [pageSize] long). Frame ordering follows the
///   ascending page-number order, which is sufficient for SQLite to
///   replay correctly because the last frame is the commit frame.
/// * [dbSizeAfterCommit] is the post-commit database size in pages —
///   this value is written into the commit frame's `commit` field. For a
///   pure overlay (no extension) pass the existing page count.
/// * [salt1]/[salt2]/[checkpointSeq] default to deterministic values for
///   reproducibility; pass your own when chaining multiple commits.
/// * Always emits the little-endian-checksum WAL variant
///   (magic 0x377f0682), matching what SQLite produces on x86/ARM.
Uint8List buildWal({
  required int pageSize,
  required Map<int, Uint8List> pageOverrides,
  required int dbSizeAfterCommit,
  int salt1 = 0x12345678,
  int salt2 = 0x9abcdef0,
  int checkpointSeq = 0,
}) {
  if (pageSize <= 0 || pageSize & (pageSize - 1) != 0) {
    throw ArgumentError('pageSize must be a power of two, got $pageSize');
  }
  for (final e in pageOverrides.entries) {
    if (e.value.length != pageSize) {
      throw ArgumentError('page ${e.key} is ${e.value.length} bytes; '
          'expected $pageSize');
    }
  }
  if (pageOverrides.isEmpty) {
    throw ArgumentError('pageOverrides must not be empty');
  }
  final pageNos = pageOverrides.keys.toList()..sort();
  final totalLen =
      _walHeaderSize + pageNos.length * (_walFrameHeaderSize + pageSize);
  final out = Uint8List(totalLen);
  final bd = ByteData.sublistView(out);

  // Header.
  bd.setUint32(0, _walMagicLE); // little-endian variant
  bd.setUint32(4, 3007000); // file format
  bd.setUint32(8, pageSize);
  bd.setUint32(12, checkpointSeq);
  bd.setUint32(16, salt1);
  bd.setUint32(20, salt2);
  // Header checksum is over header[0..23].
  var (ck1, ck2) = _walChecksum(0, 0, out, 0, 24, false);
  bd.setUint32(24, ck1);
  bd.setUint32(28, ck2);

  // Frames.
  var off = _walHeaderSize;
  for (var i = 0; i < pageNos.length; i++) {
    final pno = pageNos[i];
    final isLast = i == pageNos.length - 1;
    bd.setUint32(off + 0, pno);
    bd.setUint32(off + 4, isLast ? dbSizeAfterCommit : 0);
    bd.setUint32(off + 8, salt1);
    bd.setUint32(off + 12, salt2);
    // Page bytes go in first so the checksum sees the final layout.
    out.setRange(off + _walFrameHeaderSize,
        off + _walFrameHeaderSize + pageSize, pageOverrides[pno]!);
    // Cumulative checksum: first 8 bytes of frame header, then page.
    (ck1, ck2) = _walChecksum(ck1, ck2, out, off, 8, false);
    (ck1, ck2) =
        _walChecksum(ck1, ck2, out, off + _walFrameHeaderSize, pageSize, false);
    bd.setUint32(off + 16, ck1);
    bd.setUint32(off + 20, ck2);
    off += _walFrameHeaderSize + pageSize;
  }

  return out;
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
  /// Ignored when [withoutRowid] is true.
  final List<int>? rowids;

  /// True for `CREATE TABLE ... WITHOUT ROWID`. The table is written as
  /// an INDEX B-tree (page types 0x02/0x0a) sorted by the rows' on-disk
  /// key. Each entry in [rows] must already be in on-disk column order
  /// (PK columns first, then the remaining columns in declared order).
  final bool withoutRowid;

  SqliteWriteTable({
    required this.name,
    required this.createSql,
    required this.rows,
    this.rowids,
    this.withoutRowid = false,
  });
}

/// A logical index to write into a SQLite file.
///
/// Entries are pre-formed records: each entry is
/// `[...keyColumnValues, rowid]` (matching how SQLite stores index
/// payloads internally). They will be sorted in ascending key order
/// before being written. Comparison ordering matches SQLite's type
/// affinity rules in the common cases (NULL < numbers < text < blob).
class SqliteWriteIndex {
  /// CREATE INDEX statement string. Stored verbatim in `sqlite_schema.sql`.
  final String createSql;
  final String name;

  /// The user table this index is on (goes into `sqlite_schema.tbl_name`).
  final String tableName;

  /// One entry per indexed row. Each entry is the list of indexed-column
  /// values followed by the integer rowid as the final element.
  final List<List<Object?>> entries;

  SqliteWriteIndex({
    required this.name,
    required this.tableName,
    required this.createSql,
    required this.entries,
  });
}

/// Lexicographic comparison of two index keys. Last element of each
/// list is the rowid (integer); all earlier elements are key columns.
int _compareIndexKeys(List<Object?> a, List<Object?> b) {
  final n = a.length < b.length ? a.length : b.length;
  for (var i = 0; i < n; i++) {
    final c = _compareSqliteValues(a[i], b[i]);
    if (c != 0) return c;
  }
  return a.length.compareTo(b.length);
}

int _compareSqliteValues(Object? x, Object? y) {
  // SQLite ordering: NULL < REAL/INT < TEXT < BLOB.
  int rank(Object? v) {
    if (v == null) return 0;
    if (v is num) return 1;
    if (v is String) return 2;
    if (v is List<int>) return 3;
    return 4;
  }

  final rx = rank(x), ry = rank(y);
  if (rx != ry) return rx.compareTo(ry);
  if (x == null) return 0;
  if (x is num) return (x).compareTo(y as num);
  if (x is String) return x.compareTo(y as String);
  if (x is List<int>) {
    final yb = y as List<int>;
    final n = x.length < yb.length ? x.length : yb.length;
    for (var i = 0; i < n; i++) {
      final c = x[i].compareTo(yb[i]);
      if (c != 0) return c;
    }
    return x.length.compareTo(yb.length);
  }
  return 0;
}

/// Build a complete SQLite file from a set of tables and indexes.
///
/// Layout: page 1 holds `sqlite_schema` (one table-leaf with the schema
/// rows), then each user table/index gets one or more pages — leaves
/// first, then interior B-tree pages above them, with the root being
/// the highest page number assigned for that tree. Overflow pages for
/// long records follow at the very end of the file.
///
/// Both tables (rowid B-trees, page types 0x05/0x0d) and indexes (page
/// types 0x02/0x0a) support arbitrary depth — the writer keeps building
/// interior levels until a single root remains.
///
/// Throws [StateError] if the schema itself doesn't fit in one
/// table-leaf page (extremely large `CREATE TABLE`/`CREATE INDEX`
/// strings can spill onto overflow pages, but the schema-leaf page
/// itself is single).
Uint8List writeSqliteFile(
  List<SqliteWriteTable> tables, {
  int pageSize = 4096,
  List<SqliteWriteIndex> indexes = const [],
}) {
  if (pageSize < 512 || pageSize > 65536 || (pageSize & (pageSize - 1)) != 0) {
    throw ArgumentError(
        'pageSize must be a power of two between 512 and 65536');
  }
  const reservedSpace = 0;
  final usable = pageSize - reservedSpace;
  final maxLocalTable = usable - 35;
  final maxLocalIndex = ((usable - 12) * 64 ~/ 255) - 23;
  final minLocal = ((usable - 12) * 32 ~/ 255) - 23;

  // 1. Plan leaf cells and build a B-tree (leaves + interior pages) per
  //    table and per index.
  final tableTrees = <List<_BTreePage>>[];
  for (final t in tables) {
    if (t.withoutRowid) {
      // WITHOUT ROWID: store the table as an index B-tree whose cells are
      // the row records themselves. Rows must already be in on-disk order
      // (PK first, then the rest in declared order); the index-B-tree
      // writer sorts them by the full record so the on-disk B-tree is
      // PK-ordered.
      final sortedRows = [...t.rows]..sort(_compareIndexKeys);
      final cells = <_PlannedCell>[
        for (final r in sortedRows)
          _planCell(
            rowid: 0,
            payload: _encodeRecord(r),
            maxLocal: maxLocalIndex,
            minLocal: minLocal,
            usable: usable,
          ),
      ];
      tableTrees.add(_buildIndexBTree(cells, sortedRows, pageSize));
      continue;
    }
    final cells = <_PlannedCell>[];
    for (var r = 0; r < t.rows.length; r++) {
      final rowid = t.rowids != null ? t.rowids![r] : (r + 1);
      cells.add(_planCell(
          rowid: rowid,
          payload: _encodeRecord(t.rows[r]),
          maxLocal: maxLocalTable,
          minLocal: minLocal,
          usable: usable));
    }
    if (t.rowids != null && t.rowids!.length != t.rows.length) {
      throw ArgumentError(
          'Table ${t.name}: rowids length (${t.rowids!.length}) '
          'does not match row count (${t.rows.length})');
    }
    final leaves = _packTableLeaves(cells, pageSize).cast<_BTreePage>();
    tableTrees.add(_buildBTree(leaves,
        isIndex: false,
        pageSize: pageSize,
        maxLocalIndex: maxLocalIndex,
        minLocal: minLocal,
        usable: usable));
  }

  final indexTrees = <List<_BTreePage>>[];
  for (final ix in indexes) {
    final sorted = [...ix.entries]..sort(_compareIndexKeys);
    final cells = <_PlannedCell>[
      for (final e in sorted)
        _planCell(
          rowid: 0,
          payload: _encodeRecord(e),
          maxLocal: maxLocalIndex,
          minLocal: minLocal,
          usable: usable,
        ),
    ];
    indexTrees.add(_buildIndexBTree(cells, sorted, pageSize));
  }

  // 2. Assign page numbers (page 1 = schema; trees get the rest).
  var nextPage = 2;
  for (final tree in tableTrees) {
    for (final p in tree) {
      p.pageNo = nextPage++;
    }
  }
  for (final tree in indexTrees) {
    for (final p in tree) {
      p.pageNo = nextPage++;
    }
  }

  // 3. Build schema rows now that we know each tree's root page.
  final schemaRows = <List<Object?>>[];
  for (var i = 0; i < tables.length; i++) {
    final t = tables[i];
    schemaRows.add([
      'table',
      t.name,
      t.name,
      tableTrees[i].last.pageNo!,
      t.createSql,
    ]);
  }
  for (var i = 0; i < indexes.length; i++) {
    final ix = indexes[i];
    schemaRows.add([
      'index',
      ix.name,
      ix.tableName,
      indexTrees[i].last.pageNo!,
      ix.createSql,
    ]);
  }
  final schemaCells = <_PlannedCell>[
    for (var i = 0; i < schemaRows.length; i++)
      _planCell(
          rowid: i + 1,
          payload: _encodeRecord(schemaRows[i]),
          maxLocal: maxLocalTable,
          minLocal: minLocal,
          usable: usable),
  ];

  // 4. Collect every _PlannedCell that may have overflow (leaves and
  //    interior separator cells), then assign overflow page numbers.
  final allPlannedCells = <_PlannedCell>[...schemaCells];
  void collect(List<_BTreePage> tree) {
    for (final p in tree) {
      if (p is _LeafPageNode) {
        allPlannedCells.addAll(p.cells);
      } else if (p is _InteriorPageNode && p.isIndex) {
        allPlannedCells.addAll(p.indexSeparators!);
      }
    }
  }

  for (final tree in tableTrees) {
    collect(tree);
  }
  for (final tree in indexTrees) {
    collect(tree);
  }

  var nextOverflowPage = nextPage;
  for (final c in allPlannedCells) {
    if (c.overflowChunks.isEmpty) continue;
    final pages = <int>[];
    for (var j = 0; j < c.overflowChunks.length; j++) {
      pages.add(nextOverflowPage++);
    }
    c.overflowPages = pages;
  }
  final pageCount = nextOverflowPage - 1;

  // 5. Allocate the file and write header.
  final out = Uint8List(pageSize * pageCount);
  final hdr = SqliteHeader(
    pageSize: pageSize,
    fileFormatWrite: 1,
    fileFormatRead: 1,
    reservedSpace: reservedSpace,
    textEncoding: 1,
    schemaCookie: 1,
    schemaFormat: 4,
    userVersion: 0,
    applicationId: 0,
    dbSizeInPages: pageCount,
  );
  out.setRange(0, 100, hdr.encode());

  // 6. Write the schema leaf at page 1 (header inset by 100 bytes).
  _writeTableLeafPage(out,
      pageOffset: 0,
      pageSize: pageSize,
      headerInsetOffset: 100,
      planned: _PlannedLeaf(cells: schemaCells));

  // 7. Write every tree page.
  void writeTree(List<_BTreePage> tree) {
    for (final p in tree) {
      final pageOffset = (p.pageNo! - 1) * pageSize;
      if (p is _LeafPageNode) {
        if (p.isIndex) {
          _writeIndexLeafPage(out,
              pageOffset: pageOffset,
              pageSize: pageSize,
              planned: _PlannedLeaf(cells: p.cells));
        } else {
          _writeTableLeafPage(out,
              pageOffset: pageOffset,
              pageSize: pageSize,
              headerInsetOffset: 0,
              planned: _PlannedLeaf(cells: p.cells));
        }
      } else if (p is _InteriorPageNode) {
        if (p.isIndex) {
          _writeIndexInteriorPage(out,
              pageOffset: pageOffset, pageSize: pageSize, planned: p);
        } else {
          _writeTableInteriorPage(out,
              pageOffset: pageOffset, pageSize: pageSize, planned: p);
        }
      }
    }
  }

  for (final tree in tableTrees) {
    writeTree(tree);
  }
  for (final tree in indexTrees) {
    writeTree(tree);
  }

  // 8. Write overflow chains.
  for (final c in allPlannedCells) {
    if (c.overflowChunks.isEmpty) continue;
    for (var j = 0; j < c.overflowChunks.length; j++) {
      final pageNo = c.overflowPages[j];
      final pageOff = (pageNo - 1) * pageSize;
      final next = j + 1 < c.overflowPages.length ? c.overflowPages[j + 1] : 0;
      ByteData.sublistView(out).setUint32(pageOff, next);
      out.setRange(pageOff + 4, pageOff + 4 + c.overflowChunks[j].length,
          c.overflowChunks[j]);
    }
  }

  return out;
}

// ---------------------------------------------------------------------------
// B-tree page node types (in-memory representation while planning).
// ---------------------------------------------------------------------------

abstract class _BTreePage {
  int? pageNo;

  /// `int` for table B-trees (rowid), `List<Object?>` for indexes
  /// (the full key record including trailing rowid).
  Object get maxKey;
}

class _LeafPageNode extends _BTreePage {
  final bool isIndex;
  final List<_PlannedCell> cells;

  /// Decoded entries parallel to [cells], used to derive interior
  /// separators for index trees. Null for table leaves.
  final List<List<Object?>>? entries;

  _LeafPageNode({required this.isIndex, required this.cells, this.entries});

  @override
  Object get maxKey {
    if (isIndex) return entries!.last;
    return cells.last.rowid;
  }
}

class _InteriorPageNode extends _BTreePage {
  final bool isIndex;

  /// Length >= 2; the last entry is the rightmost child (no separator).
  final List<_BTreePage> children;

  /// For index interiors only: pre-planned separator cells, length =
  /// `children.length - 1`. Each separator's payload encodes that
  /// child's `maxKey` so SQLite's binary search works correctly.
  final List<_PlannedCell>? indexSeparators;

  _InteriorPageNode({
    required this.isIndex,
    required this.children,
    this.indexSeparators,
  });

  @override
  Object get maxKey => children.last.maxKey;
}

// ---------------------------------------------------------------------------
// Cell-size estimators (used by the greedy packers).
// ---------------------------------------------------------------------------

int _tableLeafCellSize(_PlannedCell c) =>
    _writeVarint(c.payloadLen).length +
    _writeVarint(c.rowid).length +
    c.localBytes.length +
    (c.overflowChunks.isNotEmpty ? 4 : 0);

int _indexLeafCellSize(_PlannedCell c) =>
    _writeVarint(c.payloadLen).length +
    c.localBytes.length +
    (c.overflowChunks.isNotEmpty ? 4 : 0);

int _tableInteriorCellSize(int separatorRowid) =>
    4 + _writeVarint(separatorRowid).length;

int _indexInteriorCellSize(_PlannedCell sep) => 4 + _indexLeafCellSize(sep);

// ---------------------------------------------------------------------------
// Greedy packers and bottom-up B-tree builder.
// ---------------------------------------------------------------------------

List<_LeafPageNode> _packTableLeaves(List<_PlannedCell> cells, int pageSize) {
  final pages = <_LeafPageNode>[];
  var current = <_PlannedCell>[];
  var size = 8; // page header
  for (final c in cells) {
    final delta = _tableLeafCellSize(c) + 2; // + cell pointer
    if (current.isNotEmpty && size + delta > pageSize) {
      pages.add(_LeafPageNode(isIndex: false, cells: current));
      current = [];
      size = 8;
    }
    current.add(c);
    size += delta;
  }
  if (current.isNotEmpty) {
    pages.add(_LeafPageNode(isIndex: false, cells: current));
  }
  return pages;
}

/// One level of an index B-tree during construction. [pages] holds the
/// pages at this level (left-to-right), and [separators] holds the
/// `length - 1` separator entries that go BETWEEN them — each
/// separator is an index entry that has been promoted up out of the
/// level below, so that every entry in the original index appears in
/// exactly one cell across the whole tree (matching SQLite's index
/// B-tree invariant that interior cells are real entries, not just
/// routing keys).
class _IndexLevel {
  final List<_BTreePage> pages;
  final List<_PlannedCell> separators;
  _IndexLevel({required this.pages, required this.separators});
}

_IndexLevel _buildIndexLeafLevel(
  List<_PlannedCell> cells,
  List<List<Object?>> entries,
  int pageSize,
) {
  final pages = <_BTreePage>[];
  final separators = <_PlannedCell>[];

  var i = 0;
  while (i < cells.length) {
    final current = <_PlannedCell>[];
    final currentEntries = <List<Object?>>[];
    var size = 8;
    while (i < cells.length) {
      final c = cells[i];
      final delta = _indexLeafCellSize(c) + 2;
      if (current.isNotEmpty && size + delta > pageSize) break;
      current.add(c);
      currentEntries.add(entries[i]);
      size += delta;
      i++;
    }
    pages.add(
        _LeafPageNode(isIndex: true, cells: current, entries: currentEntries));
    if (i < cells.length) {
      // Promote cells[i] up as the separator between this leaf and the
      // next — it does NOT appear in any leaf.
      separators.add(cells[i]);
      i++;
    }
  }
  return _IndexLevel(pages: pages, separators: separators);
}

_IndexLevel _buildIndexInteriorLevelPromoted(_IndexLevel below, int pageSize) {
  final newPages = <_BTreePage>[];
  final newSeparators = <_PlannedCell>[];

  var i = 0;
  while (i < below.pages.length) {
    final children = <_BTreePage>[below.pages[i]];
    final seps = <_PlannedCell>[];
    var size = 12;
    i++;
    while (i < below.pages.length) {
      final sep = below.separators[i - 1];
      final delta = _indexInteriorCellSize(sep) + 2;
      if (size + delta > pageSize) break;
      seps.add(sep);
      children.add(below.pages[i]);
      size += delta;
      i++;
    }
    // Take-back: if exactly one page would remain, steal the last child
    // (and its separator) so the next interior gets >=2 children.
    if (i < below.pages.length && below.pages.length - i == 1) {
      if (children.length >= 3) {
        children.removeLast();
        seps.removeLast();
        i--;
      } else {
        throw StateError(
            'Page size too small: cannot split an index B-tree level '
            'without producing an interior page with <2 children.');
      }
    }
    newPages.add(_InteriorPageNode(
      isIndex: true,
      children: children,
      indexSeparators: seps,
    ));
    if (i < below.pages.length) {
      // Promote the separator between this interior and the next: it
      // lives at below.separators[i-1] (between the last child of the
      // current interior and the first child of the next). Do NOT
      // increment `i` — below.pages[i] becomes the next interior's
      // first child.
      newSeparators.add(below.separators[i - 1]);
    }
  }
  return _IndexLevel(pages: newPages, separators: newSeparators);
}

/// Build a complete index B-tree using key promotion at every level.
/// Returns every page in the tree (leaves first, root last).
List<_BTreePage> _buildIndexBTree(
  List<_PlannedCell> cells,
  List<List<Object?>> entries,
  int pageSize,
) {
  var level = _buildIndexLeafLevel(cells, entries, pageSize);
  final all = <_BTreePage>[...level.pages];
  while (level.pages.length > 1) {
    final next = _buildIndexInteriorLevelPromoted(level, pageSize);
    if (next.pages.length >= level.pages.length) {
      throw StateError('Index B-tree did not converge (level shrunk from '
          '${level.pages.length} to ${next.pages.length}); page size '
          'may be too small for this dataset.');
    }
    all.addAll(next.pages);
    level = next;
  }
  return all;
}

List<_InteriorPageNode> _buildTableInteriorLevel(
    List<_BTreePage> children, int pageSize) {
  final out = <_InteriorPageNode>[];
  var current = <_BTreePage>[];
  var size = 12; // interior page header
  for (final child in children) {
    final delta = _tableInteriorCellSize(child.maxKey as int) + 2;
    if (current.length >= 2 && size + delta > pageSize) {
      // Close: last child of `current` becomes the rightmost — refund
      // its cell + pointer cost (it isn't represented as a cell).
      final last = current.last;
      size -= _tableInteriorCellSize(last.maxKey as int) + 2;
      out.add(_InteriorPageNode(isIndex: false, children: current.toList()));
      current = [];
      size = 12;
    }
    current.add(child);
    size += delta;
  }
  if (current.isNotEmpty) {
    if (current.length < 2) {
      throw StateError(
          'Page size too small: a table-interior page would have only '
          '${current.length} child(ren).');
    }
    out.add(_InteriorPageNode(isIndex: false, children: current.toList()));
  }
  return out;
}

List<_InteriorPageNode> _buildIndexInteriorLevel(List<_BTreePage> children,
    int pageSize, int maxLocalIndex, int minLocal, int usable) {
  // Pre-plan a separator cell for each child (sized as if it were a
  // separator on this level). Some of these get discarded for the
  // child that ends up as a page's rightmost.
  final allSeps = <_PlannedCell>[
    for (final child in children)
      _planCell(
          rowid: 0,
          payload: _encodeRecord(child.maxKey as List<Object?>),
          maxLocal: maxLocalIndex,
          minLocal: minLocal,
          usable: usable),
  ];

  final out = <_InteriorPageNode>[];
  var currentChildren = <_BTreePage>[];
  var currentSeps = <_PlannedCell>[];
  var size = 12;
  for (var i = 0; i < children.length; i++) {
    final child = children[i];
    final sep = allSeps[i];
    final delta = _indexInteriorCellSize(sep) + 2;
    if (currentChildren.length >= 2 && size + delta > pageSize) {
      final lastSep = currentSeps.removeLast();
      size -= _indexInteriorCellSize(lastSep) + 2;
      out.add(_InteriorPageNode(
        isIndex: true,
        children: currentChildren.toList(),
        indexSeparators: currentSeps.toList(),
      ));
      currentChildren = [];
      currentSeps = [];
      size = 12;
    }
    currentChildren.add(child);
    currentSeps.add(sep);
    size += delta;
  }
  if (currentChildren.isNotEmpty) {
    if (currentChildren.length < 2) {
      throw StateError(
          'Page size too small: an index-interior page would have only '
          '${currentChildren.length} child(ren).');
    }
    currentSeps.removeLast(); // rightmost has no separator
    out.add(_InteriorPageNode(
      isIndex: true,
      children: currentChildren.toList(),
      indexSeparators: currentSeps.toList(),
    ));
  }
  return out;
}

/// Build a B-tree bottom-up from a leaf list. Returns every page in the
/// tree (leaves first, root last) so callers can assign page numbers
/// and write them out.
List<_BTreePage> _buildBTree(
  List<_BTreePage> leaves, {
  required bool isIndex,
  required int pageSize,
  required int maxLocalIndex,
  required int minLocal,
  required int usable,
}) {
  final all = <_BTreePage>[...leaves];
  var level = leaves;
  while (level.length > 1) {
    final nextLevel = isIndex
        ? _buildIndexInteriorLevel(
            level, pageSize, maxLocalIndex, minLocal, usable)
        : _buildTableInteriorLevel(level, pageSize);
    if (nextLevel.length >= level.length) {
      throw StateError(
          'B-tree did not converge (level shrunk from ${level.length} to '
          '${nextLevel.length}); page size may be too small.');
    }
    all.addAll(nextLevel);
    level = nextLevel.cast<_BTreePage>();
  }
  return all;
}

// ---------------------------------------------------------------------------
// Interior page writers.
// ---------------------------------------------------------------------------

void _writeTableInteriorPage(
  Uint8List file, {
  required int pageOffset,
  required int pageSize,
  required _InteriorPageNode planned,
}) {
  // Page-header layout (12 bytes):
  //   0:1 page type (0x05)
  //   1:2 freeblock (0)
  //   3:2 cell count
  //   5:2 cell content area start
  //   7:1 fragmented (0)
  //   8:4 right-most child page number
  // Cells: leftChild(u32) || rowidVarint
  final cells = planned.children.sublist(0, planned.children.length - 1);
  final rightmost = planned.children.last;

  final cellBytes = <Uint8List>[];
  var totalCellBytes = 0;
  for (final c in cells) {
    final v = _writeVarint(c.maxKey as int);
    final cb = Uint8List(4 + v.length);
    ByteData.sublistView(cb).setUint32(0, c.pageNo!);
    cb.setRange(4, 4 + v.length, v);
    cellBytes.add(cb);
    totalCellBytes += cb.length;
  }

  const ph = 12;
  final paSize = cells.length * 2;
  if (ph + paSize + totalCellBytes > pageSize) {
    throw StateError(
        'Table interior page does not fit in one ${pageSize}-byte page '
        '(need ${ph + paSize + totalCellBytes} bytes).');
  }

  file[pageOffset] = 0x05;
  file[pageOffset + 1] = 0;
  file[pageOffset + 2] = 0;
  ByteData.sublistView(file).setUint16(pageOffset + 3, cells.length);
  ByteData.sublistView(file).setUint32(pageOffset + 8, rightmost.pageNo!);

  var cursor = pageSize;
  final pointers = List<int>.filled(cells.length, 0);
  for (var i = cells.length - 1; i >= 0; i--) {
    final cb = cellBytes[i];
    cursor -= cb.length;
    file.setRange(pageOffset + cursor, pageOffset + cursor + cb.length, cb);
    pointers[i] = cursor;
  }
  ByteData.sublistView(file).setUint16(pageOffset + 5, cursor);
  file[pageOffset + 7] = 0;
  for (var i = 0; i < pointers.length; i++) {
    ByteData.sublistView(file).setUint16(pageOffset + ph + i * 2, pointers[i]);
  }
}

void _writeIndexInteriorPage(
  Uint8List file, {
  required int pageOffset,
  required int pageSize,
  required _InteriorPageNode planned,
}) {
  // Cells: leftChild(u32) || payloadLenVarint || localBytes
  //         [|| firstOverflowPage(u32)]
  final cells = planned.children.sublist(0, planned.children.length - 1);
  final rightmost = planned.children.last;
  final seps = planned.indexSeparators!;

  final cellBytes = <Uint8List>[];
  var totalCellBytes = 0;
  for (var i = 0; i < cells.length; i++) {
    final child = cells[i];
    final s = seps[i];
    final payloadLen = _writeVarint(s.payloadLen);
    final tail = s.overflowChunks.isNotEmpty ? 4 : 0;
    final cb = Uint8List(4 + payloadLen.length + s.localBytes.length + tail);
    var off = 0;
    ByteData.sublistView(cb).setUint32(off, child.pageNo!);
    off += 4;
    cb.setRange(off, off + payloadLen.length, payloadLen);
    off += payloadLen.length;
    cb.setRange(off, off + s.localBytes.length, s.localBytes);
    off += s.localBytes.length;
    if (tail == 4) {
      ByteData.sublistView(cb).setUint32(off, s.overflowPages.first);
    }
    cellBytes.add(cb);
    totalCellBytes += cb.length;
  }

  const ph = 12;
  final paSize = cells.length * 2;
  if (ph + paSize + totalCellBytes > pageSize) {
    throw StateError(
        'Index interior page does not fit in one ${pageSize}-byte page '
        '(need ${ph + paSize + totalCellBytes} bytes).');
  }

  file[pageOffset] = 0x02;
  file[pageOffset + 1] = 0;
  file[pageOffset + 2] = 0;
  ByteData.sublistView(file).setUint16(pageOffset + 3, cells.length);
  ByteData.sublistView(file).setUint32(pageOffset + 8, rightmost.pageNo!);

  var cursor = pageSize;
  final pointers = List<int>.filled(cells.length, 0);
  for (var i = cells.length - 1; i >= 0; i--) {
    final cb = cellBytes[i];
    cursor -= cb.length;
    file.setRange(pageOffset + cursor, pageOffset + cursor + cb.length, cb);
    pointers[i] = cursor;
  }
  ByteData.sublistView(file).setUint16(pageOffset + 5, cursor);
  file[pageOffset + 7] = 0;
  for (var i = 0; i < pointers.length; i++) {
    ByteData.sublistView(file).setUint16(pageOffset + ph + i * 2, pointers[i]);
  }
}

void _writeIndexLeafPage(
  Uint8List file, {
  required int pageOffset,
  required int pageSize,
  required _PlannedLeaf planned,
}) {
  // Index-leaf cell layout:
  //   payloadLenVarint || localBytes [|| firstOverflowPage(u32)]
  // (No rowid varint — the rowid is the last record column.)
  final cells = planned.cells;
  final cellBytes = <Uint8List>[];
  var totalCellBytes = 0;
  for (final c in cells) {
    final payloadLen = _writeVarint(c.payloadLen);
    final tail = c.overflowChunks.isNotEmpty ? 4 : 0;
    final size = payloadLen.length + c.localBytes.length + tail;
    final cb = Uint8List(size);
    var off = 0;
    cb.setRange(off, off + payloadLen.length, payloadLen);
    off += payloadLen.length;
    cb.setRange(off, off + c.localBytes.length, c.localBytes);
    off += c.localBytes.length;
    if (tail == 4) {
      ByteData.sublistView(cb).setUint32(off, c.overflowPages.first);
    }
    cellBytes.add(cb);
    totalCellBytes += size;
  }

  const pageHeaderSize = 8;
  final pointerArraySize = cells.length * 2;
  final overhead = pageHeaderSize + pointerArraySize;
  if (overhead + totalCellBytes > pageSize) {
    throw StateError('Index leaf does not fit in one ${pageSize}-byte page '
        '(need ${overhead + totalCellBytes} bytes). '
        'This should not happen — cells are pre-packed by the writer.');
  }

  file[pageOffset + 0] = 0x0a; // index leaf
  file[pageOffset + 1] = 0;
  file[pageOffset + 2] = 0;
  ByteData.sublistView(file).setUint16(pageOffset + 3, cells.length);

  // Cells already sorted (index entries pre-sorted at plan time). Write
  // physically descending so the ascending pointer array indexes them
  // in key order.
  var cursor = pageSize;
  final pointers = List<int>.filled(cells.length, 0);
  for (var i = cells.length - 1; i >= 0; i--) {
    final cb = cellBytes[i];
    cursor -= cb.length;
    file.setRange(pageOffset + cursor, pageOffset + cursor + cb.length, cb);
    pointers[i] = cursor;
  }
  ByteData.sublistView(file).setUint16(pageOffset + 5, cursor);
  file[pageOffset + 7] = 0;
  for (var i = 0; i < pointers.length; i++) {
    ByteData.sublistView(file)
        .setUint16(pageOffset + pageHeaderSize + i * 2, pointers[i]);
  }
}

/// One cell about to be written to a table-leaf page.
class _PlannedCell {
  final int rowid;

  /// Total payload size (P) — what gets serialized in the cell header.
  final int payloadLen;

  /// Bytes that live directly in the leaf cell (P or local-size for
  /// overflow cells).
  final Uint8List localBytes;

  /// Per-overflow-page chunks of the spilled tail. Empty when no overflow.
  final List<Uint8List> overflowChunks;

  /// Filled in pass 2: page number of each overflow chunk.
  List<int> overflowPages;

  _PlannedCell({
    required this.rowid,
    required this.payloadLen,
    required this.localBytes,
    required this.overflowChunks,
    this.overflowPages = const [],
  });

  _PlannedCell withOverflowPages(List<int> pages) => _PlannedCell(
        rowid: rowid,
        payloadLen: payloadLen,
        localBytes: localBytes,
        overflowChunks: overflowChunks,
        overflowPages: pages,
      );

  _PlannedCell withRowid(int newRowid) => _PlannedCell(
        rowid: newRowid,
        payloadLen: payloadLen,
        localBytes: localBytes,
        overflowChunks: overflowChunks,
        overflowPages: overflowPages,
      );
}

class _PlannedLeaf {
  final List<_PlannedCell> cells;
  _PlannedLeaf({required this.cells});
}

_PlannedCell _planCell({
  required int rowid,
  required Uint8List payload,
  required int maxLocal,
  required int minLocal,
  required int usable,
}) {
  final p = payload.length;
  if (p <= maxLocal) {
    return _PlannedCell(
        rowid: rowid,
        payloadLen: p,
        localBytes: payload,
        overflowChunks: const []);
  }
  final m = minLocal + ((p - minLocal) % (usable - 4));
  final localSize = m <= maxLocal ? m : minLocal;
  final local = Uint8List.sublistView(payload, 0, localSize);
  final tail = Uint8List.sublistView(payload, localSize);
  final chunkSize = usable - 4;
  final chunks = <Uint8List>[];
  for (var off = 0; off < tail.length; off += chunkSize) {
    final end = off + chunkSize < tail.length ? off + chunkSize : tail.length;
    chunks.add(Uint8List.sublistView(tail, off, end));
  }
  return _PlannedCell(
      rowid: rowid, payloadLen: p, localBytes: local, overflowChunks: chunks);
}

void _writeTableLeafPage(
  Uint8List file, {
  required int pageOffset,
  required int pageSize,
  required int headerInsetOffset,
  required _PlannedLeaf planned,
}) {
  // Page-header layout for a table leaf (8 bytes):
  //   0:1 page type (0x0d)
  //   1:2 first freeblock (0 = none)
  //   3:2 cell count
  //   5:2 cell content area start
  //   7:1 number of fragmented free bytes
  // Cells are written from the end of the page going down so the
  // ascending cell-pointer array can index them by rowid.
  final cells = planned.cells;

  // Build the on-disk cell bytes:
  //   payloadLenVarint || rowidVarint || localBytes [|| firstOverflowPage(u32)]
  final cellBytes = <Uint8List>[];
  var totalCellBytes = 0;
  for (final c in cells) {
    final payloadLen = _writeVarint(c.payloadLen);
    final rowidVarint = _writeVarint(c.rowid);
    final tail = c.overflowChunks.isNotEmpty ? 4 : 0;
    final size =
        payloadLen.length + rowidVarint.length + c.localBytes.length + tail;
    final cb = Uint8List(size);
    var off = 0;
    cb.setRange(off, off + payloadLen.length, payloadLen);
    off += payloadLen.length;
    cb.setRange(off, off + rowidVarint.length, rowidVarint);
    off += rowidVarint.length;
    cb.setRange(off, off + c.localBytes.length, c.localBytes);
    off += c.localBytes.length;
    if (tail == 4) {
      ByteData.sublistView(cb).setUint32(off, c.overflowPages.first);
    }
    cellBytes.add(cb);
    totalCellBytes += size;
  }

  const pageHeaderSize = 8;
  final pointerArraySize = cells.length * 2;
  final overhead = headerInsetOffset + pageHeaderSize + pointerArraySize;
  if (overhead + totalCellBytes > pageSize) {
    throw StateError('Leaf page contents do not fit in one ${pageSize}-byte '
        'page (need ${overhead + totalCellBytes} bytes). '
        'This should not happen — cells are pre-packed by the writer.');
  }

  final ph = headerInsetOffset;
  file[pageOffset + ph + 0] = 0x0d;
  file[pageOffset + ph + 1] = 0;
  file[pageOffset + ph + 2] = 0;
  ByteData.sublistView(file).setUint16(pageOffset + ph + 3, cells.length);

  var cursor = pageSize;
  // Sort by rowid so pointer array ends up ascending; cells go in
  // descending physical order so the largest-rowid cell is deepest.
  final indexed = List<int>.generate(cells.length, (i) => i);
  indexed.sort((a, b) => cells[a].rowid.compareTo(cells[b].rowid));
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
  final paStart = ph + pageHeaderSize;
  for (var i = 0; i < pointers.length; i++) {
    ByteData.sublistView(file)
        .setUint16(pageOffset + paStart + i * 2, pointers[i]);
  }
}
