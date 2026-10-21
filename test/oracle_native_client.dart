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
/// This client lets tests drive that path without needing a real Instant
/// Client installed — the "other gun" that can be swapped in for the PHP
/// `oci8` client. It runs the full native authentication exchange: the
/// FAST_AUTH decline, the classical DATA-TYPES + AUTH_PHASE_ONE/TWO round
/// trips, the O5LOGON/PBKDF2 client crypto, and validation of the server's
/// AUTH_SVR_RESPONSE mutual-auth proof.
///
/// The protocol details it mirrors are documented in
/// `doc/oracle-native-thick-client-auth.md`.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dart_db_server/server/oracle_codec.dart';
import 'package:dart_db_server/server/oracle_crypto.dart';

import 'oracle_support.dart'
    show FrameReader, wrapData, protocolRequest, dataTypesRequest, ttcBody;

const int _tnsHeaderSize = 8;
const int _tnsPacketConnect = 1;
const int _tnsPacketData = 6;
const int _tnsPacketMarker = 12;
const int _ttcMsgTypeFunction = 3;
const int _ttcAuthPhaseOne = 0x76;
const int _ttcAuthPhaseTwo = 0x73;
const int _ttcMsgTypeParameter = 8;
const int _ttcMsgTypeFastAuth = 34;

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

/// Builds a native-format AUTH message body (no TNS framing) for [functionCode]
/// (AUTH_PHASE_ONE `0x76` or AUTH_PHASE_TWO `0x73`).
///
/// Unlike the thin client's self-describing UB4 key-value layout, the native
/// client marshals OCI-RPC style: 8-byte pointer-indicator arguments
/// (`FE FF FF FF FF FF FF FF`), 4-byte little-endian lengths, and a redundant
/// 1-byte length before each non-empty string.
Uint8List buildNativeAuthMessage({
  required int functionCode,
  required String username,
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
  b.writeUint8(functionCode);
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
  pairs.forEach((key, value) => _writeNativeKeyValue(b, key, value));
  return b.toBytes();
}

/// AUTH_PHASE_ONE convenience wrapper over [buildNativeAuthMessage].
Uint8List buildNativeAuthPhaseOne(String username, {int sequence = 2}) =>
    buildNativeAuthMessage(
        functionCode: _ttcAuthPhaseOne, username: username, sequence: sequence);

void _writeIndicator(WriteBuffer b) {
  b.writeUint8(0xFE);
  for (var i = 0; i < 7; i++) {
    b.writeUint8(0xFF);
  }
}

/// Writes one native key/value pair. A real client omits the inline length byte
/// (and bytes) for an empty value, writing only the 4-byte length of 0.
void _writeNativeKeyValue(WriteBuffer b, String key, String value) {
  final k = utf8.encode(key);
  final v = utf8.encode(value);
  b.writeUint32LE(k.length);
  b.writeUint8(k.length);
  b.writeBytes(Uint8List.fromList(k));
  b.writeUint32LE(v.length);
  if (v.isNotEmpty) {
    b.writeUint8(v.length);
    b.writeBytes(Uint8List.fromList(v));
  }
  b.writeUint32LE(0); // flags (the server ignores these)
}

final _random = Random.secure();

Uint8List _randomBytes(int n) =>
    Uint8List.fromList(List<int>.generate(n, (_) => _random.nextInt(256)));

/// Derives the 12c PBKDF2 verifier hash: `SHA512(PBKDF2-HMAC-SHA512(password,
/// salt + "AUTH_PBKDF2_SPEEDY_KEY", iterations, 64) + salt)[0:32]`.
Uint8List _pbkdf2PasswordHash(String password, Uint8List salt, int iterations) {
  final extendedSalt =
      Uint8List.fromList([...salt, ...utf8.encode('AUTH_PBKDF2_SPEEDY_KEY')]);
  final derived = pbkdf2Sha512(
    password: Uint8List.fromList(utf8.encode(password)),
    salt: extendedSalt,
    iterations: iterations,
    keyLength: 64,
  );
  return Uint8List.sublistView(
      sha512(Uint8List.fromList([...derived, ...salt])), 0, 32);
}

/// Parses a native parameter response (message type 8): a UB2LE count then
/// `UB4LE(klen) U8 key UB4LE(vlen) [value] UB4LE(flags)` triples. Values of 254+
/// bytes use the chunked `0xFE` form with 4-byte little-endian chunk sizes.
Map<String, String> _parseNativeResponseParams(Uint8List body) {
  final r = ReadBuffer(body);
  r.readUint8(); // message type (8)
  final count = r.readUint16LE();
  final out = <String, String>{};
  for (var i = 0; i < count && r.hasRemaining; i++) {
    r.readUint32LE(); // key length (redundant)
    final key = utf8.decode(r.readBytes(r.readUint8()));
    final declared = r.readUint32LE();
    var value = '';
    if (declared != 0) {
      final marker = r.readUint8();
      if (marker == 0xFE) {
        final bytes = <int>[];
        for (var size = r.readUint32LE(); size != 0; size = r.readUint32LE()) {
          bytes.addAll(r.readBytes(size));
        }
        value = utf8.decode(bytes);
      } else {
        value = utf8.decode(r.readBytes(marker));
      }
    }
    r.readUint32LE(); // flags
    out[key] = value;
  }
  return out;
}

/// The client half of the O5LOGON/PBKDF2 exchange, derived from a phase-one
/// challenge. Produces the phase-two `AUTH_SESSKEY`/`AUTH_PASSWORD` proof and
/// validates the server's `AUTH_SVR_RESPONSE`.
class _NativeO5Logon {
  _NativeO5Logon._(this._comboKey, this.clientSessKeyHex, this.authPasswordHex);

  final Uint8List _comboKey;
  final String clientSessKeyHex;
  final String authPasswordHex;

  factory _NativeO5Logon.fromChallenge({
    required String password,
    required Map<String, String> challenge,
  }) {
    final iv = Uint8List(16);
    final salt = hexDecode(challenge['AUTH_VFR_DATA']!);
    final iterations = int.parse(challenge['AUTH_PBKDF2_VGEN_COUNT']!);
    final mixingSalt = hexDecode(challenge['AUTH_PBKDF2_CSK_SALT']!);
    final mixingIterations = int.parse(challenge['AUTH_PBKDF2_SDER_COUNT']!);
    final serverSessKey = hexDecode(challenge['AUTH_SESSKEY']!);

    final passwordHash = _pbkdf2PasswordHash(password, salt, iterations);
    // Recover the server nonce, mint our own, and seal it back for the server.
    final serverNonce =
        aes256CbcDecryptRaw(key: passwordHash, iv: iv, data: serverSessKey);
    final clientNonce = _randomBytes(serverNonce.length);
    final clientSessKey =
        aes256CbcEncryptRaw(key: passwordHash, iv: iv, data: clientNonce);
    // Combo key over hex(clientNonce[0:32] + serverNonce[0:32]).
    final partAB = Uint8List(64)
      ..setRange(0, 32, clientNonce)
      ..setRange(32, 64, serverNonce);
    final comboKey = pbkdf2Sha512(
      password: Uint8List.fromList(utf8.encode(hexEncodeUpper(partAB))),
      salt: mixingSalt,
      iterations: mixingIterations,
      keyLength: 32,
    );
    // AUTH_PASSWORD = PKCS7(16 random bytes + password) under the combo key.
    final authPassword = aes256CbcEncryptPkcs7(
      key: comboKey,
      iv: iv,
      data: Uint8List.fromList([..._randomBytes(16), ...utf8.encode(password)]),
    );
    return _NativeO5Logon._(
      comboKey,
      hexEncodeUpper(clientSessKey),
      hexEncodeUpper(authPassword),
    );
  }

  Map<String, String> phaseTwoPairs() => {
        'AUTH_SESSKEY': clientSessKeyHex,
        'AUTH_PASSWORD': authPasswordHex,
        'AUTH_TERMINAL': 'dart-test',
        'AUTH_PROGRAM_NM': 'dart-test',
        'AUTH_MACHINE': 'localhost',
        'AUTH_PID': '0',
        'AUTH_SID': 'test',
      };

  /// Validates the server's mutual-auth proof: `AUTH_SVR_RESPONSE` decrypts
  /// under the combo key to `random16 + "SERVER_TO_CLIENT" + PKCS7`.
  bool verifyServerResponse(String? responseHex) {
    if (responseHex == null) return false;
    final plain = aes256CbcDecryptRaw(
        key: _comboKey, iv: Uint8List(16), data: hexDecode(responseHex));
    if (plain.length < 32) return false;
    return utf8.decode(plain.sublist(16, 32)) == 'SERVER_TO_CLIENT';
  }
}

/// The outcome of a native [NativeThickClient.login].
class NativeLoginResult {
  NativeLoginResult({required this.authenticated, required this.params});

  /// Whether the server's AUTH_SVR_RESPONSE mutual-auth proof validated.
  final bool authenticated;

  /// The session parameters the server returned on success (empty on failure).
  final Map<String, String> params;
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

  /// The protocol-only response (message type 28) the server returns when it
  /// declines the FAST_AUTH attempt.
  Uint8List? fastAuthResponse;

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

  /// Sends a FAST_AUTH (message type 34) attempt and returns the server's
  /// protocol-only decline (message type 28). A real 23ai listener declines
  /// FAST_AUTH for native clients, so the client then runs classical auth.
  Future<Uint8List> fastAuthDecline() async {
    // version, flag1, flag2 — the server ignores the body and just declines.
    socket.add(wrapData(
        Uint8List.fromList([_ttcMsgTypeFastAuth, 0x01, 0x02, 0x00])));
    return fastAuthResponse = await frames.next();
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

  /// Runs the full native authentication flow the way a real OCI/OCCI client
  /// does: CONNECT → ACCEPT → break/reset → FAST_AUTH decline → DATA-TYPES →
  /// AUTH_PHASE_ONE → AUTH_PHASE_TWO, computing the O5LOGON/PBKDF2 proof and
  /// validating the server's AUTH_SVR_RESPONSE. [password] must match the
  /// server's PBKDF2 verifier for [username].
  Future<NativeLoginResult> login({
    required String username,
    required String password,
  }) async {
    await connectAndAccept();
    await breakResetProbe();
    await fastAuthDecline();
    await negotiateDataTypes();

    // Phase one: send the native AUTH_PHASE_ONE and read the PBKDF2 challenge.
    socket.add(wrapData(buildNativeAuthMessage(
        functionCode: _ttcAuthPhaseOne, username: username)));
    final challenge = _parseNativeResponseParams(ttcBody(await frames.next()));

    // Phase two: compute the O5LOGON proof and send it.
    final o5logon =
        _NativeO5Logon.fromChallenge(password: password, challenge: challenge);
    socket.add(wrapData(buildNativeAuthMessage(
      functionCode: _ttcAuthPhaseTwo,
      username: username,
      sequence: 3,
      pairs: o5logon.phaseTwoPairs(),
    )));
    final responseBody = ttcBody(await frames.next());
    if (responseBody.isEmpty || responseBody.first != _ttcMsgTypeParameter) {
      return NativeLoginResult(authenticated: false, params: const {});
    }
    final params = _parseNativeResponseParams(responseBody);
    return NativeLoginResult(
      authenticated: o5logon.verifyServerResponse(params['AUTH_SVR_RESPONSE']),
      params: params,
    );
  }

  /// Sends a native-format AUTH_PHASE_ONE without reading the reply (a building
  /// block for lower-level tests; [login] drives the full exchange).
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
