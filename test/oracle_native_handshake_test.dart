/// Native (thick) OCI/OCCI client handshake conformance, driven by the
/// in-process [NativeThickClient] emulator (no Instant Client required).
///
/// Proves the server takes its native-client code path end-to-end through the
/// DATA-TYPES negotiation — the checkpoint for native support — while the thin
/// client path (covered elsewhere) is unchanged.
library;

import 'dart:typed_data';

import 'package:dart_db_server/dart_db_server.dart';
import 'package:dart_db_server/server/oracle_codec.dart';
import 'package:dart_db_server/server/oracle_native_datatypes.dart';
import 'package:test/test.dart';

import 'oracle_native_client.dart';
import 'oracle_support.dart' show ttcBody;

/// Reads the `numElem` (charset-element count) field from a PROTOCOL response
/// frame. The native response carries the full conversion map (10); the thin
/// response carries none (0).
int _protocolNumElem(Uint8List frame) {
  final r = ReadBuffer(ttcBody(frame));
  r.readUint8(); // message type (1)
  r.readUint8(); // server version
  r.readUint8(); // reserved
  while (r.readUint8() != 0) {} // banner, null-terminated
  r.readUint16LE(); // charset id
  r.readUint8(); // server flags
  return r.readUint16LE(); // numElem
}

void main() {
  group('native thick-client handshake', () {
    late Database db;
    late OracleServer server;
    late NativeThickClient client;

    setUp(() async {
      db = await Database.open(null);
      server = OracleServer(db, port: 0, users: {'app': 'secret'});
      await server.start();
      client = await NativeThickClient.connect(server.boundPort);
    });

    tearDown(() async {
      await client.close();
      await server.stop();
    });

    test('ACCEPT echoes the client service options and uses native layout',
        () async {
      final accept = await client.connectAndAccept();
      // 61-byte version-320 ACCEPT: type 2.
      expect(accept.length, 61);
      expect(accept[4], 2);
      // Negotiated version 320.
      expect(accept[8], 0x01);
      expect(accept[9], 0x40);
      // Service options are echoed with PACKET_IO (0x400) cleared: 0x0C41 ->
      // 0x0841 (so the native client doesn't pick async I/O / an OOB probe).
      expect(accept[10], 0x08);
      expect(accept[11], 0x41);
      // Native layout: legacy 16-bit SDU/TDU zeroed.
      expect(accept[12], 0); // SDU16 high
      expect(accept[13], 0); // SDU16 low
    });

    test('break/reset self-test is answered with a RESET marker', () async {
      await client.connectAndAccept();
      final reply = await client.breakResetProbe();
      expect(reply[4], 12); // MARKER packet type
      // Body [1, 0, 2] after the 8-byte header (4-byte large-SDU framing).
      expect(reply.sublist(8), [1, 0, 2]);
    });

    test('PROTOCOL response carries the full charset map (native path)',
        () async {
      await client.connectAndAccept();
      await client.breakResetProbe();
      final proto = await client.negotiateProtocol();
      expect(_protocolNumElem(proto), 10);
    });

    test('DATA-TYPES response is the real 23ai type list (native path)',
        () async {
      await client.connectAndAccept();
      await client.breakResetProbe();
      await client.negotiateProtocol();
      await client.negotiateDataTypes();
      expect(client.dataTypesBody, nativeDataTypesResponse);
    });

    test('full handshake completes through DATA TYPES', () async {
      await client.handshakeThroughDataTypes();
      expect(_protocolNumElem(client.protocolResponse!), 10);
      expect(client.dataTypesBody, nativeDataTypesResponse);
    });
  });
}
