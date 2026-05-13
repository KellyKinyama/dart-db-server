/// Incremental BLOB I/O — analogous to SQLite's `sqlite3_blob_open` /
/// `sqlite3_blob_read` / `sqlite3_blob_write` family. Lets callers
/// stream bytes in and out of an existing BLOB column without
/// materializing the whole value as a single Uint8List in user code.
///
/// Open a handle via [Database.openBlob]. Like SQLite's API, the
/// handle's underlying blob length is fixed at open time; writes
/// cannot extend the blob. Use `UPDATE ... SET col = zeroblob(n)` (or
/// supply a pre-sized BLOB literal) before opening a writable handle
/// if you need to allocate space first.
library;

import 'dart:math' as math;
import 'dart:typed_data';

class BlobHandle {
  final List<Object?> _row;
  final int _colIdx;
  final String _tableName;
  final String _columnName;
  final bool _writable;
  bool _closed = false;
  int _offset = 0;

  BlobHandle.internal(
    this._row,
    this._colIdx, {
    required String tableName,
    required String columnName,
    required bool writable,
  })  : _tableName = tableName,
        _columnName = columnName,
        _writable = writable;

  String get tableName => _tableName;
  String get columnName => _columnName;
  bool get isWritable => _writable;
  bool get isClosed => _closed;

  Uint8List _backing() {
    if (_closed) {
      throw StateError('BlobHandle is closed');
    }
    final v = _row[_colIdx];
    if (v is Uint8List) return v;
    if (v is List<int>) {
      // Promote a generic List<int> (e.g. legacy ZEROBLOB result) to a
      // Uint8List in-place so writes through this handle persist back
      // to the row.
      final promoted = Uint8List.fromList(v);
      _row[_colIdx] = promoted;
      return promoted;
    }
    if (v == null) {
      throw StateError('BLOB column $_tableName.$_columnName is NULL');
    }
    throw StateError(
        'BLOB column $_tableName.$_columnName does not contain bytes '
        '(got ${v.runtimeType})');
  }

  /// Total length of the blob in bytes.
  int get length => _backing().length;

  /// Current read/write cursor position (bytes from start of blob).
  int get position => _offset;

  /// Move the cursor. Must be in `[0, length]`.
  set position(int p) {
    if (p < 0 || p > length) {
      throw RangeError.range(p, 0, length, 'position');
    }
    _offset = p;
  }

  /// Read up to [count] bytes starting at [position] (or [offset] if
  /// given). Returns a fresh copy. Advances the cursor by the number
  /// of bytes returned.
  Uint8List read(int count, {int? offset}) {
    final b = _backing();
    final from = offset ?? _offset;
    if (from < 0 || from > b.length) {
      throw RangeError.range(from, 0, b.length, 'offset');
    }
    final end = math.min(from + count, b.length);
    final out = Uint8List.fromList(b.sublist(from, end));
    _offset = end;
    return out;
  }

  /// Write [data] starting at [position] (or [offset] if given).
  /// Cannot grow the blob — throws [RangeError] if the write would
  /// extend past the current length. Advances the cursor by
  /// `data.length`.
  void write(List<int> data, {int? offset}) {
    if (!_writable) {
      throw StateError('BlobHandle is read-only');
    }
    final b = _backing();
    final from = offset ?? _offset;
    if (from < 0 || from + data.length > b.length) {
      throw RangeError('write of ${data.length} bytes at offset $from exceeds '
          'blob length ${b.length}; sqlite incremental blob I/O '
          'cannot grow the blob');
    }
    b.setRange(from, from + data.length, data);
    _offset = from + data.length;
  }

  /// Release the handle. Idempotent. Subsequent reads/writes throw.
  void close() {
    _closed = true;
  }
}
