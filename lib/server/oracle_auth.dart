/// Oracle authentication — the verifier (server) side of the O5LOGON exchange.
///
/// This is the inverse of the client auth flow in
/// `../dart-oracledb/lib/src/crypto/auth.dart`. The server never stores a
/// plaintext password: per user it keeps a salt and
/// `passwordHash = SHA512(password || salt)[0:32]`. In AUTH_PHASE_ONE it seals
/// a fresh server nonce into `AUTH_SESSKEY` with that hash and advertises the
/// salt in `AUTH_VFR_DATA`. In AUTH_PHASE_TWO it reverses the client's key
/// schedule (decrypt the client session key, derive the combo key, decrypt
/// `AUTH_PASSWORD`) and re-derives the hash to confirm the password — matching
/// bytes mean the client proved knowledge of the password.
///
/// Uses the SHA512 verifier (type 0x939): no PBKDF2 password step and no
/// speedy key, which keeps the crypto surface minimal. The combo-key mixing
/// uses the client's defaults (zero salt, one iteration) since the server omits
/// the optional `AUTH_PBKDF2_*` parameters.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'oracle_codec.dart';
import 'oracle_crypto.dart';
import 'oracle_ttc.dart';

// TTC function codes (second byte when message type is FUNCTION).
const int ttcAuthPhaseOne = 0x76;
const int ttcAuthPhaseTwo = 0x73;

/// SHA512 (O5LOGON) verifier type advertised in `AUTH_VFR_DATA` flags.
const int verifierTypeSha512 = 0x939;

/// 12c PBKDF2-SHA512 (O8LOGON) verifier type advertised in `AUTH_VFR_DATA`
/// flags. The client derives its password key with PBKDF2 and sends an
/// `AUTH_PBKDF2_SPEEDY_KEY`; the server mixes with `AUTH_PBKDF2_CSK_SALT` /
/// `AUTH_PBKDF2_SDER_COUNT`.
const int verifierTypePbkdf2 = 0x4815;

/// PBKDF2 salt suffix the client appends to `AUTH_VFR_DATA` when deriving the
/// password key (client `crypto/auth.dart`).
const String _pbkdf2SpeedyKeySalt = 'AUTH_PBKDF2_SPEEDY_KEY';

/// Default PBKDF2 iteration count for a 12c verifier (client default; also
/// encoded into `AUTH_VFR_DATA` after the salt).
const int _pbkdf2DefaultIterations = 4096;

/// Default mixing-salt iteration count (`AUTH_PBKDF2_SDER_COUNT`).
const int _pbkdf2DefaultMixingIterations = 3;

/// ORA-01017: invalid username/password; logon denied.
const int oraInvalidCredentials = 1017;

final Random _secureRandom = Random.secure();

Uint8List _randomBytes(int length) {
  final out = Uint8List(length);
  for (var i = 0; i < length; i++) {
    out[i] = _secureRandom.nextInt(256);
  }
  return out;
}

/// A stored password verifier: the salt and the derived hash. Never the
/// password itself.
class OracleVerifier {
  OracleVerifier(
    this.salt,
    this.passwordHash, {
    this.verifierType = verifierTypeSha512,
    this.iterations = 0,
  });

  final Uint8List salt; // 16 bytes
  final Uint8List passwordHash; // 32 bytes (AES-256 key)

  /// Which verifier scheme this user authenticates with — [verifierTypeSha512]
  /// or [verifierTypePbkdf2].
  final int verifierType;

  /// PBKDF2 iteration count (0 for the SHA512 verifier).
  final int iterations;

  bool get isPbkdf2 => verifierType == verifierTypePbkdf2;

  /// Derives a SHA512 verifier from a plaintext password (at user-creation
  /// time only). The optional [salt] is for deterministic tests.
  factory OracleVerifier.fromPassword(String password, {Uint8List? salt}) {
    final s = salt ?? _randomBytes(16);
    final pw = Uint8List.fromList(utf8.encode(password));
    final input = Uint8List(pw.length + s.length)
      ..setRange(0, pw.length, pw)
      ..setRange(pw.length, pw.length + s.length, s);
    final hash = Uint8List.sublistView(sha512(input), 0, 32);
    return OracleVerifier(s, hash);
  }

  /// Derives a 12c PBKDF2-SHA512 verifier from a plaintext password:
  /// `passwordKey = PBKDF2(password, salt ‖ "AUTH_PBKDF2_SPEEDY_KEY",
  /// iterations, 64)`, `passwordHash = SHA512(passwordKey ‖ salt)[0:32]`.
  factory OracleVerifier.pbkdf2(
    String password, {
    Uint8List? salt,
    int iterations = _pbkdf2DefaultIterations,
  }) {
    final s = salt ?? _randomBytes(16);
    final pw = Uint8List.fromList(utf8.encode(password));
    final hash = _pbkdf2PasswordHash(pw, s, iterations);
    return OracleVerifier(s, hash,
        verifierType: verifierTypePbkdf2, iterations: iterations);
  }
}

/// `passwordHash = SHA512(PBKDF2(password, salt ‖ "AUTH_PBKDF2_SPEEDY_KEY",
/// iterations, 64) ‖ salt)[0:32]` — the 12c password-hash derivation shared by
/// user creation and phase-two re-validation.
Uint8List _pbkdf2PasswordHash(Uint8List password, Uint8List salt, int iterations) {
  final suffix = utf8.encode(_pbkdf2SpeedyKeySalt);
  final combinedSalt = Uint8List(salt.length + suffix.length)
    ..setRange(0, salt.length, salt)
    ..setRange(salt.length, salt.length + suffix.length, suffix);
  final passwordKey = pbkdf2Sha512(
    password: password,
    salt: combinedSalt,
    iterations: iterations,
    keyLength: 64,
  );
  final hashInput = Uint8List(passwordKey.length + salt.length)
    ..setRange(0, passwordKey.length, passwordKey)
    ..setRange(passwordKey.length, passwordKey.length + salt.length, salt);
  return Uint8List.sublistView(sha512(hashInput), 0, 32);
}

/// In-memory user → verifier store. Oracle identifiers are matched
/// case-insensitively (upper-cased), as for unquoted usernames.
class OracleUserStore {
  final Map<String, OracleVerifier> _byUser = <String, OracleVerifier>{};

  void addUser(String username, String password) {
    _byUser[username.toUpperCase()] = OracleVerifier.fromPassword(password);
  }

  /// Registers a user that authenticates with the 12c PBKDF2 verifier.
  void addPbkdf2User(String username, String password,
      {int iterations = _pbkdf2DefaultIterations}) {
    _byUser[username.toUpperCase()] =
        OracleVerifier.pbkdf2(password, iterations: iterations);
  }

  OracleVerifier? lookup(String username) => _byUser[username.toUpperCase()];

  /// Registered usernames (upper-cased), for admin introspection.
  Iterable<String> get usernames => _byUser.keys;

  bool get isEmpty => _byUser.isEmpty;
}

/// Per-connection auth state carried between the two phases.
class AuthPhaseState {
  Uint8List? serverNonce;
  OracleVerifier? verifier;
  String? username;

  /// PBKDF2 combo-key mixing salt (`AUTH_PBKDF2_CSK_SALT`) and iteration count
  /// (`AUTH_PBKDF2_SDER_COUNT`) — null for the SHA512 verifier, where the
  /// client defaults to a zero salt and one iteration.
  Uint8List? mixingSalt;
  int? mixingIterations;

  /// Whether phase one arrived in a FAST_AUTH envelope — the client then
  /// prefixes AUTH_PHASE_TWO with a 23ai token-number field.
  bool viaFastAuth = false;

  /// The derived O5LOGON combo key (set by [verifyO5LogonProof]); the native
  /// success response seals the AUTH_SVR_RESPONSE mutual-auth proof with it.
  Uint8List? comboKey;
}

/// A built TTC response plus whether authentication has now succeeded.
class AuthResponse {
  AuthResponse(this.bytes, {required this.authenticated});
  final Uint8List bytes;
  final bool authenticated;
}

/// Handles AUTH_PHASE_ONE. [body] is positioned just past the TTC function
/// header (message type, function code, sequence already consumed). Returns the
/// TTC body to send back.
AuthResponse handleAuthPhaseOne(
  ReadBuffer body,
  OracleUserStore users,
  AuthPhaseState state,
) {
  final username = _parseRequestUsername(body);
  final verifier = users.lookup(username);
  if (verifier == null) {
    return AuthResponse(
      buildTtcError(oraInvalidCredentials,
          'invalid username/password; logon denied'),
      authenticated: false,
    );
  }
  final serverNonce = _randomBytes(48); // block-aligned, >= 32 bytes
  state
    ..serverNonce = serverNonce
    ..verifier = verifier
    ..username = username;

  final authSessKey = hexEncodeUpper(aes256CbcEncryptRaw(
    key: verifier.passwordHash,
    iv: Uint8List(16),
    data: serverNonce,
  ));

  final b = WriteBuffer();
  b.writeUint8(ttcMsgTypeParameter);
  if (verifier.isPbkdf2) {
    // 12c: AUTH_VFR_DATA carries salt ‖ iterations (4-byte BE); the mixing
    // salt and iteration count seed the combo key.
    final mixingSalt = _randomBytes(16);
    const mixingIterations = _pbkdf2DefaultMixingIterations;
    state
      ..mixingSalt = mixingSalt
      ..mixingIterations = mixingIterations;
    final vfr = Uint8List(verifier.salt.length + 4)
      ..setRange(0, verifier.salt.length, verifier.salt);
    final it = verifier.iterations;
    vfr[verifier.salt.length] = (it >> 24) & 0xFF;
    vfr[verifier.salt.length + 1] = (it >> 16) & 0xFF;
    vfr[verifier.salt.length + 2] = (it >> 8) & 0xFF;
    vfr[verifier.salt.length + 3] = it & 0xFF;
    b.writeUB2(5); // five parameters
    _writeKeyValue(b, 'AUTH_VFR_DATA', hexEncodeUpper(vfr),
        flags: verifierTypePbkdf2);
    _writeKeyValue(b, 'AUTH_SESSKEY', authSessKey, flags: 0);
    _writeKeyValue(b, 'AUTH_PBKDF2_CSK_SALT', hexEncodeUpper(mixingSalt));
    _writeKeyValue(b, 'AUTH_PBKDF2_SDER_COUNT', '$mixingIterations');
    _writeKeyValue(b, 'AUTH_PBKDF2_VGEN_COUNT', '${verifier.iterations}');
  } else {
    final vfrData = hexEncodeUpper(verifier.salt);
    b.writeUB2(2); // two parameters
    _writeKeyValue(b, 'AUTH_VFR_DATA', vfrData, flags: verifierTypeSha512);
    _writeKeyValue(b, 'AUTH_SESSKEY', authSessKey, flags: 0);
  }
  return AuthResponse(b.toBytes(), authenticated: false);
}

/// Handles AUTH_PHASE_TWO: validates the client's password proof. [body] is
/// positioned just past the TTC function header.
AuthResponse handleAuthPhaseTwo(ReadBuffer body, AuthPhaseState state) {
  // A FAST_AUTH client prefixes AUTH_PHASE_TWO with a 23ai token number
  // (UB8, zero) before the request preamble.
  if (state.viaFastAuth) {
    body.readUB8(); // token number (unused)
  }
  final pairs = _parseRequestKeyValues(body);
  if (verifyO5LogonProof(
      state, pairs['AUTH_SESSKEY'], pairs['AUTH_PASSWORD'])) {
    return AuthResponse(buildAuthSuccess(), authenticated: true);
  }
  return AuthResponse(
    buildTtcError(
        oraInvalidCredentials, 'invalid username/password; logon denied'),
    authenticated: false,
  );
}

/// Seals the AUTH_PHASE_ONE crypto into [state]: mints the server nonce and a
/// PBKDF2 mixing salt, and returns the AES-sealed `AUTH_SESSKEY` hex plus the
/// mixing parameters. Shared by the thin and native phase-one builders.
({String authSessKey, Uint8List mixingSalt, int mixingIterations}) sealPhaseOne(
    OracleVerifier verifier, AuthPhaseState state, {int nonceLength = 48}) {
  final serverNonce = _randomBytes(nonceLength);
  final mixingSalt = _randomBytes(16);
  const mixingIterations = _pbkdf2DefaultMixingIterations;
  state
    ..serverNonce = serverNonce
    ..verifier = verifier
    ..mixingSalt = mixingSalt
    ..mixingIterations = mixingIterations;
  final authSessKey = hexEncodeUpper(aes256CbcEncryptRaw(
      key: verifier.passwordHash, iv: Uint8List(16), data: serverNonce));
  return (
    authSessKey: authSessKey,
    mixingSalt: mixingSalt,
    mixingIterations: mixingIterations,
  );
}

/// Verifies the O5LOGON proof from AUTH_PHASE_TWO: recovers the client session
/// key from [sessKeyHex], derives the combo key, decrypts [passwordHex], and
/// compares the re-derived verifier hash against the stored one. Shared by the
/// thin and native auth paths.
bool verifyO5LogonProof(
    AuthPhaseState state, String? sessKeyHex, String? passwordHex) {
  final verifier = state.verifier;
  final serverNonce = state.serverNonce;
  if (verifier == null ||
      serverNonce == null ||
      sessKeyHex == null ||
      passwordHex == null) {
    return false;
  }
  try {
    // Recover the client's session-key part B from AUTH_SESSKEY.
    final clientSessKey = hexDecode(sessKeyHex);
    final partB = aes256CbcDecryptRaw(
      key: verifier.passwordHash,
      iv: Uint8List(16),
      data: clientSessKey,
    );
    if (partB.length < 32) return false;

    // Combo key: PBKDF2 over hex(partB[0:32] || serverNonce[0:32]).
    final partAB = Uint8List(64)
      ..setRange(0, 32, partB)
      ..setRange(32, 64, serverNonce);
    final partABHex =
        Uint8List.fromList(utf8.encode(hexEncodeUpper(partAB)));
    final comboKey = pbkdf2Sha512(
      password: partABHex,
      salt: state.mixingSalt ?? Uint8List(16),
      iterations: state.mixingIterations ?? 1,
      keyLength: 32,
    );
    state.comboKey = comboKey;

    // Decrypt AUTH_PASSWORD, drop the 16-byte random prefix, re-derive the
    // verifier's hash, and compare against the stored one.
    final plain = aes256CbcDecryptPkcs7(
      key: comboKey,
      iv: Uint8List(16),
      data: hexDecode(passwordHex),
    );
    if (plain.length < 16) return false;
    final password = Uint8List.fromList(Uint8List.sublistView(plain, 16));
    final recomputed = verifier.isPbkdf2
        ? _pbkdf2PasswordHash(password, verifier.salt, verifier.iterations)
        : _sha512PasswordHash(password, verifier.salt);
    return constantTimeEquals(recomputed, verifier.passwordHash);
  } catch (_) {
    return false;
  }
}

/// `passwordHash = SHA512(password ‖ salt)[0:32]` — the SHA512 verifier's
/// phase-two re-derivation.
Uint8List _sha512PasswordHash(Uint8List password, Uint8List salt) {
  final check = Uint8List(password.length + salt.length)
    ..setRange(0, password.length, password)
    ..setRange(password.length, password.length + salt.length, salt);
  return Uint8List.sublistView(sha512(check), 0, 32);
}

/// Builds a successful AUTH_PHASE_TWO response (a STATUS message, status 0).
Uint8List buildAuthSuccess() {
  final b = WriteBuffer();
  b.writeUint8(ttcMsgTypeStatus);
  b.writeUB4(0); // call status: success
  b.writeUB2(0); // end-to-end sequence
  return b.toBytes();
}

/// Builds a TTC ERROR message carrying an ORA-[errorCode] and [message], laid
/// out exactly as the client's `_parseAuthTtcError` reads it.
Uint8List buildTtcError(int errorCode, String message) {
  final b = WriteBuffer();
  b.writeUint8(ttcMsgTypeError);
  b.writeUB4(0); // call status
  b.writeUB2(0); // end-to-end seq
  b.writeUB4(0); // current row number
  b.writeUB2(0); // error number (short)
  b.writeUB2(0); // array elem w/ error
  b.writeUB2(0); // array elem error
  b.writeUB2(0); // cursor id
  b.writeUint16BE(0); // error position
  b.writeUint8(0); // sql type
  b.writeUint8(0); // fatal
  b.writeUint8(0); // flags
  b.writeUint8(0); // user cursor options
  b.writeUint8(0); // UPI parameter
  b.writeUint8(0); // warning flag
  b.writeUB4(errorCode); // the ORA error code
  final msg = Uint8List.fromList(utf8.encode(message));
  b.writeBytesWithLength(msg);
  return b.toBytes();
}

// ---------------------------------------------------------------------------
// Request parsing (mirrors AuthPhaseOneRequest / AuthPhaseTwoRequest.toBytes)
// ---------------------------------------------------------------------------

/// Reads the fixed request preamble and returns the username. Leaves [body]
/// positioned at the first key-value pair.
String _parseRequestUsername(ReadBuffer body) {
  final usernamePresent = body.readUint8();
  body.readUB4(); // username byte length (redundant with the inline bytes)
  body.readUB4(); // auth mode flags
  body.readUint8(); // unknown flag
  body.readUB4(); // number of key-value pairs
  body.readUint8(); // unknown
  body.readUint8(); // unknown
  if (usernamePresent == 1) {
    return body.readStringWithLength();
  }
  return '';
}

/// Parses the full request (preamble + key-value pairs) into a map.
Map<String, String> _parseRequestKeyValues(ReadBuffer body) {
  final usernamePresent = body.readUint8();
  body.readUB4(); // username byte length
  body.readUB4(); // auth mode flags
  body.readUint8(); // unknown
  final numPairs = body.readUB4();
  body.readUint8(); // unknown
  body.readUint8(); // unknown
  if (usernamePresent == 1) {
    body.readStringWithLength(); // username (already known from phase one)
  }
  final out = <String, String>{};
  for (var i = 0; i < numPairs && body.hasRemaining; i++) {
    body.readUB4(); // key length (redundant)
    final key = body.readStringWithLength();
    final valueLen = body.readUB4();
    final value = valueLen > 0 ? body.readStringWithLength() : '';
    body.readUB4(); // flags
    out[key] = value;
  }
  return out;
}

/// Writes one TTC key-value pair in the client's wire format.
void _writeKeyValue(WriteBuffer b, String key, String value,
    {int flags = 0}) {
  final keyBytes = Uint8List.fromList(utf8.encode(key));
  final valueBytes = Uint8List.fromList(utf8.encode(value));
  b.writeUB4(keyBytes.length);
  b.writeBytesWithLength(keyBytes);
  b.writeUB4(valueBytes.length);
  if (valueBytes.isNotEmpty) {
    b.writeBytesWithLength(valueBytes);
  }
  b.writeUB4(flags);
}
