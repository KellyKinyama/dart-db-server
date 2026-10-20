/// Shared test helpers that simulate the client half of the Oracle wire
/// protocol: TNS framing, the PROTOCOL/DATA-TYPES negotiation, the O5LOGON
/// proof, and the EXECUTE request/response codecs. These mirror the client
/// decoders/encoders in `../dart-oracledb` so a passing test proves the server
/// emits bytes the real client reads.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dart_db_server/server/oracle_codec.dart';
import 'package:dart_db_server/server/oracle_crypto.dart';
import 'package:dart_db_server/server/oracle_json.dart';
import 'package:dart_db_server/server/oracle_number.dart';
import 'package:dart_db_server/server/oracle_ttc.dart';

const int tnsHeaderSize = 8;
const int tnsPacketConnect = 1;
const int tnsPacketAccept = 2;
const int tnsPacketData = 6;
const int ttcFuncExecute = 94;
const int ttcFuncCommit = 14;
const int ttcFuncRollback = 15;
const int ttcFuncPing = 0x93;
const int ttcAuthPhaseOne = 0x76;
const int ttcAuthPhaseTwo = 0x73;

final _rand = Random(98765);
Uint8List _randBytes(int n) =>
    Uint8List.fromList(List<int>.generate(n, (_) => _rand.nextInt(256)));

Uint8List concatBytes(Uint8List a, Uint8List b) => Uint8List(a.length + b.length)
  ..setRange(0, a.length, a)
  ..setRange(a.length, a.length + b.length, b);

// --- TNS framing -----------------------------------------------------------

Uint8List buildConnect({int versionDesired = 319}) {
  const data = '(DESCRIPTION=(CONNECT_DATA=(SERVICE_NAME=DARTDB)))';
  final bytes = Uint8List.fromList(data.codeUnits);
  const bodyPrefix = 66;
  final body = ByteData(bodyPrefix + bytes.length);
  body.setUint16(0, versionDesired);
  body.setUint16(2, 300);
  body.setUint16(4, 0x0001);
  body.setUint16(6, 8192);
  body.setUint16(8, 32767);
  body.setUint16(14, 1);
  body.setUint16(16, bytes.length);
  body.setUint16(18, tnsHeaderSize + bodyPrefix);
  for (var i = 0; i < bytes.length; i++) {
    body.setUint8(bodyPrefix + i, bytes[i]);
  }
  final bb = body.buffer.asUint8List();
  final out = BytesBuilder();
  final header = ByteData(tnsHeaderSize);
  header.setUint16(0, tnsHeaderSize + bb.length);
  header.setUint8(4, tnsPacketConnect);
  out.add(header.buffer.asUint8List());
  out.add(bb);
  return out.toBytes();
}

Uint8List protocolRequest() {
  final b = BytesBuilder();
  b.addByte(ttcMsgProtocol);
  b.addByte(6);
  b.addByte(0);
  b.add('dart-oracledb'.codeUnits);
  b.addByte(0);
  return b.toBytes();
}

Uint8List dataTypesRequest() {
  final b = BytesBuilder();
  b.addByte(ttcMsgDataTypes);
  b.add([0, 0]);
  return b.toBytes();
}

/// Wraps a TTC body in a DATA packet using the 4-byte large-SDU length header
/// (all client DATA packets are post-ACCEPT, so large SDU at v >= 315).
Uint8List wrapData(Uint8List ttcBody) {
  final out = BytesBuilder();
  final header = ByteData(tnsHeaderSize);
  header.setUint32(0, tnsHeaderSize + 2 + ttcBody.length);
  header.setUint8(4, tnsPacketData);
  out.add(header.buffer.asUint8List());
  out.add([0, 0]);
  out.add(ttcBody);
  return out.toBytes();
}

Uint8List ttcBody(Uint8List frame) =>
    Uint8List.sublistView(frame, tnsHeaderSize + 2);

/// Reassembles whole TNS frames from a socket's byte stream. The ACCEPT (first
/// frame) uses 2-byte framing; once it is read the client switches to the
/// 4-byte large-SDU length header for all DATA packets (negotiated v >= 315).
class FrameReader {
  FrameReader(Stream<Uint8List> socket) {
    _sub = socket.listen((chunk) {
      _buf = concatBytes(_buf, chunk);
      _drain();
    });
  }

  late final StreamSubscription<Uint8List> _sub;
  Uint8List _buf = Uint8List(0);
  bool _largeSdu = false;
  final _queue = <Uint8List>[];
  final _waiters = <Completer<Uint8List>>[];

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

// --- authentication (O5LOGON client side) ----------------------------------

({String authSessKey, String authPassword}) clientProof({
  required String password,
  required Uint8List salt,
  required Uint8List serverKeyEncoded,
}) {
  final pw = Uint8List.fromList(utf8.encode(password));
  final passwordHash = Uint8List.sublistView(sha512(concatBytes(pw, salt)), 0, 32);
  final partA = aes256CbcDecryptRaw(
      key: passwordHash, iv: Uint8List(16), data: serverKeyEncoded);
  final partB = _randBytes(partA.length);
  final encodedClientKey = aes256CbcEncryptPkcs7(
      key: passwordHash, iv: Uint8List(16), data: partB);
  final authSessKey = hexEncodeUpper(encodedClientKey).substring(0, 64);
  final partAB = Uint8List(64)
    ..setRange(0, 32, partB)
    ..setRange(32, 64, partA);
  final comboKey = pbkdf2Sha512(
    password: Uint8List.fromList(utf8.encode(hexEncodeUpper(partAB))),
    salt: Uint8List(16),
    iterations: 1,
    keyLength: 32,
  );
  final salted = concatBytes(_randBytes(16), pw);
  final encPassword =
      aes256CbcEncryptPkcs7(key: comboKey, iv: Uint8List(16), data: salted);
  return (authSessKey: authSessKey, authPassword: hexEncodeUpper(encPassword));
}

Uint8List phaseOneRequest(String username) {
  final userBytes = Uint8List.fromList(utf8.encode(username));
  final b = WriteBuffer();
  b.writeUint8(ttcMsgTypeFunction);
  b.writeUint8(ttcAuthPhaseOne);
  b.writeUint8(1);
  b.writeUint8(userBytes.isNotEmpty ? 1 : 0);
  b.writeUB4(userBytes.length);
  b.writeUB4(0x00000101);
  b.writeUint8(1);
  b.writeUB4(5);
  b.writeUint8(0);
  b.writeUint8(1);
  if (userBytes.isNotEmpty) b.writeBytesWithLength(userBytes);
  return b.toBytes();
}

Uint8List phaseTwoRequest(String username, Map<String, String> pairs) {
  final userBytes = Uint8List.fromList(utf8.encode(username));
  final b = WriteBuffer();
  b.writeUint8(ttcMsgTypeFunction);
  b.writeUint8(ttcAuthPhaseTwo);
  b.writeUint8(2);
  b.writeUint8(userBytes.isNotEmpty ? 1 : 0);
  b.writeUB4(userBytes.length);
  b.writeUB4(0x00000101);
  b.writeUint8(1);
  b.writeUB4(pairs.length);
  b.writeUint8(1);
  b.writeUint8(1);
  if (userBytes.isNotEmpty) b.writeBytesWithLength(userBytes);
  pairs.forEach((k, v) => _writeKv(b, k, v));
  return b.toBytes();
}

void _writeKv(WriteBuffer b, String key, String value) {
  final kb = Uint8List.fromList(utf8.encode(key));
  final vb = Uint8List.fromList(utf8.encode(value));
  b.writeUB4(kb.length);
  b.writeBytesWithLength(kb);
  b.writeUB4(vb.length);
  if (vb.isNotEmpty) b.writeBytesWithLength(vb);
  b.writeUB4(0);
}

Map<String, String> parseParamResponse(Uint8List body) {
  final r = ReadBuffer(body);
  r.readUint8(); // message type (8)
  final n = r.readUB2();
  final out = <String, String>{};
  for (var i = 0; i < n; i++) {
    r.readUB4();
    final key = r.readStringWithLength();
    final valueLen = r.readUB4();
    final value = valueLen > 0 ? r.readStringWithLength() : '';
    r.readUB4();
    out[key] = value;
  }
  return out;
}

/// Drives the full CONNECT → PROTOCOL → DATA-TYPES → AUTH1 → AUTH2 handshake
/// over [socket], authenticating [username]/[password].
Future<void> handshakeAndLogin(
  Socket socket,
  FrameReader frames, {
  required String username,
  required String password,
}) async {
  socket.add(buildConnect());
  await frames.next(); // ACCEPT
  socket.add(wrapData(protocolRequest()));
  await frames.next();
  socket.add(wrapData(dataTypesRequest()));
  await frames.next();
  socket.add(wrapData(phaseOneRequest(username)));
  final params = parseParamResponse(ttcBody(await frames.next()));
  final proof = clientProof(
    password: password,
    salt: hexDecode(params['AUTH_VFR_DATA']!),
    serverKeyEncoded: hexDecode(params['AUTH_SESSKEY']!),
  );
  socket.add(wrapData(phaseTwoRequest(username, {
    'AUTH_SESSKEY': proof.authSessKey,
    'AUTH_PASSWORD': proof.authPassword,
  })));
  final status = ttcBody(await frames.next());
  if (status.first != ttcMsgTypeStatus) {
    throw StateError('login failed (status byte ${status.first})');
  }
}

// --- EXECUTE request/response (client side) --------------------------------

/// Builds a bare FUNCTION RPC request (COMMIT, ROLLBACK, PING) at TTC field
/// version 24: message type, function code, sequence, and the 23.1 token.
Uint8List buildFunctionRequest(int functionCode, {int seq = 4}) {
  final b = WriteBuffer();
  b.writeUint8(ttcMsgTypeFunction);
  b.writeUint8(functionCode);
  b.writeUint8(seq);
  b.writeUB8(0); // token number
  return b.toBytes();
}

/// Builds a no-bind EXECUTE (OALL8) request body at TTC field version 24. When
/// [cursorId] is non-zero this is a cached re-execute: no SQL bytes travel.
/// When [binds] is non-empty, bind metadata + a ROW_DATA value block follow.
Uint8List buildExecuteRequest(String sql,
    {bool isQuery = false,
    int seq = 3,
    int cursorId = 0,
    List<Object?> binds = const []}) {
  final fresh = cursorId == 0;
  final sqlBytes = Uint8List.fromList(utf8.encode(sql));
  final b = WriteBuffer();
  b.writeUint8(ttcMsgTypeFunction);
  b.writeUint8(ttcFuncExecute);
  b.writeUint8(seq);
  b.writeUB8(0); // token
  b.writeUB4(isQuery ? 0x61 : 0x8021); // options (value irrelevant to server)
  b.writeUB4(cursorId);
  b.writeUint8(fresh ? 1 : 0); // sql ptr
  b.writeUB4(fresh ? sqlBytes.length : 0);
  b.writeUint8(1); // pointer vector
  b.writeUB4(13);
  b.writeUint8(0); // al8o4
  b.writeUint8(0); // al8o4l
  b.writeUint8(0); // prefetch buffer size
  b.writeUB4(isQuery ? 50 : 1); // prefetch num rows
  b.writeUB4(0x7fffffff); // max long size
  b.writeUint8(binds.isEmpty ? 0 : 1); // numParams ptr
  b.writeUB4(binds.length); // numParams
  b.writeUint8(0); // al8pp
  b.writeUint8(0); // al8txn
  b.writeUint8(0); // al8txl
  b.writeUint8(0); // al8kv
  b.writeUint8(0); // al8kvl
  b.writeUint8(0); // defines ptr
  b.writeUB4(0); // defines count
  b.writeUB4(0); // registration id
  b.writeUint8(0); // al8objlist
  b.writeUint8(0); // al8objlen
  b.writeUint8(0); // al8blv ptr
  b.writeUB4(0); // al8blv
  b.writeUint8(0); // al8dnam
  b.writeUB4(0); // al8dnaml
  b.writeUB4(0); // al8regid_msb
  b.writeUint8(0); // dml-rowcounts ptr
  b.writeUB4(0); // count
  b.writeUint8(0); // length ptr
  b.writeUint8(0); // al8sqlsig
  b.writeUB4(0);
  b.writeUint8(0); // sql id
  b.writeUB4(0);
  b.writeUint8(0); // length of sql id
  b.writeUint8(0); // chunk ids
  b.writeUB4(0);
  if (fresh) {
    b.writeBytesWithLength(sqlBytes);
    b.writeUB4(1); // al8i4[0]
  } else {
    b.writeUB4(0); // al8i4[0]
  }
  for (var i = 1; i < 13; i++) {
    b.writeUB4(0);
  }
  if (binds.isNotEmpty) {
    for (final v in binds) {
      _writeBindMeta(b, _bindOraType(v));
    }
    b.writeUint8(ttcMsgTypeRowData);
    for (final v in binds) {
      _writeBindValue(b, v);
    }
  }
  return b.toBytes();
}

int _bindOraType(Object? v) {
  if (v == null) return 1; // VARCHAR (null)
  if (v is RawBind) return v.oraType;
  if (v is VectorBind) return 127; // VECTOR
  if (v is JsonBind) return 119; // JSON
  if (v is num) return 2; // NUMBER
  if (v is Uint8List) return 23; // RAW
  return 1; // VARCHAR / STRING
}

void _writeBindMeta(WriteBuffer b, int oraType) {
  b.writeUint8(oraType);
  b.writeUint8(32); // bind-use indicators flag (ignored by server)
  b.writeUint8(0); // precision
  b.writeUint8(0); // scale
  b.writeUB4(oraType == 2 ? 22 : 4000); // max size
  b.writeUB4(0); // max num elements
  b.writeUB4(0); // cont flag
  b.writeUB4(0); // OID
  b.writeUB2(0); // version
  b.writeUB2(0); // charset field
  b.writeUint8(0); // csfrm
  b.writeUB4(0); // LOB prefetch length
  b.writeUB4(0); // oaccolid (fv >= 12.2)
}

void _writeBindValue(WriteBuffer b, Object? v) {
  if (v == null) {
    b.writeUint8(0); // zero-length NULL indicator
  } else if (v is RawBind) {
    b.writeBytesWithLength(v.bytes);
  } else if (v is VectorBind) {
    final image = encodeVectorImageF32(v.values);
    _writeQLocator(b, image.length);
    b.writeBytesWithLength(image);
  } else if (v is JsonBind) {
    final oson = encodeOson(v.value);
    _writeQLocator(b, oson.length);
    b.writeBytesWithLength(oson);
  } else if (v is num) {
    b.writeBytesWithLength(encodeOracleNumber(v));
  } else if (v is Uint8List) {
    b.writeBytesWithLength(v);
  } else {
    b.writeBytesWithLength(Uint8List.fromList(utf8.encode(v.toString())));
  }
}

/// Writes the 40-byte value-based QLocator that precedes an inline VECTOR bind
/// value (client `_writeQLocator`): a UB4 byte count (40) then the
/// length-prefixed locator.
void _writeQLocator(WriteBuffer b, int payloadLength) {
  final loc = WriteBuffer()
    ..writeUint16BE(38)
    ..writeUint16BE(4) // tnsLobQLocatorVersion
    ..writeUint8(0x20 | 0x01 | 0x40) // value-based | blob | abstract
    ..writeUint8(0x08) // init
    ..writeUint16BE(0)
    ..writeUint16BE(1)
    ..writeUint32BE(0)
    ..writeUint32BE(payloadLength)
    ..writeUint16BE(0)
    ..writeUint16BE(0)
    ..writeUint16BE(0)
    ..writeUint32BE(0)
    ..writeUint32BE(0)
    ..writeUint32BE(0)
    ..writeUint32BE(0);
  final bytes = loc.toBytes();
  b.writeUB4(bytes.length);
  b.writeBytesWithLength(bytes);
}

/// A VECTOR bind value (a dense FLOAT32 vector), encoded as the client does.
class VectorBind {
  VectorBind(this.values);
  final List<double> values;
}

/// A native JSON bind value, encoded as OSON (as the client does).
class JsonBind {
  JsonBind(this.value);
  final Object? value;
}

/// Encodes a dense FLOAT32 VECTOR image (client `encodeVector` for a
/// `Float32List`): 9-byte header, 8 zero norm bytes, byte-comparable FLOAT32
/// elements.
Uint8List encodeVectorImageF32(List<double> values) {
  final image = Uint8List(9 + 8 + values.length * 4);
  final data = ByteData.sublistView(image);
  image[0] = 0xDB; // magic
  image[1] = 0; // version base
  data.setUint16(2, 0x0010 | 0x0002); // NORMSRC | NORM
  image[4] = 2; // FLOAT32
  data.setUint32(5, values.length);
  var pos = 17;
  final scratch = ByteData(4);
  for (final v in values) {
    scratch.setFloat32(0, v);
    final bits = scratch.getUint32(0);
    data.setUint32(
        pos, (bits & 0x80000000) == 0 ? bits | 0x80000000 : ~bits & 0xFFFFFFFF);
    pos += 4;
  }
  return image;
}

/// Decodes a dense FLOAT32 VECTOR image back to a list of doubles.
List<double> decodeVectorImageF32(Uint8List image) {
  final data = ByteData.sublistView(image);
  final count = data.getUint32(5);
  final out = List<double>.filled(count, 0);
  var pos = 17;
  final scratch = ByteData(4);
  for (var i = 0; i < count; i++, pos += 4) {
    var bits = data.getUint32(pos);
    bits = (bits & 0x80000000) != 0 ? bits & 0x7FFFFFFF : ~bits & 0xFFFFFFFF;
    scratch.setUint32(0, bits);
    out[i] = scratch.getFloat32(0);
  }
  return out;
}

/// A bind value with an explicit Oracle wire type and pre-encoded bytes, for
/// binding types [buildExecuteRequest]'s value inference does not cover (e.g.
/// INTERVAL). Mirrors how the real client encodes typed binds.
class RawBind {
  RawBind(this.oraType, this.bytes);
  final int oraType;
  final Uint8List bytes;
}

/// Encodes an `INTERVAL YEAR TO MONTH` (type 182) wire value: bytes 0-3 years
/// + 0x80000000 (big-endian), byte 4 months + 60.
RawBind intervalYMBind(int years, int months) {
  final d = ByteData(5)
    ..setUint32(0, years + 0x80000000)
    ..setUint8(4, months + 60);
  return RawBind(182, d.buffer.asUint8List());
}

/// Encodes an `INTERVAL DAY TO SECOND` (type 183) wire value: bytes 0-3 days +
/// 0x80000000, byte 4 hours + 60, byte 5 minutes + 60, byte 6 seconds + 60,
/// bytes 7-10 nanoseconds + 0x80000000 (all big-endian).
RawBind intervalDSBind(
    int days, int hours, int minutes, int seconds, int fseconds) {
  final d = ByteData(11)
    ..setUint32(0, days + 0x80000000)
    ..setUint8(4, hours + 60)
    ..setUint8(5, minutes + 60)
    ..setUint8(6, seconds + 60)
    ..setUint32(7, fseconds + 0x80000000);
  return RawBind(183, d.buffer.asUint8List());
}

/// Builds a close-cursors piggyback body (prepended before a real message).
Uint8List buildCloseCursorsPiggyback(List<int> cursorIds, {int seq = 9}) {
  final b = WriteBuffer();
  b.writeUint8(ttcMsgTypePiggyback);
  b.writeUint8(105); // ttcFuncCloseCursors
  b.writeUint8(seq);
  b.writeUB8(0); // token number
  b.writeUint8(1); // pointer
  b.writeUB4(cursorIds.length);
  for (final id in cursorIds) {
    b.writeUB4(id);
  }
  return b.toBytes();
}

/// A decoded EXECUTE response (query rows or a DML/DDL status).
class ExecuteResponse {
  final List<String> columns = [];
  final List<int> columnTypes = []; // Oracle wire type per column
  final List<List<Object?>> rows = [];
  int? rowsAffected;
  int cursorId = 0;
  int errorNum = 0;
  String? errorMessage;

  /// Whether a terminal message (ERROR / STATUS) was reached — false means the
  /// body was a partial, multi-packet response.
  bool terminated = false;
}

/// Reads a (possibly multi-packet) EXECUTE response, reassembling DATA frames
/// until the TTC stream reaches its terminal message.
Future<ExecuteResponse> readExecuteResponse(FrameReader frames,
    {bool isQuery = false}) async {
  final buf = BytesBuilder();
  while (true) {
    buf.add(ttcBody(await frames.next()));
    try {
      final resp = decodeExecuteResponse(buf.toBytes(), isQuery: isQuery);
      if (resp.terminated) return resp;
    } on OracleBufferException {
      // Partial stream split across packets — wait for the next frame.
    }
  }
}

/// Decodes an EXECUTE response body, mirroring the client's message dispatch
/// for the message types the server emits.
ExecuteResponse decodeExecuteResponse(Uint8List body, {bool isQuery = false}) {
  final r = ReadBuffer(body);
  final out = ExecuteResponse();
  while (r.hasRemaining) {
    final msgType = r.readUint8();
    switch (msgType) {
      case ttcMsgTypeDescribeInfo:
        _decodeDescribe(r, out);
        break;
      case ttcMsgTypeRowHeader:
        _decodeRowHeader(r);
        break;
      case ttcMsgTypeRowData:
        _decodeRowData(r, out);
        break;
      case ttcMsgTypeError:
        _decodeError(r, out, isQuery: isQuery);
        out.terminated = true;
        return out; // terminal
      case ttcMsgTypeStatus:
        r.readUB4();
        r.readUB2();
        out.terminated = true;
        return out;
      default:
        throw StateError('unexpected response message type $msgType');
    }
  }
  return out;
}

void _decodeDescribe(ReadBuffer r, ExecuteResponse out) {
  r.readBytesWithLength(); // version bytes
  r.readUB4(); // max row size
  final numCols = r.readUB4();
  if (numCols > 0) r.readUint8();
  for (var i = 0; i < numCols; i++) {
    _decodeColumn(r, out);
  }
  final dateBytes = r.readUB4();
  if (dateBytes > 0) r.readBytesWithLength();
  r.readUB4(); // dcbflag
  r.readUB4(); // dcbmdbz
  r.readUB4(); // dcbmnpr
  r.readUB4(); // dcbmxpr
  final tailBytes = r.readUB4();
  if (tailBytes > 0) r.readBytesWithLength();
}

String _decodeColumn(ReadBuffer r, ExecuteResponse out) {
  final dataType = r.readUint8(); // data type
  r.readUint8(); // flags
  r.readUint8(); // precision
  r.readUint8(); // scale
  r.readUB4(); // max size
  r.readUB4(); // max num array elements
  r.readUB8(); // cont flags
  final oidLen = r.readUB4();
  if (oidLen > 0) r.readBytesWithLength();
  r.readUB2(); // version
  r.readUB2(); // charset id
  r.readUint8(); // csfrm
  r.readUB4(); // size
  r.readUB4(); // oaccolid (12.2)
  r.readUint8(); // nullable
  r.readUint8(); // v7 name length
  String name = '';
  final nameLen = r.readUB4();
  if (nameLen > 0) name = utf8.decode(r.readBytesWithLength());
  final schemaLen = r.readUB4();
  if (schemaLen > 0) r.readBytesWithLength();
  final typeNameLen = r.readUB4();
  if (typeNameLen > 0) r.readBytesWithLength();
  r.readUB2(); // column position
  r.readUB4(); // uds flags
  // 23.1 domain schema / name
  final domainSchemaLen = r.readUB4();
  if (domainSchemaLen > 0) r.readBytesWithLength();
  final domainNameLen = r.readUB4();
  if (domainNameLen > 0) r.readBytesWithLength();
  // 23.1 ext3 annotations
  final annoLen = r.readUB4();
  if (annoLen > 0) throw StateError('annotations not expected in test server');
  // 23.4 vector fields
  r.readUB4(); // dimensions
  r.readUint8(); // format
  r.readUint8(); // flags
  out.columns.add(name);
  out.columnTypes.add(dataType);
  return name;
}

void _decodeRowHeader(ReadBuffer r) {
  r.readUint8(); // flags
  r.readUB2(); // num requests
  r.readUB4(); // iteration number
  r.readUB4(); // num iters
  r.readUB2(); // buffer length
  final bitVecLen = r.readUB4();
  if (bitVecLen > 0) r.readBytesWithLength();
  final rxhridLen = r.readUB4();
  if (rxhridLen > 0) r.readBytesWithLength();
}

void _decodeRowData(ReadBuffer r, ExecuteResponse out) {
  final row = <Object?>[];
  for (var i = 0; i < out.columns.length; i++) {
    if (out.columnTypes[i] == 127) {
      // VECTOR: UB4 marker (0 = NULL), UB8 size, UB4 chunk, image, locator.
      final marker = r.readUB4();
      if (marker == 0) {
        row.add(null);
        continue;
      }
      r.readUB8(); // size
      r.readUB4(); // chunk size
      final image = r.readBytesWithLength();
      r.readBytesWithLength(); // locator (unused)
      row.add(decodeVectorImageF32(image));
      continue;
    }
    if (out.columnTypes[i] == 119) {
      // JSON: UB4 marker (0 = NULL), UB8 size, UB4 chunk, OSON, locator.
      final marker = r.readUB4();
      if (marker == 0) {
        row.add(null);
        continue;
      }
      r.readUB8(); // size
      r.readUB4(); // chunk size
      final oson = r.readBytesWithLength();
      r.readBytesWithLength(); // locator (unused)
      row.add(decodeOson(oson));
      continue;
    }
    final bytes = r.readBytesWithLength();
    if (bytes.isEmpty) {
      row.add(null);
    } else if (out.columnTypes[i] == 2) {
      row.add(decodeOracleNumber(ReadBuffer(bytes))); // NUMBER
    } else if (out.columnTypes[i] == 23) {
      row.add(Uint8List.fromList(bytes)); // RAW
    } else {
      row.add(utf8.decode(bytes));
    }
  }
  out.rows.add(row);
}

void _decodeError(ReadBuffer r, ExecuteResponse out, {required bool isQuery}) {
  r.readUB4(); // end of call status
  r.readUB2(); // end-to-end seq
  r.readUB4(); // current row number
  r.readUB2(); // error number (short)
  r.readUB2(); // array elem error
  r.readUB2(); // array elem error
  out.cursorId = r.readUB4(); // cursor id
  r.readSB4(); // error position
  for (var i = 0; i < 6; i++) {
    r.readUint8();
  }
  r.readUB4(); // rowID rba
  r.readUB2();
  r.readUint8();
  r.readUB4();
  r.readUB2();
  r.readUB4(); // OS error
  r.readUint8(); // statement error
  r.readUint8(); // call number
  r.readUB2(); // padding
  r.readUB4(); // success iters
  final oerrddLen = r.readUB4();
  if (oerrddLen > 0) r.readBytesWithLength();
  r.readUB2(); // batch error codes count
  r.readUB4(); // batch error offsets count
  r.readUB2(); // batch error messages count
  final num = r.readUB4();
  final rowCount = r.readUB8(); // rowCount (>= 12.2)
  r.readUB4(); // sql type (>= 20.1)
  r.readUB4(); // server checksum (>= 20.1)
  out.errorNum = num;
  if (num != 0) {
    out.errorMessage = utf8.decode(r.readBytesWithLength());
  }
  if (isQuery && num == 1403) {
    out.errorNum = 0; // end of fetch
  } else if (!isQuery && num == 0) {
    out.rowsAffected = rowCount;
  }
}
