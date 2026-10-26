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
const int _execOptionNotPlSql = 0x8000;
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

  bool get isSuccess => errorNum == null || errorNum == 0;
}

/// Thrown when a column carries a type this increment does not decode yet.
class NativeUnsupportedTypeException implements Exception {
  NativeUnsupportedTypeException(this.oraType);
  final int oraType;
  @override
  String toString() =>
      'NativeUnsupportedTypeException: Oracle type $oraType not supported yet';
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

/// Builds an OALL8 EXECUTE for a row-returning [sql] with no binds. [numIters]
/// is the prefetch row window. A fresh parse always uses cursor id 0.
Uint8List buildQueryExecute(
  String sql, {
  int numIters = 100,
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
  // Query, fresh parse, no binds.
  final options = _execOptionParse |
      _execOptionExecute |
      _execOptionFetch |
      _execOptionNotPlSql;
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

  b.writeUint8(0); // numParams == 0
  b.writeUB4(0);

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

  return b.toBytes();
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

// --- response decode -------------------------------------------------------

class _DecodeState {
  _DecodeState({required this.isQuery, required this.ttcFieldVersion});
  final bool isQuery;
  final int ttcFieldVersion;
  List<NativeColumn> columns = [];
  final List<List<Object?>> rows = [];
  int cursorId = 0;
  int? rowsAffected;
  bool moreRowsToFetch = false;
  bool endOfResponse = false;
  int? errorNum;
  String? errorMessage;
  Uint8List? bitVector;
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
  int ttcFieldVersion = _fieldVersion23_4,
}) {
  final s = _DecodeState(isQuery: isQuery, ttcFieldVersion: ttcFieldVersion);
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
      throw NativeUnsupportedTypeException(-_msgTypeImplicitResultSet);
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

void _processBitVector(ReadBuffer buf, _DecodeState s) {
  final numColsSent = buf.readUB2();
  var numBytes = (s.columns.length / 8).floor();
  if (s.columns.length % 8 > 0) numBytes++;
  if (numBytes <= 0) numBytes = (numColsSent + 7) ~/ 8;
  s.bitVector = buf.readBytes(numBytes);
}

void _processIoVector(ReadBuffer buf, _DecodeState s) {
  // No binds in this increment; a query never ships an IO_VECTOR. Treat its
  // presence as an unsupported shape rather than guessing the byte walk.
  throw NativeUnsupportedTypeException(-_msgTypeIoVector);
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

void _processError(ReadBuffer buf, _DecodeState s) {
  buf.readUB4(); // end of call status
  buf.skipUB2(); // end-to-end seq num
  buf.skipUB4(); // current row number
  buf.skipUB2(); // error number (short)
  buf.skipUB2(); // array elem error
  buf.skipUB2(); // array elem error
  s.cursorId = buf.readUB4();
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
  // Batch error arrays (always 0 here — no array DML in this increment).
  final numErrs = buf.readUB2();
  if (numErrs > 0) {
    final firstByte = buf.readUint8();
    for (var i = 0; i < numErrs; i++) {
      if (firstByte == 0xFE) buf.skipUB4();
      buf.readUB2();
    }
    if (firstByte == 0xFE) buf.skip(1);
  }
  final numOff = buf.readUB4();
  if (numOff > 0) {
    final firstByte = buf.readUint8();
    for (var i = 0; i < numOff; i++) {
      if (firstByte == 0xFE) buf.skipUB4();
      buf.readUB4();
    }
    if (firstByte == 0xFE) buf.skip(1);
  }
  final errMsgArr = buf.readUB2();
  if (errMsgArr > 0) {
    buf.skip(1);
    for (var i = 0; i < errMsgArr; i++) {
      buf.skipUB2();
      buf.readBytesWithLength();
      buf.skip(2);
    }
  }
  final num = buf.readUB4(); // extended error number
  int? rowCount;
  if (s.ttcFieldVersion >= _fieldVersion12_2) {
    rowCount = buf.readUB8();
    if (s.ttcFieldVersion >= 21 /* 20.1 */) {
      buf.skipUB4(); // sql type
      buf.skipUB4(); // server checksum
    }
  }
  String? message;
  if (num != 0) {
    message = utf8.decode(buf.readBytesWithLength(), allowMalformed: true).trim();
  }

  s.errorNum = num;
  if (num != 0) {
    s.errorMessage = message;
  }
  if (s.isQuery && num == 1403) {
    s.errorNum = 0;
    s.moreRowsToFetch = false;
  } else if (s.isQuery && num == 0) {
    s.moreRowsToFetch = true;
  }
  if (!s.isQuery && num == 0) {
    s.rowsAffected = rowCount;
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
