/// TTC (Two-Task Common) negotiation messages for the Oracle server
/// front-end.
///
/// TTC rides inside TNS DATA packets. After the TNS CONNECT/ACCEPT handshake
/// the client runs the classical negotiation: it sends a PROTOCOL request
/// (function 1), then a DATA-TYPES request (function 2), and expects a matching
/// response to each before authentication.
///
/// These builders are the inverse of the client decoders in
/// `../dart-oracledb/lib/src/protocol/messages/protocol_message.dart`
/// (`ProtocolResponse.decode`, `parseDataTypesResponse`): every field is placed
/// exactly where that decoder reads it.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'oracle_codec.dart';

/// TTC message/function codes (first byte of a TTC message body).
const int ttcMsgProtocol = 1;
const int ttcMsgDataTypes = 2;

/// TTC message types that prefix every TTC body (shared across auth, execute,
/// and negotiation). The protocol/data-types negotiation reuse 1/2 above.
const int ttcMsgTypeFunction = 3; // RPC function call
const int ttcMsgTypeError = 4; // error / success-with-rowcount
const int ttcMsgTypeRowHeader = 6; // fetch row header
const int ttcMsgTypeRowData = 7; // one result row
const int ttcMsgTypeParameter = 8; // key-value parameter block
const int ttcMsgTypeStatus = 9; // terminal call status
const int ttcMsgTypeDescribeInfo = 16; // query column metadata

/// Server protocol version byte the client stores (Oracle 8.1+ uses 6).
const int ttcServerVersion = 6;

/// AL32UTF8 character set id. The client speaks UTF-8 on the wire.
const int charsetAl32Utf8 = 873;

/// AL16UTF16 national character set id (the national/csfrm charset).
const int charsetAl16Utf16 = 2000;

/// Default server banner. Includes a `Release NN.` token the client's
/// `_extractMajorVersion` parses for feature gating; kept at 19 so the
/// classical (non-FAST_AUTH) negotiation path stays clean.
const String defaultServerBanner =
    'dart-db-server Release 19.0.0.0.0 - Production';

// Compile-capability indices (TNS_CCAP_*), mirroring the client builder.
const int _ccapSqlVersion = 0;
const int _ccapLogonTypes = 4;
const int _ccapCtbFeatureBackport = 5;
const int _ccapFieldVersion = 7;
const int _ccapServerDefineConv = 8;
const int _ccapTtc1 = 15;
const int _ccapOci1 = 16;
const int _ccapTdsVersion = 17;
const int _ccapRpcVersion = 18;
const int _ccapRpcSig = 19;
const int _ccapDbfVersion = 21;
const int _ccapLob = 23;
const int _ccapTtc2 = 26;
const int _ccapUb2Dty = 27;
const int _ccapClientFn = 34;
const int _ccapTtc3 = 37;
const int _ccapTtc4 = 40;
const int _ccapLob2 = 42;
const int _ccapMax = 53;

// Runtime-capability indices (TNS_RCAP_*).
const int _rcapCompat = 0;
const int _rcapTtc = 6;
const int _rcapMax = 7;

/// Field version the server advertises at compile-cap slot 7. The client caps
/// its own `ttcFieldVersion` at this value; 24 is TNS_CCAP_FIELD_VERSION_MAX.
const int serverFieldVersion = 24;

/// Builds the server's compile-capability vector (53 bytes). The client only
/// strictly reads slot 7 (field version), but a realistic vector keeps later
/// phases honest.
Uint8List buildServerCompileCaps() {
  final caps = Uint8List(_ccapMax);
  caps[_ccapSqlVersion] = 6;
  caps[_ccapLogonTypes] = 8 | 2 | 32 | 64 | 0x80; // O5/O7/O8/O9 logon
  caps[_ccapCtbFeatureBackport] = 0x08 | 0x10;
  caps[_ccapFieldVersion] = serverFieldVersion;
  caps[_ccapServerDefineConv] = 1;
  caps[_ccapTtc1] = 0x20 | 0x01 | 0x08;
  caps[_ccapOci1] = 0x10 | 0x80;
  caps[_ccapTdsVersion] = 3;
  caps[_ccapRpcVersion] = 7;
  caps[_ccapRpcSig] = 3;
  caps[_ccapDbfVersion] = 1;
  caps[_ccapLob] = 0x01 | 0x02 | 0x04 | 0x08 | 0x40 | 0x80;
  caps[_ccapTtc2] = 0x04;
  caps[_ccapUb2Dty] = 1;
  caps[_ccapClientFn] = 12;
  caps[_ccapTtc3] = 0x10 | 0x20 | 0x80 | 0x08;
  caps[_ccapTtc4] = 0x04;
  caps[_ccapLob2] = 0x01 | 0x04;
  return caps;
}

/// Builds the server's runtime-capability vector (7 bytes).
Uint8List buildServerRuntimeCaps() {
  final caps = Uint8List(_rcapMax);
  caps[_rcapCompat] = 2; // TNS_RCAP_COMPAT_81
  caps[_rcapTtc] = 0x01 | 0x04; // ZERO_COPY | 32K
  return caps;
}

/// Builds a minimal "format descriptor" (FDO) blob from which the client reads
/// the national character set id at the fixed offset its decoder uses
/// (`ix = 6 + fdo[5] + fdo[6]`, then `nCharsetId = (fdo[ix+3] << 8) |
/// fdo[ix+4]`). With bytes 5 and 6 zero, `ix = 6`, so slots 9 and 10 carry the
/// national charset.
Uint8List _buildFdo(int nCharset) {
  final fdo = Uint8List(13);
  fdo[9] = (nCharset >> 8) & 0xFF;
  fdo[10] = nCharset & 0xFF;
  return fdo;
}

/// Builds the TTC PROTOCOL response (function 1) answering the client's
/// PROTOCOL request. Returned bytes are the TTC body (no TNS framing); wrap
/// them in a DATA packet before sending.
Uint8List buildProtocolResponse({
  String banner = defaultServerBanner,
  int charset = charsetAl32Utf8,
  int nCharset = charsetAl16Utf16,
  int serverFlags = 0,
  Uint8List? compileCaps,
  Uint8List? runtimeCaps,
}) {
  final compile = compileCaps ?? buildServerCompileCaps();
  final runtime = runtimeCaps ?? buildServerRuntimeCaps();
  final fdo = _buildFdo(nCharset);

  final b = WriteBuffer();
  b.writeUint8(ttcMsgProtocol); // message type
  b.writeUint8(ttcServerVersion); // server version
  b.writeUint8(0); // reserved byte the client skips
  b.writeBytes(Uint8List.fromList(utf8.encode(banner)));
  b.writeUint8(0); // banner terminator
  b.writeUint16LE(charset); // server charset id
  b.writeUint8(serverFlags); // server flags
  b.writeUint16LE(0); // numElem: no charset elements
  b.writeUint16BE(fdo.length); // FDO length (big-endian)
  b.writeBytes(fdo);
  b.writeUint8(compile.length);
  b.writeBytes(compile);
  b.writeUint8(runtime.length);
  b.writeBytes(runtime);
  return b.toBytes();
}

/// Builds the TTC DATA-TYPES response (function 2). The client's
/// `parseDataTypesResponse` reads the message-type byte then type-mapping
/// pairs until a `0x0000` terminator — so an empty mapping list is valid and
/// sufficient for negotiation. Returned bytes are the TTC body only.
Uint8List buildDataTypesResponse() {
  final b = WriteBuffer();
  b.writeUint8(ttcMsgDataTypes);
  b.writeUint16BE(0); // terminator: no data-type mappings
  return b.toBytes();
}
