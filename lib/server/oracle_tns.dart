/// TNS (Transparent Network Substrate) transport framing for the Oracle
/// server front-end.
///
/// This is the **server** half of the transport the sibling pure-Dart client
/// (`../dart-oracledb/lib/src/transport/packet.dart`) speaks: it decodes the
/// CONNECT a client sends and encodes the ACCEPT the client expects, plus the
/// DATA/MARKER/RESEND frames that carry everything above this layer.
///
/// All multi-byte header fields are big-endian. Field offsets mirror the
/// constant names the client uses so the two sides diff cleanly.
library;

import 'dart:typed_data';

import 'oracle_codec.dart';

// ---------------------------------------------------------------------------
// Packet types (NSPTxx)
// ---------------------------------------------------------------------------

const int tnsPacketConnect = 1;
const int tnsPacketAccept = 2;
const int tnsPacketAck = 3;
const int tnsPacketRefuse = 4;
const int tnsPacketRedirect = 5;
const int tnsPacketData = 6;
const int tnsPacketNull = 7;
const int tnsPacketAbort = 9;
const int tnsPacketResend = 11;
const int tnsPacketMarker = 12;
const int tnsPacketAttention = 13;

/// Size of the fixed TNS header that prefixes every packet.
const int tnsHeaderSize = 8;

// Protocol versions the client advertises / we negotiate against.
const int tnsVersionMinLargeSdu = 315; // 4-byte SDU/TDU fields present
const int tnsVersionMinDataFlags = 318; // flag2 (accept flags) present
const int tnsVersionMinEndOfResponse = 319; // end-of-request/response markers

/// Highest version this server negotiates. Pinned to 318 for now: enables the
/// 4-byte SDU and the accept-flag word without taking on the 319
/// end-of-request/response marker protocol (a later phase).
const int tnsServerVersion = 318;

const int tnsDefaultSdu = 8192;
const int tnsDefaultTdu = 32767;

// Accept-flag (flag2) bits.
const int tnsAcceptFlagHasEndOfRequest = 0x02000000;
const int tnsAcceptFlagFastAuth = 0x10000000;

// DATA packet flags (NSPDAxxx).
const int tnsDataFlagEndOfRequest = 0x2000;
const int tnsDataFlagEndOfResponse = 0x0020;

/// Thrown when a TNS frame cannot be parsed.
class TnsException implements Exception {
  const TnsException(this.message);
  final String message;
  @override
  String toString() => 'TnsException: $message';
}

/// A decoded TNS frame: an 8-byte header plus its payload.
class TnsPacket {
  TnsPacket({required this.type, required this.payload, this.flags = 0});

  /// Packet type (one of the `tnsPacket*` constants).
  final int type;

  /// Payload bytes following the 8-byte header.
  final Uint8List payload;

  /// DATA-packet data flags (bytes 8..9 of a DATA packet); 0 otherwise.
  final int flags;

  int get length => tnsHeaderSize + payload.length;

  /// Encodes a non-DATA control packet (header + raw payload).
  Uint8List encode() {
    final b = WriteBuffer();
    b.writeUint16BE(length);
    b.writeUint16BE(0); // packet checksum
    b.writeUint8(type);
    b.writeUint8(0); // marker/reserved
    b.writeUint16BE(0); // header checksum
    b.writeBytes(payload);
    return b.toBytes();
  }

  /// Decodes exactly one TNS frame from [data], which must contain at least a
  /// full packet (see [frameLength]).
  static TnsPacket decode(Uint8List data) {
    if (data.length < tnsHeaderSize) {
      throw TnsException(
        'short header: ${data.length} < $tnsHeaderSize',
      );
    }
    final r = ReadBuffer(data);
    final packetLength = r.readUint16BE();
    r.readUint16BE(); // checksum
    final type = r.readUint8();
    r.readUint8(); // marker
    r.readUint16BE(); // header checksum
    final payloadLength = packetLength - tnsHeaderSize;
    if (payloadLength < 0) {
      throw TnsException('invalid packet length $packetLength');
    }
    if (data.length < packetLength) {
      throw TnsException(
        'truncated: have ${data.length}, need $packetLength',
      );
    }
    var flags = 0;
    if (type == tnsPacketData && payloadLength >= 2) {
      flags = (data[tnsHeaderSize] << 8) | data[tnsHeaderSize + 1];
    }
    final payload =
        payloadLength > 0 ? r.readBytes(payloadLength) : Uint8List(0);
    return TnsPacket(type: type, payload: payload, flags: flags);
  }

  /// Returns the full frame length declared in [data]'s header, or null if
  /// fewer than [tnsHeaderSize] bytes are present yet.
  static int? frameLength(Uint8List data, int available) {
    if (available < tnsHeaderSize) return null;
    return (data[0] << 8) | data[1];
  }
}

/// Builds a DATA packet wrapping [payload] (the TTC bytes).
Uint8List buildDataPacket(Uint8List payload, {int flags = 0}) {
  final b = WriteBuffer();
  b.writeUint16BE(tnsHeaderSize + 2 + payload.length);
  b.writeUint16BE(0); // checksum
  b.writeUint8(tnsPacketData);
  b.writeUint8(0); // marker
  b.writeUint16BE(0); // header checksum
  b.writeUint16BE(flags); // data flags
  b.writeBytes(payload);
  return b.toBytes();
}

/// Parameters a client offers in its CONNECT packet.
class ConnectRequest {
  const ConnectRequest({
    required this.versionDesired,
    required this.versionMinimum,
    required this.sdu,
    required this.tdu,
    required this.connectData,
  });

  final int versionDesired;
  final int versionMinimum;
  final int sdu;
  final int tdu;

  /// The connect descriptor string (e.g. the `(DESCRIPTION=...)` or EZConnect
  /// data), when it fit inline in the CONNECT packet.
  final String connectData;

  /// Parses a CONNECT packet's raw bytes (header included).
  static ConnectRequest parse(Uint8List raw) {
    if (raw.length < tnsHeaderSize + 20) {
      throw const TnsException('CONNECT packet too short');
    }
    final r = ReadBuffer(raw);
    r.seek(tnsHeaderSize); // skip header
    final versionDesired = r.readUint16BE(); // +0
    final versionMinimum = r.readUint16BE(); // +2
    r.readUint16BE(); // +4 options
    final sdu = r.readUint16BE(); // +6
    final tdu = r.readUint16BE(); // +8
    r.readUint16BE(); // +10 NT characteristics
    r.readUint16BE(); // +12 line turnaround
    r.readUint16BE(); // +14 endianness marker
    final connectDataLength = r.readUint16BE(); // +16
    final connectDataOffset = r.readUint16BE(); // +18 (absolute from start)

    String connectData = '';
    if (connectDataLength > 0 &&
        connectDataOffset + connectDataLength <= raw.length) {
      connectData = ReadBuffer(
        Uint8List.sublistView(
          raw,
          connectDataOffset,
          connectDataOffset + connectDataLength,
        ),
      ).readString(connectDataLength);
    }
    return ConnectRequest(
      versionDesired: versionDesired,
      versionMinimum: versionMinimum,
      sdu: sdu,
      tdu: tdu,
      connectData: connectData,
    );
  }
}

/// Builds the ACCEPT packet answering a [ConnectRequest].
///
/// Field offsets are chosen so the client's `AcceptPacketInfo.parse` reads
/// back the negotiated [version], [sdu]/[tdu], and [flag2] accept bits.
Uint8List buildAcceptPacket({
  required int version,
  required int sdu,
  required int tdu,
  int flag2 = 0,
}) {
  // Payload is 37 bytes so the flag2 word lands at absolute offset 41..44.
  final payload = Uint8List(37);
  final v = ByteData.sublistView(payload);
  // Offsets below are payload-relative (absolute = +8 for the header).
  v.setUint16(0, version); // abs 8  negotiated version
  v.setUint16(2, 0); // abs 10 global service options
  v.setUint16(4, sdu & 0xFFFF); // abs 12 SDU (legacy 16-bit)
  v.setUint16(6, tdu & 0xFFFF); // abs 14 TDU (legacy 16-bit)
  v.setUint16(8, 1); // abs 16 byte-order marker
  v.setUint16(10, 0); // abs 18 accept-data length
  v.setUint16(12, 0); // abs 20 accept-data offset
  payload[14] = 0; // abs 22 accept flag0
  payload[15] = 0; // abs 23 accept flag1
  v.setUint32(24, sdu); // abs 32 large SDU
  v.setUint32(28, tdu); // abs 36 large TDU
  v.setUint32(33, flag2); // abs 41 accept flag2

  final b = WriteBuffer();
  b.writeUint16BE(tnsHeaderSize + payload.length);
  b.writeUint16BE(0); // checksum
  b.writeUint8(tnsPacketAccept);
  b.writeUint8(0); // marker
  b.writeUint16BE(0); // header checksum
  b.writeBytes(payload);
  return b.toBytes();
}

/// Negotiates the protocol version: the lowest of what the client wants and
/// what this server supports, floored at the client's stated minimum.
int negotiateVersion(ConnectRequest req) {
  final v = req.versionDesired < tnsServerVersion
      ? req.versionDesired
      : tnsServerVersion;
  return v < req.versionMinimum ? req.versionMinimum : v;
}
