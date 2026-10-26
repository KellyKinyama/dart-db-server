/// Phase 0/1 conformance tests for the Oracle TNS/TTC server front-end.
///
/// Covers the transport handshake: a client CONNECT is parsed, a version is
/// negotiated, and the ACCEPT we emit places its fields where the real client
/// (`../dart-oracledb`'s `AcceptPacketInfo.parse`) reads them back.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_db_server/dart_db_server.dart';
import 'package:dart_db_server/server/oracle_codec.dart';
import 'package:dart_db_server/server/oracle_tns.dart';
import 'package:dart_db_server/server/oracle_ttc.dart';
import 'package:test/test.dart';

/// Builds a minimal CONNECT packet the way a thin client does: an 8-byte TNS
/// header (type 1) followed by the connect body, with the descriptor inline.
Uint8List buildConnect({
  int versionDesired = 319,
  int versionMinimum = 300,
  int sdu = 8192,
  int tdu = 32767,
  String connectData = '(DESCRIPTION=(CONNECT_DATA=(SERVICE_NAME=DARTDB)))',
}) {
  final data = Uint8List.fromList(connectData.codeUnits);
  // Connect body is 66 bytes before the descriptor (absolute offset 74).
  const bodyPrefix = 66;
  const connectDataOffset = tnsHeaderSize + bodyPrefix; // 74
  final body = ByteData(bodyPrefix + data.length);
  body.setUint16(0, versionDesired);
  body.setUint16(2, versionMinimum);
  body.setUint16(4, 0x0001); // options
  body.setUint16(6, sdu);
  body.setUint16(8, tdu);
  body.setUint16(14, 1); // endianness marker
  body.setUint16(16, data.length); // connect data length
  body.setUint16(18, connectDataOffset); // connect data offset
  for (var i = 0; i < data.length; i++) {
    body.setUint8(bodyPrefix + i, data[i]);
  }
  final bodyBytes = body.buffer.asUint8List();

  final out = BytesBuilder();
  final header = ByteData(tnsHeaderSize);
  header.setUint16(0, tnsHeaderSize + bodyBytes.length); // total length
  header.setUint8(4, tnsPacketConnect);
  out.add(header.buffer.asUint8List());
  out.add(bodyBytes);
  return out.toBytes();
}

void main() {
  group('TNS CONNECT parsing', () {
    test('reads version, sizes, and descriptor', () {
      final raw = buildConnect(versionDesired: 318, sdu: 8192, tdu: 32767);
      final req = ConnectRequest.parse(raw);
      expect(req.versionDesired, 318);
      expect(req.versionMinimum, 300);
      expect(req.sdu, 8192);
      expect(req.tdu, 32767);
      expect(req.connectData, contains('SERVICE_NAME=DARTDB'));
    });
  });

  group('version negotiation', () {
    test('caps the client desire at the server version', () {
      final req = ConnectRequest.parse(buildConnect(versionDesired: 319));
      expect(negotiateVersion(req), tnsServerVersion); // 318
    });

    test('never drops below the client minimum', () {
      final req = ConnectRequest.parse(
        buildConnect(versionDesired: 305, versionMinimum: 305),
      );
      expect(negotiateVersion(req), 305);
    });
  });

  group('ACCEPT encoding', () {
    test('places fields where the client reads them back', () {
      final accept = buildAcceptPacket(
        version: 318,
        sdu: 8192,
        tdu: 32767,
        flag2: 0,
      );
      final v = ByteData.sublistView(accept);
      expect(v.getUint8(4), tnsPacketAccept); // packet type
      expect(v.getUint16(8), 318); // version   (abs 8)
      expect(v.getUint16(12), 8192); // SDU16   (abs 12)
      expect(v.getUint16(14), 32767); // TDU16  (abs 14)
      expect(v.getUint32(32), 8192); // large SDU (abs 32)
      expect(v.getUint32(36), 32767); // large TDU (abs 36)
      expect(v.getUint32(41), 0); // flag2       (abs 41)
    });
  });

  group('live loopback', () {
    test('CONNECT gets an ACCEPT with the negotiated version', () async {
      final db = await Database.open(null);
      final server = OracleServer(db, port: 0);
      await server.start();
      addTearDown(() async {
        await server.stop();
      });

      final socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        server.boundPort,
      );
      addTearDown(() async {
        await socket.close();
      });

      socket.add(buildConnect(versionDesired: 319));

      final reply = await socket.first.timeout(const Duration(seconds: 5));
      final bytes = Uint8List.fromList(reply);
      final v = ByteData.sublistView(bytes);
      expect(v.getUint8(4), tnsPacketAccept);
      expect(v.getUint16(8), tnsServerVersion);
    });
  });

  group('TTC PROTOCOL response', () {
    test('decodes the way the client ProtocolResponse.decode does', () {
      final body = buildProtocolResponse();
      final d = _ProtocolResponse.decode(body);
      expect(d.msgType, ttcMsgProtocol);
      expect(d.serverVersion, ttcServerVersion);
      expect(d.banner, contains('dart-db-server'));
      expect(d.charset, charsetAl32Utf8);
      expect(d.nCharset, charsetAl16Utf16);
      // The client reads compileCaps[7] as its field-version ceiling.
      expect(d.compileCaps, isNotNull);
      expect(d.compileCaps!.length, greaterThan(7));
      expect(d.compileCaps![7], serverFieldVersion);
    });
  });

  group('TTC DATA-TYPES response', () {
    test('is message type 2 followed by the 0x0000 terminator', () {
      final body = buildDataTypesResponse();
      expect(body, hasLength(3));
      expect(body[0], ttcMsgDataTypes);
      expect((body[1] << 8) | body[2], 0); // terminator
    });
  });

  group('live handshake through negotiation', () {
    test('CONNECT, PROTOCOL, and DATA-TYPES each get a response', () async {
      final db = await Database.open(null);
      final server = OracleServer(db, port: 0);
      await server.start();
      addTearDown(() async => server.stop());

      final socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        server.boundPort,
      );
      addTearDown(() async => socket.close());

      final frames = _FrameReader(socket);

      // 1) CONNECT -> ACCEPT
      socket.add(buildConnect());
      final accept = await frames.next();
      expect(accept[4], tnsPacketAccept);

      // 2) PROTOCOL request -> PROTOCOL response
      socket.add(_wrapData(_protocolRequestBody()));
      final protoFrame = await frames.next();
      expect(protoFrame[4], tnsPacketData);
      final protoBody = _ttcBody(protoFrame);
      final proto = _ProtocolResponse.decode(protoBody);
      expect(proto.serverVersion, ttcServerVersion);
      expect(proto.charset, charsetAl32Utf8);

      // 3) DATA-TYPES request -> DATA-TYPES response
      socket.add(_wrapData(_dataTypesRequestBody()));
      final dtFrame = await frames.next();
      expect(dtFrame[4], tnsPacketData);
      final dtBody = _ttcBody(dtFrame);
      expect(dtBody[0], ttcMsgDataTypes);
    });
  });
}

/// A client PROTOCOL request body: `[1][6][0]"dart-oracledb"[0]`.
Uint8List _protocolRequestBody() {
  final b = BytesBuilder();
  b.addByte(ttcMsgProtocol);
  b.addByte(6); // protocol version
  b.addByte(0);
  b.add('dart-oracledb'.codeUnits);
  b.addByte(0);
  return b.toBytes();
}

/// A minimal client DATA-TYPES request body: type + charset preamble + empty
/// caps + terminator. The server ignores the body and just replies.
Uint8List _dataTypesRequestBody() {
  final b = BytesBuilder();
  b.addByte(ttcMsgDataTypes);
  b.add([charsetAl32Utf8 & 0xFF, (charsetAl32Utf8 >> 8) & 0xFF]); // LE
  b.add([charsetAl32Utf8 & 0xFF, (charsetAl32Utf8 >> 8) & 0xFF]); // LE
  b.addByte(0x03); // encoding flags
  b.addByte(0); // compile caps length
  b.addByte(0); // runtime caps length
  b.add([0, 0]); // terminator
  return b.toBytes();
}

/// Wraps a TTC body in a TNS DATA packet (4-byte large-SDU length header).
Uint8List _wrapData(Uint8List ttcBody) {
  final out = BytesBuilder();
  final header = ByteData(tnsHeaderSize);
  header.setUint32(0, tnsHeaderSize + 2 + ttcBody.length);
  header.setUint8(4, tnsPacketData);
  out.add(header.buffer.asUint8List());
  out.add([0, 0]); // data flags
  out.add(ttcBody);
  return out.toBytes();
}

/// Extracts the TTC body (after the 8-byte header and 2 data-flag bytes) from a
/// DATA frame.
Uint8List _ttcBody(Uint8List frame) =>
    Uint8List.sublistView(frame, tnsHeaderSize + 2);

/// Reassembles whole TNS frames from a socket byte stream for tests.
class _FrameReader {
  _FrameReader(Stream<Uint8List> socket) {
    _sub = socket.listen((chunk) {
      final merged = Uint8List(_buf.length + chunk.length)
        ..setRange(0, _buf.length, _buf)
        ..setRange(_buf.length, _buf.length + chunk.length, chunk);
      _buf = merged;
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
      final frame = Uint8List.sublistView(_buf, 0, len);
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
}

/// Minimal mirror of the client's `ProtocolResponse.decode`, used to assert the
/// server places every field where the real client reads it.
class _ProtocolResponse {
  _ProtocolResponse({
    required this.msgType,
    required this.serverVersion,
    required this.banner,
    required this.charset,
    required this.nCharset,
    required this.compileCaps,
  });

  final int msgType;
  final int serverVersion;
  final String banner;
  final int charset;
  final int nCharset;
  final Uint8List? compileCaps;

  static _ProtocolResponse decode(Uint8List data) {
    final r = ReadBuffer(data);
    final msgType = r.readUint8();
    final serverVersion = r.readUint8();
    r.skip(1);
    final bannerBytes = <int>[];
    while (r.hasRemaining) {
      final b = r.readUint8();
      if (b == 0) break;
      bannerBytes.add(b);
      if (bannerBytes.length >= 48) break;
    }
    final banner = String.fromCharCodes(bannerBytes);
    final charset = r.readUint16LE();
    r.readUint8(); // server flags
    final numElem = r.readUint16LE();
    if (numElem > 0) r.skip(numElem * 5);
    final fdoLen = r.readUint16BE();
    final fdo = r.readBytes(fdoLen);
    var nCharset = 0;
    if (fdo.length > 10) {
      final ix = 6 + fdo[5] + fdo[6];
      if (ix + 4 < fdo.length) {
        nCharset = (fdo[ix + 3] << 8) + fdo[ix + 4];
      }
    }
    Uint8List? compileCaps;
    if (r.hasRemaining) {
      final len = r.readUint8();
      if (len > 0 && r.remaining >= len) compileCaps = r.readBytes(len);
    }
    return _ProtocolResponse(
      msgType: msgType,
      serverVersion: serverVersion,
      banner: banner,
      charset: charset,
      nCharset: nCharset,
      compileCaps: compileCaps,
    );
  }
}
