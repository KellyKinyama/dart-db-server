/// A pure-Dart *native* (thick OCI/OCCI, TTC v320) Oracle client.
///
/// This is the importable, self-contained counterpart to the thin
/// `package:oracledb` driver: it speaks the native wire dialect an Instant
/// Client / `oci8` / OCCI program uses, so a consumer can exercise the server's
/// native path without a real Instant Client installed.
///
/// It runs the full native exchange end to end:
///   * the native CONNECT with the out-of-line descriptor "overflow" flow that
///     tags the session as native;
///   * the break/reset self-test, FAST_AUTH decline, and classical
///     DATA-TYPES / AUTH_PHASE_ONE / AUTH_PHASE_TWO negotiation;
///   * the O5LOGON / PBKDF2 client crypto and AUTH_SVR_RESPONSE mutual-auth
///     validation;
///   * a full statement round-trip — [OracleThickClient.query] /
///     [OracleThickClient.execute] encode a native OALL8 EXECUTE (plus FETCH
///     pagination for large result sets) and decode the describe / row / status
///     stream back into columns, rows, or an affected-row count.
///
/// Only the subset of types the server emits is decoded: NUMBER (base-100) and
/// VARCHAR2 (UTF-8). That matches the server's native response encoder.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dart_db_server/server/oracle_codec.dart';
import 'package:dart_db_server/server/oracle_crypto.dart';
import 'package:dart_db_server/server/oracle_number.dart';
import 'package:dart_db_server/server/oracle_ttc.dart' show ttcMsgDataTypes;
import 'package:dart_db_server/oracle_native_handshake.dart' as hs;
import 'package:dart_db_server/oracle_native_execute.dart' as ex;

const int _tnsHeaderSize = 8;
const int _tnsPacketConnect = 1;
const int _tnsPacketData = 6;
const int _tnsPacketMarker = 12;
const int _ttcMsgTypeFunction = 3;
const int _ttcAuthPhaseOne = 0x76;
const int _ttcAuthPhaseTwo = 0x73;
const int _ttcMsgTypeParameter = 8;
const int _ttcMsgTypeFastAuth = 34;

/// Function code of the OALL8 execute call (94 = 0x5E).
const int _ttcFuncExecute = 0x5E;

/// Default rows per native fetch batch (mirrors the server's `nativeBatchSize`).
const int _nativeBatchSize = 100;

/// TTI end-of-call marker: the last byte of every native EXECUTE/FETCH response.
const int _ttiEndOfCall = 0x1d;

const String _defaultDescriptor =
    '(DESCRIPTION=(CONNECT_DATA=(SERVICE_NAME=FREEPDB1)))';

// --- TNS framing -----------------------------------------------------------

/// Wraps a TTC body in a DATA packet using the 4-byte large-SDU length header.
/// [dataFlags] carries the 2-byte data flags (0x0800 END_OF_RPC on 23ai+).
Uint8List _wrapData(Uint8List ttc, {int dataFlags = 0}) {
  final out = BytesBuilder();
  final header = ByteData(_tnsHeaderSize);
  header.setUint32(0, _tnsHeaderSize + 2 + ttc.length);
  header.setUint8(4, _tnsPacketData);
  out.add(header.buffer.asUint8List());
  out.add([(dataFlags >> 8) & 0xFF, dataFlags & 0xFF]);
  out.add(ttc);
  return out.toBytes();
}

/// The TTC body of a received DATA frame (strips the 8-byte header + 2 flags).
Uint8List _ttcBody(Uint8List frame) =>
    Uint8List.sublistView(frame, _tnsHeaderSize + 2);

/// Builds a native CONNECT packet. By default (dart-db-server) the descriptor
/// length is announced but the descriptor itself is *not* inline (the offset
/// points just past this packet), so the server treats it as the overflow flow
/// and marks the session native.
///
/// Set [inline] for the standard real-Oracle CONNECT: the descriptor is
/// appended inside the packet and the v315+ large SDU/TDU fields are populated,
/// matching what a real listener (Oracle docker / Instant Client) expects. In
/// that mode the follow-up descriptor packet must be skipped.
Uint8List buildNativeConnect({
  String descriptor = _defaultDescriptor,
  int versionDesired = 320,
  int versionMinimum = 300,
  int serviceOptions = 0x0C41,
  int sdu = 8192,
  int tdu = 0xFFFF,
  int connectFlags0 = 0x41,
  int connectFlags1 = 0x41,
  bool inline = false,
}) {
  final descBytes = utf8.encode(descriptor);
  final descLen = descBytes.length;
  const bodyLen = 66;
  final body = ByteData(bodyLen);
  if (inline) {
    // Standard real-Oracle CONNECT body (mirrors the thin driver). Big-endian.
    body.setUint16(0, versionDesired);
    body.setUint16(2, versionMinimum);
    body.setUint16(4, 0x0001); // options: DONT_CARE
    body.setUint16(6, 8192); // SDU
    body.setUint16(8, 32767); // TDU
    body.setUint16(10, 0); // NT characteristics
    body.setUint16(12, 0); // line turnaround
    body.setUint16(14, 1); // endianness marker
    body.setUint16(16, descLen); // connect-data length
    body.setUint16(18, _tnsHeaderSize + bodyLen); // data offset (74)
    body.setUint16(20, 230); // max connect data
    body.setUint16(22, 0); // reserved
    body.setUint8(24, 0x04); // connect flags 0: NA disabled
    body.setUint8(25, 0x04); // connect flags 1: NA disabled
    body.setUint32(50, 8192); // large SDU (v315+)
    body.setUint32(54, 32767); // large TDU (v315+)
  } else {
    body.setUint16(0, versionDesired);
    body.setUint16(2, versionMinimum);
    body.setUint16(4, serviceOptions);
    body.setUint16(6, sdu);
    body.setUint16(8, tdu);
    body.setUint16(14, 1); // endianness marker
    body.setUint16(16, descLen); // connect-data length (announced)
    body.setUint16(18, _tnsHeaderSize + bodyLen); // offset past this packet
    body.setUint32(20, 0x00200000); // maximum receivable connect data
    body.setUint8(24, connectFlags0);
    body.setUint8(25, connectFlags1);
  }

  final packetLen = _tnsHeaderSize + bodyLen + (inline ? descLen : 0);
  final header = ByteData(_tnsHeaderSize);
  header.setUint16(0, packetLen);
  header.setUint8(4, _tnsPacketConnect);
  final out = BytesBuilder()
    ..add(header.buffer.asUint8List())
    ..add(body.buffer.asUint8List());
  if (inline) out.add(descBytes);
  return out.toBytes();
}

/// The follow-up DATA packet carrying the descriptor after a native CONNECT.
Uint8List buildDescriptorPacket({String descriptor = _defaultDescriptor}) {
  final desc = utf8.encode(descriptor);
  final header = ByteData(_tnsHeaderSize);
  header.setUint16(0, _tnsHeaderSize + 2 + desc.length);
  header.setUint8(4, _tnsPacketData);
  return (BytesBuilder()
        ..add(header.buffer.asUint8List())
        ..add(const [0, 0]) // data flags
        ..add(desc))
      .toBytes();
}

/// A RESET marker (4-byte large-SDU framing) for the break/reset self-test.
Uint8List buildResetMarker() {
  final header = ByteData(_tnsHeaderSize);
  header.setUint32(0, _tnsHeaderSize + 3);
  header.setUint8(4, _tnsPacketMarker);
  return (BytesBuilder()
        ..add(header.buffer.asUint8List())
        ..add(const [1, 0, 2]))
      .toBytes();
}

Uint8List _dataTypesRequest() {
  final b = BytesBuilder();
  b.addByte(ttcMsgDataTypes);
  b.add(const [0, 0]);
  return b.toBytes();
}

/// Reassembles whole TNS frames from a socket's byte stream. The ACCEPT (first
/// frame) uses 2-byte framing; thereafter the client switches to the 4-byte
/// large-SDU length header for all DATA packets (negotiated v >= 315).
class _FrameReader {
  _FrameReader(Stream<Uint8List> socket) {
    _sub = socket.listen((chunk) {
      _buf = _concat(_buf, chunk);
      _drain();
    });
  }

  late final StreamSubscription<Uint8List> _sub;
  Uint8List _buf = Uint8List(0);
  bool _largeSdu = false;
  final _queue = <Uint8List>[];
  final _waiters = <Completer<Uint8List>>[];

  static Uint8List _concat(Uint8List a, Uint8List b) =>
      Uint8List(a.length + b.length)
        ..setRange(0, a.length, a)
        ..setRange(a.length, a.length + b.length, b);

  void _drain() {
    while (_buf.length >= (_largeSdu ? 8 : 2)) {
      final len = _largeSdu
          ? (_buf[0] << 24) | (_buf[1] << 16) | (_buf[2] << 8) | _buf[3]
          : (_buf[0] << 8) | _buf[1];
      if (_buf.length < len) break;
      final frame = Uint8List.fromList(Uint8List.sublistView(_buf, 0, len));
      _buf = Uint8List.fromList(Uint8List.sublistView(_buf, len));
      _largeSdu = true; // the ACCEPT is the only 2-byte reply
      if (_waiters.isNotEmpty) {
        _waiters.removeAt(0).complete(frame);
      } else {
        _queue.add(frame);
      }
    }
  }

  Future<Uint8List> next() {
    if (_queue.isNotEmpty) return Future.value(_queue.removeAt(0));
    final c = Completer<Uint8List>();
    _waiters.add(c);
    return c.future.timeout(const Duration(seconds: 5), onTimeout: () {
      _sub.cancel();
      throw StateError('timed out waiting for a TNS frame');
    });
  }

  Future<void> cancel() => _sub.cancel();
}

// --- native AUTH marshaling ------------------------------------------------

/// Builds a native-format AUTH message body (no TNS framing) for [functionCode]
/// (AUTH_PHASE_ONE `0x76` or AUTH_PHASE_TWO `0x73`).
Uint8List buildNativeAuthMessage({
  required int functionCode,
  required String username,
  int authMode = 0x8001,
  int sequence = 2,
  Map<String, String> pairs = const {
    'AUTH_TERMINAL': 'unknown',
    'AUTH_PROGRAM_NM': 'dart-thick',
    'AUTH_MACHINE': 'localhost',
    'AUTH_PID': '0',
    'AUTH_SID': 'test',
  },
}) {
  final user = utf8.encode(username);
  final b = WriteBuffer();
  b.writeUint8(_ttcMsgTypeFunction);
  b.writeUint8(functionCode);
  b.writeUint8(sequence);
  _writeIndicator(b);
  b.writeUint32LE(user.length);
  b.writeUint32LE(authMode);
  _writeIndicator(b);
  b.writeUint32LE(pairs.length);
  _writeIndicator(b);
  _writeIndicator(b);
  b.writeUint8(user.length);
  b.writeBytes(Uint8List.fromList(user));
  pairs.forEach((key, value) => _writeNativeKeyValue(b, key, value));
  return b.toBytes();
}

void _writeIndicator(WriteBuffer b) {
  b.writeUint8(0xFE);
  for (var i = 0; i < 7; i++) {
    b.writeUint8(0xFF);
  }
}

void _writeNativeKeyValue(WriteBuffer b, String key, String value) {
  final k = utf8.encode(key);
  final v = utf8.encode(value);
  b.writeUint32LE(k.length);
  b.writeUint8(k.length);
  b.writeBytes(Uint8List.fromList(k));
  b.writeUint32LE(v.length);
  if (v.isNotEmpty) {
    b.writeUint8(v.length);
    b.writeBytes(Uint8List.fromList(v));
  }
  b.writeUint32LE(0); // flags
}

final _random = Random.secure();

Uint8List _randomBytes(int n) =>
    Uint8List.fromList(List<int>.generate(n, (_) => _random.nextInt(256)));

/// Derives the 12c PBKDF2 verifier hash.
Uint8List _pbkdf2PasswordHash(String password, Uint8List salt, int iterations) {
  final extendedSalt =
      Uint8List.fromList([...salt, ...utf8.encode('AUTH_PBKDF2_SPEEDY_KEY')]);
  final derived = pbkdf2Sha512(
    password: Uint8List.fromList(utf8.encode(password)),
    salt: extendedSalt,
    iterations: iterations,
    keyLength: 64,
  );
  return Uint8List.sublistView(
      sha512(Uint8List.fromList([...derived, ...salt])), 0, 32);
}

/// Parses a native parameter response (message type 8).
Map<String, String> _parseNativeResponseParams(Uint8List body) {
  final r = ReadBuffer(body);
  r.readUint8(); // message type (8)
  final count = r.readUint16LE();
  final out = <String, String>{};
  for (var i = 0; i < count && r.hasRemaining; i++) {
    r.readUint32LE(); // key length (redundant)
    final key = utf8.decode(r.readBytes(r.readUint8()));
    final declared = r.readUint32LE();
    var value = '';
    if (declared != 0) {
      final marker = r.readUint8();
      if (marker == 0xFE) {
        final bytes = <int>[];
        for (var size = r.readUint32LE(); size != 0; size = r.readUint32LE()) {
          bytes.addAll(r.readBytes(size));
        }
        value = utf8.decode(bytes);
      } else {
        value = utf8.decode(r.readBytes(marker));
      }
    }
    r.readUint32LE(); // flags
    out[key] = value;
  }
  return out;
}

/// The client half of the O5LOGON/PBKDF2 exchange, derived from a phase-one
/// challenge. Produces the phase-two `AUTH_SESSKEY`/`AUTH_PASSWORD` proof and
/// validates the server's `AUTH_SVR_RESPONSE`.
class _NativeO5Logon {
  _NativeO5Logon._(this._comboKey, this.clientSessKeyHex, this.authPasswordHex);

  final Uint8List _comboKey;
  final String clientSessKeyHex;
  final String authPasswordHex;

  factory _NativeO5Logon.fromChallenge({
    required String password,
    required Map<String, String> challenge,
  }) {
    final iv = Uint8List(16);
    final salt = hexDecode(challenge['AUTH_VFR_DATA']!);
    final iterations = int.parse(challenge['AUTH_PBKDF2_VGEN_COUNT']!);
    final mixingSalt = hexDecode(challenge['AUTH_PBKDF2_CSK_SALT']!);
    final mixingIterations = int.parse(challenge['AUTH_PBKDF2_SDER_COUNT']!);
    final serverSessKey = hexDecode(challenge['AUTH_SESSKEY']!);

    final passwordHash = _pbkdf2PasswordHash(password, salt, iterations);
    final serverNonce =
        aes256CbcDecryptRaw(key: passwordHash, iv: iv, data: serverSessKey);
    final clientNonce = _randomBytes(serverNonce.length);
    final clientSessKey =
        aes256CbcEncryptRaw(key: passwordHash, iv: iv, data: clientNonce);
    final partAB = Uint8List(64)
      ..setRange(0, 32, clientNonce)
      ..setRange(32, 64, serverNonce);
    final comboKey = pbkdf2Sha512(
      password: Uint8List.fromList(utf8.encode(hexEncodeUpper(partAB))),
      salt: mixingSalt,
      iterations: mixingIterations,
      keyLength: 32,
    );
    final authPassword = aes256CbcEncryptPkcs7(
      key: comboKey,
      iv: iv,
      data: Uint8List.fromList([..._randomBytes(16), ...utf8.encode(password)]),
    );
    return _NativeO5Logon._(
      comboKey,
      hexEncodeUpper(clientSessKey),
      hexEncodeUpper(authPassword),
    );
  }

  Map<String, String> phaseTwoPairs() => {
        'AUTH_SESSKEY': clientSessKeyHex,
        'AUTH_PASSWORD': authPasswordHex,
        'AUTH_TERMINAL': 'dart-thick',
        'AUTH_PROGRAM_NM': 'dart-thick',
        'AUTH_MACHINE': 'localhost',
        'AUTH_PID': '0',
        'AUTH_SID': 'test',
      };

  bool verifyServerResponse(String? responseHex) {
    if (responseHex == null) return false;
    final plain = aes256CbcDecryptRaw(
        key: _comboKey, iv: Uint8List(16), data: hexDecode(responseHex));
    if (plain.length < 32) return false;
    return utf8.decode(plain.sublist(16, 32)) == 'SERVER_TO_CLIENT';
  }
}

/// The outcome of [OracleThickClient.login].
class NativeLoginResult {
  NativeLoginResult({required this.authenticated, required this.params});

  /// Whether the server's AUTH_SVR_RESPONSE mutual-auth proof validated.
  final bool authenticated;

  /// The session parameters the server returned on success (empty on failure).
  final Map<String, String> params;
}

/// An `ORA-xxxxx` error surfaced by a native EXECUTE.
class OracleThickException implements Exception {
  OracleThickException(this.code, this.message);

  /// The ORA error number (e.g. 942 for `ORA-00942`).
  final int code;

  /// The error text (with the `ORA-xxxxx:` prefix, as the server sent it).
  final String message;

  @override
  String toString() => 'OracleThickException($code): $message';
}

/// The result of running a statement with [OracleThickClient.run].
class OracleThickResult {
  OracleThickResult.query(this.columns, this.rows)
      : affected = 0,
        isQuery = true;

  OracleThickResult.dml(this.affected)
      : columns = const [],
        rows = const [],
        isQuery = false;

  /// Column names (empty for a non-query).
  final List<String> columns;

  /// Row values, each a list aligned to [columns]. NUMBER columns decode to
  /// `num`, VARCHAR2 to `String`, and a NULL to `null`.
  final List<List<Object?>> rows;

  /// Rows affected by an INSERT/UPDATE/DELETE (0 for a query or DDL).
  final int affected;

  /// Whether this came from a row-returning statement.
  final bool isQuery;
}

// --- native EXECUTE request / response codecs ------------------------------

void _u32le(WriteBuffer b, int v) {
  b.writeUint8(v & 0xFF);
  b.writeUint8((v >> 8) & 0xFF);
  b.writeUint8((v >> 16) & 0xFF);
  b.writeUint8((v >> 24) & 0xFF);
}

int _le32(Uint8List b, int off) =>
    b[off] | (b[off + 1] << 8) | (b[off + 2] << 16) | (b[off + 3] << 24);

/// True when [body] contains the ASCII of [needle] at or after [start] — used
/// to tell a terminal `ORA-01403: no data found` status from a "more rows" one.
bool _containsAscii(Uint8List body, int start, String needle) {
  final n = needle.codeUnits;
  for (var i = start; i + n.length <= body.length; i++) {
    var hit = true;
    for (var j = 0; j < n.length; j++) {
      if (body[i + j] != n[j]) {
        hit = false;
        break;
      }
    }
    if (hit) return true;
  }
  return false;
}

/// Encodes a native OALL8 EXECUTE: the TTC call header, the SQL as a short
/// `U8(len)+bytes` run (or the `0xFE`-chunked long form), then — when present —
/// the tail `0x07` bind block of one text value per placeholder (NULL = `FD 01`).
Uint8List _buildExecuteRequest(String sql, List<Object?> binds) {
  final b = WriteBuffer();
  b.writeUint8(_ttcMsgTypeFunction); // 3: RPC call
  b.writeUint8(_ttcFuncExecute); // 0x5E: OALL8 execute
  b.writeUint8(0x01); // sequence
  _writeNativeString(b, Uint8List.fromList(utf8.encode(sql)));
  if (binds.isNotEmpty) {
    b.writeUint8(0x07); // bind-values marker
    for (final v in binds) {
      if (v == null) {
        b.writeUint8(0xFD); // NULL bind
        b.writeUint8(0x01);
        continue;
      }
      _writeNativeString(b, Uint8List.fromList(utf8.encode(v.toString())));
    }
  }
  return b.toBytes();
}

/// Writes a `U8(len)+bytes` string, or the `0xFE + LE32(len)+bytes + LE32(0)`
/// chunked long form for values of 253 bytes or more.
void _writeNativeString(WriteBuffer b, Uint8List v) {
  if (v.length <= 252) {
    b.writeUint8(v.length);
    b.writeBytes(v);
  } else {
    b.writeUint8(0xFE);
    _u32le(b, v.length);
    b.writeBytes(v);
    _u32le(b, 0);
  }
}

/// Encodes a native FETCH call (`03 05 …`) requesting [count] rows (LE32 at
/// offset 9), as the server's `decodeNativeFetchCount` expects.
Uint8List _buildFetchRequest(int count) {
  final b = WriteBuffer();
  b.writeUint8(_ttcMsgTypeFunction); // 3
  b.writeUint8(0x05); // FETCH function
  b.writeUint8(0x01); // sequence
  for (var i = 0; i < 6; i++) {
    b.writeUint8(0); // offsets 3..8
  }
  _u32le(b, count); // offsets 9..12
  return b.toBytes();
}

Object? _decodeCell(Uint8List v, bool isNumber) {
  if (v.isEmpty) return null;
  if (isNumber) return decodeOracleNumber(ReadBuffer(v));
  return utf8.decode(v, allowMalformed: true);
}

/// Parses a native describe response (message type `0x10`): the column records,
/// then the inline row batch, reporting whether the server paginated the rest.
class _DescribeResult {
  _DescribeResult(this.columns, this.isNumber, this.rows, this.moreRows);
  final List<String> columns;
  final List<bool> isNumber;
  final List<List<Object?>> rows;
  final bool moreRows;
}

_DescribeResult _decodeDescribe(Uint8List body) {
  final ncols = _le32(body, 32);
  var pos = 37; // past 0x10, u32(23), 16 sig, 7 date, u32(headerSize), u32(ncols), 0x82
  final columns = <String>[];
  final isNumber = <bool>[];
  for (var i = 0; i < ncols; i++) {
    isNumber.add(body[pos] == 0x02); // 0x02 = NUMBER, 0x60 = VARCHAR2
    final nameLen = body[pos + 31];
    columns.add(utf8.decode(body.sublist(pos + 37, pos + 37 + nameLen)));
    pos += 69 + nameLen;
  }
  final rows = <List<Object?>>[];
  // An empty result has a 32-byte mid block immediately followed by the status
  // block (0x08); a non-empty one has the 54-byte mid block then row data.
  final emptyResult = body[pos + 32] == 0x08;
  if (emptyResult) {
    return _DescribeResult(columns, isNumber, rows, false);
  }
  pos += 54; // skip the mid block
  pos = _readRows(body, pos, ncols, isNumber, rows, interRowMarkers: true);
  final more = !_containsAscii(body, pos, 'no data found');
  return _DescribeResult(columns, isNumber, rows, more);
}

/// Parses a native FETCH response (message type `0x06`) into [rows], returning
/// whether more rows remain.
bool _decodeFetch(
    Uint8List body, int ncols, List<bool> isNumber, List<List<Object?>> rows) {
  final batch = body[8] | (body[9] << 8);
  var pos = 22; // past the fixed FETCH header
  for (var r = 0; r < batch; r++) {
    pos = _readRow(body, pos, ncols, isNumber, rows);
  }
  return !_containsAscii(body, pos, 'no data found');
}

/// Reads row data starting at [pos] until the status block (0x08), appending to
/// [rows]. Returns the position of the status block.
int _readRows(Uint8List body, int pos, int ncols, List<bool> isNumber,
    List<List<Object?>> rows,
    {required bool interRowMarkers}) {
  while (pos < body.length && (body[pos] == 0x07 || body[pos] == 0x15)) {
    if (interRowMarkers && body[pos] == 0x15) {
      pos += 4; // inter-row marker: 15 <ncols> <mask-hi> <mask-lo>
    }
    pos = _readRow(body, pos, ncols, isNumber, rows);
  }
  return pos;
}

/// Reads one `0x07`-marked row of [ncols] values at [pos]; returns the next pos.
int _readRow(Uint8List body, int pos, int ncols, List<bool> isNumber,
    List<List<Object?>> rows) {
  pos += 1; // 0x07 row marker
  final row = <Object?>[];
  for (var c = 0; c < ncols; c++) {
    final len = body[pos++];
    if (len == 0xFE) {
      final bytes = <int>[];
      while (true) {
        final clen = _le32(body, pos);
        pos += 4;
        if (clen == 0) break;
        bytes.addAll(body.sublist(pos, pos + clen));
        pos += clen;
      }
      row.add(_decodeCell(Uint8List.fromList(bytes), isNumber[c]));
    } else {
      row.add(_decodeCell(
          Uint8List.sublistView(body, pos, pos + len), isNumber[c]));
      pos += len;
    }
  }
  rows.add(row);
  return pos;
}

/// A pure-Dart native (thick) Oracle client driving an [OracleServer]-style
/// listener over the native TTC dialect.
class OracleThickClient {
  OracleThickClient._(this._socket, this._frames);

  final Socket _socket;
  final _FrameReader _frames;

  /// Data flags applied to each DATA packet after a real-Oracle [loginReal]
  /// (0x0800 END_OF_RPC on 23ai+). 0 for the dart-db-server flow.
  int _realDataFlags = 0;

  /// Connects to a native listener at [host]:[port]. Defaults to the loopback
  /// interface (the local dart-db-server); pass [host] to reach a real Oracle
  /// listener.
  static Future<OracleThickClient> connect(int port,
      {String host = '127.0.0.1'}) async {
    final socket = await Socket.connect(host, port);
    return OracleThickClient._(socket, _FrameReader(socket));
  }

  /// Runs the full native authentication flow (CONNECT → ACCEPT → break/reset →
  /// FAST_AUTH decline → DATA-TYPES → AUTH_PHASE_ONE → AUTH_PHASE_TWO),
  /// computing the O5LOGON/PBKDF2 proof and validating the server's
  /// AUTH_SVR_RESPONSE. [password] must match the server's verifier.
  Future<NativeLoginResult> login({
    required String username,
    required String password,
    String descriptor = _defaultDescriptor,
    bool inlineDescriptor = false,
  }) async {
    _socket.add(
        buildNativeConnect(descriptor: descriptor, inline: inlineDescriptor));
    // The overflow (dart-db-server) flow carries the descriptor in a second
    // packet; the inline (real Oracle) flow already included it.
    if (!inlineDescriptor) {
      _socket.add(buildDescriptorPacket(descriptor: descriptor));
    }
    await _frames.next(); // ACCEPT
    _socket.add(buildResetMarker());
    await _frames.next(); // RESET reply
    _socket.add(_wrapData(
        Uint8List.fromList([_ttcMsgTypeFastAuth, 0x01, 0x02, 0x00])));
    await _frames.next(); // FAST_AUTH decline
    _socket.add(_wrapData(_dataTypesRequest()));
    await _frames.next(); // DATA-TYPES response

    _socket.add(_wrapData(buildNativeAuthMessage(
        functionCode: _ttcAuthPhaseOne, username: username)));
    final challenge = _parseNativeResponseParams(_ttcBody(await _frames.next()));

    final o5logon =
        _NativeO5Logon.fromChallenge(password: password, challenge: challenge);
    _socket.add(_wrapData(buildNativeAuthMessage(
      functionCode: _ttcAuthPhaseTwo,
      username: username,
      sequence: 3,
      pairs: o5logon.phaseTwoPairs(),
    )));
    final responseBody = _ttcBody(await _frames.next());
    if (responseBody.isEmpty || responseBody.first != _ttcMsgTypeParameter) {
      return NativeLoginResult(authenticated: false, params: const {});
    }
    final params = _parseNativeResponseParams(responseBody);
    return NativeLoginResult(
      authenticated: o5logon.verifyServerResponse(params['AUTH_SVR_RESPONSE']),
      params: params,
    );
  }

  /// Authenticates against a **real Oracle** listener (19c+/21c/23ai/26ai) using
  /// the inline CONNECT + FAST_AUTH flow and the canonical O8LOGON proof — the
  /// path a genuine OCI/thin client uses, distinct from the dart-db-server
  /// [login] flow. Returns a [NativeLoginResult] whose `authenticated` reflects
  /// the server's AUTH_SVR_RESPONSE mutual-auth validation.
  Future<NativeLoginResult> loginReal({
    required String username,
    required String password,
    required String serviceName,
    String? alterSession,
  }) async {
    final descriptor = '(DESCRIPTION=(CONNECT_DATA=(SERVICE_NAME=$serviceName)'
        '(CID=(PROGRAM=dart-thick)(HOST=localhost)(USER=$username))))';
    _socket.add(
        buildNativeConnect(descriptor: descriptor, inline: true, versionDesired: 319));
    final accept = hs.parseAccept(await _frames.next());
    _realDataFlags = accept.supportsEndOfRequest ? hs.tnsDataFlagsEndOfRpc : 0;

    _socket.add(_wrapData(
        hs.buildFastAuthMessage(
            username: username, endOfRequest: accept.supportsEndOfRequest),
        dataFlags: _realDataFlags));
    final bundle = _ttcBody(await _frames.next());
    final challenge = hs.findAuthChallenge(bundle);
    if (challenge == null) {
      return NativeLoginResult(authenticated: false, params: const {});
    }

    final o8 = hs.computeO8Logon(password, challenge.pairs);
    final tz = alterSession ?? "ALTER SESSION SET TIME_ZONE='+00:00'\u0000";
    _socket.add(_wrapData(
        hs.buildAuthPhaseTwoMessage(
          username: username,
          sessionKeyHex: o8.sessionKeyHex,
          authPasswordHex: o8.authPasswordHex,
          speedyKeyHex: o8.speedyKeyHex,
          alterSession: tz,
        ),
        dataFlags: _realDataFlags));
    final resp2 = _ttcBody(await _frames.next());
    final txt = String.fromCharCodes(resp2.where((b) => b >= 32 && b < 127));
    final ora = RegExp(r'ORA-\d{5}').firstMatch(txt);
    if (ora != null) {
      return NativeLoginResult(authenticated: false, params: {'error': ora.group(0)!});
    }
    final params = hs.parseAuthParams(ReadBuffer(resp2)).pairs;
    return NativeLoginResult(
      authenticated: o8.verifyServerResponse(params['AUTH_SVR_RESPONSE']),
      params: params,
    );
  }

  /// Runs a row-returning [sql] against a **real Oracle** server over the
  /// canonical OALL8 execute path, optionally parameterised by positional
  /// [binds] (one value per `:1`, `:2` … placeholder), following FETCH
  /// round-trips until the cursor is drained. Requires a prior [loginReal].
  /// Throws [OracleThickException] on an `ORA-xxxxx` error.
  Future<ex.NativeExecuteResponse> queryReal(String sql,
      {List<Object?> binds = const [], int prefetch = 100}) async {
    _socket.add(_wrapData(
        ex.buildQueryExecute(sql, binds: binds, numIters: prefetch),
        dataFlags: _realDataFlags));
    var resp = await _readRealResponse(isQuery: true);
    final columns = resp.columns;
    final rows = <List<Object?>>[...resp.rows];
    var cursorId = resp.cursorId;
    var seq = 3;
    while (resp.moreRows) {
      _socket.add(_wrapData(
          ex.buildFetch(cursorId, prefetch, sequence: seq++),
          dataFlags: _realDataFlags));
      resp = await _readRealResponse(isQuery: true, expectedColumns: columns);
      rows.addAll(resp.rows);
      if (resp.cursorId != 0) cursorId = resp.cursorId;
      if (!resp.isSuccess) break;
    }
    if (!resp.isSuccess) {
      throw OracleThickException(
          resp.errorNum ?? -1,
          'ORA-${(resp.errorNum ?? 0).toString().padLeft(5, '0')}: '
          '${resp.errorMessage ?? ''}');
    }
    return ex.NativeExecuteResponse(
      columns: columns,
      rows: rows,
      cursorId: cursorId,
      moreRows: false,
      complete: true,
    );
  }

  /// Reads DATA frames, concatenating their TTC bodies, until the OALL8
  /// response decodes to completion (terminal STATUS / ERROR / END_OF_REQUEST).
  Future<ex.NativeExecuteResponse> _readRealResponse({
    required bool isQuery,
    List<ex.NativeColumn>? expectedColumns,
  }) async {
    final acc = BytesBuilder();
    while (true) {
      acc.add(_ttcBody(await _frames.next()));
      final resp = ex.decodeExecuteResponse(
        acc.toBytes(),
        isQuery: isQuery,
        expectedColumns: expectedColumns,
      );
      if (resp.complete) return resp;
    }
  }

  /// Runs [sql] (optionally parameterised by [binds], one value per `:name`
  /// placeholder in wire order) and returns the describe/DML result. Throws an
  /// [OracleThickException] on an `ORA-xxxxx` error.
  Future<OracleThickResult> run(String sql, {List<Object?> binds = const []}) async {
    _socket.add(_wrapData(_buildExecuteRequest(sql, binds)));
    final body = await _readNativeResponse();
    if (body.isEmpty) {
      throw StateError('empty native EXECUTE response');
    }
    switch (body[0]) {
      case 0x04: // error
        final code = _le32(body, 11);
        final len = body[79];
        final text = utf8.decode(body.sublist(80, 80 + len)).trim();
        throw OracleThickException(code, text);
      case 0x08: // DML / DDL status
        return OracleThickResult.dml(_le32(body, 42));
      case 0x09: // control-call OK
        return OracleThickResult.dml(0);
      case 0x10: // describe (query)
        break;
      default:
        throw StateError(
            'unexpected native response message 0x${body[0].toRadixString(16)}');
    }
    final d = _decodeDescribe(body);
    final rows = d.rows;
    var more = d.moreRows;
    while (more) {
      _socket.add(_wrapData(_buildFetchRequest(_nativeBatchSize)));
      final fb = await _readNativeResponse();
      more = _decodeFetch(fb, d.columns.length, d.isNumber, rows);
    }
    return OracleThickResult.query(d.columns, rows);
  }

  /// Runs a row-returning [sql] and returns its [OracleThickResult].
  Future<OracleThickResult> query(String sql, {List<Object?> binds = const []}) =>
      run(sql, binds: binds);

  /// Runs a non-row statement (INSERT/UPDATE/DELETE/DDL) and returns the number
  /// of rows affected (0 for DDL).
  Future<int> execute(String sql, {List<Object?> binds = const []}) async =>
      (await run(sql, binds: binds)).affected;

  /// Reads one native EXECUTE/FETCH response, reassembling the DATA packets the
  /// server splits a response larger than one SDU into. The split carries no
  /// per-packet "more" flag, so packets are concatenated until the TTI
  /// end-of-call marker that terminates every native response.
  Future<Uint8List> _readNativeResponse() async {
    var body = _ttcBody(await _frames.next());
    while (body.isEmpty || body.last != _ttiEndOfCall) {
      final next = _ttcBody(await _frames.next());
      final merged = Uint8List(body.length + next.length)
        ..setRange(0, body.length, body)
        ..setRange(body.length, body.length + next.length, next);
      body = merged;
    }
    return body;
  }

  Future<void> close() async {
    await _frames.cancel();
    await _socket.close();
  }
}
