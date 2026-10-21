/// A self-contained emulation of a *native* (thick) Oracle OCI/OCCI client's
/// wire behaviour, up to the authentication point.
///
/// The real thick client (PHP `oci8`, OCCI, Instant Client) differs from thin
/// clients (node/python/dart `oracledb`) in several ways the server must handle:
///   * it sends the connect descriptor out-of-line (the large connect-data
///     "overflow" flow), which is how the server tags a session as native;
///   * after the handshake it runs an out-of-band break/reset self-test;
///   * it strictly parses the TTC PROTOCOL and DATA-TYPES responses, so the
///     server must reply with a real 23ai listener's byte-exact messages.
///
/// This client lets tests (and future native-auth development) drive that path
/// without needing a real Instant Client installed — the "other gun" that can
/// be swapped in for the PHP `oci8` client. It deliberately stops at AUTH:
/// native AUTH marshaling is not implemented server-side yet.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_db_server/server/oracle_codec.dart';

import 'oracle_support.dart'
    show FrameReader, wrapData, protocolRequest, dataTypesRequest, ttcBody;

const int _tnsHeaderSize = 8;
const int _tnsPacketConnect = 1;
const int _tnsPacketData = 6;
const int _tnsPacketMarker = 12;
const int _ttcMsgTypeFunction = 3;
const int _ttcAuthPhaseOne = 0x76;

const String _defaultDescriptor =
    '(DESCRIPTION=(CONNECT_DATA=(SERVICE_NAME=FREEPDB1)))';

/// Builds a native CONNECT packet. The descriptor length is announced but the
/// descriptor itself is *not* inline (the offset points just past this packet),
/// so the server treats it as the overflow flow and marks the session native.
Uint8List buildNativeConnect({
  String descriptor = _defaultDescriptor,
  int versionDesired = 320,
  int versionMinimum = 300,
  int serviceOptions = 0x0C41,
  int sdu = 8192,
  int tdu = 0xFFFF,
  int connectFlags0 = 0x41,
  int connectFlags1 = 0x41,
}) {
  final descLen = utf8.encode(descriptor).length;
  const bodyLen = 66;
  final body = ByteData(bodyLen);
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

  final header = ByteData(_tnsHeaderSize);
  header.setUint16(0, _tnsHeaderSize + bodyLen);
  header.setUint8(4, _tnsPacketConnect);
  return (BytesBuilder()
        ..add(header.buffer.asUint8List())
        ..add(body.buffer.asUint8List()))
      .toBytes();
}

/// The follow-up DATA packet that carries the descriptor after a native
/// CONNECT. Uses 2-byte framing (it arrives before the ACCEPT).
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

/// A RESET marker (4-byte large-SDU framing). Body `[1, 0, 2]` is the standard
/// reset marker the native client sends during its break/reset self-test.
Uint8List buildResetMarker() {
  final header = ByteData(_tnsHeaderSize);
  header.setUint32(0, _tnsHeaderSize + 3);
  header.setUint8(4, _tnsPacketMarker);
  return (BytesBuilder()
        ..add(header.buffer.asUint8List())
        ..add(const [1, 0, 2]))
      .toBytes();
}

/// Builds a native-format AUTH_PHASE_ONE message body (no TNS framing).
///
/// Unlike the thin client's self-describing UB4 key-value layout, the native
/// client marshals OCI-RPC style: 8-byte pointer-indicator arguments
/// (`FE FF FF FF FF FF FF FF`), 4-byte little-endian lengths, and a redundant
/// 1-byte length before each string. Provided so native AUTH can be built out.
Uint8List buildNativeAuthPhaseOne(
  String username, {
  int authMode = 0x8001,
  int sequence = 2,
  Map<String, String> pairs = const {
    'AUTH_TERMINAL': 'unknown',
    'AUTH_PROGRAM_NM': 'dart-test',
    'AUTH_MACHINE': 'localhost',
    'AUTH_PID': '0',
    'AUTH_SID': 'test',
  },
}) {
  final user = utf8.encode(username);
  final b = WriteBuffer();
  b.writeUint8(_ttcMsgTypeFunction);
  b.writeUint8(_ttcAuthPhaseOne);
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
  pairs.forEach((key, value) {
    _writeNativeKeyValue(b, key, value);
  });
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
  b.writeUint8(v.length);
  b.writeBytes(Uint8List.fromList(v));
  b.writeUint32LE(0); // flags
}

/// Drives a native (thick) client's handshake against an [OracleServer].
class NativeThickClient {
  NativeThickClient._(this.socket, this.frames);

  final Socket socket;
  final FrameReader frames;

  /// The ACCEPT frame, protocol response, and data-types response, captured as
  /// each negotiation step completes.
  Uint8List? accept;
  Uint8List? protocolResponse;
  Uint8List? dataTypesResponse;

  static Future<NativeThickClient> connect(int port) async {
    final socket = await Socket.connect(InternetAddress.loopbackIPv4, port);
    return NativeThickClient._(socket, FrameReader(socket));
  }

  /// Sends the native CONNECT + out-of-line descriptor and returns the ACCEPT.
  Future<Uint8List> connectAndAccept({String descriptor = _defaultDescriptor}) async {
    socket.add(buildNativeConnect(descriptor: descriptor));
    socket.add(buildDescriptorPacket(descriptor: descriptor));
    return accept = await frames.next();
  }

  /// Runs the break/reset OOB self-test: sends a RESET marker and returns the
  /// server's reply (which should be a RESET marker).
  Future<Uint8List> breakResetProbe() async {
    socket.add(buildResetMarker());
    return frames.next();
  }

  /// Sends the TTC PROTOCOL request and returns the response frame.
  Future<Uint8List> negotiateProtocol() async {
    socket.add(wrapData(protocolRequest()));
    return protocolResponse = await frames.next();
  }

  /// Sends the TTC DATA-TYPES request and returns the response frame.
  Future<Uint8List> negotiateDataTypes() async {
    socket.add(wrapData(dataTypesRequest()));
    return dataTypesResponse = await frames.next();
  }

  /// CONNECT → ACCEPT → break/reset → PROTOCOL → DATA-TYPES, stopping at AUTH.
  Future<void> handshakeThroughDataTypes() async {
    await connectAndAccept();
    await breakResetProbe();
    await negotiateProtocol();
    await negotiateDataTypes();
  }

  /// Sends a native-format AUTH_PHASE_ONE. The server does not parse this yet;
  /// provided so native authentication can be developed against this client.
  void sendNativeAuthPhaseOne(String username) {
    socket.add(wrapData(buildNativeAuthPhaseOne(username)));
  }

  /// The TTC body of the data-types response (no TNS framing).
  Uint8List get dataTypesBody => ttcBody(dataTypesResponse!);

  Future<void> close() async {
    await frames.cancel();
    await socket.close();
  }
}
