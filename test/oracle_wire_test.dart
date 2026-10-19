/// Phase 0/1 conformance tests for the Oracle TNS/TTC server front-end.
///
/// Covers the transport handshake: a client CONNECT is parsed, a version is
/// negotiated, and the ACCEPT we emit places its fields where the real client
/// (`../dart-oracledb`'s `AcceptPacketInfo.parse`) reads them back.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:dart_db_server/dart_db_server.dart';
import 'package:dart_db_server/server/oracle_tns.dart';
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
}
