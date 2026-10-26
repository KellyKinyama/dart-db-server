/// Cryptographic primitives for the Oracle (TNS/TTC) authentication verifier.
///
/// Mirrors the primitives the sibling thin client uses
/// (`../dart-oracledb/lib/src/crypto/`): SHA-512, PBKDF2-HMAC-SHA512, and
/// AES-256-CBC. The server is the *verifier* side, so it also needs the raw
/// (no-padding) AES decrypt the client applies to `AUTH_SESSKEY` and the
/// PKCS7-padded decrypt it applies to `AUTH_PASSWORD`.
library;

import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// SHA-512 digest (64 bytes).
Uint8List sha512(Uint8List data) => SHA512Digest().process(data);

/// PBKDF2-HMAC-SHA512 key derivation.
Uint8List pbkdf2Sha512({
  required Uint8List password,
  required Uint8List salt,
  required int iterations,
  required int keyLength,
}) {
  final kdf = KeyDerivator('SHA-512/HMAC/PBKDF2')
    ..init(Pbkdf2Parameters(salt, iterations, keyLength));
  return kdf.process(password);
}

/// AES-256-CBC encrypt WITHOUT padding. [data] must be block-aligned (a
/// multiple of 16 bytes). Used to seal the server nonce into `AUTH_SESSKEY`,
/// which the client decrypts raw.
Uint8List aes256CbcEncryptRaw({
  required Uint8List key,
  required Uint8List iv,
  required Uint8List data,
}) {
  const blockSize = 16;
  final cipher = CBCBlockCipher(AESEngine())
    ..init(true, ParametersWithIV(KeyParameter(key), iv));
  final out = Uint8List(data.length);
  for (var off = 0; off < data.length; off += blockSize) {
    cipher.processBlock(data, off, out, off);
  }
  return out;
}

/// AES-256-CBC encrypt WITH PKCS7 padding. The server never uses this (it only
/// decrypts the client's proof); it mirrors the client's `aes256CbcEncrypt` for
/// tests that simulate the client side.
Uint8List aes256CbcEncryptPkcs7({
  required Uint8List key,
  required Uint8List iv,
  required Uint8List data,
}) {
  const blockSize = 16;
  final pad = blockSize - (data.length % blockSize);
  final padded = Uint8List(data.length + pad)..setRange(0, data.length, data);
  for (var i = data.length; i < padded.length; i++) {
    padded[i] = pad;
  }
  return aes256CbcEncryptRaw(key: key, iv: iv, data: padded);
}

/// AES-256-CBC decrypt WITHOUT padding removal (raw). Returns bytes the same
/// length as [data].
Uint8List aes256CbcDecryptRaw({
  required Uint8List key,
  required Uint8List iv,
  required Uint8List data,
}) {
  const blockSize = 16;
  final cipher = CBCBlockCipher(AESEngine())
    ..init(false, ParametersWithIV(KeyParameter(key), iv));
  final out = Uint8List(data.length);
  for (var off = 0; off < data.length; off += blockSize) {
    cipher.processBlock(data, off, out, off);
  }
  return out;
}

/// AES-256-CBC decrypt and strip PKCS7 padding. Used for `AUTH_PASSWORD`, which
/// the client encrypts with PKCS7 padding. Throws [FormatException] on invalid
/// padding.
Uint8List aes256CbcDecryptPkcs7({
  required Uint8List key,
  required Uint8List iv,
  required Uint8List data,
}) {
  final raw = aes256CbcDecryptRaw(key: key, iv: iv, data: data);
  if (raw.isEmpty || raw.length % 16 != 0) {
    throw const FormatException('ciphertext not block-aligned');
  }
  final pad = raw.last;
  if (pad < 1 || pad > 16 || pad > raw.length) {
    throw const FormatException('invalid PKCS7 padding');
  }
  for (var i = raw.length - pad; i < raw.length; i++) {
    if (raw[i] != pad) throw const FormatException('invalid PKCS7 padding');
  }
  return Uint8List.sublistView(raw, 0, raw.length - pad);
}

/// Uppercase hex encoding, matching the client's wire format for the auth
/// key-value strings.
String hexEncodeUpper(Uint8List bytes) {
  final sb = StringBuffer();
  for (final b in bytes) {
    sb.write(b.toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString().toUpperCase();
}

/// Decodes a hex string (any case) to bytes.
Uint8List hexDecode(String hex) {
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

/// Constant-time equality for two byte lists.
bool constantTimeEquals(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}
