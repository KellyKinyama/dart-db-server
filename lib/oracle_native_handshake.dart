/// Real-Oracle native (TTC) connect + FAST_AUTH handshake, ported byte-for-byte
/// from the proven thin driver (`../dart-oracledb`) so [OracleThickClient] can
/// authenticate against a genuine Oracle listener (19c+/21c/23ai/26ai), not just
/// the dart-db-server native listener.
///
/// Oracle 23ai/26ai advertises FAST_AUTH (ACCEPT flag2 bit 0x10000000): the
/// client bundles the PROTOCOL, DATA-TYPES and AUTH_PHASE_ONE messages into one
/// round trip (message type 34). Every client DATA packet on 23ai+ must carry
/// the END_OF_RPC data flag (0x0800).
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:dart_db_server/server/oracle_codec.dart';
import 'package:dart_db_server/server/oracle_crypto.dart';

// --- TTC message / field constants ----------------------------------------
const int ttcMsgTypeProtocol = 1;
const int ttcMsgTypeDataTypes = 2;
const int ttcMsgTypeFunction = 3;
const int ttcMsgTypeFastAuth = 34;
const int ttcProtocolVersion = 6;
const int ttcAuthPhaseOne = 0x76;
const int ttcAuthPhaseTwo = 0x73;
const int ttcCharsetUtf8 = 873; // AL32UTF8
const int ttcAuthModeLogon = 0x00000001;
const int ttcAuthModeWithPassword = 0x00000100;
const int ttcVerifierType12c = 0x4815;
const int fastAuthFieldVersion = 13;
const String clientDriverName = 'dart-oracledb';

/// 23ai+ requires this data flag on every client DATA packet (END_OF_RPC).
const int tnsDataFlagsEndOfRpc = 0x0800;

// --- ACCEPT parse ----------------------------------------------------------
const int _acceptVersionOffset = 8;
const int _acceptFlag2Offset = 41;
const int _tnsVersionMinLargeSdu = 315;
const int _tnsVersionMinDataFlags = 318;
const int _tnsVersionMinEndOfResponse = 319;
const int _tnsAcceptFlagHasEndOfRequest = 0x02000000;
const int _tnsAcceptFlagFastAuth = 0x10000000;

/// Negotiated transport properties parsed from a TNS ACCEPT packet.
class AcceptInfo {
  AcceptInfo(this.version, this.useLargeSdu, this.supportsFastAuth,
      this.supportsEndOfRequest, this.sdu);
  final int version;
  final bool useLargeSdu;
  final bool supportsFastAuth;
  final bool supportsEndOfRequest;

  /// Negotiated Session Data Unit (max TNS packet size, header included).
  final int sdu;
}

/// Parse a raw ACCEPT packet (the full TNS frame).
AcceptInfo parseAccept(Uint8List frame) {
  int be16(int off) => (frame[off] << 8) | frame[off + 1];
  int be32(int off) =>
      (frame[off] << 24) | (frame[off + 1] << 16) | (frame[off + 2] << 8) |
      frame[off + 3];
  final version = be16(_acceptVersionOffset);
  final useLargeSdu = version >= _tnsVersionMinLargeSdu;
  // SDU: 2-byte field at offset 12, or 4-byte "large SDU" at offset 32 (v315+).
  var sdu = frame.length >= 14 ? be16(12) : 8192;
  if (useLargeSdu && frame.length >= 36) {
    sdu = be32(32);
  }
  if (sdu < 512) sdu = 8192; // defensive floor
  var fastAuth = false;
  var endOfRequest = false;
  if (version >= _tnsVersionMinDataFlags &&
      frame.length >= _acceptFlag2Offset + 4) {
    final flag2 = be32(_acceptFlag2Offset);
    if (version >= _tnsVersionMinEndOfResponse) {
      endOfRequest = (flag2 & _tnsAcceptFlagHasEndOfRequest) != 0;
    }
    fastAuth = (flag2 & _tnsAcceptFlagFastAuth) != 0;
  }
  return AcceptInfo(version, useLargeSdu, fastAuth, endOfRequest, sdu);
}

// --- Capabilities (ported from thin driver transport.dart) ----------------
int _ttcFieldVersion = 24; // TNS_CCAP_FIELD_VERSION_MAX (23.4)

/// Client compile capabilities (53 bytes). [endOfRequest] sets the TTC4 bit.
Uint8List buildCompileCaps({bool endOfRequest = false}) {
  final c = Uint8List(53);
  c[0] = 6; // SQL version
  c[4] = 0xBE; // logon types (O5/O7/O8/O9 LOGON)
  c[5] = 0x18; // CTB feature backport
  c[7] = _ttcFieldVersion; // field version
  c[8] = 1; // server define conv
  c[9] = 1; // dequeue with selector
  c[15] = 0x29; // TTC1
  c[16] = 0x90; // OCI1
  c[17] = 3; // TDS version
  c[18] = 7; // RPC version
  c[19] = 3; // RPC sig
  c[21] = 1; // DBF version
  c[23] = 0xCF; // LOB
  c[26] = 0x04; // TTC2
  c[27] = 1; // UB2 DTY
  c[31] = 0x10; // OCI2
  c[34] = 12; // client FN
  c[35] = 0x20; // OCI3
  c[37] = 0xB8; // TTC3
  c[39] = 8; // session signature version
  c[40] = endOfRequest ? (0x04 | 0x20) : 0x04; // TTC4
  c[42] = 0x05; // LOB2
  c[44] = 0x28; // TTC5
  c[52] = 0x03; // vector features
  return c;
}

/// Client runtime capabilities (7 bytes).
Uint8List buildRuntimeCaps() {
  final c = Uint8List(7);
  c[0] = 2; // compat (81)
  c[6] = 0x05; // TTC (zero-copy | 32k)
  return c;
}

Uint8List _trimTrailingZeros(Uint8List b) {
  var end = b.length;
  while (end > 0 && b[end - 1] == 0) {
    end--;
  }
  return Uint8List.sublistView(b, 0, end);
}

/// Write an Oracle auth key/value pair (UB4 lengths + chunked bytes + flags).
void writeKeyValue(WriteBuffer b, String key, String value, {int flags = 0}) {
  final k = Uint8List.fromList(utf8.encode(key));
  final v = Uint8List.fromList(utf8.encode(value));
  b.writeUB4(k.length);
  b.writeBytesWithLength(k);
  b.writeUB4(v.length);
  if (v.isNotEmpty) b.writeBytesWithLength(v);
  b.writeUB4(flags);
}

/// Standard client auth key/value pairs for AUTH_PHASE_ONE.
Map<String, String> defaultAuthPairs() => const {
      'AUTH_TERMINAL': 'unknown',
      'AUTH_PROGRAM_NM': 'dart-thick',
      'AUTH_MACHINE': 'localhost',
      'AUTH_PID': '1',
      'AUTH_SID': 'dart',
    };

/// Builds the FAST_AUTH (type 34) message: embedded PROTOCOL + DATA-TYPES +
/// AUTH_PHASE_ONE in one round trip.
Uint8List buildFastAuthMessage({
  required String username,
  required bool endOfRequest,
  int sequence = 1,
}) {
  final b = WriteBuffer();
  b.writeUint8(ttcMsgTypeFastAuth);
  b.writeUint8(1); // fast-auth version
  b.writeUint8(1); // flag1: server converts chars
  b.writeUint8(0); // flag2

  // Embedded PROTOCOL (with msg-type prefix, per thin driver).
  _writeProtocol(b);

  // Server charset fields (unused in client message).
  b.writeUint16BE(0);
  b.writeUint8(0);
  b.writeUint16BE(0);
  b.writeUint8(fastAuthFieldVersion);

  // Embedded DATA-TYPES.
  _writeDataTypes(b, endOfRequest);

  // Embedded AUTH_PHASE_ONE.
  _writeAuthPhaseOne(b, username, sequence);
  return b.toBytes();
}

/// Standalone PROTOCOL negotiation message (type 1) for the non-fast-auth
/// (pre-23ai) handshake, where PROTOCOL / DATA-TYPES / AUTH are sent as
/// separate round trips instead of one bundled FAST_AUTH message.
Uint8List buildProtocolMessage() {
  final b = WriteBuffer();
  _writeProtocol(b);
  return b.toBytes();
}

/// Standalone DATA-TYPES message (type 2) for the non-fast-auth handshake.
Uint8List buildDataTypesMessage({bool endOfRequest = false}) {
  final b = WriteBuffer();
  _writeDataTypes(b, endOfRequest);
  return b.toBytes();
}

/// Standalone AUTH_PHASE_ONE message (type 3 / func 0x76) for the non-fast-auth
/// handshake — requests the O8LOGON challenge for [username].
Uint8List buildAuthPhaseOneMessage(
    {required String username, int sequence = 1}) {
  final b = WriteBuffer();
  _writeAuthPhaseOne(b, username, sequence);
  return b.toBytes();
}

void _writeProtocol(WriteBuffer b) {
  b.writeUint8(ttcMsgTypeProtocol);
  b.writeUint8(ttcProtocolVersion);
  b.writeUint8(0);
  b.writeBytes(Uint8List.fromList(utf8.encode(clientDriverName)));
  b.writeUint8(0);
}

void _writeDataTypes(WriteBuffer b, bool endOfRequest) {
  b.writeUint8(ttcMsgTypeDataTypes);
  b.writeUint16LE(ttcCharsetUtf8);
  b.writeUint16LE(ttcCharsetUtf8);
  b.writeUint8(0x01 | 0x02); // MULTI_BYTE | CONV_LENGTH
  final cc = _trimTrailingZeros(buildCompileCaps(endOfRequest: endOfRequest));
  b.writeUint8(cc.length);
  b.writeBytes(cc);
  final rc = _trimTrailingZeros(buildRuntimeCaps());
  b.writeUint8(rc.length);
  b.writeBytes(rc);
  for (final dt in kClientDataTypes) {
    b.writeUint16BE(dt[0]);
    b.writeUint16BE(dt[1]);
    b.writeUint16BE(dt[2]);
    b.writeUint16BE(0);
  }
  b.writeUint16BE(0); // terminator
}

void _writeAuthPhaseOne(WriteBuffer b, String username, int sequence) {
  b.writeUint8(ttcMsgTypeFunction);
  b.writeUint8(ttcAuthPhaseOne);
  b.writeUint8(sequence & 0xFF);
  const authMode = ttcAuthModeLogon | ttcAuthModeWithPassword;
  final user = Uint8List.fromList(utf8.encode(username));
  b.writeUint8(user.isNotEmpty ? 1 : 0);
  b.writeUB4(user.length);
  b.writeUB4(authMode);
  b.writeUint8(1);
  b.writeUB4(5);
  b.writeUint8(0);
  b.writeUint8(1);
  if (user.isNotEmpty) b.writeBytesWithLength(user);
  defaultAuthPairs().forEach((k, v) => writeKeyValue(b, k, v));
}

/// Builds AUTH_PHASE_TWO (type 0x73) with the O8LOGON proof.
Uint8List buildAuthPhaseTwoMessage({
  required String username,
  required String sessionKeyHex,
  required String authPasswordHex,
  String? speedyKeyHex,
  required String alterSession,
  int sequence = 2,
  bool includeToken = true,
}) {
  final b = WriteBuffer();
  b.writeUint8(ttcMsgTypeFunction);
  b.writeUint8(ttcAuthPhaseTwo);
  b.writeUint8(sequence & 0xFF);
  if (includeToken) b.writeUB8(0); // token number (23ai fast-auth only)
  const authMode = ttcAuthModeLogon | ttcAuthModeWithPassword;
  final user = Uint8List.fromList(utf8.encode(username));
  b.writeUint8(user.isNotEmpty ? 1 : 0);
  b.writeUB4(user.length);
  b.writeUB4(authMode);
  var numPairs = 6;
  if (speedyKeyHex != null) numPairs += 1;
  b.writeUint8(1);
  b.writeUB4(numPairs);
  b.writeUint8(1);
  b.writeUint8(1);
  if (user.isNotEmpty) b.writeBytesWithLength(user);
  writeKeyValue(b, 'AUTH_SESSKEY', sessionKeyHex, flags: 1);
  if (speedyKeyHex != null) {
    writeKeyValue(b, 'AUTH_PBKDF2_SPEEDY_KEY', speedyKeyHex);
  }
  writeKeyValue(b, 'SESSION_CLIENT_CHARSET', '$ttcCharsetUtf8');
  writeKeyValue(b, 'SESSION_CLIENT_DRIVER_NAME', 'dart-thick : 0.1.0 thk');
  writeKeyValue(b, 'SESSION_CLIENT_VERSION', '111149056');
  writeKeyValue(b, 'AUTH_ALTER_SESSION', alterSession, flags: 1);
  writeKeyValue(b, 'AUTH_PASSWORD', authPasswordHex);
  return b.toBytes();
}

/// Parses an Oracle AUTH parameter response (message type 8) in the canonical
/// wire format, returning the key/value pairs and the AUTH_VFR_DATA verifier
/// flags (0 when absent).
class AuthParams {
  AuthParams(this.pairs, this.verifierType);
  final Map<String, String> pairs;
  final int verifierType;
}

/// Skips an embedded PROTOCOL response (message type 1) in a bundled FAST_AUTH
/// reply, leaving [r] positioned at the next message.
void skipProtocolResponse(ReadBuffer r) {
  r.readUint8(); // msg type (1)
  r.readUint8(); // server version
  r.skip(1);
  while (r.hasRemaining) {
    if (r.readUint8() == 0) break; // banner terminator
  }
  r.readUint16LE(); // charset id
  r.readUint8(); // server flags
  final numElem = r.readUint16LE();
  if (numElem > 0) r.skip(numElem * 5);
  final fdoLen = r.readUint16BE();
  if (fdoLen > 0) r.skip(fdoLen);
  final compileLen = r.readUint8();
  if (compileLen > 0) r.skip(compileLen);
  final runtimeLen = r.readUint8();
  if (runtimeLen > 0) r.skip(runtimeLen);
}

/// Skips an embedded DATA-TYPES response (message type 2).
void skipDataTypesResponse(ReadBuffer r) {
  r.readUint8(); // msg type (2)
  final compileLen = r.readUint8();
  if (compileLen > 0) r.skip(compileLen);
  final runtimeLen = r.readUint8();
  if (runtimeLen > 0) r.skip(runtimeLen);
}

/// Locates and parses the AUTH parameter message (type 8) within a bundled
/// FAST_AUTH response [body], starting the search after the PROTOCOL response.
/// Returns null when no valid auth challenge is present.
AuthParams? findAuthChallenge(Uint8List body) {
  final r = ReadBuffer(body);
  skipProtocolResponse(r);
  for (var p = r.position; p < body.length; p++) {
    if (body[p] != 8) continue;
    try {
      final ap = parseAuthParams(ReadBuffer(Uint8List.sublistView(body, p)));
      if (ap.pairs.containsKey('AUTH_VFR_DATA') &&
          ap.pairs.containsKey('AUTH_SESSKEY')) {
        return ap;
      }
    } catch (_) {/* not the auth message */}
  }
  return null;
}

/// Locates and parses a standalone AUTH parameter message (type 8) anywhere in
/// a non-fast-auth AUTH_PHASE_ONE response [body] (no PROTOCOL prefix to skip).
/// Returns null when no valid auth challenge is present.
AuthParams? parseAuthChallenge(Uint8List body) {
  for (var p = 0; p < body.length; p++) {
    if (body[p] != 8) continue;
    try {
      final ap = parseAuthParams(ReadBuffer(Uint8List.sublistView(body, p)));
      if (ap.pairs.containsKey('AUTH_VFR_DATA') &&
          ap.pairs.containsKey('AUTH_SESSKEY')) {
        return ap;
      }
    } catch (_) {/* not the auth message */}
  }
  return null;
}

AuthParams parseAuthParams(ReadBuffer r) {
  r.readUint8(); // message type (8 = parameter)
  final count = r.readUB2();
  final out = <String, String>{};
  var verifierType = 0;
  for (var i = 0; i < count; i++) {
    r.readUB4(); // unused leading field
    final key = r.readStringWithLength();
    final valueLen = r.readUB4();
    final value = valueLen > 0 ? r.readStringWithLength() : '';
    final flags = r.readUB4();
    if (key == 'AUTH_VFR_DATA') verifierType = flags;
    out[key] = value;
  }
  return AuthParams(out, verifierType);
}

final _rng = Random.secure();
Uint8List _randomBytes(int n) =>
    Uint8List.fromList(List<int>.generate(n, (_) => _rng.nextInt(256)));

/// The computed O8LOGON (12c PBKDF2) proof for AUTH_PHASE_TWO.
class O8LogonResult {
  O8LogonResult(this.sessionKeyHex, this.authPasswordHex, this.speedyKeyHex,
      this.comboKey);
  final String sessionKeyHex;
  final String authPasswordHex;
  final String speedyKeyHex;
  final Uint8List comboKey;

  /// Validates the server's `AUTH_SVR_RESPONSE` mutual-auth proof.
  bool verifyServerResponse(String? responseHex) {
    if (responseHex == null) return false;
    final plain = aes256CbcDecryptRaw(
        key: comboKey, iv: Uint8List(16), data: hexDecode(responseHex));
    if (plain.length < 32) return false;
    return utf8.decode(plain.sublist(16, 32)) == 'SERVER_TO_CLIENT';
  }
}

/// Computes the canonical O8LOGON proof from the AUTH_PHASE_ONE [challenge]
/// (ported from the thin driver `crypto/auth.dart`).
O8LogonResult computeO8Logon(String password, Map<String, String> challenge) {
  final iv = Uint8List(16);
  final salt = hexDecode(challenge['AUTH_VFR_DATA']!);
  final vgen = int.parse(challenge['AUTH_PBKDF2_VGEN_COUNT']!);
  final mixingSalt = hexDecode(challenge['AUTH_PBKDF2_CSK_SALT']!);
  final mixingIters = int.parse(challenge['AUTH_PBKDF2_SDER_COUNT']!);
  final serverSessKey = hexDecode(challenge['AUTH_SESSKEY']!);
  final pwd = Uint8List.fromList(utf8.encode(password));

  final passwordKey = pbkdf2Sha512(
    password: pwd,
    salt: Uint8List.fromList(
        [...salt, ...utf8.encode('AUTH_PBKDF2_SPEEDY_KEY')]),
    iterations: vgen,
    keyLength: 64,
  );
  final passwordHash = Uint8List.sublistView(
      sha512(Uint8List.fromList([...passwordKey, ...salt])), 0, 32);
  final parta =
      aes256CbcDecryptRaw(key: passwordHash, iv: iv, data: serverSessKey);
  final partb = _randomBytes(parta.length);
  final clientSessKey =
      aes256CbcEncryptPkcs7(key: passwordHash, iv: iv, data: partb);
  final sessionKeyHex = hexEncodeUpper(clientSessKey).substring(0, 64);

  final partAB =
      Uint8List.fromList([...partb.sublist(0, 32), ...parta.sublist(0, 32)]);
  final comboKey = pbkdf2Sha512(
    password: Uint8List.fromList(utf8.encode(hexEncodeUpper(partAB))),
    salt: mixingSalt,
    iterations: mixingIters,
    keyLength: 32,
  );

  final speedyInput = Uint8List.fromList([..._randomBytes(16), ...passwordKey]);
  final speedyEnc =
      aes256CbcEncryptPkcs7(key: comboKey, iv: iv, data: speedyInput);
  final speedyKeyHex = hexEncodeUpper(Uint8List.sublistView(speedyEnc, 0, 80));

  final authPassword = aes256CbcEncryptPkcs7(
      key: comboKey, iv: iv, data: Uint8List.fromList([..._randomBytes(16), ...pwd]));
  final authPasswordHex = hexEncodeUpper(authPassword);

  return O8LogonResult(sessionKeyHex, authPasswordHex, speedyKeyHex, comboKey);
}


/// The client's advertised TTC data types (`[dataType, convDataType, typeRep]`),
/// ported verbatim from the thin driver. The server negotiates against this.
const List<List<int>> kClientDataTypes = [
  [1, 1, 1], [2, 2, 10], [8, 8, 1], [12, 12, 10], [23, 23, 1], [24, 24, 1],
  [25, 25, 1], [26, 26, 1], [27, 27, 10], [28, 28, 1], [29, 29, 1], [30, 30, 1],
  [31, 31, 1], [32, 32, 1], [33, 33, 1], [10, 10, 1], [11, 11, 1], [40, 40, 1],
  [41, 41, 1], [117, 117, 1], [120, 120, 1], [290, 290, 1], [291, 291, 1],
  [292, 292, 1], [293, 293, 1], [294, 294, 1], [298, 298, 1], [299, 299, 1],
  [300, 300, 1], [301, 301, 1], [302, 302, 1], [303, 303, 1], [304, 304, 1],
  [305, 305, 1], [306, 306, 1], [307, 307, 1], [308, 308, 1], [309, 309, 1],
  [310, 310, 1], [311, 311, 1], [312, 312, 1], [313, 313, 1], [315, 315, 1],
  [316, 316, 1], [317, 317, 1], [318, 318, 1], [319, 319, 1], [320, 320, 1],
  [321, 321, 1], [322, 322, 1], [323, 323, 1], [327, 327, 1], [328, 328, 1],
  [329, 329, 1], [331, 331, 1], [333, 333, 1], [334, 334, 1], [335, 335, 1],
  [336, 336, 1], [337, 337, 1], [338, 338, 1], [339, 339, 1], [340, 340, 1],
  [341, 341, 1], [342, 342, 1], [343, 343, 1], [344, 344, 1], [345, 345, 1],
  [346, 346, 1], [348, 348, 1], [349, 349, 1], [354, 354, 1], [355, 355, 1],
  [359, 359, 1], [363, 363, 1], [380, 380, 1], [381, 381, 1], [382, 382, 1],
  [383, 383, 1], [384, 384, 1], [385, 385, 1], [386, 386, 1], [387, 387, 1],
  [388, 388, 1], [389, 389, 1], [390, 390, 1], [391, 391, 1], [393, 393, 1],
  [394, 394, 1], [395, 395, 1], [396, 396, 1], [397, 397, 1], [398, 398, 1],
  [399, 399, 1], [400, 400, 1], [401, 401, 1], [404, 404, 1], [405, 405, 1],
  [406, 406, 1], [407, 407, 1], [413, 413, 1], [414, 414, 1], [415, 415, 1],
  [416, 416, 1], [417, 417, 1], [418, 418, 1], [419, 419, 1], [420, 420, 1],
  [421, 421, 1], [422, 422, 1], [423, 423, 1], [424, 424, 1], [425, 425, 1],
  [426, 426, 1], [427, 427, 1], [429, 429, 1], [430, 430, 1], [431, 431, 1],
  [432, 432, 1], [433, 433, 1], [449, 449, 1], [450, 450, 1], [454, 454, 1],
  [455, 455, 1], [456, 456, 1], [457, 457, 1], [458, 458, 1], [459, 459, 1],
  [460, 460, 1], [461, 461, 1], [462, 462, 1], [463, 463, 1], [466, 466, 1],
  [467, 467, 1], [468, 468, 1], [469, 469, 1], [470, 470, 1], [471, 471, 1],
  [472, 472, 1], [473, 473, 1], [474, 474, 1], [475, 475, 1], [476, 476, 1],
  [477, 477, 1], [478, 478, 1], [479, 479, 1], [480, 480, 1], [481, 481, 1],
  [482, 482, 1], [483, 483, 1], [484, 484, 1], [485, 485, 1], [486, 486, 1],
  [490, 490, 1], [491, 491, 1], [492, 492, 1], [493, 493, 1], [494, 494, 1],
  [495, 495, 1], [496, 496, 1], [498, 498, 1], [499, 499, 1], [500, 500, 1],
  [501, 501, 1], [502, 502, 1], [509, 509, 1], [510, 510, 1], [513, 513, 1],
  [514, 514, 1], [516, 516, 1], [517, 517, 1], [518, 518, 1], [519, 519, 1],
  [520, 520, 1], [521, 521, 1], [522, 522, 1], [523, 523, 1], [524, 524, 1],
  [525, 525, 1], [526, 526, 1], [527, 527, 1], [528, 528, 1], [529, 529, 1],
  [530, 530, 1], [531, 531, 1], [532, 532, 1], [533, 533, 1], [534, 534, 1],
  [535, 535, 1], [536, 536, 1], [537, 537, 1], [538, 538, 1], [539, 539, 1],
  [540, 540, 1], [541, 541, 1], [542, 542, 1], [543, 543, 1], [560, 560, 1],
  [565, 565, 1], [572, 572, 1], [573, 573, 1], [574, 574, 1], [575, 575, 1],
  [576, 576, 1], [578, 578, 1], [563, 563, 1], [564, 564, 1], [579, 579, 1],
  [580, 580, 1], [581, 581, 1], [582, 582, 1], [583, 583, 1], [584, 584, 1],
  [585, 585, 1], [3, 2, 10], [4, 2, 10], [5, 1, 1], [6, 2, 10], [7, 2, 10],
  [9, 1, 1], [15, 1, 1], [39, 39, 1], [68, 2, 10], [91, 2, 10], [94, 1, 1],
  [95, 23, 1], [96, 96, 1], [97, 96, 1], [100, 100, 1], [101, 101, 1],
  [102, 102, 1], [104, 11, 1], [106, 106, 1], [108, 109, 1], [109, 109, 1],
  [110, 111, 1], [111, 111, 1], [112, 112, 1], [113, 113, 1], [114, 114, 1],
  [115, 115, 1], [116, 102, 1], [119, 119, 1], [198, 198, 1], [146, 146, 1],
  [152, 2, 10], [153, 2, 10], [154, 2, 10], [155, 1, 1], [156, 12, 10],
  [172, 2, 10], [178, 178, 1], [179, 179, 1], [180, 180, 1], [181, 181, 1],
  [182, 182, 1], [183, 183, 1], [184, 12, 10], [185, 185, 1], [186, 186, 1],
  [187, 187, 1], [188, 188, 1], [189, 189, 1], [190, 190, 1], [195, 112, 1],
  [196, 113, 1], [197, 114, 1], [208, 208, 1], [231, 231, 1], [232, 231, 1],
  [233, 233, 1], [241, 109, 1], [252, 252, 1], [590, 590, 1], [591, 591, 1],
  [592, 592, 1], [613, 613, 1], [614, 614, 1], [615, 615, 1], [616, 616, 1],
  [611, 611, 1], [612, 612, 1], [593, 593, 1], [594, 594, 1], [595, 595, 1],
  [596, 596, 1], [597, 597, 1], [598, 598, 1], [599, 599, 1], [600, 600, 1],
  [601, 601, 1], [602, 602, 1], [603, 603, 1], [604, 604, 1], [605, 605, 1],
  [622, 622, 1], [623, 623, 1], [624, 624, 1], [625, 625, 1], [626, 626, 1],
  [627, 627, 1], [628, 628, 1], [629, 629, 1], [630, 630, 1], [631, 631, 1],
  [632, 632, 1], [637, 637, 1], [638, 638, 1], [636, 636, 1], [639, 639, 1],
  [663, 663, 1], [640, 640, 1], [652, 652, 1], [646, 646, 1], [647, 647, 1],
  [127, 127, 1], // vector
];
