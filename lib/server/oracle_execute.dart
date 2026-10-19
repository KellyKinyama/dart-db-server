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

/// TTC RPC function code for a full execute (OALL8).
const int ttcFuncExecute = 94;

/// TTC RPC function codes for the transaction / lifecycle calls.
const int ttcFuncCommit = 14;
const int ttcFuncRollback = 15;
const int ttcFuncPing = 0x93;

/// Oracle VARCHAR2 data type indicator.
const int _oraTypeVarchar = 1;

/// Oracle NUMBER data type indicator.
const int _oraTypeNumber = 2;

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
  });

  final int options;
  final int cursorId;

  /// The SQL text, when the request carried it (a fresh statement, cursorId 0).
  final String sql;

  /// Number of bind parameters declared. Non-zero binds are not yet handled.
  final int numParams;

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
  return ExecuteRequestInfo(
    options: options,
    cursorId: cursorId,
    sql: sql,
    numParams: numParams,
  );
}

/// Builds the response for a query [result]: DESCRIBE_INFO, one ROW_HEADER, a
/// ROW_DATA per row, and a terminal ORA-01403 (end of fetch). Returns the TTC
/// body (no TNS framing).
Uint8List buildQueryResponse(QueryResult result) {
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
  _writeErrorBody(b, num: _oraNoDataFound, message: 'ORA-01403: no data found');
  return b.toBytes();
}

/// Infers the Oracle wire type for column [colIndex]: NUMBER when every
/// non-null value is a representable number, else VARCHAR2.
int _inferColumnOraType(List<List<Object?>> rows, int colIndex) {
  var sawValue = false;
  for (final row in rows) {
    if (colIndex >= row.length) continue;
    final v = row[colIndex];
    if (v == null) continue;
    sawValue = true;
    if (v is num && isOracleNumberRepresentable(v)) continue;
    return _oraTypeVarchar;
  }
  return sawValue ? _oraTypeNumber : _oraTypeVarchar;
}

/// Builds the response for a non-query [result] (DML/DDL): a success ERROR with
/// the affected row count.
Uint8List buildDmlResponse(QueryResult result) {
  final b = WriteBuffer();
  _writeErrorBody(b, num: 0, rowCount: result.affected);
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

/// Writes one column's metadata (NUMBER or VARCHAR2), laid out exactly as the
/// client's `_processColumnInfo` reads it at field version 24.
void _writeColumnInfo(WriteBuffer b, String name, int position, int oraType) {
  final isNumber = oraType == _oraTypeNumber;
  final maxLen = isNumber ? 22 : 4000;
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
    if (cell == null) {
      b.writeBytesWithLength(Uint8List(0)); // 0-length == NULL
    } else if (i < types.length && types[i] == _oraTypeNumber && cell is num) {
      b.writeBytesWithLength(encodeOracleNumber(cell));
    } else {
      b.writeBytesWithLength(Uint8List.fromList(utf8.encode(cell.toString())));
    }
  }
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
