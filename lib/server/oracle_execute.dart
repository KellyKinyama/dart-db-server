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

import 'lexer.dart';
import 'oracle_codec.dart';
import 'oracle_json.dart';
import 'oracle_lob.dart';
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

/// Oracle native JSON data type indicator (Oracle 21c+).
const int _oraTypeJson = 119;

/// Oracle CLOB / BLOB data type indicators.
const int _oraTypeClob = 112;
const int _oraTypeBlob = 113;

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
  LobStore? lobStore,
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
      ? _decodeBinds(body, numParams, ttcFieldVersion, lobStore)
      : const <Object?>[];
  return ExecuteRequestInfo(
    options: options,
    cursorId: cursorId,
    sql: sql,
    numParams: numParams,
    binds: binds,
  );
}

/// Decodes a *native* (thick OCI/OCCI) OALL8 execute body. [body] holds the
/// bytes after the TTC function header (message type, function 0x5E, sequence).
///
/// The native OALL8 argument list is OCI-RPC marshaled (8-byte `FE FF…` pointer
/// indicators, 4-byte little-endian scalars) rather than the thin UB layout, so
/// the fixed header is not walked field-by-field. Instead the SQL text is
/// recovered by scanning for its inline `U8(len)` length-prefixed byte run, and
/// any IN bind values from the trailing `0x07`-prefixed value block (oci8
/// marshals bind values as length-prefixed text after the bind descriptors).
/// Re-executed cursors (no inline SQL) are not yet supported on this path.
ExecuteRequestInfo decodeNativeExecuteRequest(Uint8List body) {
  final sql = _scanNativeSqlText(body);
  final binds = _scanNativeBindValues(body, sql);
  return ExecuteRequestInfo(
    options: 0,
    cursorId: 0,
    sql: sql,
    numParams: binds.length,
    binds: binds,
  );
}

/// Recovers IN bind values from a native OALL8 body. oci8 keeps the `:name`
/// placeholders in the SQL and appends the bound values at the very end as a
/// single `0x07` marker followed by one `U8(len) + bytes` (text) value per
/// distinct placeholder. Returns the values in wire order, or empty when the
/// statement has no binds / the block cannot be located.
List<Object?> _scanNativeBindValues(Uint8List p, String sql) {
  final names = <String>{};
  // Count distinct placeholders with the lexer (not a regex) so a ':' inside a
  // string literal isn't mistaken for a bind — matching how _executeWithBinds
  // maps the values onto the placeholders.
  try {
    for (final tok in Lexer(sql).tokenize()) {
      if (tok.type == TokType.param) names.add(tok.text);
    }
  } catch (_) {
    return const [];
  }
  final n = names.length;
  if (n == 0) return const [];
  // The value block sits at the tail; take the last 0x07 whose n length-
  // prefixed values consume exactly to the end of the payload.
  for (var i = p.length - 1; i >= 0; i--) {
    if (p[i] != 0x07) continue;
    final values = <Object?>[];
    var cur = i + 1;
    var ok = true;
    for (var k = 0; k < n; k++) {
      if (cur >= p.length) {
        ok = false;
        break;
      }
      final len = p[cur++];
      if (len == 0xFD) {
        // NULL bind: a 0xFD marker followed by a 1-byte indicator.
        if (cur >= p.length) {
          ok = false;
          break;
        }
        cur += 1;
        values.add(null);
        continue;
      }
      if (len == 0xFE) {
        // Long bind: a 0xFE marker then LE32(chunkLen)+bytes, terminated by
        // LE32(0) — the same chunked form as a long SQL statement.
        final sb = <int>[];
        var okChunks = true;
        while (cur + 4 <= p.length) {
          final clen = p[cur] |
              (p[cur + 1] << 8) |
              (p[cur + 2] << 16) |
              (p[cur + 3] << 24);
          cur += 4;
          if (clen == 0) break;
          if (clen > 0x100000 || cur + clen > p.length) {
            okChunks = false;
            break;
          }
          sb.addAll(p.sublist(cur, cur + clen));
          cur += clen;
        }
        if (!okChunks) {
          ok = false;
          break;
        }
        values.add(_coerceBind(utf8.decode(sb, allowMalformed: true)));
        continue;
      }
      if (cur + len > p.length) {
        ok = false;
        break;
      }
      values.add(
          _coerceBind(utf8.decode(p.sublist(cur, cur + len), allowMalformed: true)));
      cur += len;
    }
    if (ok && cur == p.length) return values;
  }
  return const [];
}

/// Binds arrive as text; a clean decimal (no leading zeros) is coerced to a
/// number so numeric predicates/inserts match, while leading-zero strings
/// (e.g. `"01234"`) stay text.
Object? _coerceBind(String s) {
  if (RegExp(r'^-?(0|[1-9]\d*)(\.\d+)?$').hasMatch(s)) {
    return num.tryParse(s) ?? s;
  }
  return s;
}

/// The keywords an Oracle statement can lead with, used to tell the SQL text
/// apart from a (possibly longer) string bind value in a native OALL8 body.
const Set<String> _sqlLeadingVerbs = {
  'SELECT', 'INSERT', 'UPDATE', 'DELETE', 'MERGE', 'WITH', 'CREATE', 'DROP',
  'ALTER', 'TRUNCATE', 'BEGIN', 'DECLARE', 'CALL', 'GRANT', 'REVOKE', 'COMMIT',
  'ROLLBACK', 'SAVEPOINT', 'SET', 'EXPLAIN', 'LOCK', 'RENAME', 'COMMENT',
};

/// Whether [s] begins with a SQL statement keyword (its first whitespace- or
/// paren-delimited word).
bool _startsWithSqlVerb(String s) {
  final t = s.trimLeft();
  final end = t.indexOf(RegExp(r'[\s(]'));
  final word = (end < 0 ? t : t.substring(0, end)).toUpperCase();
  return _sqlLeadingVerbs.contains(word);
}

bool _startsWithAsciiLetter(int c) =>
    (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A);

/// Returns the ASCII string of [len] bytes at [start] in [p], or null if any
/// byte is non-printable.
String? _printableAscii(List<int> p, int start, int len) {
  for (var j = start; j < start + len; j++) {
    final c = p[j];
    if (c < 0x20 || c > 0x7E) return null;
  }
  return String.fromCharCodes(p, start, start + len);
}

/// Reads the native "long" string at [i]: a `0xFE` marker then repeated
/// `LE32(chunkLen) + bytes`, terminated by `LE32(0)`. Returns the concatenated
/// bytes, or null if [i] is not a valid long-string header (e.g. an `FE FF…`
/// pointer indicator). Bounded to 1 MiB as a sanity cap.
List<int>? _readNativeLongString(Uint8List p, int i) {
  if (p[i] != 0xFE) return null;
  final out = <int>[];
  var cur = i + 1;
  while (cur + 4 <= p.length) {
    final clen = p[cur] | (p[cur + 1] << 8) | (p[cur + 2] << 16) | (p[cur + 3] << 24);
    cur += 4;
    if (clen == 0) return out.isEmpty ? null : out;
    if (clen > 0x100000 || cur + clen > p.length) return null;
    out.addAll(p.sublist(cur, cur + clen));
    cur += clen;
  }
  return null;
}

/// Finds the statement text in a native OALL8 body. The SQL is marshaled either
/// as a short `U8(len) + bytes` run (len ≤ 253) or, for longer statements, as a
/// `0xFE`-chunked long string (`LE32(len) + bytes`, terminated by `LE32(0)`).
/// The statement leads with a SQL verb and precedes the bind-value block, so the
/// first verb-anchored run (of either form) is the SQL even when a bind value is
/// longer. Falls back to the longest printable run for forms outside the verb
/// set.
String _scanNativeSqlText(Uint8List p) {
  var fallback = '';
  for (var i = 0; i + 1 < p.length; i++) {
    if (p[i] == 0xFE) {
      final bytes = _readNativeLongString(p, i);
      if (bytes != null && bytes.isNotEmpty && _startsWithAsciiLetter(bytes[0])) {
        final text = _printableAscii(bytes, 0, bytes.length);
        if (text != null) {
          if (_startsWithSqlVerb(text)) return text;
          if (text.length > fallback.length) fallback = text;
        }
      }
      continue;
    }
    final len = p[i];
    if (len < 4 || len > 253 || i + 1 + len > p.length) continue;
    if (!_startsWithAsciiLetter(p[i + 1])) continue;
    final text = _printableAscii(p, i + 1, len);
    if (text == null) continue;
    if (_startsWithSqlVerb(text)) return text;
    if (len > fallback.length) fallback = text;
  }
  return fallback;
}

/// Decodes [numParams] bind metadata blocks followed by the single ROW_DATA
/// message carrying the IN bind values, returning the values in wire order.
List<Object?> _decodeBinds(
    ReadBuffer body, int numParams, int fv, LobStore? lobStore) {
  final oraTypes = <int>[];
  final csfrms = <int>[];
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
    csfrms.add(body.readUint8()); // csfrm (2 = NChar for NCLOB)
    body.readUB4(); // LOB prefetch length
    if (fv >= _fv12_2) {
      body.readUB4(); // oaccolid
    }
  }
  if (!body.hasRemaining) {
    return List<Object?>.filled(numParams, null); // all-NULL / no row data
  }
  body.readUint8(); // ROW_DATA message type (7)
  return [
    for (var i = 0; i < oraTypes.length; i++)
      _decodeBindValue(body, oraTypes[i], csfrms[i], lobStore),
  ];
}

/// Decodes one IN bind value. Supported: NUMBER, VARCHAR2/CHAR, RAW, DATE /
/// TIMESTAMP (decoded to an ISO-8601 string the engine stores as text),
/// INTERVAL YEAR TO MONTH / DAY TO SECOND (decoded to a signed literal
/// string), CLOB / BLOB (a bound temporary-LOB locator resolved to its stored
/// text/bytes via [lobStore]), and NULL (a zero-length value). Other types are
/// not yet handled.
Object? _decodeBindValue(
    ReadBuffer body, int oraType, int csfrm, LobStore? lobStore) {
  if (oraType == _oraTypeVector) return _decodeVectorBind(body);
  if (oraType == _oraTypeJson) return _decodeJsonBind(body);
  if (oraType == _oraTypeClob || oraType == _oraTypeBlob) {
    return _decodeLobBind(body, oraType, csfrm == 2, lobStore);
  }
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
  final negative =
      days < 0 || hours < 0 || minutes < 0 || seconds < 0 || fseconds < 0;
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
const int _vectorVersionWithBinary = 1;
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

/// Decodes a VECTOR bind value (type 127) into the engine's [Vector] (dense),
/// an [OracleBinaryVector], or an [OracleSparseVector].
///
/// The client writes a VECTOR bind as a 40-byte value-based QLocator — a UB4
/// byte count (40) then the length-prefixed locator — followed by the
/// length-prefixed vector image (client `_writeQLocator` + `encodeVector`). A
/// NULL arrives as a single zero-length indicator.
Object? _decodeVectorBind(ReadBuffer body) {
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

/// Decodes a native JSON bind value (type 119) into a Dart value (`Map` /
/// `List` / `String` / `num` / `bool` / `null`). The client always writes a
/// JSON bind as the 40-byte value-based QLocator (UB4 byte count then the
/// length-prefixed locator) followed by the length-prefixed OSON document —
/// a NULL travels as the OSON scalar null, not a zero-length indicator.
Object? _decodeJsonBind(ReadBuffer body) {
  body.readUB4(); // QLocator byte count (40)
  body.readBytesWithLength(); // 40-byte value-based QLocator (ignored)
  final oson = body.readBytesWithLength();
  return decodeOson(oson);
}

/// Decodes a bound CLOB (112) / BLOB (113) value: the client writes a UB4
/// locator length then the length-prefixed locator bytes of a temporary LOB it
/// created via `ttcLobOp` CREATE_TEMP. [lobStore] resolves the locator to its
/// stored bytes — decoded to a `String` for CLOB (UTF-8) / NCLOB (UTF-16BE, the
/// engine stores text) or raw `Uint8List` for BLOB. A zero-length locator is
/// SQL NULL.
Object? _decodeLobBind(
    ReadBuffer body, int oraType, bool isNClob, LobStore? lobStore) {
  body.readUB4(); // locator length
  final locator = body.readBytesWithLength();
  if (locator.isEmpty) return null; // SQL NULL
  final bytes = lobStore?.resolve(locator) ?? Uint8List(0);
  if (oraType == _oraTypeClob) {
    return isNClob
        ? _decodeUtf16Be(Uint8List.fromList(bytes))
        : utf8.decode(bytes, allowMalformed: true);
  }
  return Uint8List.fromList(bytes);
}

/// Decodes UTF-16 big-endian bytes (Oracle national charset AL16UTF16).
String _decodeUtf16Be(Uint8List bytes) {
  final units = <int>[];
  for (var i = 0; i + 1 < bytes.length; i += 2) {
    units.add((bytes[i] << 8) | bytes[i + 1]);
  }
  return String.fromCharCodes(units);
}

/// Decodes a VECTOR image into the engine's dense [Vector] (`Float32List`) for
/// FLOAT32 / FLOAT64 / INT8, an [OracleBinaryVector] for a packed BINARY
/// vector, or an [OracleSparseVector] for a sparse one — inverting the client's
/// `encodeVector`. FLOAT32 / FLOAT64 elements are read from Oracle's
/// byte-comparable IEEE form. Dense vectors become the engine's indexable
/// `Float32` type; BINARY and sparse vectors are carried verbatim (the engine
/// stores them unchanged) and re-encoded on fetch.
Object _decodeVectorImage(Uint8List image) {
  if (image.length < _vectorImageHeaderLength || image[0] != _vectorMagicByte) {
    throw const FormatException('malformed VECTOR image');
  }
  final data = ByteData.sublistView(image);
  final version = image[1];
  if (version > _vectorVersionWithSparse) {
    throw FormatException('unsupported VECTOR image version $version');
  }
  final flags = data.getUint16(2);
  final format = image[4];
  final numDimensions = data.getUint32(5);
  var pos = _vectorImageHeaderLength;
  if (format == _vectorFormatBinary || (flags & _vectorFlagNorm) != 0) {
    pos += _vectorNormLength; // skip the norm (or its reserved space)
  }
  final sparse = (flags & _vectorFlagSparse) != 0;
  List<int>? indices;
  var count = numDimensions; // dense element count (dimensions)
  if (sparse) {
    final numElements = data.getUint16(pos);
    pos += 2;
    indices = <int>[
      for (var i = 0; i < numElements; i++, pos += 4) data.getUint32(pos)
    ];
    count = numElements;
  } else if (format == _vectorFormatBinary) {
    // A dense BINARY vector packs 8 dimensions per byte.
    final nbytes = numDimensions ~/ 8;
    return OracleBinaryVector(
        numDimensions, Uint8List.fromList(image.sublist(pos, pos + nbytes)));
  }
  final values = <num>[];
  switch (format) {
    case _vectorFormatFloat32:
      for (var i = 0; i < count; i++, pos += 4) {
        values.add(_readComparableFloat32(data, pos));
      }
    case _vectorFormatFloat64:
      for (var i = 0; i < count; i++, pos += 8) {
        values.add(_readComparableFloat64(data, pos));
      }
    case _vectorFormatInt8:
      for (var i = 0; i < count; i++, pos += 1) {
        final b = image[pos];
        values.add(b > 127 ? b - 256 : b);
      }
    case _vectorFormatBinary:
      for (var i = 0; i < count; i++, pos += 1) {
        values.add(image[pos]);
      }
    default:
      throw FormatException('unsupported VECTOR format $format');
  }
  if (sparse) {
    return OracleSparseVector(
        numDimensions: numDimensions,
        indices: indices!,
        values: values,
        format: format);
  }
  // Dense FLOAT32/FLOAT64/INT8 become the engine's indexable Float32 vector.
  return Vector(Float32List.fromList([for (final v in values) v.toDouble()]));
}

/// A packed BINARY VECTOR value (8 dimensions per byte) the engine stores
/// verbatim. [bytes] length × 8 == [numDimensions].
class OracleBinaryVector {
  OracleBinaryVector(this.numDimensions, this.bytes);
  final int numDimensions;
  final Uint8List bytes;
}

/// A sparse VECTOR value (only [indices] carry non-zero [values]) in one of the
/// VECTOR element formats, stored verbatim by the engine.
class OracleSparseVector {
  OracleSparseVector({
    required this.numDimensions,
    required this.indices,
    required this.values,
    required this.format,
  });
  final int numDimensions;
  final List<int> indices;
  final List<num> values;
  final int format;
}

/// Wire element size for a VECTOR format.
int _vectorElementSize(int format) => switch (format) {
      _vectorFormatFloat32 => 4,
      _vectorFormatFloat64 => 8,
      _ => 1, // INT8 / BINARY
    };

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

/// Encodes an [OracleBinaryVector] into a BINARY VECTOR image (client
/// `encodeVector` for a `Uint8List`): version 1, flags NORMSRC (the norm space
/// is reserved, never set), element count = bytes × 8, then the packed bytes.
Uint8List _encodeBinaryVectorImage(OracleBinaryVector v) {
  final size = _vectorImageHeaderLength + _vectorNormLength + v.bytes.length;
  final image = Uint8List(size);
  final data = ByteData.sublistView(image);
  image[0] = _vectorMagicByte;
  image[1] = _vectorVersionWithBinary;
  data.setUint16(2, _vectorFlagNormSrc);
  image[4] = _vectorFormatBinary;
  data.setUint32(5, v.bytes.length * 8);
  image.setRange(_vectorImageHeaderLength + _vectorNormLength,
      _vectorImageHeaderLength + _vectorNormLength + v.bytes.length, v.bytes);
  return image;
}

/// Encodes an [OracleSparseVector] into a sparse VECTOR image (client
/// `encodeVector` for an `OracleSparseVector`): version 2, [_vectorFlagSparse]
/// added, element count = the dimension count, then a UInt16 non-zero count,
/// the UInt32 indices, and the values in the vector's format.
Uint8List _encodeSparseVectorImage(OracleSparseVector v) {
  final elementSize = _vectorElementSize(v.format);
  final size = _vectorImageHeaderLength +
      _vectorNormLength +
      2 +
      v.indices.length * 4 +
      v.values.length * elementSize;
  final image = Uint8List(size);
  final data = ByteData.sublistView(image);
  image[0] = _vectorMagicByte;
  image[1] = _vectorVersionWithSparse;
  var flags = _vectorFlagSparse;
  if (v.format != _vectorFormatBinary) {
    flags |= _vectorFlagNormSrc | _vectorFlagNorm;
  }
  data.setUint16(2, flags);
  image[4] = v.format;
  data.setUint32(5, v.numDimensions);
  var pos = _vectorImageHeaderLength + _vectorNormLength;
  data.setUint16(pos, v.indices.length);
  pos += 2;
  for (final idx in v.indices) {
    data.setUint32(pos, idx);
    pos += 4;
  }
  for (final val in v.values) {
    switch (v.format) {
      case _vectorFormatFloat32:
        _writeComparableFloat32(data, pos, val.toDouble());
        pos += 4;
      case _vectorFormatFloat64:
        _writeComparableFloat64(data, pos, val.toDouble());
        pos += 8;
      default: // INT8 / BINARY
        image[pos] = val.toInt() & 0xFF;
        pos += 1;
    }
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

/// Writes [value] as a FLOAT64 element in Oracle's byte-comparable form
/// (client `_writeComparableFloat64`).
void _writeComparableFloat64(ByteData data, int pos, double value) {
  _floatScratch.setFloat64(0, value);
  var hi = _floatScratch.getUint32(0);
  var lo = _floatScratch.getUint32(4);
  if ((hi & 0x80000000) == 0) {
    hi |= 0x80000000;
  } else {
    hi = ~hi & 0xFFFFFFFF;
    lo = ~lo & 0xFFFFFFFF;
  }
  data
    ..setUint32(pos, hi)
    ..setUint32(pos + 4, lo);
}

/// Builds the response for a query [result]: DESCRIBE_INFO, one ROW_HEADER, a
/// ROW_DATA per row, and a terminal ORA-01403 (end of fetch). [cursorId] is
/// echoed so the client can cache the statement. [lobStore] mints the locators
/// for CLOB/BLOB columns. Returns the TTC body (no TNS framing).
Uint8List buildQueryResponse(QueryResult result,
    {int cursorId = 0, LobStore? lobStore}) {
  final b = WriteBuffer();
  // Prefer each column's declared type (CLOB/BLOB/JSON/VECTOR); fall back to
  // value inference (NUMBER / RAW / VARCHAR2) when it is unknown.
  final types = [
    for (var i = 0; i < result.columns.length; i++) _columnOraType(result, i),
  ];
  // Parallel flag: NCLOB columns (wire type 112 like CLOB, but national
  // charset — described with csfrm=2 and sent as UTF-16BE).
  final nclob = [
    for (var i = 0; i < result.columns.length; i++) _isNClobColumn(result, i),
  ];
  _writeDescribeInfo(b, result.columns, types, nclob);
  _writeRowHeader(b);
  for (final row in result.rows) {
    _writeRowData(b, row, types, nclob, lobStore);
  }
  _writeErrorBody(b,
      num: _oraNoDataFound,
      cursorId: cursorId,
      message: 'ORA-01403: no data found');
  return b.toBytes();
}

/// The Oracle wire type for result column [colIndex]: the declared column type
/// (CLOB/BLOB/JSON/VECTOR) when known, else value inference.
int _columnOraType(QueryResult result, int colIndex) {
  final declared =
      result.columnTypes != null && colIndex < result.columnTypes!.length
          ? result.columnTypes![colIndex]
          : null;
  if (declared != null) {
    final t = _oraTypeForDeclared(declared);
    if (t != null) return t;
  }
  return _inferColumnOraType(result.rows, colIndex);
}

/// Maps a declared DDL type token to its Oracle wire type, or null when the
/// type is not one the describe layer special-cases.
int? _oraTypeForDeclared(String declared) {
  final d = declared.toLowerCase();
  if (d.contains('clob')) return _oraTypeClob; // CLOB and NCLOB
  if (d.contains('blob')) return _oraTypeBlob;
  if (d.contains('json')) return _oraTypeJson;
  if (d.contains('vector')) return _oraTypeVector;
  return null;
}

/// True when column [colIndex] is declared `NCLOB` (national-charset CLOB).
bool _isNClobColumn(QueryResult result, int colIndex) {
  final declared =
      result.columnTypes != null && colIndex < result.columnTypes!.length
          ? result.columnTypes![colIndex]
          : null;
  return declared != null && declared.toLowerCase().contains('nclob');
}

/// Infers the Oracle wire type for column [colIndex]: VECTOR when every
/// non-null value is a [Vector], JSON when every non-null value is a `Map` or
/// `List`, NUMBER when every non-null value is a representable number, RAW
/// when every value is a byte buffer, else VARCHAR2.
int _inferColumnOraType(List<List<Object?>> rows, int colIndex) {
  var sawValue = false;
  var allNumber = true;
  var allRaw = true;
  var allVector = true;
  var allJson = true;
  for (final row in rows) {
    if (colIndex >= row.length) continue;
    final v = row[colIndex];
    if (v == null) continue;
    sawValue = true;
    if (!(v is num && isOracleNumberRepresentable(v))) allNumber = false;
    if (v is! Uint8List) allRaw = false;
    if (!(v is Vector || v is OracleBinaryVector || v is OracleSparseVector)) {
      allVector = false;
    }
    if (!((v is Map || v is List) && v is! Uint8List)) allJson = false;
    if (!allNumber && !allRaw && !allVector && !allJson) return _oraTypeVarchar;
  }
  if (!sawValue) return _oraTypeVarchar;
  if (allVector) return _oraTypeVector;
  if (allJson) return _oraTypeJson;
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

void _writeDescribeInfo(
    WriteBuffer b, List<String> columns, List<int> types, List<bool> nclob) {
  b.writeUint8(ttcMsgTypeDescribeInfo);
  b.writeBytesWithLength(Uint8List(0)); // version bytes
  b.writeUB4(0); // max row size
  b.writeUB4(columns.length); // column count
  if (columns.isNotEmpty) {
    b.writeUint8(0); // one spare UB1 the client skips
  }
  for (var i = 0; i < columns.length; i++) {
    _writeColumnInfo(b, columns[i], i + 1, types[i], nclob[i]);
  }
  b.writeUB4(0); // current date bytes
  b.writeUB4(0); // dcbflag
  b.writeUB4(0); // dcbmdbz
  b.writeUB4(0); // dcbmnpr
  b.writeUB4(0); // dcbmxpr
  b.writeUB4(0); // tail bytes
}

/// Writes one column's metadata (NUMBER, RAW, VARCHAR2, or VECTOR), laid out
/// Writes one column's metadata (NUMBER, RAW, VARCHAR2, VECTOR, JSON, or
/// CLOB/BLOB), laid out exactly as the client's `_processColumnInfo` reads it
/// at field version 24.
void _writeColumnInfo(
    WriteBuffer b, String name, int position, int oraType, bool nclob) {
  final maxLen = oraType == _oraTypeNumber
      ? 22
      : oraType == _oraTypeRaw
          ? 2000
          : oraType == _oraTypeVector
              ? 8200
              : oraType == _oraTypeJson
                  ? 8200
                  : (oraType == _oraTypeClob || oraType == _oraTypeBlob)
                      ? 4000
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
  b.writeUint8(nclob ? 2 : 0); // csfrm (2 = NChar for NCLOB, else implicit)
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

void _writeRowData(WriteBuffer b, List<Object?> row, List<int> types,
    List<bool> nclob, LobStore? lobStore) {
  b.writeUint8(ttcMsgTypeRowData);
  for (var i = 0; i < row.length; i++) {
    final cell = row[i];
    final type = i < types.length ? types[i] : _oraTypeVarchar;
    if (type == _oraTypeVector) {
      _writeVectorColumn(b, cell);
    } else if (type == _oraTypeJson) {
      _writeJsonColumn(b, cell);
    } else if (type == _oraTypeClob || type == _oraTypeBlob) {
      _writeLobColumn(b, cell, type == _oraTypeClob,
          i < nclob.length && nclob[i], lobStore);
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

/// Writes a CLOB (112) / BLOB (113) column value as a LOB locator the client
/// reads back with a `ttcLobOp` READ (client `execute_message` `oraTypeClob` /
/// `oraTypeBlob`): a UB4 locator length (0 ⇒ SQL NULL), UB8 LOB length
/// (characters for CLOB, bytes for BLOB), UB4 chunk size, then the
/// length-prefixed locator. [lobStore] mints a server LOB holding the value.
/// When [isNClob] the body is stored as UTF-16BE and the locator is flagged
/// national-charset so the client decodes it as UTF-16.
void _writeLobColumn(WriteBuffer b, Object? cell, bool isClob, bool isNClob,
    LobStore? lobStore) {
  if (cell == null || lobStore == null) {
    b.writeUB4(0); // SQL NULL
    return;
  }
  final List<int> bytes;
  final int lobLength;
  if (isClob) {
    final text = cell is String ? cell : cell.toString();
    bytes = isNClob ? _encodeUtf16Be(text) : utf8.encode(text);
    lobLength = text.length; // characters (UTF-16 code units)
  } else {
    bytes = cell is Uint8List ? cell : Uint8List.fromList(const <int>[]);
    lobLength = bytes.length;
  }
  final locator = lobStore.createColumnLob(bytes, nationalCharset: isNClob);
  b.writeUB4(locator.length); // locator length
  b.writeUB8(lobLength); // LOB length (chars for CLOB, bytes for BLOB)
  b.writeUB4(lobChunkSize); // chunk size
  b.writeBytesWithLength(locator);
}

/// Encodes [s] as UTF-16 big-endian (Oracle national charset AL16UTF16).
Uint8List _encodeUtf16Be(String s) {
  final units = s.codeUnits; // UTF-16 code units
  final out = Uint8List(units.length * 2);
  for (var i = 0; i < units.length; i++) {
    out[i * 2] = (units[i] >> 8) & 0xFF;
    out[i * 2 + 1] = units[i] & 0xFF;
  }
  return out;
}

/// Writes a VECTOR column value in the LOB-prefetch inline shape the client's
/// VECTOR column decoder reads (client `execute_message` `oraTypeVector`): a
/// UB4 marker (0 ⇒ SQL NULL), UB8 size and UB4 chunk size (unused), the
/// length-prefixed vector image, then an empty length-prefixed locator. A dense
/// [Vector] encodes as FLOAT32; [OracleBinaryVector] / [OracleSparseVector]
/// re-encode their original format.
void _writeVectorColumn(WriteBuffer b, Object? cell) {
  final Uint8List? image = cell is Vector
      ? _encodeVectorImage(cell)
      : cell is OracleBinaryVector
          ? _encodeBinaryVectorImage(cell)
          : cell is OracleSparseVector
              ? _encodeSparseVectorImage(cell)
              : null;
  if (image == null) {
    b.writeUB4(0); // SQL NULL
    return;
  }
  b.writeUB4(image.length); // marker / locator length (non-zero)
  b.writeUB8(image.length); // size (unused by the client)
  b.writeUB4(0); // chunk size (unused)
  b.writeBytesWithLength(image);
  b.writeBytesWithLength(Uint8List(0)); // locator (unused)
}

/// Writes a native JSON column value in the LOB-prefetch inline shape the
/// client's JSON column decoder reads (client `execute_message` `oraTypeJson`):
/// a UB4 marker (0 ⇒ SQL NULL), UB8 size and UB4 chunk size (unused), the
/// length-prefixed OSON document, then an empty length-prefixed locator.
void _writeJsonColumn(WriteBuffer b, Object? cell) {
  if (cell == null) {
    b.writeUB4(0); // SQL NULL
    return;
  }
  final oson = encodeOson(cell);
  b.writeUB4(oson.length); // marker / locator length (non-zero)
  b.writeUB8(oson.length); // size (unused)
  b.writeUB4(0); // chunk size (unused)
  b.writeBytesWithLength(oson);
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
