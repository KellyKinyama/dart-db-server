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

/// Marker-packet body types (3rd byte of a marker's [1, 0, type] body).
const int tnsMarkerTypeBreak = 1;
const int tnsMarkerTypeReset = 2;
const int tnsMarkerTypeInterrupt = 3;

/// Size of the fixed TNS header that prefixes every packet.
const int tnsHeaderSize = 8;

// Protocol versions the client advertises / we negotiate against.
const int tnsVersionMinLargeSdu = 315; // 4-byte SDU/TDU fields present
const int tnsVersionMinDataFlags = 318; // flag2 (accept flags) present
const int tnsVersionMinEndOfResponse = 319; // end-of-request/response markers

/// Highest version this server negotiates. 318 enables the 4-byte large-SDU
/// packet framing and the accept-flag word (a FAST_AUTH prerequisite) while
/// staying below the 319 end-of-request/response marker protocol.
const int tnsServerVersion = 318;

/// Version negotiated with native (thick) OCI/OCCI clients. They request a
/// connect-time out-of-band break probe below 320 (which Dart sockets can't
/// service); negotiating 320 makes them skip it.
const int tnsServerVersionNative = 320;

const int tnsDefaultSdu = 8192;
const int tnsDefaultTdu = 32767;

// Accept-flag (flag2) bits.
const int tnsAcceptFlagHasEndOfRequest = 0x02000000;
const int tnsAcceptFlagFastAuth = 0x10000000;

/// flag2 a real 23ai listener returns to a native client at version 320.
/// We omit FAST_AUTH (0x10000000) so the client runs the classical
/// PROTOCOL/DATA-TYPES/AUTH exchange this server implements for native clients.
const int tnsAcceptFlagsNativeV320 = 0x08000000;

/// 16-byte break cookie a version-320 ACCEPT carries (abs 45..60). A native
/// client stores it for in-band break resynchronization; a fixed value is fine.
final Uint8List _acceptBreakCookie = Uint8List.fromList(const [
  0xFE, 0x21, 0xD3, 0x36, 0x8A, 0xB0, 0xC0, 0xC7, //
  0xC5, 0x65, 0x91, 0x86, 0x06, 0x63, 0xD5, 0xDB, //
]);

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
  /// full packet (see [frameLength]). When [largeSdu] is set the packet length
  /// is a 4-byte field at bytes 0-3 (version >= 315) instead of the classic
  /// 2-byte length + 2-byte checksum.
  static TnsPacket decode(Uint8List data, {bool largeSdu = false}) {
    if (data.length < tnsHeaderSize) {
      throw TnsException(
        'short header: ${data.length} < $tnsHeaderSize',
      );
    }
    final r = ReadBuffer(data);
    final int packetLength;
    if (largeSdu) {
      packetLength = r.readUint32BE();
    } else {
      packetLength = r.readUint16BE();
      r.readUint16BE(); // checksum
    }
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
    // A DATA packet carries a 2-byte data-flags field ahead of its TTC
    // payload; lift it into [flags] and expose only the TTC bytes as [payload].
    if (type == tnsPacketData) {
      if (payloadLength >= 2) {
        final flags = r.readUint16BE();
        final body = payloadLength > 2 ? r.readBytes(payloadLength - 2)
            : Uint8List(0);
        return TnsPacket(type: type, payload: body, flags: flags);
      }
      return TnsPacket(
        type: type,
        payload: payloadLength > 0 ? r.readBytes(payloadLength) : Uint8List(0),
      );
    }
    final payload =
        payloadLength > 0 ? r.readBytes(payloadLength) : Uint8List(0);
    return TnsPacket(type: type, payload: payload);
  }

  /// Returns the full frame length declared in [data]'s header, or null if
  /// fewer than [tnsHeaderSize] bytes are present yet. Reads a 4-byte length
  /// when [largeSdu] is set.
  static int? frameLength(Uint8List data, int available,
      {bool largeSdu = false}) {
    if (available < tnsHeaderSize) return null;
    if (largeSdu) {
      return (data[0] << 24) | (data[1] << 16) | (data[2] << 8) | data[3];
    }
    return (data[0] << 8) | data[1];
  }
}

/// Builds a DATA packet wrapping [payload] (the TTC bytes). Uses the 4-byte
/// large-SDU length header when [largeSdu] is set.
Uint8List buildDataPacket(Uint8List payload,
    {int flags = 0, bool largeSdu = false}) {
  final b = WriteBuffer();
  final total = tnsHeaderSize + 2 + payload.length;
  if (largeSdu) {
    b.writeUint32BE(total);
  } else {
    b.writeUint16BE(total);
    b.writeUint16BE(0); // checksum
  }
  b.writeUint8(tnsPacketData);
  b.writeUint8(0); // marker
  b.writeUint16BE(0); // header checksum
  b.writeUint16BE(flags); // data flags
  b.writeBytes(payload);
  return b.toBytes();
}

/// Builds a MARKER control packet carrying [body] (e.g. `[1, 0, 2]` for a
/// RESET marker). Uses the 4-byte large-SDU length header when [largeSdu] is
/// set, matching the framing of the surrounding DATA packets.
Uint8List buildMarkerPacket(List<int> body, {bool largeSdu = false}) {
  final b = WriteBuffer();
  final total = tnsHeaderSize + body.length;
  if (largeSdu) {
    b.writeUint32BE(total);
  } else {
    b.writeUint16BE(total);
    b.writeUint16BE(0); // checksum
  }
  b.writeUint8(tnsPacketMarker);
  b.writeUint8(0); // marker/reserved
  b.writeUint16BE(0); // header checksum
  b.writeBytes(Uint8List.fromList(body));
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
    this.connectDataLength = 0,
    this.serviceOptions = 0,
    this.connectFlags0 = 0,
    this.connectFlags1 = 0,
  });

  final int versionDesired;
  final int versionMinimum;
  final int sdu;
  final int tdu;

  /// The client's requested global service options and connect flags. A real
  /// listener echoes these back in the ACCEPT; native (thick) OCI/OCCI clients
  /// validate that the server agreed to them (thin clients ignore them).
  final int serviceOptions;
  final int connectFlags0;
  final int connectFlags1;

  /// The connect descriptor string (e.g. the `(DESCRIPTION=...)` or EZConnect
  /// data), when it fit inline in the CONNECT packet.
  final String connectData;

  /// The announced descriptor length. When > 0 but [connectData] is empty, the
  /// client sent the CONNECT header without the descriptor inline (the large
  /// connect-data flow) and expects a RESEND before resending it in full.
  final int connectDataLength;

  /// Parses a CONNECT packet's raw bytes (header included).
  static ConnectRequest parse(Uint8List raw) {
    if (raw.length < tnsHeaderSize + 20) {
      throw const TnsException('CONNECT packet too short');
    }
    final r = ReadBuffer(raw);
    r.seek(tnsHeaderSize); // skip header
    final versionDesired = r.readUint16BE(); // +0
    final versionMinimum = r.readUint16BE(); // +2
    final serviceOptions = r.readUint16BE(); // +4 global service options
    final sdu = r.readUint16BE(); // +6
    final tdu = r.readUint16BE(); // +8
    r.readUint16BE(); // +10 NT characteristics
    r.readUint16BE(); // +12 line turnaround
    r.readUint16BE(); // +14 endianness marker
    final connectDataLength = r.readUint16BE(); // +16
    final connectDataOffset = r.readUint16BE(); // +18 (absolute from start)

    // Connect flags 0/1 live at payload offsets +24/+25 (after the 4-byte
    // maximum-receivable-connect-data field at +20). Present on all modern
    // CONNECT packets; default to 0 if the packet is unexpectedly short.
    int connectFlags0 = 0;
    int connectFlags1 = 0;
    if (raw.length >= tnsHeaderSize + 26) {
      connectFlags0 = raw[tnsHeaderSize + 24];
      connectFlags1 = raw[tnsHeaderSize + 25];
    }

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
      connectDataLength: connectDataLength,
      serviceOptions: serviceOptions,
      connectFlags0: connectFlags0,
      connectFlags1: connectFlags1,
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
  int serviceOptions = 0,
  int connectFlags0 = 0,
  int connectFlags1 = 0,
  bool nativeClient = false,
}) {
  // Version 320 native clients expect a longer ACCEPT: flag2 lands at abs 41
  // and a 16-byte break cookie follows. Older/thin layouts use a 37-byte
  // payload with flag2 at abs 40/41.
  final bool v320 = nativeClient && version >= tnsVersionMinEndOfResponse;
  final payload = Uint8List(v320 ? 53 : 37);
  final v = ByteData.sublistView(payload);
  // Offsets below are payload-relative (absolute = +8 for the header).
  v.setUint16(0, version); // abs 8  negotiated version
  v.setUint16(2, serviceOptions); // abs 10 echo client's global service options
  if (nativeClient) {
    // Real 23ai listeners zero the legacy 16-bit SDU/TDU and carry the values
    // only in the 32-bit fields below; native OCI/OCCI clients require this.
    v.setUint16(4, 0); // abs 12 SDU (legacy 16-bit)
    v.setUint16(6, 0); // abs 14 TDU (legacy 16-bit)
  } else {
    v.setUint16(4, sdu & 0xFFFF); // abs 12 SDU (legacy 16-bit)
    v.setUint16(6, tdu & 0xFFFF); // abs 14 TDU (legacy 16-bit)
  }
  // "Value of 1 in hardware" endianness marker, written in native (little-
  // endian) order the way a real Oracle server does: bytes 01 00.
  v.setUint16(8, 1, Endian.little); // abs 16 byte-order marker
  v.setUint16(10, 0); // abs 18 accept-data length
  // Accept-data offset: real listeners point it just past the packet (no accept
  // data follows); thin clients accept 0.
  v.setUint16(12, nativeClient ? tnsHeaderSize + payload.length : 0); // abs 20
  payload[14] = connectFlags0; // abs 22 echo client's connect flag0
  payload[15] = connectFlags1; // abs 23 echo client's connect flag1
  v.setUint32(24, sdu); // abs 32 large SDU
  v.setUint32(28, tdu); // abs 36 large TDU
  if (v320) {
    // flag2 at abs 41 (payload 33), then a 16-byte break cookie at abs 45.
    v.setUint32(33, flag2); // abs 41 accept flag2
    payload.setRange(37, 53, _acceptBreakCookie); // abs 45..60
  } else if (nativeClient) {
    // Real layout: flag2 word at payload 32..35, with a trailing 0x01 byte.
    v.setUint32(32, flag2); // abs 40 accept flag2
    payload[36] = 1; // abs 44 trailing marker
  } else {
    v.setUint32(33, flag2); // abs 41 accept flag2 (thin-client layout)
  }

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
/// what this server supports ([serverVersion], default [tnsServerVersion]),
/// floored at the client's stated minimum.
int negotiateVersion(ConnectRequest req, {int serverVersion = tnsServerVersion}) {
  final v = req.versionDesired < serverVersion
      ? req.versionDesired
      : serverVersion;
  return v < req.versionMinimum ? req.versionMinimum : v;
}
