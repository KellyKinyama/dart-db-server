// Canonical OALL8 execute/fetch for a REAL Oracle server (19c+/21c/23ai/26ai),
// ported from the proven thin driver (C:\projects\ai_projects\dart-oracledb,
// lib/src/protocol/messages/execute_message.dart). This is the wire format a
// genuine OCI/thin client uses — distinct from the dart-db-server smoke format
// in oracle_thick_client.dart. Query-only, no binds (the T1 keystone); typed
// binds, DATE/TIMESTAMP/LOB breadth land in later increments.
//
// All multi-byte integers use Oracle's variable-length UB encoding via the
// shared WriteBuffer/ReadBuffer in oracle_codec.dart (validated against real
// Oracle during the FAST_AUTH handshake).
import 'dart:convert';
import 'dart:typed_data';

import 'package:dart_db_server/server/oracle_codec.dart';
import 'package:dart_db_server/server/oracle_number.dart';

// --- TTC message types (server -> client) ----------------------------------
const int _msgTypeFunction = 3;
const int _msgTypeError = 4;
const int _msgTypeRowHeader = 6;
const int _msgTypeRowData = 7;
const int _msgTypeParameter = 8;
const int _msgTypeStatus = 9;
const int _msgTypeWarning = 15;
const int _msgTypeDescribeInfo = 16;
const int _msgTypeIoVector = 11;
const int _msgTypeBitVector = 21;
const int _msgTypeServerSidePiggyback = 23;
const int _msgTypeImplicitResultSet = 27;
const int _msgTypeEndOfRequest = 29;
const int _msgTypeFlushOutBinds = 19;

// --- TTC function codes (client -> server) ---------------------------------
const int _funcExecute = 94; // OALL8
const int _funcFetch = 5;

// --- execute option flags --------------------------------------------------
const int _execOptionParse = 0x01;
const int _execOptionExecute = 0x20;
const int _execOptionFetch = 0x40;
const int _execOptionImplicitResultset = 0x8000;

const int _maxLongLength = 0x7fffffff;

// --- field-version gates ---------------------------------------------------
const int _fieldVersion12_2 = 8;
const int _fieldVersion23_1 = 17;
const int _fieldVersion23_1Ext1 = 18;
const int _fieldVersion23_1Ext3 = 20;
const int _fieldVersion23_4 = 24;

// --- Oracle data type indicators -------------------------------------------
const int _oraTypeVarchar = 1;
const int _oraTypeNumber = 2;
const int _oraTypeInteger = 3;
const int _oraTypeFloat = 4;
const int _oraTypeString = 5;
const int _oraTypeVarnum = 6;
const int _oraTypeLong = 8;
const int _oraTypeVarchar2 = 9;
const int _oraTypeDate = 12;
const int _oraTypeRaw = 23;
const int _oraTypeLongRaw = 24;
const int _oraTypeChar = 96;
const int _oraTypeBinaryFloat = 100;
const int _oraTypeBinaryDouble = 101;
const int _oraTypeRowid = 11;
const int _oraTypeURowid = 208;
const int _oraTypeTimestamp = 180;
const int _oraTypeTimestampTz = 181;
const int _oraTypeTimestampLtz = 231;
const int _oraTypeIntervalYM = 182;
const int _oraTypeIntervalDS = 183;
const int _oraTypeClob = 112;
const int _oraTypeBlob = 113;

const int _csfrmNChar = 2;

/// Column metadata decoded from a DESCRIBE_INFO message.
class NativeColumn {
  NativeColumn({
    required this.name,
    required this.oracleType,
    required this.maxLength,
    this.precision,
    this.scale,
    this.csfrm = 0,
  });

  final String name;
  final int oracleType;
  final int maxLength;
  final int? precision;
  final int? scale;
  final int csfrm;

  @override
  String toString() =>
      'NativeColumn($name, type=$oracleType, prec=$precision, scale=$scale)';
}

/// The decoded outcome of an OALL8 execute (or a follow-up fetch).
class NativeExecuteResponse {
  NativeExecuteResponse({
    required this.columns,
    required this.rows,
    required this.cursorId,
    required this.moreRows,
    required this.complete,
    this.rowsAffected,
    this.errorNum,
    this.errorMessage,
    this.refCursorId,
    this.refCursorColumns,
    this.outBindValues = const [],
    this.implicitResults = const [],
    this.batchErrors = const [],
  });

  final List<NativeColumn> columns;
  final List<List<Object?>> rows;
  final int cursorId;

  /// More rows remain on the server cursor (issue a FETCH).
  final bool moreRows;

  /// The response stream reached its terminal message (STATUS / ERROR /
  /// END_OF_REQUEST). False means more DATA packets are needed before the
  /// response can be decoded — the caller should read another frame and retry.
  final bool complete;

  final int? rowsAffected;
  final int? errorNum;
  final String? errorMessage;

  /// A REF CURSOR OUT bind's server cursor id (SYS_REFCURSOR), when the
  /// executed statement opened one. FETCH from this id to drain its rows.
  final int? refCursorId;

  /// The REF CURSOR's column metadata, decoded from its embedded describe.
  final List<NativeColumn>? refCursorColumns;

  /// Decoded PL/SQL OUT bind values, one per OUT bind in declaration order.
  final List<Object?> outBindValues;

  /// Implicit result-set cursors (`DBMS_SQL.RETURN_RESULT`).
  final List<NativeImplicitResult> implicitResults;

  /// Per-row errors from an array-DML `executeMany(batchErrors: true)` call
  /// (the valid rows were still applied; see `rowsAffected`).
  final List<NativeBatchError> batchErrors;

  bool get isSuccess => errorNum == null || errorNum == 0;
}

/// An implicit result set (a cursor returned via `DBMS_SQL.RETURN_RESULT`):
/// its server cursor id and column metadata. FETCH the id to drain its rows.
class NativeImplicitResult {
  NativeImplicitResult(this.cursorId, this.columns);
  final int cursorId;
  final List<NativeColumn> columns;
}

/// Thrown when a column carries a type this increment does not decode yet.
class NativeUnsupportedTypeException implements Exception {
  NativeUnsupportedTypeException(this.oraType);
  final int oraType;
  @override
  String toString() =>
      'NativeUnsupportedTypeException: Oracle type $oraType not supported yet';
}

/// Bind direction for a PL/SQL bind.
enum NativeBindDir { input, output, inputOutput }

/// A PL/SQL bind — an IN value or an OUT placeholder of a declared type. Build
/// with the factory constructors (`NativeBind.value`, `NativeBind.outNumber`,
/// …) and pass a list to [buildPlsqlExecute].
class NativeBind {
  const NativeBind._({
    required this.dir,
    required this.oraType,
    required this.maxSize,
    required this.csfrm,
    this.contFlags = 0,
    this.value,
  });

  /// An IN bind whose Oracle type is inferred from the Dart [value].
  factory NativeBind.value(Object? value) {
    final e = _encodeBind(value);
    return NativeBind._(
      dir: NativeBindDir.input,
      oraType: e.oraType,
      maxSize: e.maxSize,
      csfrm: e.csfrm,
      contFlags: e.contFlags,
      value: value,
    );
  }

  /// An IN OUT bind: sends [value] and receives the block's updated value.
  /// [maxSize] is the OUT buffer (default 4000 for strings; the inferred type's
  /// minimum otherwise).
  factory NativeBind.inOut(Object? value, {int? maxSize}) {
    final e = _encodeBind(value);
    return NativeBind._(
      dir: NativeBindDir.inputOutput,
      oraType: e.oraType,
      maxSize: maxSize ?? (e.oraType == _oraTypeVarchar ? 4000 : e.maxSize),
      csfrm: e.csfrm,
      contFlags: e.contFlags,
      value: value,
    );
  }

  /// An OUT NUMBER bind.
  factory NativeBind.outNumber() => const NativeBind._(
      dir: NativeBindDir.output, oraType: _oraTypeNumber, maxSize: 22, csfrm: 0);

  /// An OUT VARCHAR2 bind; [maxSize] is the server-side buffer (bytes).
  factory NativeBind.outVarchar({int maxSize = 4000}) => NativeBind._(
      dir: NativeBindDir.output,
      oraType: _oraTypeVarchar,
      maxSize: maxSize,
      csfrm: _csfrmImplicit);

  /// An OUT DATE bind.
  factory NativeBind.outDate() => const NativeBind._(
      dir: NativeBindDir.output, oraType: _oraTypeDate, maxSize: 7, csfrm: 0);

  /// An OUT TIMESTAMP bind.
  factory NativeBind.outTimestamp() => const NativeBind._(
      dir: NativeBindDir.output,
      oraType: _oraTypeTimestamp,
      maxSize: 11,
      csfrm: 0);

  /// An OUT `SYS_REFCURSOR` bind.
  factory NativeBind.outCursor() => const NativeBind._(
      dir: NativeBindDir.output, oraType: _oraTypeCursor, maxSize: 1, csfrm: 0);

  final NativeBindDir dir;
  final int oraType;
  final int maxSize;
  final int csfrm;
  final int contFlags;
  final Object? value;

  bool get isOut => dir == NativeBindDir.output;
}

/// An Oracle `INTERVAL YEAR TO MONTH` value (Dart has no year-month duration).
class OracleYearMonth {
  const OracleYearMonth(this.years, this.months);
  final int years;
  final int months;
  @override
  bool operator ==(Object other) =>
      other is OracleYearMonth &&
      other.years == years &&
      other.months == months;
  @override
  int get hashCode => Object.hash(years, months);
  @override
  String toString() => 'INTERVAL $years-$months YEAR TO MONTH';
}

/// A CLOB/BLOB locator decoded from a fetched row. The value bytes are NOT
/// inline — the caller materializes them with a LOB READ ([buildLobRead]) and
/// replaces the cell. `isNChar` CLOBs (NCLOB) read back as UTF-16BE.
class NativeLob {
  NativeLob({
    required this.locator,
    required this.oracleType,
    required this.length,
    required this.chunkSize,
    required this.isNChar,
  });

  final Uint8List locator;
  final int oracleType;

  /// LOB length: characters for CLOB, bytes for BLOB.
  final int length;
  final int chunkSize;
  final bool isNChar;

  bool get isClob => oracleType == _oraTypeClob;
}

/// A nested `CURSOR(SELECT …)` column value: its server cursor id + column
/// metadata. `OracleThickClient.queryReal` fetches it and replaces the cell
/// with the cursor's rows (`List<List<Object?>>`).
class NativeNestedCursor {
  NativeNestedCursor(this.cursorId, this.columns);
  final int cursorId;
  final List<NativeColumn> columns;
}

/// Builds an OALL8 EXECUTE for a row-returning [sql] with no binds. [numIters]
/// is the prefetch row window. A fresh parse always uses cursor id 0.
/// Builds an OALL8 EXECUTE for a row-returning [sql], optionally parameterised
/// by positional [binds] (one Dart value per `:1`, `:2` … placeholder in wire
/// order). [numIters] is the prefetch row window. A fresh parse always uses
/// cursor id 0.
Uint8List buildQueryExecute(
  String sql, {
  List<Object?> binds = const [],
  int numIters = 100,
  int ttcFieldVersion = _fieldVersion23_4,
  int sequence = 1,
}) {
  final encodedBinds = [for (final v in binds) _encodeBind(v)];
  final numParams = encodedBinds.length;
  final b = WriteBuffer();
  b.writeUint8(_msgTypeFunction);
  b.writeUint8(_funcExecute);
  b.writeUint8(sequence & 0xFF);
  if (ttcFieldVersion >= _fieldVersion23_1Ext1) {
    b.writeUB8(0); // token number
  }

  final sqlBytes = utf8.encode(sql);
  // Query, fresh parse; add the bind flag when binds are present.
  var options =
      _execOptionParse | _execOptionExecute | _execOptionFetch;
  if (numParams > 0) options |= _execOptionBind;
  final dmlOptions = _execOptionImplicitResultset;

  b.writeUB4(options);
  b.writeUB4(0); // cursor id (0 = fresh parse)

  b.writeUint8(1); // ptr to SQL
  b.writeUB4(sqlBytes.length);

  b.writeUint8(1); // pointer (al8i4 vector)
  b.writeUB4(13); // al8i4 array length

  b.writeUint8(0); // al8o4
  b.writeUint8(0); // al8o4l
  b.writeUint8(0); // prefetch buffer size
  b.writeUB4(numIters); // prefetch num rows
  b.writeUB4(_maxLongLength); // maximum long size

  if (numParams == 0) {
    b.writeUint8(0);
    b.writeUB4(0);
  } else {
    b.writeUint8(1);
    b.writeUB4(numParams);
  }

  b.writeUint8(0); // al8pp
  b.writeUint8(0); // al8txn
  b.writeUint8(0); // al8txl
  b.writeUint8(0); // al8kv
  b.writeUint8(0); // al8kvl

  b.writeUint8(0); // defines absent
  b.writeUB4(0);

  b.writeUB4(0); // registration id

  b.writeUint8(0); // al8objlist
  b.writeUint8(0); // al8objlen
  b.writeUint8(0); // al8blv
  b.writeUB4(0); // al8blv
  b.writeUint8(0); // al8dnam
  b.writeUB4(0); // al8dnaml
  b.writeUB4(0); // al8regid_msb

  b.writeUint8(0); // array dml row counts absent
  b.writeUB4(0);
  b.writeUint8(0);

  if (ttcFieldVersion >= _fieldVersion12_2) {
    b.writeUint8(0); // al8sqlsig
    b.writeUB4(0);
    b.writeUint8(0); // sql id
    b.writeUB4(0);
    b.writeUint8(0); // length of sql id
    if (ttcFieldVersion >= 9 /* ext1 */) {
      b.writeUint8(0); // chunk ids
      b.writeUB4(0);
    }
  }

  // SQL bytes + al8i4[0] parse flag.
  b.writeBytesWithLength(Uint8List.fromList(sqlBytes));
  b.writeUB4(1); // al8i4[0] parse

  b.writeUB4(0); // al8i4[1] execution count (0 for fresh query parse)
  b.writeUB4(0); // al8i4[2]
  b.writeUB4(0); // al8i4[3]
  b.writeUB4(0); // al8i4[4]
  b.writeUB4(0); // al8i4[5] SCN p1
  b.writeUB4(0); // al8i4[6] SCN p2
  b.writeUB4(1); // al8i4[7] (query)
  b.writeUB4(0); // al8i4[8]
  b.writeUB4(dmlOptions); // al8i4[9]
  b.writeUB4(0); // al8i4[10]
  b.writeUB4(0); // al8i4[11]
  b.writeUB4(0); // al8i4[12]

  if (numParams > 0) {
    _writeBindMetadata(b, encodedBinds, ttcFieldVersion);
    b.writeUint8(_msgTypeRowData);
    for (final bind in encodedBinds) {
      _writeBindValue(b, bind);
    }
  }

  return b.toBytes();
}

/// Writes one bind value into a ROW_DATA stream: a NULL indicator, a CLOB/BLOB
/// locator (`UB4(len)+length-prefixed`), or a plain length-prefixed value.
void _writeBindValue(WriteBuffer b, _EncodedBind bind) {
  if (bind.bytes == null) {
    b.writeUint8(0); // NULL indicator
  } else if (bind.isLobLocator) {
    b.writeUB4(bind.bytes!.length);
    b.writeBytesWithLength(bind.bytes!);
  } else {
    b.writeBytesWithLength(bind.bytes!);
  }
}

// --- typed binds -----------------------------------------------------------

const int _execOptionBind = 0x08;
const int _bindUseIndicators = 0x0001;
const int _charsetUtf8 = 873;
const int _csfrmImplicit = 1;

/// An encoded bind: its wire type + metadata, and the encoded value bytes
/// (null ⇒ SQL NULL, written as a zero-length indicator).
class _EncodedBind {
  _EncodedBind({
    required this.oraType,
    required this.maxSize,
    required this.csfrm,
    required this.bytes,
    this.contFlags = 0,
    this.isLobLocator = false,
  });
  final int oraType;
  final int maxSize;
  final int csfrm;
  final Uint8List? bytes;

  /// Bind cont-flags word (LOB-prefetch flag for a CLOB/BLOB locator bind).
  final int contFlags;

  /// Whether [bytes] is a LOB locator — written as `UB4(len) + length-prefixed
  /// bytes` rather than a plain length-prefixed value.
  final bool isLobLocator;
}

/// A pre-created temporary LOB locator used as a bind value — the vehicle for
/// binding a String/`Uint8List` larger than the 32767-byte VARCHAR2/RAW limit.
/// Create one via `OracleThickClient` oversized-bind handling; it binds as a
/// CLOB (112) or BLOB (113) locator.
class NativeClobBindValue {
  NativeClobBindValue(this.locator,
      {this.oraType = _oraTypeClob, this.csfrm = _csfrmImplicit});

  /// A temporary BLOB locator bind (raw bytes, no charset form).
  NativeClobBindValue.blob(this.locator)
      : oraType = _oraTypeBlob,
        csfrm = 0;

  final Uint8List locator;
  final int oraType;
  final int csfrm;
}

/// Maps a Dart value to its Oracle bind wire type + encoded bytes. Supports
/// NUMBER (num), VARCHAR2 (String), RAW (Uint8List), TIMESTAMP (DateTime),
/// CLOB/BLOB locator ([NativeClobBindValue]), and NULL; other types throw
/// [NativeUnsupportedTypeException].
_EncodedBind _encodeBind(Object? value) {
  if (value == null) {
    // Untyped NULL binds as a 1-byte VARCHAR slot.
    return _EncodedBind(
        oraType: _oraTypeVarchar, maxSize: 1, csfrm: _csfrmImplicit, bytes: null);
  }
  if (value is NativeClobBindValue) {
    return _EncodedBind(
        oraType: value.oraType,
        maxSize: _lobLocatorBindBufferSize,
        csfrm: value.csfrm,
        contFlags: _lobPrefetchFlag,
        bytes: value.locator,
        isLobLocator: true);
  }
  if (value is num) {
    return _EncodedBind(
        oraType: _oraTypeNumber,
        maxSize: 22,
        csfrm: 0,
        bytes: encodeOracleNumber(value));
  }
  if (value is String) {
    final bytes = Uint8List.fromList(utf8.encode(value));
    return _EncodedBind(
        oraType: _oraTypeVarchar,
        maxSize: bytes.isEmpty ? 1 : bytes.length,
        csfrm: _csfrmImplicit,
        bytes: bytes);
  }
  if (value is Uint8List) {
    return _EncodedBind(
        oraType: _oraTypeRaw,
        maxSize: value.isEmpty ? 1 : value.length,
        csfrm: 0,
        bytes: value);
  }
  if (value is DateTime) {
    return _EncodedBind(
        oraType: _oraTypeTimestamp,
        maxSize: 11,
        csfrm: 0,
        bytes: _encodeTimestamp(value));
  }
  throw NativeUnsupportedTypeException(-1);
}

/// Writes one bind-metadata block per bind (node-oracledb writeColumnMetadata).
void _writeBindMetadata(
    WriteBuffer b, List<_EncodedBind> binds, int ttcFieldVersion) {
  for (final bind in binds) {
    b.writeUint8(bind.oraType);
    b.writeUint8(_bindUseIndicators);
    b.writeUint8(0); // precision
    b.writeUint8(0); // scale
    b.writeUB4(bind.maxSize);
    b.writeUB4(0); // max num elements
    b.writeUB4(bind.contFlags); // cont flags (LOB prefetch for locator binds)
    b.writeUB4(0); // OID
    b.writeUB2(0); // version
    b.writeUB2(bind.csfrm != 0 ? _charsetUtf8 : 0); // charset field
    b.writeUint8(bind.csfrm);
    b.writeUB4(0); // LOB prefetch length
    if (ttcFieldVersion >= _fieldVersion12_2) {
      b.writeUB4(0); // oaccolid
    }
  }
}

/// Oracle 11-byte TIMESTAMP wire (no time zone): the 7 DATE bytes then a
/// big-endian UInt32 nanoseconds field.
Uint8List _encodeTimestamp(DateTime v) {
  final out = Uint8List(11);
  out[0] = (v.year ~/ 100) + 100;
  out[1] = (v.year % 100) + 100;
  out[2] = v.month;
  out[3] = v.day;
  out[4] = v.hour + 1;
  out[5] = v.minute + 1;
  out[6] = v.second + 1;
  final nanos = (v.millisecond * 1000 + v.microsecond) * 1000;
  out[7] = (nanos >> 24) & 0xFF;
  out[8] = (nanos >> 16) & 0xFF;
  out[9] = (nanos >> 8) & 0xFF;
  out[10] = nanos & 0xFF;
  return out;
}

/// Builds a FETCH for [numRows] more rows from an open server [cursorId].
Uint8List buildFetch(
  int cursorId,
  int numRows, {
  int ttcFieldVersion = _fieldVersion23_4,
  int sequence = 2,
}) {
  final b = WriteBuffer();
  b.writeUint8(_msgTypeFunction);
  b.writeUint8(_funcFetch);
  b.writeUint8(sequence & 0xFF);
  if (ttcFieldVersion >= _fieldVersion23_1Ext1) {
    b.writeUB8(0); // token number
  }
  b.writeUB4(cursorId);
  b.writeUB4(numRows);
  return b.toBytes();
}

const int _execOptionPlSqlBind = 0x400;
const int _execOptionNotPlSql = 0x8000;
const int _execOptionBatchErrors = 0x80000;
const int _oraTypeCursor = 102;

/// Builds a DML OALL8 EXECUTE (INSERT/UPDATE/DELETE), optionally with
/// `RETURNING … INTO` OUT binds and/or array (executeMany) iterations.
///
/// [binds] are the single-iteration bind templates (IN values + OUT returning
/// targets). For array DML, [bulkRows] holds one inner list of IN values per
/// iteration (OUT binds keep their template); otherwise a single iteration uses
/// the [binds] values. [returning] enables the RETURNING decode (OUT binds are
/// omitted from ROW_DATA and their values stream back count-prefixed).
Uint8List buildDmlExecute(
  String sql,
  List<NativeBind> binds, {
  bool returning = false,
  bool batchErrors = false,
  List<List<Object?>>? bulkRows,
  int ttcFieldVersion = _fieldVersion23_4,
  int sequence = 1,
}) {
  final b = WriteBuffer();
  b.writeUint8(_msgTypeFunction);
  b.writeUint8(_funcExecute);
  b.writeUint8(sequence & 0xFF);
  if (ttcFieldVersion >= _fieldVersion23_1Ext1) {
    b.writeUB8(0); // token number
  }

  final sqlBytes = utf8.encode(sql);
  final numParams = binds.length;
  final numExecs = bulkRows?.length ?? 1;
  var options = _execOptionParse | _execOptionExecute | _execOptionNotPlSql;
  if (numParams > 0) options |= _execOptionBind;
  if (batchErrors) options |= _execOptionBatchErrors;
  final dmlOptions = _execOptionImplicitResultset;

  b.writeUB4(options);
  b.writeUB4(0); // cursor id

  b.writeUint8(1); // ptr to SQL
  b.writeUB4(sqlBytes.length);

  b.writeUint8(1); // al8i4 vector pointer
  b.writeUB4(13);

  b.writeUint8(0); // al8o4
  b.writeUint8(0); // al8o4l
  b.writeUint8(0); // prefetch buffer size
  b.writeUB4(1); // prefetch num rows
  b.writeUB4(_maxLongLength);

  if (numParams == 0) {
    b.writeUint8(0);
    b.writeUB4(0);
  } else {
    b.writeUint8(1);
    b.writeUB4(numParams);
  }

  b.writeUint8(0); // al8pp
  b.writeUint8(0); // al8txn
  b.writeUint8(0); // al8txl
  b.writeUint8(0); // al8kv
  b.writeUint8(0); // al8kvl

  b.writeUint8(0); // defines absent
  b.writeUB4(0);

  b.writeUB4(0); // registration id

  b.writeUint8(0); // al8objlist
  b.writeUint8(0); // al8objlen
  b.writeUint8(0); // al8blv
  b.writeUB4(0); // al8blv
  b.writeUint8(0); // al8dnam
  b.writeUB4(0); // al8dnaml
  b.writeUB4(0); // al8regid_msb

  b.writeUint8(0); // array dml row counts absent
  b.writeUB4(0);
  b.writeUint8(0);

  if (ttcFieldVersion >= _fieldVersion12_2) {
    b.writeUint8(0); // al8sqlsig
    b.writeUB4(0);
    b.writeUint8(0); // sql id
    b.writeUB4(0);
    b.writeUint8(0); // length of sql id
    b.writeUint8(0); // chunk ids
    b.writeUB4(0);
  }

  b.writeBytesWithLength(Uint8List.fromList(sqlBytes));
  b.writeUB4(1); // al8i4[0] parse

  b.writeUB4(numExecs); // al8i4[1] execution count
  b.writeUB4(0); // al8i4[2]
  b.writeUB4(0); // al8i4[3]
  b.writeUB4(0); // al8i4[4]
  b.writeUB4(0); // al8i4[5] SCN p1
  b.writeUB4(0); // al8i4[6] SCN p2
  b.writeUB4(0); // al8i4[7] (not a query)
  b.writeUB4(0); // al8i4[8]
  b.writeUB4(dmlOptions); // al8i4[9]
  b.writeUB4(0); // al8i4[10]
  b.writeUB4(0); // al8i4[11]
  b.writeUB4(0); // al8i4[12]

  if (numParams > 0) {
    // For array DML the per-bind buffer must fit the largest value across all
    // iterations, so widen each bind's declared maxSize to the column max.
    final maxSizes = [for (final bind in binds) bind.maxSize];
    if (bulkRows != null) {
      for (final row in bulkRows) {
        for (var i = 0; i < binds.length && i < row.length; i++) {
          final e = _encodeBind(row[i]);
          final n = e.bytes?.length ?? 0;
          if (n > maxSizes[i]) maxSizes[i] = n;
        }
      }
    }
    for (var bi = 0; bi < binds.length; bi++) {
      final bind = binds[bi];
      b.writeUint8(bind.oraType);
      b.writeUint8(_bindUseIndicators);
      b.writeUint8(0); // precision
      b.writeUint8(0); // scale
      b.writeUB4(maxSizes[bi] == 0 ? 1 : maxSizes[bi]);
      b.writeUB4(0); // max num elements
      b.writeUB4(bind.contFlags); // cont flags (LOB prefetch for locator binds)
      b.writeUB4(0); // OID
      b.writeUB2(0); // version
      b.writeUB2(bind.csfrm != 0 ? _charsetUtf8 : 0); // charset field
      b.writeUint8(bind.csfrm);
      b.writeUB4(0); // LOB prefetch length
      if (ttcFieldVersion >= _fieldVersion12_2) {
        b.writeUB4(0); // oaccolid
      }
    }
    // One ROW_DATA message per iteration. A RETURNING target (OUT bind) is
    // omitted from the row data — the server fills and streams it back.
    final rows = bulkRows ?? [[for (final bind in binds) bind.value]];
    for (final rowValues in rows) {
      b.writeUint8(_msgTypeRowData);
      for (var i = 0; i < binds.length; i++) {
        final bind = binds[i];
        if (returning && bind.isOut) continue; // omit RETURNING targets
        if (bind.isOut) {
          b.writeUint8(0); // OUT slot null indicator (non-returning)
          continue;
        }
        _writeBindValue(
            b, _encodeBind(i < rowValues.length ? rowValues[i] : bind.value));
      }
    }
  }

  return b.toBytes();
}

/// Builds a PL/SQL OALL8 EXECUTE for a block with [binds] (IN and/or OUT). The
/// server runs the block and returns OUT bind values (and any opened REF
/// CURSOR id + describe) in the response. A single OUT `SYS_REFCURSOR` bind is
/// the `BEGIN OPEN :1 FOR <query>; END;` shape.
Uint8List buildPlsqlExecute(
  String plsql,
  List<NativeBind> binds, {
  int ttcFieldVersion = _fieldVersion23_4,
  int sequence = 1,
}) {
  final b = WriteBuffer();
  b.writeUint8(_msgTypeFunction);
  b.writeUint8(_funcExecute);
  b.writeUint8(sequence & 0xFF);
  if (ttcFieldVersion >= _fieldVersion23_1Ext1) {
    b.writeUB8(0); // token number
  }

  final sqlBytes = utf8.encode(plsql);
  final numParams = binds.length;
  var options = _execOptionParse | _execOptionExecute;
  if (numParams > 0) options |= _execOptionBind | _execOptionPlSqlBind;
  final dmlOptions = _execOptionImplicitResultset;

  b.writeUB4(options);
  b.writeUB4(0); // cursor id (0 = fresh parse)

  b.writeUint8(1); // ptr to SQL
  b.writeUB4(sqlBytes.length);

  b.writeUint8(1); // al8i4 vector pointer
  b.writeUB4(13); // al8i4 array length

  b.writeUint8(0); // al8o4
  b.writeUint8(0); // al8o4l
  b.writeUint8(0); // prefetch buffer size
  b.writeUB4(1); // prefetch num rows (1 for PL/SQL)
  b.writeUB4(_maxLongLength); // maximum long size

  if (numParams == 0) {
    b.writeUint8(0);
    b.writeUB4(0);
  } else {
    b.writeUint8(1);
    b.writeUB4(numParams);
  }

  b.writeUint8(0); // al8pp
  b.writeUint8(0); // al8txn
  b.writeUint8(0); // al8txl
  b.writeUint8(0); // al8kv
  b.writeUint8(0); // al8kvl

  b.writeUint8(0); // defines absent
  b.writeUB4(0);

  b.writeUB4(0); // registration id

  b.writeUint8(0); // al8objlist
  b.writeUint8(0); // al8objlen
  b.writeUint8(0); // al8blv
  b.writeUB4(0); // al8blv
  b.writeUint8(0); // al8dnam
  b.writeUB4(0); // al8dnaml
  b.writeUB4(0); // al8regid_msb

  b.writeUint8(0); // array dml row counts absent
  b.writeUB4(0);
  b.writeUint8(0);

  if (ttcFieldVersion >= _fieldVersion12_2) {
    b.writeUint8(0); // al8sqlsig
    b.writeUB4(0);
    b.writeUint8(0); // sql id
    b.writeUB4(0);
    b.writeUint8(0); // length of sql id
    b.writeUint8(0); // chunk ids
    b.writeUB4(0);
  }

  b.writeBytesWithLength(Uint8List.fromList(sqlBytes));
  b.writeUB4(1); // al8i4[0] parse

  b.writeUB4(1); // al8i4[1] execution count (1 for PL/SQL)
  b.writeUB4(0); // al8i4[2]
  b.writeUB4(0); // al8i4[3]
  b.writeUB4(0); // al8i4[4]
  b.writeUB4(0); // al8i4[5] SCN p1
  b.writeUB4(0); // al8i4[6] SCN p2
  b.writeUB4(0); // al8i4[7] (not a query)
  b.writeUB4(0); // al8i4[8]
  b.writeUB4(dmlOptions); // al8i4[9]
  b.writeUB4(0); // al8i4[10]
  b.writeUB4(0); // al8i4[11]
  b.writeUB4(0); // al8i4[12]

  if (numParams > 0) {
    for (final bind in binds) {
      b.writeUint8(bind.oraType);
      b.writeUint8(_bindUseIndicators);
      b.writeUint8(0); // precision
      b.writeUint8(0); // scale
      b.writeUB4(bind.maxSize);
      b.writeUB4(0); // max num elements
      b.writeUB4(bind.contFlags); // cont flags (LOB prefetch for locator binds)
      b.writeUB4(0); // OID
      b.writeUB2(0); // version
      b.writeUB2(bind.csfrm != 0 ? _charsetUtf8 : 0); // charset field
      b.writeUint8(bind.csfrm);
      b.writeUB4(0); // LOB prefetch length
      if (ttcFieldVersion >= _fieldVersion12_2) {
        b.writeUB4(0); // oaccolid
      }
    }
    // ROW_DATA with each bind's value (cursor OUT → [1][0]; other OUT → NULL
    // indicator; IN → encoded value).
    b.writeUint8(_msgTypeRowData);
    for (final bind in binds) {
      if (bind.oraType == _oraTypeCursor) {
        b.writeUint8(1);
        b.writeUint8(0);
      } else if (bind.isOut) {
        b.writeUint8(0); // NULL indicator for an OUT slot
      } else {
        _writeBindValue(b, _encodeBind(bind.value));
      }
    }
  }

  return b.toBytes();
}

// --- response decode -------------------------------------------------------

class _DecodeState {
  _DecodeState({
    required this.isQuery,
    required this.ttcFieldVersion,
    this.binds = const [],
    this.dmlReturning = false,
  });
  final bool isQuery;
  final int ttcFieldVersion;

  /// Bind metadata (PL/SQL), used to decode OUT bind values by type.
  final List<NativeBind> binds;

  /// Whether this is a DML `RETURNING … INTO` response (OUT values stream back
  /// count-prefixed with no IO_VECTOR).
  final bool dmlReturning;
  List<NativeColumn> columns = [];
  final List<List<Object?>> rows = [];
  int cursorId = 0;
  int? rowsAffected;
  bool moreRowsToFetch = false;
  bool endOfResponse = false;
  int? errorNum;
  String? errorMessage;
  Uint8List? bitVector;

  /// OUT bind positions reported by the IO_VECTOR (PL/SQL OUT binds).
  final List<int> outBindIndices = [];

  /// Decoded OUT bind values, one per entry of [outBindIndices], in order.
  final List<Object?> outBindValues = [];

  /// A REF CURSOR OUT bind's server cursor id + its column metadata, decoded
  /// from the OUT-bind ROW_DATA. Null until seen.
  int? refCursorId;
  List<NativeColumn>? refCursorColumns;
  bool outBindsDecoded = false;

  /// Implicit result-set cursors (`DBMS_SQL.RETURN_RESULT`, TTC msg 27): each
  /// is a (cursorId, columns) pair the caller FETCH-drains.
  final List<NativeImplicitResult> implicitResults = [];

  /// Per-row errors from an array-DML `executeMany(batchErrors: true)` call.
  List<NativeBatchError> batchErrors = const [];
}

/// Decodes a concatenated OALL8 response body ([body] = all DATA-packet TTC
/// bodies joined, header + data flags already stripped). When the stream is
/// truncated mid-message the returned [NativeExecuteResponse.complete] is
/// false — read another frame, re-concatenate, and call again.
///
/// [expectedColumns] carries the describe metadata forward across FETCH rounds
/// (a FETCH response ships rows with no DESCRIBE_INFO).
NativeExecuteResponse decodeExecuteResponse(
  Uint8List body, {
  required bool isQuery,
  List<NativeColumn>? expectedColumns,
  List<NativeBind> binds = const [],
  bool dmlReturning = false,
  int ttcFieldVersion = _fieldVersion23_4,
}) {
  final s = _DecodeState(
      isQuery: isQuery,
      ttcFieldVersion: ttcFieldVersion,
      binds: binds,
      dmlReturning: dmlReturning);
  // DML RETURNING has no IO_VECTOR: seed the OUT indices from the bind list.
  if (dmlReturning) {
    for (var i = 0; i < binds.length; i++) {
      if (binds[i].isOut) s.outBindIndices.add(i);
    }
  }
  if (expectedColumns != null) s.columns = List.of(expectedColumns);
  final buf = ReadBuffer(body);
  try {
    while (buf.hasRemaining && !s.endOfResponse) {
      _dispatch(buf.readUint8(), buf, s);
    }
  } on OracleBufferUnderflow {
    // Response is split across more packets — caller reads another frame.
    return NativeExecuteResponse(
      columns: s.columns,
      rows: s.rows,
      cursorId: s.cursorId,
      moreRows: s.moreRowsToFetch,
      complete: false,
      rowsAffected: s.rowsAffected,
    );
  }

  final complete = s.endOfResponse;
  // A query with no ERROR/ORA-01403 marker means more rows are pending.
  if (isQuery && s.errorNum == null && complete) {
    s.moreRowsToFetch = true;
  }
  return NativeExecuteResponse(
    columns: s.columns,
    rows: s.rows,
    cursorId: s.cursorId,
    moreRows: s.moreRowsToFetch,
    complete: complete,
    rowsAffected: s.rowsAffected,
    errorNum: s.errorNum,
    errorMessage: s.errorMessage,
    refCursorId: s.refCursorId,
    refCursorColumns: s.refCursorColumns,
    outBindValues: s.outBindValues,
    implicitResults: s.implicitResults,
    batchErrors: s.batchErrors,
  );
}

void _dispatch(int msgType, ReadBuffer buf, _DecodeState s) {
  switch (msgType) {
    case _msgTypeDescribeInfo:
      _processDescribeInfo(buf, s);
      return;
    case _msgTypeRowHeader:
      _processRowHeader(buf, s);
      return;
    case _msgTypeRowData:
      _processRowData(buf, s);
      return;
    case _msgTypeBitVector:
      _processBitVector(buf, s);
      return;
    case _msgTypeIoVector:
      _processIoVector(buf, s);
      return;
    case _msgTypeError:
      _processError(buf, s);
      return;
    case _msgTypeWarning:
      _skipWarning(buf);
      return;
    case _msgTypeStatus:
      buf.skipUB4(); // call status
      buf.skipUB2(); // end-to-end seq num
      s.endOfResponse = true;
      return;
    case _msgTypeParameter:
      _processReturnParameter(buf, s);
      return;
    case _msgTypeServerSidePiggyback:
      _processServerSidePiggyback(buf);
      return;
    case _msgTypeImplicitResultSet:
      _processImplicitResultSet(buf, s);
      return;
    case _msgTypeEndOfRequest:
      s.endOfResponse = true;
      return;
    case _msgTypeFlushOutBinds:
      s.endOfResponse = true;
      return;
    default:
      throw StateError('Unknown TTC message type: $msgType');
  }
}

void _processDescribeInfo(ReadBuffer buf, _DecodeState s) {
  buf.readBytesWithLength(); // version bytes
  buf.skipUB4(); // max row size
  final numCols = buf.readUB4();
  if (numCols > 0) buf.skipUB1();
  final columns = <NativeColumn>[];
  for (var i = 0; i < numCols; i++) {
    columns.add(_processColumnInfo(buf, s.ttcFieldVersion));
  }
  final dateBytes = buf.readUB4();
  if (dateBytes > 0) buf.readBytesWithLength();
  buf.skipUB4(); // dcbflag
  buf.skipUB4(); // dcbmdbz
  buf.skipUB4(); // dcbmnpr
  buf.skipUB4(); // dcbmxpr
  final tailBytes = buf.readUB4();
  if (tailBytes > 0) buf.readBytesWithLength();
  s.columns = columns;
}

NativeColumn _processColumnInfo(ReadBuffer buf, int ttcFieldVersion) {
  final dataType = buf.readUint8();
  buf.skipUB1(); // flags
  final precisionRaw = buf.readUint8();
  final scaleRaw = buf.readUint8();
  final precision = precisionRaw > 127 ? precisionRaw - 256 : precisionRaw;
  final scale = scaleRaw > 127 ? scaleRaw - 256 : scaleRaw;
  final maxSize = buf.readUB4();
  buf.skipUB4(); // max num array elements
  buf.readUB8(); // cont flags
  final oidLen = buf.readUB4();
  if (oidLen > 0) buf.readBytesWithLength();
  buf.skipUB2(); // version
  buf.skipUB2(); // charset id
  final csfrm = buf.readUint8();
  final size = buf.readUB4();
  if (ttcFieldVersion >= _fieldVersion12_2) {
    buf.skipUB4(); // oaccolid
  }
  buf.skipUB1(); // nullable
  buf.skipUB1(); // v7 name length
  String name = '';
  final nameLen = buf.readUB4();
  if (nameLen > 0) {
    name = utf8.decode(buf.readBytesWithLength(), allowMalformed: true);
  }
  final schemaLen = buf.readUB4();
  if (schemaLen > 0) buf.readBytesWithLength();
  final typeNameLen = buf.readUB4();
  if (typeNameLen > 0) buf.readBytesWithLength();
  buf.skipUB2(); // column position
  buf.readUB4(); // uds flags
  if (ttcFieldVersion >= _fieldVersion23_1) {
    final domainSchemaLen = buf.readUB4();
    if (domainSchemaLen > 0) buf.readBytesWithLength();
    final domainNameLen = buf.readUB4();
    if (domainNameLen > 0) buf.readBytesWithLength();
  }
  if (ttcFieldVersion >= _fieldVersion23_1Ext3) {
    final annoLen = buf.readUB4();
    if (annoLen > 0) {
      buf.skipUB1();
      final numAnno = buf.readUB4();
      buf.skipUB1();
      for (var i = 0; i < numAnno; i++) {
        buf.skipUB4();
        buf.readBytesWithLength(); // key
        final valBytes = buf.readUB4();
        if (valBytes > 0) buf.readBytesWithLength();
        buf.skipUB4(); // flags
      }
      buf.skipUB4(); // flags
    }
  }
  if (ttcFieldVersion >= _fieldVersion23_4) {
    buf.skipUB4(); // dimensions
    buf.skipUB1(); // format
    buf.skipUB1(); // flags
  }

  return NativeColumn(
    name: name,
    oracleType: dataType,
    maxLength: dataType == _oraTypeRaw ? maxSize : size,
    precision: precision > 0 ? precision : null,
    scale: scale > 0 ? scale : null,
    csfrm: csfrm,
  );
}

void _processRowHeader(ReadBuffer buf, _DecodeState s) {
  buf.skipUB1(); // flags
  buf.skipUB2(); // num requests
  buf.skipUB4(); // iteration number
  buf.skipUB4(); // num iters
  buf.skipUB2(); // buffer length
  final bitVecLen = buf.readUB4();
  if (bitVecLen > 0) s.bitVector = buf.readBytesWithLength();
  final rxhridLen = buf.readUB4();
  if (rxhridLen > 0) buf.readBytesWithLength();
}

void _processRowData(ReadBuffer buf, _DecodeState s) {
  // A PL/SQL response ships OUT bind values in ROW_DATA after the IO_VECTOR.
  if (!s.isQuery && s.outBindIndices.isNotEmpty) {
    if (s.dmlReturning) {
      _decodeReturningBinds(buf, s);
      return;
    }
    if (!s.outBindsDecoded) {
      _decodeOutBinds(buf, s);
      s.outBindsDecoded = true;
    }
    return;
  }
  final row = <Object?>[];
  for (var i = 0; i < s.columns.length; i++) {
    if (_isDuplicate(s.bitVector, i)) {
      final prior = s.rows.isNotEmpty ? s.rows.last : null;
      row.add(prior != null && i < prior.length ? prior[i] : null);
      continue;
    }
    row.add(_decodeColumnValue(buf, s.columns[i]));
  }
  s.rows.add(row);
  s.bitVector = null;
}

/// Decodes one OUT-bind ROW_DATA: one value per OUT bind (by its declared
/// type). A cursor OUT bind yields an embedded describe + server cursor id; a
/// scalar OUT bind yields its decoded value. Each value carries an SB4 "actual
/// num bytes" trailer.
void _decodeOutBinds(ReadBuffer buf, _DecodeState s) {
  for (final idx in s.outBindIndices) {
    final bind = idx < s.binds.length ? s.binds[idx] : null;
    if (bind != null && bind.oraType == _oraTypeCursor) {
      final numBytes = buf.readUint8();
      if (numBytes == 0 || numBytes == 0xFF) {
        s.outBindValues.add(null);
        continue;
      }
      final columns = _readEmbeddedCursorDescribe(buf, s.ttcFieldVersion);
      final cursorId = buf.readUB2();
      // First cursor seeds the legacy single-cursor fields (openRefCursor);
      // every cursor OUT bind is also a drainable value.
      s.refCursorId ??= cursorId;
      s.refCursorColumns ??= columns;
      buf.readSB4();
      s.outBindValues.add(NativeNestedCursor(cursorId, columns));
      continue;
    }
    // Scalar OUT: decode by the declared bind type, then the SB4 trailer.
    final oraType = bind?.oraType ?? _oraTypeVarchar;
    final col = NativeColumn(
        name: '', oracleType: oraType, maxLength: 0, csfrm: bind?.csfrm ?? 0);
    final value = _decodeColumnValue(buf, col);
    buf.readSB4();
    s.outBindValues.add(value);
  }
}

/// Reads an embedded cursor describe block (a DESCRIBE_INFO without the leading
/// version-bytes preamble).
List<NativeColumn> _readEmbeddedCursorDescribe(
    ReadBuffer buf, int ttcFieldVersion) {
  buf.skipUB4(); // max row size
  final numCols = buf.readUB4();
  if (numCols > 0) buf.skipUB1();
  final columns = <NativeColumn>[];
  for (var i = 0; i < numCols; i++) {
    columns.add(_processColumnInfo(buf, ttcFieldVersion));
  }
  final dateBytes = buf.readUB4();
  if (dateBytes > 0) buf.readBytesWithLength();
  buf.skipUB4(); // dcbflag
  buf.skipUB4(); // dcbmdbz
  buf.skipUB4(); // dcbmnpr
  buf.skipUB4(); // dcbmxpr
  final tailBytes = buf.readUB4();
  if (tailBytes > 0) buf.readBytesWithLength();
  return columns;
}

/// Decodes a DML `RETURNING … INTO` ROW_DATA: each OUT bind is a `UB4 numRows`
/// count followed by that many (value + SB4 trailer). Collects each bind's
/// returned values as a `List` into [_DecodeState.outBindValues].
void _decodeReturningBinds(ReadBuffer buf, _DecodeState s) {
  final result = <Object?>[];
  for (final idx in s.outBindIndices) {
    final bind = idx < s.binds.length ? s.binds[idx] : null;
    final oraType = bind?.oraType ?? _oraTypeVarchar;
    final numRows = buf.readUB4();
    final values = <Object?>[];
    final col = NativeColumn(
        name: '', oracleType: oraType, maxLength: 0, csfrm: bind?.csfrm ?? 0);
    for (var j = 0; j < numRows; j++) {
      values.add(_decodeColumnValue(buf, col));
      buf.readSB4();
    }
    result.add(values);
  }
  s.outBindValues
    ..clear()
    ..addAll(result);
}

void _processBitVector(ReadBuffer buf, _DecodeState s) {
  final numColsSent = buf.readUB2();
  var numBytes = (s.columns.length / 8).floor();
  if (s.columns.length % 8 > 0) numBytes++;
  if (numBytes <= 0) numBytes = (numColsSent + 7) ~/ 8;
  s.bitVector = buf.readBytes(numBytes);
}

void _processIoVector(ReadBuffer buf, _DecodeState s) {
  buf.skipUB1(); // flag
  final temp16 = buf.readUB2();
  final temp32 = buf.readUB4();
  final numBinds = temp32 * 256 + temp16;
  buf.skipUB4(); // num iters this time
  buf.skipUB2(); // uac buffer length
  final fastFetchLen = buf.readUB2();
  if (fastFetchLen > 0) buf.skip(fastFetchLen);
  final rowidLen = buf.readUB2();
  if (rowidLen > 0) buf.skip(rowidLen);
  s.outBindIndices.clear();
  for (var i = 0; i < numBinds; i++) {
    final dir = buf.readUint8();
    // 32 = IN, 16 = OUT, 48 = IN OUT. OUT/IN OUT binds carry return values.
    if (dir != 32) s.outBindIndices.add(i);
  }
}

/// Decodes a TTC implicit result-set message (type 27,
/// `DBMS_SQL.RETURN_RESULT`): UB4 count, then per result a UInt8 skip-length +
/// opaque bytes, an embedded cursor describe, and a UB2 server cursor id.
void _processImplicitResultSet(ReadBuffer buf, _DecodeState s) {
  final numResults = buf.readUB4();
  for (var i = 0; i < numResults; i++) {
    final numBytes = buf.readUint8();
    if (numBytes > 0) buf.skip(numBytes);
    final columns = _readEmbeddedCursorDescribe(buf, s.ttcFieldVersion);
    final cursorId = buf.readUB2();
    s.implicitResults.add(NativeImplicitResult(cursorId, columns));
  }
}

bool _isDuplicate(Uint8List? bitVector, int colIndex) {
  if (bitVector == null) return false;
  final byteNum = colIndex ~/ 8;
  final bitNum = colIndex % 8;
  if (byteNum >= bitVector.length) return false;
  return (bitVector[byteNum] & (1 << bitNum)) == 0;
}

Object? _decodeColumnValue(ReadBuffer buf, NativeColumn col) {
  switch (col.oracleType) {
    case _oraTypeVarchar:
    case _oraTypeVarchar2:
    case _oraTypeString:
    case _oraTypeChar:
      final bytes = buf.readBytesWithLength();
      if (bytes.isEmpty) return null;
      if (col.csfrm == _csfrmNChar) {
        return _decodeUtf16Be(bytes);
      }
      return utf8.decode(bytes, allowMalformed: true);
    case _oraTypeRaw:
      final bytes = buf.readBytesWithLength();
      return bytes.isEmpty ? null : Uint8List.fromList(bytes);
    case _oraTypeNumber:
    case _oraTypeInteger:
    case _oraTypeFloat:
    case _oraTypeVarnum:
      final bytes = buf.readBytesWithLength();
      if (bytes.isEmpty) return null;
      return decodeOracleNumber(ReadBuffer(bytes),
          forceDouble: (col.scale ?? 0) > 0);
    case _oraTypeBinaryFloat:
    case _oraTypeBinaryDouble:
      final bytes = buf.readBytesWithLength();
      if (bytes.isEmpty) return null;
      return _decodeBinaryFloat(bytes);
    case _oraTypeDate:
      final bytes = buf.readBytesWithLength();
      if (bytes.isEmpty) return null;
      return _decodeDate(bytes);
    case _oraTypeTimestamp:
    case _oraTypeTimestampLtz:
      final bytes = buf.readBytesWithLength();
      if (bytes.isEmpty) return null;
      return _decodeTimestamp(bytes, asUtc: false);
    case _oraTypeTimestampTz:
      final bytes = buf.readBytesWithLength();
      if (bytes.isEmpty) return null;
      // Default UTC-instant contract (numeric-offset preservation is a later
      // refinement): a 13-byte TSTZ payload's fields are already UTC.
      return _decodeTimestamp(bytes, asUtc: true);
    case _oraTypeIntervalDS:
      final bytes = buf.readBytesWithLength();
      if (bytes.isEmpty) return null;
      return _decodeIntervalDS(bytes);
    case _oraTypeIntervalYM:
      final bytes = buf.readBytesWithLength();
      if (bytes.isEmpty) return null;
      return _decodeIntervalYM(bytes);
    case _oraTypeRowid:
      // Fetch shape: one-byte length (0 / 0xFF = NULL), then the physical
      // rowid fields, rendered as Oracle's 18-char base64 text.
      final numBytes = buf.readUint8();
      if (numBytes == 0 || numBytes == 0xFF) return null;
      return _decodeRowid(buf);
    case _oraTypeClob:
    case _oraTypeBlob:
      // Non-prefetch LOB wire shape (this connection does not negotiate LOB
      // prefetch): UB4 locator length (0 = NULL), then the length-prefixed
      // locator. The length is unknown here — materialized via GET_LENGTH +
      // READ. The redundant locatorLen matches the length prefix.
      final locatorLen = buf.readUB4();
      if (locatorLen == 0) return null;
      final locator = buf.readBytesWithLength();
      return NativeLob(
        locator: Uint8List.fromList(locator),
        oracleType: col.oracleType,
        length: -1, // unknown until GET_LENGTH
        chunkSize: 0,
        isNChar: col.csfrm == _csfrmNChar,
      );
    case _oraTypeCursor:
      // Nested CURSOR(SELECT …) column: UInt8 length (0 / 0xFF = NULL), an
      // embedded describe, then the UB2 server cursor id. id 0 = NULL cursor.
      final numBytes = buf.readUint8();
      if (numBytes == 0 || numBytes == 0xFF) return null;
      final columns = _readEmbeddedCursorDescribe(buf, _fieldVersion23_4);
      final cursorId = buf.readUB2();
      if (cursorId == 0) return null;
      return NativeNestedCursor(cursorId, columns);
    case _oraTypeLong:
    case _oraTypeLongRaw:
    case _oraTypeURowid:
      throw NativeUnsupportedTypeException(col.oracleType);
    default:
      throw NativeUnsupportedTypeException(col.oracleType);
  }
}

String _decodeUtf16Be(List<int> bytes) {
  final units = <int>[];
  for (var i = 0; i + 1 < bytes.length; i += 2) {
    units.add((bytes[i] << 8) | bytes[i + 1]);
  }
  return String.fromCharCodes(units);
}

/// Oracle 7-byte DATE: [century+100, year+100, month, day, hour+1, min+1,
/// sec+1]. Decoded as a local-wall-clock [DateTime].
DateTime _decodeDate(List<int> b) {
  final year = (b[0] - 100) * 100 + (b[1] - 100);
  final month = b[2];
  final day = b[3];
  final hour = b.length > 4 ? b[4] - 1 : 0;
  final minute = b.length > 5 ? b[5] - 1 : 0;
  final second = b.length > 6 ? b[6] - 1 : 0;
  return DateTime(year, month, day, hour, minute, second);
}

/// Oracle TIMESTAMP wire: the 7 DATE bytes, then (>=11 bytes) a big-endian
/// UInt32 nanoseconds field, then (>=13 bytes) 2 time-zone bytes. [asUtc]
/// builds the instant in UTC (TIMESTAMP WITH TIME ZONE ships UTC fields);
/// otherwise a local wall-clock DateTime (plain / LTZ TIMESTAMP).
DateTime _decodeTimestamp(List<int> b, {required bool asUtc}) {
  final year = (b[0] - 100) * 100 + (b[1] - 100);
  final month = b[2];
  final day = b[3];
  final hour = b[4] - 1;
  final minute = b[5] - 1;
  final second = b[6] - 1;
  var micros = 0;
  if (b.length >= 11) {
    final nanos =
        (b[7] << 24) | (b[8] << 16) | (b[9] << 8) | b[10];
    micros = nanos ~/ 1000;
  }
  final ms = micros ~/ 1000;
  final us = micros % 1000;
  return asUtc
      ? DateTime.utc(year, month, day, hour, minute, second, ms, us)
      : DateTime(year, month, day, hour, minute, second, ms, us);
}

const int _durationMid = 0x80000000;
const int _durationOffset = 60;

/// Oracle 11-byte INTERVAL DAY TO SECOND → [Duration]. Bytes: UInt32 days+mid,
/// hours+60, minutes+60, seconds+60, UInt32 nanoseconds+mid.
Duration _decodeIntervalDS(List<int> raw) {
  final data = ByteData.sublistView(Uint8List.fromList(raw));
  final days = data.getUint32(0) - _durationMid;
  final hours = data.getUint8(4) - _durationOffset;
  final minutes = data.getUint8(5) - _durationOffset;
  final seconds = data.getUint8(6) - _durationOffset;
  final fseconds = data.getUint32(7) - _durationMid; // nanoseconds
  return Duration(
    days: days,
    hours: hours,
    minutes: minutes,
    seconds: seconds,
    microseconds: fseconds ~/ 1000,
  );
}

/// Oracle 5-byte INTERVAL YEAR TO MONTH → [OracleYearMonth]. Bytes: UInt32
/// years+mid, months+60.
OracleYearMonth _decodeIntervalYM(List<int> raw) {
  final data = ByteData.sublistView(Uint8List.fromList(raw));
  final years = data.getUint32(0) - _durationMid;
  final months = data.getUint8(4) - _durationOffset;
  return OracleYearMonth(years, months);
}

const String _rowidBase64 =
    'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

/// Reads a fetched physical ROWID's fields and renders Oracle's 18-char text
/// (6 base64 digits of the data-object number, 3 of the file number, 6 of the
/// block number, 3 of the slot). All-zero rowid → null.
String? _decodeRowid(ReadBuffer buf) {
  final rba = buf.readUB4();
  final partitionId = buf.readUB2();
  buf.skipUB1();
  final blockNum = buf.readUB4();
  final slotNum = buf.readUB2();
  if (rba == 0 && partitionId == 0 && blockNum == 0 && slotNum == 0) {
    return null;
  }
  final out = StringBuffer();
  _writeBase64(out, rba, 6);
  _writeBase64(out, partitionId, 3);
  _writeBase64(out, blockNum, 6);
  _writeBase64(out, slotNum, 3);
  return out.toString();
}

void _writeBase64(StringBuffer out, int value, int digits) {
  for (var shift = (digits - 1) * 6; shift >= 0; shift -= 6) {
    out.writeCharCode(_rowidBase64.codeUnitAt((value >> shift) & 0x3f));
  }
}

/// Oracle BINARY_FLOAT (4 bytes) / BINARY_DOUBLE (8 bytes): IEEE-754 with the
/// Oracle sign-bit transform (positive → high bit set; negative → all bits
/// inverted) so values sort correctly on the wire.
double _decodeBinaryFloat(List<int> raw) {
  final bytes = Uint8List.fromList(raw);
  if (bytes.length == 4) {
    if ((bytes[0] & 0x80) != 0) {
      bytes[0] &= 0x7F;
    } else {
      for (var i = 0; i < 4; i++) {
        bytes[i] = ~bytes[i] & 0xFF;
      }
    }
    return ByteData.sublistView(bytes).getFloat32(0);
  }
  if ((bytes[0] & 0x80) != 0) {
    bytes[0] &= 0x7F;
  } else {
    for (var i = 0; i < 8; i++) {
      bytes[i] = ~bytes[i] & 0xFF;
    }
  }
  return ByteData.sublistView(bytes).getFloat64(0);
}

/// A per-row error from an array-DML `executeMany(batchErrors: true)` call.
class NativeBatchError {
  NativeBatchError(this.offset, this.code, this.message);

  /// 0-based input-row index that failed.
  final int offset;

  /// Oracle error code (e.g. 1 for ORA-00001 unique-constraint).
  final int code;
  final String message;

  @override
  String toString() => 'row $offset: ORA-${code.toString().padLeft(5, '0')} '
      '${message.trim()}';
}

/// Decoded header fields of a TTC ERROR message, shared by the EXECUTE and LOB
/// response decoders.
class _TtcError {
  _TtcError(this.num, this.message, this.cursorId, this.rowCount,
      [this.batchErrors = const []]);
  final int num;
  final String? message;
  final int cursorId;
  final int? rowCount;
  final List<NativeBatchError> batchErrors;
}

/// Walks a TTC ERROR body (after the message-type byte) and returns its fields.
_TtcError _readTtcErrorBody(ReadBuffer buf, int ttcFieldVersion) {
  buf.readUB4(); // end of call status
  buf.skipUB2(); // end-to-end seq num
  buf.skipUB4(); // current row number
  buf.skipUB2(); // error number (short)
  buf.skipUB2(); // array elem error
  buf.skipUB2(); // array elem error
  final cursorId = buf.readUB4();
  buf.readSB4(); // error position
  buf.skipUB1(); // sql type
  buf.skipUB1(); // fatal?
  buf.skipUB1(); // flags
  buf.skipUB1(); // user cursor options
  buf.skipUB1(); // UPI param
  buf.skipUB1(); // warning flag
  buf.skipUB4(); // rowID rba
  buf.skipUB2(); // partitionID
  buf.skipUB1();
  buf.skipUB4(); // blockNum
  buf.skipUB2(); // slotNum
  buf.skipUB4(); // OS error
  buf.skipUB1(); // statement error
  buf.skipUB1(); // call number
  buf.skipUB2(); // padding
  buf.skipUB4(); // success iters
  final oerrddLen = buf.readUB4();
  if (oerrddLen > 0) buf.readBytesWithLength();
  // Per-row batch errors (array-DML executeMany with batchErrors): three
  // parallel arrays — codes, 0-based input-row offsets, messages.
  final batchCodes = <int>[];
  final numErrs = buf.readUB2();
  if (numErrs > 0) {
    final firstByte = buf.readUint8();
    for (var i = 0; i < numErrs; i++) {
      if (firstByte == 0xFE) buf.skipUB4();
      batchCodes.add(buf.readUB2());
    }
    if (firstByte == 0xFE) buf.skip(1);
  }
  final batchOffsets = <int>[];
  final numOff = buf.readUB4();
  if (numOff > 0) {
    final firstByte = buf.readUint8();
    for (var i = 0; i < numOff; i++) {
      if (firstByte == 0xFE) buf.skipUB4();
      batchOffsets.add(buf.readUB4());
    }
    if (firstByte == 0xFE) buf.skip(1);
  }
  final batchMessages = <String>[];
  final errMsgArr = buf.readUB2();
  if (errMsgArr > 0) {
    buf.skip(1);
    for (var i = 0; i < errMsgArr; i++) {
      buf.skipUB2();
      batchMessages.add(
          utf8.decode(buf.readBytesWithLength(), allowMalformed: true).trim());
      buf.skip(2);
    }
  }
  final num = buf.readUB4(); // extended error number
  int? rowCount;
  if (ttcFieldVersion >= _fieldVersion12_2) {
    rowCount = buf.readUB8();
    if (ttcFieldVersion >= 21 /* 20.1 */) {
      buf.skipUB4(); // sql type
      buf.skipUB4(); // server checksum
    }
  }
  String? message;
  if (num != 0) {
    message =
        utf8.decode(buf.readBytesWithLength(), allowMalformed: true).trim();
  }
  final batchErrors = <NativeBatchError>[
    for (var i = 0; i < batchCodes.length; i++)
      NativeBatchError(i < batchOffsets.length ? batchOffsets[i] : 0,
          batchCodes[i], i < batchMessages.length ? batchMessages[i] : ''),
  ];
  return _TtcError(num, message, cursorId, rowCount, batchErrors);
}

void _processError(ReadBuffer buf, _DecodeState s) {
  final err = _readTtcErrorBody(buf, s.ttcFieldVersion);
  final num = err.num;
  s.cursorId = err.cursorId;
  s.errorNum = num;
  if (num != 0) {
    s.errorMessage = err.message;
  }
  if (err.batchErrors.isNotEmpty) {
    // Array-DML executeMany(batchErrors: true): the server applied the valid
    // rows and returned per-row errors under a statement-level ORA-24381. This
    // is a SUCCESS returning row errors as data — clear the statement error.
    s.batchErrors = err.batchErrors;
    s.errorNum = 0;
    s.errorMessage = null;
    if (!s.isQuery) s.rowsAffected = err.rowCount;
    return;
  }
  if (s.isQuery && num == 1403) {
    s.errorNum = 0;
    s.moreRowsToFetch = false;
  } else if (s.isQuery && num == 0) {
    s.moreRowsToFetch = true;
  }
  if (!s.isQuery && num == 0) {
    s.rowsAffected = err.rowCount;
  }
}

void _skipWarning(ReadBuffer buf) {
  buf.skipUB2(); // warning number
  final numBytes = buf.readUB2();
  buf.skipUB2(); // flags
  if (numBytes > 0) buf.readBytesWithLength();
}

void _processReturnParameter(ReadBuffer buf, _DecodeState s) {
  final numParams = buf.readUB2();
  for (var i = 0; i < numParams; i++) {
    buf.skipUB4();
  }
  final txLen = buf.readUB2();
  if (txLen > 0) buf.skip(txLen);
  final numKv = buf.readUB2();
  for (var i = 0; i < numKv; i++) {
    final keyLen = buf.readUB2();
    if (keyLen > 0) buf.readBytesWithLength();
    final valLen = buf.readUB2();
    if (valLen > 0) buf.readBytesWithLength();
    buf.readUB2(); // keyword num
  }
  final regLen = buf.readUB2();
  if (regLen > 0) buf.skip(regLen);
}

void _processServerSidePiggyback(ReadBuffer buf) {
  final opcode = buf.readUint8();
  switch (opcode) {
    case 1: // QUERY_CACHE_INVALIDATION
    case 3: // TRACE_EVENT
      return;
    case 2: // OS_PID_MTS
      final numDtys = buf.readUB2();
      buf.skipUB1();
      buf.skip(numDtys);
      return;
    case 4: // SESS_RET
      buf.skipUB2();
      buf.skipUB1();
      final numElements = buf.readUB2();
      if (numElements > 0) {
        buf.skipUB1();
        for (var i = 0; i < numElements; i++) {
          if (buf.readUB2() > 0) buf.readBytesWithLength();
          if (buf.readUB2() > 0) buf.readBytesWithLength();
          buf.skipUB2();
        }
      }
      buf.skipUB4();
      buf.skipUB4();
      buf.skipUB2();
      return;
    case 5: // SYNC
      buf.skipUB2();
      buf.skipUB1();
      final numElements = buf.readUB4();
      buf.skipUB1();
      for (var i = 0; i < numElements; i++) {
        if (buf.readUB2() > 0) buf.readBytesWithLength();
        if (buf.readUB2() > 0) buf.readBytesWithLength();
        buf.skipUB2();
      }
      buf.skipUB4();
      return;
    case 7: // LTXID
      final n = buf.readUB4();
      if (n > 0) buf.readBytesWithLength();
      return;
    case 8: // AC_REPLAY_CONTEXT
      buf.skipUB2();
      buf.skipUB1();
      buf.skipUB4();
      buf.skipUB4();
      buf.skipUB1();
      final numBytes = buf.readUB4();
      if (numBytes > 0) buf.readBytesWithLength();
      return;
    case 9: // EXT_SYNC
      buf.skipUB2();
      buf.skipUB1();
      return;
    case 10: // SESS_SIGNATURE
      buf.skipUB2();
      buf.skipUB1();
      buf.readUB8();
      buf.readUB8();
      buf.readUB8();
      return;
    default:
      throw StateError('Unknown server-side piggyback opcode: $opcode');
  }
}

// --- LOB read (CLOB / BLOB materialization) --------------------------------

const int _funcLobOp = 0x60; // TNS_FUNC_LOB_OP (96)
const int _lobOpGetLength = 0x0001;
const int _lobOpRead = 0x0002;
const int _lobOpWrite = 0x0040;
const int _lobOpCreateTemp = 0x0110;
const int _durationSession = 10;
const int _lobLocatorBufferSize = 40;
const int _lobLocatorBindBufferSize = 112;
const int _lobPrefetchFlag = 0x2000000;
const int _charsetAl16Utf16 = 2000;
const int _msgTypeLobData = 14;

/// Builds a LOB READ request for [amount] units (characters for CLOB, bytes
/// for BLOB) from [locator] starting at 1-based [offset].
Uint8List buildLobRead(
  Uint8List locator,
  int offset,
  int amount, {
  int ttcFieldVersion = _fieldVersion23_4,
  int sequence = 1,
}) =>
    _buildLobOp(locator, _lobOpRead, offset, amount,
        ttcFieldVersion: ttcFieldVersion, sequence: sequence);

/// Builds a LOB GET_LENGTH request; the length rides back as the SB8 amount in
/// the RETURN_PARAMETER reply.
Uint8List buildLobGetLength(
  Uint8List locator, {
  int ttcFieldVersion = _fieldVersion23_4,
  int sequence = 1,
}) =>
    _buildLobOp(locator, _lobOpGetLength, 0, 0,
        ttcFieldVersion: ttcFieldVersion, sequence: sequence);

Uint8List _buildLobOp(
  Uint8List locator,
  int operation,
  int offset,
  int amount, {
  required int ttcFieldVersion,
  required int sequence,
}) {
  final b = WriteBuffer();
  b.writeUint8(_msgTypeFunction);
  b.writeUint8(_funcLobOp);
  b.writeUint8(sequence & 0xFF);
  if (ttcFieldVersion >= _fieldVersion23_1Ext1) {
    b.writeUB8(0); // token number
  }
  b.writeUint8(1); // source locator pointer
  b.writeUB4(locator.length);
  b.writeUint8(0); // dest locator pointer
  b.writeUB4(0); // dest locator length
  b.writeUB4(0); // short source offset
  b.writeUB4(0); // short dest offset
  b.writeUint8(0); // charset pointer (not CREATE_TEMP)
  b.writeUint8(0); // short amount pointer
  b.writeUint8(0); // boolean-out pointer
  b.writeUB4(operation);
  b.writeUint8(0); // SCN pointer
  b.writeUint8(0); // SCN array length
  b.writeUB8(offset);
  b.writeUB8(0); // dest offset
  b.writeUint8(1); // amount pointer (sendAmount)
  for (var i = 0; i < 3; i++) {
    b.writeUint16BE(0); // three fixed two-byte zero fields
  }
  b.writeBytes(locator);
  b.writeUB8(amount);
  return b.toBytes();
}

/// Builds a LOB CREATE_TEMP request for a temporary LOB. [oraType] is CLOB
/// (112) or BLOB (113); [csfrm] 1 = CLOB, 2 = NCLOB, 0 = BLOB. The response's
/// `updatedLocator` is the real temp-LOB locator.
Uint8List buildLobCreateTemp({
  int oraType = _oraTypeClob,
  int csfrm = 1,
  int ttcFieldVersion = _fieldVersion23_4,
  int sequence = 1,
}) {
  final locator = Uint8List(_lobLocatorBufferSize);
  final b = WriteBuffer();
  b.writeUint8(_msgTypeFunction);
  b.writeUint8(_funcLobOp);
  b.writeUint8(sequence & 0xFF);
  if (ttcFieldVersion >= _fieldVersion23_1Ext1) {
    b.writeUB8(0); // token number
  }
  b.writeUint8(1); // source locator pointer (zeroed buffer)
  b.writeUB4(locator.length);
  b.writeUint8(0); // dest locator pointer
  b.writeUB4(_durationSession); // dest length carries the temp-LOB duration
  b.writeUB4(0); // short source offset
  b.writeUB4(0); // short dest offset
  b.writeUint8(1); // charset pointer (CREATE_TEMP)
  b.writeUint8(0); // short amount pointer
  b.writeUint8(1); // boolean-out pointer (CREATE_TEMP)
  b.writeUB4(_lobOpCreateTemp);
  b.writeUint8(0); // SCN pointer
  b.writeUint8(0); // SCN array length
  b.writeUB8(csfrm); // source offset carries the charset form
  b.writeUB8(oraType); // dest offset carries the Oracle type
  b.writeUint8(0); // amount pointer
  for (var i = 0; i < 3; i++) {
    b.writeUint16BE(0);
  }
  b.writeBytes(locator);
  b.writeUB4(csfrm == _csfrmNChar ? _charsetAl16Utf16 : _charsetUtf8);
  return b.toBytes();
}

/// Builds a LOB WRITE request: writes [data] into [locator] at 1-based
/// [offset]. For a plain CLOB, [data] is UTF-8; for an NCLOB, UTF-16BE.
Uint8List buildLobWrite(
  Uint8List locator,
  int offset,
  Uint8List data, {
  int ttcFieldVersion = _fieldVersion23_4,
  int sequence = 1,
}) {
  final b = WriteBuffer();
  b.writeUint8(_msgTypeFunction);
  b.writeUint8(_funcLobOp);
  b.writeUint8(sequence & 0xFF);
  if (ttcFieldVersion >= _fieldVersion23_1Ext1) {
    b.writeUB8(0); // token number
  }
  b.writeUint8(1); // source locator pointer
  b.writeUB4(locator.length);
  b.writeUint8(0); // dest locator pointer
  b.writeUB4(0); // dest locator length
  b.writeUB4(0); // short source offset
  b.writeUB4(0); // short dest offset
  b.writeUint8(0); // charset pointer
  b.writeUint8(0); // short amount pointer
  b.writeUint8(0); // boolean-out pointer
  b.writeUB4(_lobOpWrite);
  b.writeUint8(0); // SCN pointer
  b.writeUint8(0); // SCN array length
  b.writeUB8(offset);
  b.writeUB8(0); // dest offset
  b.writeUint8(0); // amount pointer
  for (var i = 0; i < 3; i++) {
    b.writeUint16BE(0);
  }
  b.writeBytes(locator);
  b.writeUint8(_msgTypeLobData);
  b.writeBytesWithLength(data);
  return b.toBytes();
}

/// The decoded result of a LOB READ: the concatenated data bytes (CLOB/NCLOB
/// still charset-encoded) and whether the response stream was complete.
class NativeLobReadResponse {
  NativeLobReadResponse({
    required this.data,
    required this.complete,
    this.amount,
    this.updatedLocator,
    this.errorNum,
    this.errorMessage,
  });
  final Uint8List data;
  final bool complete;

  /// The SB8 amount echoed in RETURN_PARAMETER (LOB length for GET_LENGTH,
  /// bytes/chars read for READ).
  final int? amount;

  /// The locator the server echoed back — the real temp-LOB locator after
  /// CREATE_TEMP, or the updated locator after WRITE.
  final Uint8List? updatedLocator;
  final int? errorNum;
  final String? errorMessage;
  bool get isSuccess => errorNum == null || errorNum == 0;
}

/// Decodes a (possibly partial) LOB operation response. [sourceLocatorLength]
/// is the request locator's length (echoed back in RETURN_PARAMETER). For
/// CREATE_TEMP pass [isCreateTemp]; for READ/GET_LENGTH leave [sendAmount] true;
/// for WRITE pass [sendAmount] false.
NativeLobReadResponse decodeLobReadResponse(
  Uint8List body, {
  required int sourceLocatorLength,
  bool isCreateTemp = false,
  bool sendAmount = true,
  int ttcFieldVersion = _fieldVersion23_4,
}) {
  final buf = ReadBuffer(body);
  final chunks = <int>[];
  var endOfResponse = false;
  int? amount;
  Uint8List? updatedLocator;
  int? errorNum;
  String? errorMessage;
  try {
    while (buf.hasRemaining && !endOfResponse) {
      final msgType = buf.readUint8();
      switch (msgType) {
        case _msgTypeLobData:
          chunks.addAll(buf.readBytesWithLength());
          break;
        case _msgTypeParameter:
          if (sourceLocatorLength > 0) {
            updatedLocator =
                Uint8List.fromList(buf.readBytes(sourceLocatorLength));
          }
          if (isCreateTemp) {
            buf.skipUB2(); // charset
            buf.skipUB1(); // flags
          } else if (sendAmount) {
            amount = buf.readSB8(); // amount read / LOB length
          }
          break;
        case _msgTypeError:
          final err = _readTtcErrorBody(buf, ttcFieldVersion);
          errorNum = err.num;
          if (err.num != 0) errorMessage = err.message;
          break;
        case _msgTypeWarning:
          _skipWarning(buf);
          break;
        case _msgTypeStatus:
          buf.skipUB4();
          buf.skipUB2();
          endOfResponse = true;
          break;
        case _msgTypeServerSidePiggyback:
          _processServerSidePiggyback(buf);
          break;
        case _msgTypeEndOfRequest:
          endOfResponse = true;
          break;
        default:
          throw StateError('Unknown TTC message in LOB response: $msgType');
      }
    }
  } on OracleBufferUnderflow {
    return NativeLobReadResponse(
        data: Uint8List.fromList(chunks), complete: false);
  }
  return NativeLobReadResponse(
    data: Uint8List.fromList(chunks),
    complete: endOfResponse,
    amount: amount,
    updatedLocator: updatedLocator,
    errorNum: errorNum,
    errorMessage: errorMessage,
  );
}
