/// Oracle TTC EXECUTE (RPC function 94) handling — the server side of the
/// "money path".
///
/// Inverts the client's `execute_message.dart`: [decodeExecuteRequest] walks
/// the OALL8 request header to recover the SQL text (and whether binds are
/// present), and the response builders emit the describe + row stream (for
/// queries) or a success/error terminal (for DML/DDL) that the client's
/// response decoder reads back.
///
/// Scope: no-bind statements at TTC field version 24. Result columns are
/// described as VARCHAR2 and values are sent as UTF-8 strings — a valid shape
/// the client decodes to `String`, which sidesteps Oracle's base-100 NUMBER
/// encoding for now.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'oracle_codec.dart';
import 'oracle_number.dart';
import 'oracle_ttc.dart';
import 'result.dart';
import 'vector.dart';

/// TTC RPC function code for a full execute (OALL8).
const int ttcFuncExecute = 94;

/// TTC RPC function codes for the transaction / lifecycle calls.
const int ttcFuncCommit = 14;
const int ttcFuncRollback = 15;
const int ttcFuncPing = 0x93;

/// TTC RPC function code for the close-cursors piggyback.
const int ttcFuncCloseCursors = 105;

/// Oracle VARCHAR2 data type indicator.
const int _oraTypeVarchar = 1;

/// Oracle NUMBER data type indicator.
const int _oraTypeNumber = 2;

/// Oracle RAW data type indicator.
const int _oraTypeRaw = 23;

/// Oracle VECTOR data type indicator (Oracle 23ai).
const int _oraTypeVector = 127;

/// The TTC field version the server negotiates (see `oracle_ttc.dart`).
const int executeFieldVersion = 24;

// Field-version gates (TNS_CCAP_FIELD_VERSION_*), matching the client.
const int _fv12_2 = 8;
const int _fvExt1 = 9;
const int _fv23_1Ext1 = 18;

/// ORA-01403: no data found — used as the end-of-fetch terminal for queries.
const int _oraNoDataFound = 1403;

/// What [decodeExecuteRequest] recovers from an EXECUTE request.
class ExecuteRequestInfo {
  ExecuteRequestInfo({
    required this.options,
    required this.cursorId,
    required this.sql,
    required this.numParams,
    this.binds = const [],
  });

  final int options;
  final int cursorId;

  /// The SQL text, when the request carried it (a fresh statement, cursorId 0).
  final String sql;

  /// Number of bind parameters declared.
  final int numParams;

  /// Decoded IN bind values in wire order (one per declared parameter).
  final List<Object?> binds;

  bool get hasBinds => numParams > 0;
}

/// Decodes an EXECUTE request body. [body] is positioned just past the TTC
/// function header (message type, function code, sequence already consumed).
ExecuteRequestInfo decodeExecuteRequest(
  ReadBuffer body, {
  int ttcFieldVersion = executeFieldVersion,
}) {
  if (ttcFieldVersion >= _fv23_1Ext1) {
    body.readUB8(); // token number
  }
  final options = body.readUB4();
  final cursorId = body.readUB4();
  body.readUint8(); // SQL pointer
  body.readUB4(); // SQL length (redundant with the inline bytes)
  body.readUint8(); // pointer (vector)
  body.readUB4(); // al8i4 array length (13)
  body.readUint8(); // al8o4
  body.readUint8(); // al8o4l
  body.readUint8(); // prefetch buffer size
  body.readUB4(); // prefetch num rows
  body.readUB4(); // maximum long size
  body.readUint8(); // numParams pointer
  final numParams = body.readUB4();
  body.readUint8(); // al8pp
  body.readUint8(); // al8txn
  body.readUint8(); // al8txl
  body.readUint8(); // al8kv
  body.readUint8(); // al8kvl
  body.readUint8(); // defines pointer
  body.readUB4(); // defines count
  body.readUB4(); // registration id
  body.readUint8(); // al8objlist
  body.readUint8(); // al8objlen
  body.readUint8(); // al8blv (ptr)
  body.readUB4(); // al8blv
  body.readUint8(); // al8dnam
  body.readUB4(); // al8dnaml
  body.readUB4(); // al8regid_msb
  body.readUint8(); // array-dml-rowcounts pointer
  body.readUB4(); // row-count count
  body.readUint8(); // array-dml-rowcounts length pointer
  if (ttcFieldVersion >= _fv12_2) {
    body.readUint8(); // al8sqlsig
    body.readUB4();
    body.readUint8(); // sql id
    body.readUB4();
    body.readUint8(); // length of sql id
    if (ttcFieldVersion >= _fvExt1) {
      body.readUint8(); // chunk ids
      body.readUB4();
    }
  }
  var sql = '';
  if (cursorId == 0) {
    final sqlBytes = body.readBytesWithLength();
    sql = utf8.decode(sqlBytes, allowMalformed: true);
    body.readUB4(); // al8i4[0] parse
  } else {
    body.readUB4(); // al8i4[0]
  }
  for (var i = 1; i < 13; i++) {
    body.readUB4(); // al8i4[1..12]
  }
  final binds = numParams > 0
      ? _decodeBinds(body, numParams, ttcFieldVersion)
      : const <Object?>[];
  return ExecuteRequestInfo(
    options: options,
    cursorId: cursorId,
    sql: sql,
    numParams: numParams,
    binds: binds,
  );
}

/// Decodes [numParams] bind metadata blocks followed by the single ROW_DATA
/// message carrying the IN bind values, returning the values in wire order.
List<Object?> _decodeBinds(ReadBuffer body, int numParams, int fv) {
  final oraTypes = <int>[];
  for (var i = 0; i < numParams; i++) {
    oraTypes.add(body.readUint8()); // data type
    body.readUint8(); // flag (bind-use indicators)
    body.readUint8(); // precision
    body.readUint8(); // scale
    body.readUB4(); // max size
    body.readUB4(); // max num array elements
    body.readUB4(); // cont flag (LOB prefetch)
    body.readUB4(); // OID
    body.readUB2(); // version
    body.readUB2(); // charset field
    body.readUint8(); // csfrm
    body.readUB4(); // LOB prefetch length
    if (fv >= _fv12_2) {
      body.readUB4(); // oaccolid
    }
  }
  if (!body.hasRemaining) {
    return List<Object?>.filled(numParams, null); // all-NULL / no row data
  }
  body.readUint8(); // ROW_DATA message type (7)
  return [for (final ot in oraTypes) _decodeBindValue(body, ot)];
}

/// Decodes one IN bind value. Supported: NUMBER, VARCHAR2/CHAR, RAW, DATE /
/// TIMESTAMP (decoded to an ISO-8601 string the engine stores as text),
/// INTERVAL YEAR TO MONTH / DAY TO SECOND (decoded to a signed literal
/// string), and NULL (a zero-length value). Other types are not yet handled.
Object? _decodeBindValue(ReadBuffer body, int oraType) {
  if (oraType == _oraTypeVector) return _decodeVectorBind(body);
  final bytes = body.readBytesWithLength();
  if (bytes.isEmpty) return null; // NULL (also an empty string in Oracle)
  switch (oraType) {
    case 2: // NUMBER
    case 3: // INTEGER
    case 4: // FLOAT
    case 6: // VARNUM
      return decodeOracleNumber(ReadBuffer(bytes));
    case 1: // VARCHAR
    case 5: // STRING
    case 96: // CHAR
      return utf8.decode(bytes, allowMalformed: true);
    case 23: // RAW
      return Uint8List.fromList(bytes);
    case 12: // DATE
    case 180: // TIMESTAMP
    case 181: // TIMESTAMP WITH TIME ZONE
    case 231: // TIMESTAMP WITH LOCAL TIME ZONE
      return _decodeOracleDateTime(bytes);
    case 182: // INTERVAL YEAR TO MONTH
      return _decodeIntervalYM(Uint8List.fromList(bytes));
    case 183: // INTERVAL DAY TO SECOND
      return _decodeIntervalDS(Uint8List.fromList(bytes));
    default:
      throw FormatException('unsupported bind type $oraType');
  }
}

/// Bias added to the 32-bit day / fractional-second / year fields of an
/// INTERVAL wire value (client `TNS_DURATION_MID`).
const int _durationMid = 0x80000000;

/// Bias added to the one-byte hour / minute / second / month fields of an
/// INTERVAL wire value (client `TNS_DURATION_OFFSET`).
const int _durationOffset = 60;

/// Decodes the 5-byte Oracle `INTERVAL YEAR TO MONTH` wire value (type 182)
/// into a signed `[+|-]Y-MM` literal the engine stores as text. Inverts the
/// client's `encodeIntervalYM` (bytes 0-3: years + 0x80000000 big-endian;
/// byte 4: months + 60).
String _decodeIntervalYM(Uint8List b) {
  if (b.length != 5) {
    throw FormatException(
        'INTERVAL YEAR TO MONTH field has ${b.length} bytes (expected 5)');
  }
  final data = ByteData.sublistView(b);
  final years = data.getUint32(0) - _durationMid;
  final months = data.getUint8(4) - _durationOffset;
  final negative = years < 0 || months < 0;
  return '${negative ? '-' : '+'}${years.abs()}-'
      '${months.abs().toString().padLeft(2, '0')}';
}

/// Decodes the 11-byte Oracle `INTERVAL DAY TO SECOND` wire value (type 183)
/// into a signed `[+|-]D HH:MM:SS.fffffffff` literal the engine stores as
/// text. Inverts the client's `encodeIntervalDS` (bytes 0-3: days +
/// 0x80000000; byte 4: hours + 60; byte 5: minutes + 60; byte 6: seconds + 60;
/// bytes 7-10: nanoseconds + 0x80000000, all big-endian).
String _decodeIntervalDS(Uint8List b) {
  if (b.length != 11) {
    throw FormatException(
        'INTERVAL DAY TO SECOND field has ${b.length} bytes (expected 11)');
  }
  final data = ByteData.sublistView(b);
  final days = data.getUint32(0) - _durationMid;
  final hours = data.getUint8(4) - _durationOffset;
  final minutes = data.getUint8(5) - _durationOffset;
  final seconds = data.getUint8(6) - _durationOffset;
  final fseconds = data.getUint32(7) - _durationMid;
  final negative = days < 0 ||
      hours < 0 ||
      minutes < 0 ||
      seconds < 0 ||
      fseconds < 0;
  String two(int v) => v.abs().toString().padLeft(2, '0');
  final fraction = fseconds.abs().toString().padLeft(9, '0');
  return '${negative ? '-' : '+'}${days.abs()} '
      '${two(hours)}:${two(minutes)}:${two(seconds)}.$fraction';
}

/// Decodes an Oracle DATE (7 bytes) / TIMESTAMP (11) / TIMESTAMP-with-zone (13)
/// wire value to an ISO-8601 `YYYY-MM-DD HH:MM:SS[.ffffff]` string — the
/// text form the engine stores dates as. Any trailing time-zone bytes are
/// ignored (fields are taken as wall-clock).
String _decodeOracleDateTime(Uint8List b) {
  final year = (b[0] - 100) * 100 + (b[1] - 100);
  final month = b[2];
  final day = b[3];
  final hour = b[4] - 1;
  final minute = b[5] - 1;
  final second = b[6] - 1;
  var micros = 0;
  if (b.length >= 11) {
    final nanos = (b[7] << 24) | (b[8] << 16) | (b[9] << 8) | b[10];
    micros = nanos ~/ 1000;
  }
  String p2(int v) => v.toString().padLeft(2, '0');
  final base = '${year.toString().padLeft(4, '0')}-${p2(month)}-${p2(day)} '
      '${p2(hour)}:${p2(minute)}:${p2(second)}';
  return micros > 0 ? '$base.${micros.toString().padLeft(6, '0')}' : base;
}

// ===========================================================================
// VECTOR (Oracle 23ai) — type 127
// ===========================================================================

/// Magic byte that opens a VECTOR image (client `tnsVectorMagicByte`).
const int _vectorMagicByte = 0xDB;
const int _vectorVersionBase = 0;
const int _vectorVersionWithSparse = 2;
const int _vectorFlagNorm = 0x0002;
const int _vectorFlagNormSrc = 0x0010;
const int _vectorFlagSparse = 0x0020;
const int _vectorFormatFloat32 = 2;
const int _vectorFormatFloat64 = 3;
const int _vectorFormatInt8 = 4;
const int _vectorFormatBinary = 5;
const int _vectorImageHeaderLength = 9;
const int _vectorNormLength = 8;

/// Decodes a VECTOR bind value (type 127) into the engine's [Vector].
///
/// The client writes a VECTOR bind as a 40-byte value-based QLocator — a UB4
/// byte count (40) then the length-prefixed locator — followed by the
/// length-prefixed vector image (client `_writeQLocator` + `encodeVector`). A
/// NULL arrives as a single zero-length indicator.
Vector? _decodeVectorBind(ReadBuffer body) {
  final marker = body.peekUint8();
  if (marker == 0 || marker == 0xFF) {
    body.readUint8(); // zero-length NULL indicator
    return null;
  }
  body.readUB4(); // QLocator byte count (40)
  body.readBytesWithLength(); // 40-byte value-based QLocator (ignored)
  final image = body.readBytesWithLength();
  return _decodeVectorImage(image);
}

/// Decodes a VECTOR image into the engine's [Vector] (always `Float32List`).
/// Inverts the client's `encodeVector` for dense FLOAT32 / FLOAT64 / INT8
/// vectors (the formats the engine's `Float32` storage can represent);
/// BINARY and sparse images are rejected. FLOAT32 / FLOAT64 elements are read
/// from Oracle's byte-comparable IEEE form.
Vector _decodeVectorImage(Uint8List image) {
  if (image.length < _vectorImageHeaderLength || image[0] != _vectorMagicByte) {
    throw const FormatException('malformed VECTOR image');
  }
  final data = ByteData.sublistView(image);
  final version = image[1];
  if (version > _vectorVersionWithSparse) {
    throw FormatException('unsupported VECTOR image version $version');
  }
  final flags = data.getUint16(2);
  if ((flags & _vectorFlagSparse) != 0) {
    throw const FormatException('sparse VECTOR binds are not supported');
  }
  final format = image[4];
  final count = data.getUint32(5);
  var pos = _vectorImageHeaderLength;
  if (format == _vectorFormatBinary || (flags & _vectorFlagNorm) != 0) {
    pos += _vectorNormLength; // skip the norm (or its reserved space)
  }
  final out = Float32List(count);
  switch (format) {
    case _vectorFormatFloat32:
      for (var i = 0; i < count; i++, pos += 4) {
        out[i] = _readComparableFloat32(data, pos);
      }
    case _vectorFormatFloat64:
      for (var i = 0; i < count; i++, pos += 8) {
        out[i] = _readComparableFloat64(data, pos);
      }
    case _vectorFormatInt8:
      for (var i = 0; i < count; i++, pos += 1) {
        final b = image[pos];
        out[i] = (b > 127 ? b - 256 : b).toDouble();
      }
    default:
      throw FormatException('unsupported VECTOR format $format');
  }
  return Vector(out);
}

/// Encodes the engine's [Vector] (a `Float32List`) into a dense FLOAT32
/// VECTOR image (client `encodeVector` for a `Float32List`): the 9-byte
/// header, 8 zero norm bytes, then the byte-comparable FLOAT32 elements.
Uint8List _encodeVectorImage(Vector vector) {
  final values = vector.values;
  final size = _vectorImageHeaderLength + _vectorNormLength + values.length * 4;
  final image = Uint8List(size);
  final data = ByteData.sublistView(image);
  image[0] = _vectorMagicByte;
  image[1] = _vectorVersionBase;
  data.setUint16(2, _vectorFlagNormSrc | _vectorFlagNorm);
  image[4] = _vectorFormatFloat32;
  data.setUint32(5, values.length);
  // Bytes 9..16 stay zero: the norm (the server would compute it).
  var pos = _vectorImageHeaderLength + _vectorNormLength;
  for (final v in values) {
    _writeComparableFloat32(data, pos, v);
    pos += 4;
  }
  return image;
}

final ByteData _floatScratch = ByteData(8);

/// Reads a FLOAT32 element in Oracle's byte-comparable form (client
/// `_readComparableFloat32`).
double _readComparableFloat32(ByteData data, int pos) {
  var bits = data.getUint32(pos);
  bits = (bits & 0x80000000) != 0 ? bits & 0x7FFFFFFF : ~bits & 0xFFFFFFFF;
  _floatScratch.setUint32(0, bits);
  return _floatScratch.getFloat32(0);
}

/// Reads a FLOAT64 element in Oracle's byte-comparable form (client
/// `_readComparableFloat64`).
double _readComparableFloat64(ByteData data, int pos) {
  var hi = data.getUint32(pos);
  var lo = data.getUint32(pos + 4);
  if ((hi & 0x80000000) != 0) {
    hi &= 0x7FFFFFFF;
  } else {
    hi = ~hi & 0xFFFFFFFF;
    lo = ~lo & 0xFFFFFFFF;
  }
  _floatScratch
    ..setUint32(0, hi)
    ..setUint32(4, lo);
  return _floatScratch.getFloat64(0);
}

/// Writes [value] as a FLOAT32 element in Oracle's byte-comparable form
/// (client `_writeComparableFloat32`).
void _writeComparableFloat32(ByteData data, int pos, double value) {
  _floatScratch.setFloat32(0, value);
  final bits = _floatScratch.getUint32(0);
  data.setUint32(
    pos,
    (bits & 0x80000000) == 0 ? bits | 0x80000000 : ~bits & 0xFFFFFFFF,
  );
}

/// Builds the response for a query [result]: DESCRIBE_INFO, one ROW_HEADER, a
/// ROW_DATA per row, and a terminal ORA-01403 (end of fetch). [cursorId] is
/// echoed so the client can cache the statement. Returns the TTC body (no TNS
/// framing).
Uint8List buildQueryResponse(QueryResult result, {int cursorId = 0}) {
  final b = WriteBuffer();
  // Describe a column as NUMBER only when every non-null value is a
  // representable number; otherwise fall back to VARCHAR2 (stringified).
  final types = [
    for (var i = 0; i < result.columns.length; i++)
      _inferColumnOraType(result.rows, i),
  ];
  _writeDescribeInfo(b, result.columns, types);
  _writeRowHeader(b);
  for (final row in result.rows) {
    _writeRowData(b, row, types);
  }
  _writeErrorBody(b,
      num: _oraNoDataFound,
      cursorId: cursorId,
      message: 'ORA-01403: no data found');
  return b.toBytes();
}

/// Infers the Oracle wire type for column [colIndex]: VECTOR when every
/// non-null value is a [Vector], NUMBER when every non-null value is a
/// representable number, RAW when every value is a byte buffer, else VARCHAR2.
int _inferColumnOraType(List<List<Object?>> rows, int colIndex) {
  var sawValue = false;
  var allNumber = true;
  var allRaw = true;
  var allVector = true;
  for (final row in rows) {
    if (colIndex >= row.length) continue;
    final v = row[colIndex];
    if (v == null) continue;
    sawValue = true;
    if (!(v is num && isOracleNumberRepresentable(v))) allNumber = false;
    if (v is! Uint8List) allRaw = false;
    if (v is! Vector) allVector = false;
    if (!allNumber && !allRaw && !allVector) return _oraTypeVarchar;
  }
  if (!sawValue) return _oraTypeVarchar;
  if (allVector) return _oraTypeVector;
  if (allNumber) return _oraTypeNumber;
  if (allRaw) return _oraTypeRaw;
  return _oraTypeVarchar;
}

/// Builds the response for a non-query [result] (DML/DDL): a success ERROR with
/// the affected row count. [cursorId] is echoed for statement caching.
Uint8List buildDmlResponse(QueryResult result, {int cursorId = 0}) {
  final b = WriteBuffer();
  _writeErrorBody(b, num: 0, rowCount: result.affected, cursorId: cursorId);
  return b.toBytes();
}

/// Builds a terminal TTC ERROR carrying ORA-[errorCode] and [message].
Uint8List buildExecuteError(int errorCode, String message) {
  final b = WriteBuffer();
  _writeErrorBody(b, num: errorCode, message: message);
  return b.toBytes();
}

/// Builds a bare success STATUS message — the terminal reply for COMMIT,
/// ROLLBACK, and PING, which carry no result data. The client's
/// `decodeExecuteResponse` reads it as a successful end-of-call.
Uint8List buildStatusOk() {
  final b = WriteBuffer();
  b.writeUint8(ttcMsgTypeStatus);
  b.writeUB4(0); // call status
  b.writeUB2(0); // end-to-end sequence
  return b.toBytes();
}

void _writeDescribeInfo(WriteBuffer b, List<String> columns, List<int> types) {
  b.writeUint8(ttcMsgTypeDescribeInfo);
  b.writeBytesWithLength(Uint8List(0)); // version bytes
  b.writeUB4(0); // max row size
  b.writeUB4(columns.length); // column count
  if (columns.isNotEmpty) {
    b.writeUint8(0); // one spare UB1 the client skips
  }
  for (var i = 0; i < columns.length; i++) {
    _writeColumnInfo(b, columns[i], i + 1, types[i]);
  }
  b.writeUB4(0); // current date bytes
  b.writeUB4(0); // dcbflag
  b.writeUB4(0); // dcbmdbz
  b.writeUB4(0); // dcbmnpr
  b.writeUB4(0); // dcbmxpr
  b.writeUB4(0); // tail bytes
}

/// Writes one column's metadata (NUMBER, RAW, VARCHAR2, or VECTOR), laid out
/// exactly as the client's `_processColumnInfo` reads it at field version 24.
void _writeColumnInfo(WriteBuffer b, String name, int position, int oraType) {
  final maxLen = oraType == _oraTypeNumber
      ? 22
      : oraType == _oraTypeRaw
          ? 2000
          : oraType == _oraTypeVector
              ? 8200
              : 4000;
  final nameBytes = Uint8List.fromList(utf8.encode(name));
  b.writeUint8(oraType); // data type
  b.writeUint8(0); // flags
  b.writeUint8(0); // precision
  b.writeUint8(0); // scale (0: client keeps the int-vs-double heuristic)
  b.writeUB4(maxLen); // max size
  b.writeUB4(0); // max num array elements
  b.writeUB8(0); // cont flags
  b.writeUB4(0); // oid length
  b.writeUB2(0); // version
  b.writeUB2(0); // charset id
  b.writeUint8(0); // csfrm (non-national)
  b.writeUB4(maxLen); // size
  b.writeUB4(0); // oaccolid (12.2)
  b.writeUint8(1); // nullable
  b.writeUint8(0); // v7 name length
  b.writeUB4(nameBytes.length); // name length
  b.writeBytesWithLength(nameBytes); // name
  b.writeUB4(0); // schema length
  b.writeUB4(0); // type name length
  b.writeUB2(position); // column position
  b.writeUB4(0); // uds flags
  // 23.1 domain schema / name.
  b.writeUB4(0);
  b.writeUB4(0);
  // 23.1 ext3 annotations.
  b.writeUB4(0);
  // 23.4 vector fields.
  b.writeUB4(0); // dimensions
  b.writeUint8(0); // format
  b.writeUint8(0); // flags
}

void _writeRowHeader(WriteBuffer b) {
  b.writeUint8(ttcMsgTypeRowHeader);
  b.writeUint8(0); // flags
  b.writeUB2(0); // num requests
  b.writeUB4(0); // iteration number
  b.writeUB4(0); // num iters
  b.writeUB2(0); // buffer length
  b.writeUB4(0); // bit vector length
  b.writeUB4(0); // rxhrid length
}

void _writeRowData(WriteBuffer b, List<Object?> row, List<int> types) {
  b.writeUint8(ttcMsgTypeRowData);
  for (var i = 0; i < row.length; i++) {
    final cell = row[i];
    final type = i < types.length ? types[i] : _oraTypeVarchar;
    if (type == _oraTypeVector) {
      _writeVectorColumn(b, cell);
    } else if (cell == null) {
      b.writeBytesWithLength(Uint8List(0)); // 0-length == NULL
    } else if (type == _oraTypeNumber && cell is num) {
      b.writeBytesWithLength(encodeOracleNumber(cell));
    } else if (type == _oraTypeRaw && cell is Uint8List) {
      b.writeBytesWithLength(cell);
    } else {
      b.writeBytesWithLength(Uint8List.fromList(utf8.encode(cell.toString())));
    }
  }
}

/// Writes a VECTOR column value in the LOB-prefetch inline shape the client's
/// VECTOR column decoder reads (client `execute_message` `oraTypeVector`): a
/// UB4 marker (0 ⇒ SQL NULL), UB8 size and UB4 chunk size (unused), the
/// length-prefixed vector image, then an empty length-prefixed locator.
void _writeVectorColumn(WriteBuffer b, Object? cell) {
  if (cell is! Vector) {
    b.writeUB4(0); // SQL NULL
    return;
  }
  final image = _encodeVectorImage(cell);
  b.writeUB4(image.length); // marker / locator length (non-zero)
  b.writeUB8(image.length); // size (unused by the client)
  b.writeUB4(0); // chunk size (unused)
  b.writeBytesWithLength(image);
  b.writeBytesWithLength(Uint8List(0)); // locator (unused)
}

/// Writes a TTC ERROR body at field version 24. [num] 0 is a DML success (with
/// [rowCount]); a non-zero [num] carries [message]. Field order matches the
/// client's `decodeTtcErrorBody`.
void _writeErrorBody(
  WriteBuffer b, {
  required int num,
  int rowCount = 0,
  int cursorId = 0,
  String? message,
}) {
  b.writeUint8(ttcMsgTypeError);
  b.writeUB4(0); // end of call status
  b.writeUB2(0); // end-to-end seq
  b.writeUB4(0); // current row number
  b.writeUB2(0); // error number (short)
  b.writeUB2(0); // array elem error
  b.writeUB2(0); // array elem error
  b.writeUB4(cursorId); // cursor id
  b.writeUB4(0); // error position (SB4; 0 encodes identically)
  b.writeUint8(0); // sql type
  b.writeUint8(0); // fatal
  b.writeUint8(0); // flags
  b.writeUint8(0); // user cursor options
  b.writeUint8(0); // UPI parameter
  b.writeUint8(0); // warning flag
  // rowID: rba, partitionID, (pad), blockNum, slotNum.
  b.writeUB4(0);
  b.writeUB2(0);
  b.writeUint8(0);
  b.writeUB4(0);
  b.writeUB2(0);
  b.writeUB4(0); // OS error
  b.writeUint8(0); // statement error
  b.writeUint8(0); // call number
  b.writeUB2(0); // padding
  b.writeUB4(0); // success iters
  b.writeUB4(0); // oerrdd length
  b.writeUB2(0); // batch error codes count
  b.writeUB4(0); // batch error offsets count
  b.writeUB2(0); // batch error messages count
  b.writeUB4(num); // extended error number
  b.writeUB8(rowCount); // rowCount (field version >= 12.2)
  b.writeUB4(0); // sql type (>= 20.1)
  b.writeUB4(0); // server checksum (>= 20.1)
  if (num != 0) {
    b.writeBytesWithLength(Uint8List.fromList(utf8.encode(message ?? '')));
  }
}
