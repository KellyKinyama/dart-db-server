/// Native (thick) OCI/OCCI client authentication — the OCI-RPC-marshaled
/// variant of the O5LOGON exchange.
///
/// Native clients marshal AUTH differently from thin clients: 4-byte
/// little-endian lengths with a redundant 1-byte length prefix per string,
/// 8-byte `FE FF…FF` pointer-indicator arguments in the request preamble, and
/// a parameter *response* (message type 8) followed by an OERROR success
/// epilogue. The cryptography is identical O5LOGON/PBKDF2, so this module only
/// supplies the marshaling and reuses [sealPhaseOne] / [verifyO5LogonProof]
/// from `oracle_auth.dart`.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'oracle_auth.dart';
import 'oracle_codec.dart';
import 'oracle_crypto.dart';
import 'oracle_ttc.dart';

/// An 8-byte OCI pointer-indicator argument: `FE FF FF FF FF FF FF FF`.
const List<int> _indicator = [0xFE, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF];

/// The 80-byte OERROR success epilogue a real listener appends after the
/// AUTH_PHASE_ONE parameter block (error code 0).
final Uint8List _phaseOneEpilogue = Uint8List.fromList(<int>[
  0x04, 0x01, 0x00, 0x00, 0x00, 0x01,
  ...List<int>.filled(39, 0),
  0x02,
  ...List<int>.filled(33, 0),
  0x1D,
]);

void _skipIndicator(ReadBuffer body) => body.skip(_indicator.length);

/// Consumes any leading flag bytes up to and including the first 8-byte pointer
/// indicator. Some OCI builds prefix the preamble with a 2-byte flag (`01 NN`);
/// others start straight at the indicator — skipping to the first `0xFE` marker
/// handles both.
void _skipToAfterFirstIndicator(ReadBuffer body) {
  var b = body.readUint8();
  while (b != 0xFE) {
    b = body.readUint8();
  }
  body.skip(_indicator.length - 1); // the remaining FF bytes
}

/// Writes one native key/value parameter: `UB4LE(klen) U8(klen) key
/// UB4LE(vlen) U8(vlen) value UB4LE(flags)`. Auth values are always < 256 bytes.
void _writeNativeKv(WriteBuffer b, String key, String value, int flags) {
  final k = Uint8List.fromList(utf8.encode(key));
  final v = Uint8List.fromList(utf8.encode(value));
  b.writeUint32LE(k.length);
  b.writeUint8(k.length);
  b.writeBytes(k);
  b.writeUint32LE(v.length);
  b.writeUint8(v.length);
  b.writeBytes(v);
  b.writeUint32LE(flags);
}

/// Reads the native AUTH request preamble and returns the username. [body] is
/// positioned just past the TTC function header (msg type, function, sequence).
/// Layout: `01 NN | IND8 | UB4LE(userLen) | UB4LE(authMode) | IND8 |
/// UB4LE(numPairs) | IND8 | IND8 | U8(userLen) username`.
String parseNativeAuthUsername(ReadBuffer body) {
  _skipToAfterFirstIndicator(body);
  body.readUint32LE(); // username length (redundant with the inline U8 prefix)
  body.readUint32LE(); // auth mode
  _skipIndicator(body);
  body.readUint32LE(); // number of key-value pairs
  _skipIndicator(body);
  _skipIndicator(body);
  final n = body.readUint8();
  return utf8.decode(body.readBytes(n));
}

/// Parses all native AUTH request key/value pairs (used for AUTH_PHASE_TWO).
Map<String, String> parseNativeAuthPairs(ReadBuffer body) {
  _skipToAfterFirstIndicator(body);
  body.readUint32LE(); // username length
  body.readUint32LE(); // auth mode
  _skipIndicator(body);
  final numPairs = body.readUint32LE();
  _skipIndicator(body);
  _skipIndicator(body);
  final userLen = body.readUint8();
  body.readBytes(userLen); // username (already known from phase one)

  final out = <String, String>{};
  for (var i = 0; i < numPairs && body.hasRemaining; i++) {
    body.readUint32LE(); // key length (redundant)
    final keyLen = body.readUint8();
    final key = utf8.decode(body.readBytes(keyLen));
    body.readUint32LE(); // value length (redundant)
    final valLen = body.readUint8();
    final value = valLen > 0 ? utf8.decode(body.readBytes(valLen)) : '';
    body.readUint32LE(); // flags
    out[key] = value;
  }
  return out;
}

/// Builds the native AUTH_PHASE_ONE response (message type 8, six parameters,
/// then the OERROR success epilogue) for a 12c PBKDF2 [verifier].
Uint8List buildNativeAuthPhaseOneResponse(
    OracleVerifier verifier, AuthPhaseState state) {
  // Native O5LOGON uses a 32-byte server nonce (a 64-hex AUTH_SESSKEY).
  final sealed = sealPhaseOne(verifier, state, nonceLength: 32);
  final b = WriteBuffer();
  b.writeUint8(ttcMsgTypeParameter);
  b.writeUint16LE(6); // parameter count
  _writeNativeKv(b, 'AUTH_SESSKEY', sealed.authSessKey, 0);
  _writeNativeKv(
      b, 'AUTH_VFR_DATA', hexEncodeUpper(verifier.salt), verifierTypePbkdf2);
  _writeNativeKv(
      b, 'AUTH_PBKDF2_CSK_SALT', hexEncodeUpper(sealed.mixingSalt), 0);
  _writeNativeKv(b, 'AUTH_PBKDF2_VGEN_COUNT', '${verifier.iterations}', 0);
  _writeNativeKv(b, 'AUTH_PBKDF2_SDER_COUNT', '${sealed.mixingIterations}', 0);
  _writeNativeKv(b, 'AUTH_GLOBALLY_UNIQUE_DBID',
      'C204CC473D9FBD2252DDF092D37C2A25', 0);
  b.writeBytes(_phaseOneEpilogue);
  return b.toBytes();
}

/// Builds the native AUTH_PHASE_TWO success response: a parameter block of
/// session attributes the OCI client stores, then the success epilogue.
Uint8List buildNativeAuthSuccess({
  int sessionId = 1,
  int serialNum = 1,
}) {
  final params = <(String, String)>[
    ('AUTH_VERSION_STRING', 'dart-db-server Release 23.0.0.0.0 - Production'),
    ('AUTH_VERSION_SQL', '26'),
    ('AUTH_XACTION_TRAITS', '3'),
    ('AUTH_VERSION_NO', '387592192'),
    ('AUTH_VERSION_STATUS', '0'),
    ('AUTH_DBNAME', 'FREEPDB1'),
    ('AUTH_DB_ID', '0'),
    ('AUTH_USER_ID', '100'),
    ('AUTH_SESSION_ID', '$sessionId'),
    ('AUTH_SERIAL_NUM', '$serialNum'),
    ('AUTH_INSTANCE_NO', '1'),
    ('AUTH_SERVER_PID', '1'),
    ('AUTH_NLS_LXCCHARSET', 'AL32UTF8'),
    ('AUTH_NLS_LXCSORT', 'BINARY'),
    ('AUTH_NLS_LXCCALENDAR', 'GREGORIAN'),
    ('AUTH_NLS_LXCDATEFM', 'DD-MON-RR'),
    ('AUTH_NLS_LXLENSEMANTICS', 'BYTE'),
    ('AUTH_NLS_LXCCOMP', 'BINARY'),
    ('AUTH_MAX_OPEN_CURSORS', '300'),
    ('AUTH_MAX_IDEN_LENGTH', '128'),
    ('AUTH_FLAGS', '1'),
    ('AUTH_SERVER_TYPE', '1'),
    ('AUTH_SERVER_CAPABILITIES', '1'),
  ];
  final b = WriteBuffer();
  b.writeUint8(ttcMsgTypeParameter);
  b.writeUint16LE(params.length);
  for (final (key, value) in params) {
    _writeNativeKv(b, key, value, 0);
  }
  b.writeBytes(_phaseOneEpilogue);
  return b.toBytes();
}
