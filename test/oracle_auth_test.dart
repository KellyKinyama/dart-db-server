/// Phase 2 tests for the Oracle authentication verifier.
///
/// Simulates the client half of the O5LOGON (SHA512) exchange — mirroring
/// `../dart-oracledb/lib/src/crypto/auth.dart`'s `generatePasswordProof` — and
/// asserts the server verifier accepts a correct proof, rejects a wrong
/// password, and rejects an unknown user. Includes a live end-to-end handshake
/// over a socket through CONNECT -> PROTOCOL -> DATA-TYPES -> AUTH1 -> AUTH2.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dart_db_server/dart_db_server.dart';
import 'package:dart_db_server/server/oracle_auth.dart';
import 'package:dart_db_server/server/oracle_codec.dart';
import 'package:dart_db_server/server/oracle_crypto.dart';
import 'package:dart_db_server/server/oracle_tns.dart';
import 'package:dart_db_server/server/oracle_ttc.dart';
import 'package:test/test.dart';

final _rand = Random(12345); // deterministic for test reproducibility

Uint8List _randBytes(int n) =>
    Uint8List.fromList(List<int>.generate(n, (_) => _rand.nextInt(256)));

Uint8List _concat(Uint8List a, Uint8List b) => Uint8List(a.length + b.length)
  ..setRange(0, a.length, a)
  ..setRange(a.length, a.length + b.length, b);

/// The client's SHA512 password proof: given the phase-one [salt] and the
/// encrypted server key, returns the `AUTH_SESSKEY` and `AUTH_PASSWORD` hex
/// strings the client would send in AUTH_PHASE_TWO.
({String authSessKey, String authPassword}) _clientProof({
  required String password,
  required Uint8List salt,
  required Uint8List serverKeyEncoded,
}) {
  final pw = Uint8List.fromList(utf8.encode(password));
  final passwordHash = Uint8List.sublistView(sha512(_concat(pw, salt)), 0, 32);

  final partA = aes256CbcDecryptRaw(
    key: passwordHash,
    iv: Uint8List(16),
    data: serverKeyEncoded,
  );
  final partB = _randBytes(partA.length);
  final encodedClientKey = aes256CbcEncryptPkcs7(
    key: passwordHash,
    iv: Uint8List(16),
    data: partB,
  );
  final authSessKey = hexEncodeUpper(encodedClientKey).substring(0, 64);

  final partAB = Uint8List(64)
    ..setRange(0, 32, partB)
    ..setRange(32, 64, partA);
  final comboKey = pbkdf2Sha512(
    password: Uint8List.fromList(utf8.encode(hexEncodeUpper(partAB))),
    salt: Uint8List(16),
    iterations: 1,
    keyLength: 32,
  );

  final salted = _concat(_randBytes(16), pw);
  final encPassword = aes256CbcEncryptPkcs7(
    key: comboKey,
    iv: Uint8List(16),
    data: salted,
  );
  return (
    authSessKey: authSessKey,
    authPassword: hexEncodeUpper(encPassword),
  );
}

/// Builds the AUTH_PHASE_ONE request body (TTC function header + preamble +
/// username). Phase one does not read key-value pairs.
Uint8List _phaseOneRequest(String username) {
  final userBytes = Uint8List.fromList(utf8.encode(username));
  final b = WriteBuffer();
  b.writeUint8(ttcMsgTypeFunction);
  b.writeUint8(ttcAuthPhaseOne);
  b.writeUint8(1); // sequence
  b.writeUint8(userBytes.isNotEmpty ? 1 : 0);
  b.writeUB4(userBytes.length);
  b.writeUB4(0x00000101); // auth mode: logon | with password
  b.writeUint8(1);
  b.writeUB4(5); // num key-value pairs (ignored in phase one)
  b.writeUint8(0);
  b.writeUint8(1);
  if (userBytes.isNotEmpty) b.writeBytesWithLength(userBytes);
  return b.toBytes();
}

/// Builds the AUTH_PHASE_TWO request body with the given key-value pairs.
Uint8List _phaseTwoRequest(String username, Map<String, String> pairs) {
  final userBytes = Uint8List.fromList(utf8.encode(username));
  final b = WriteBuffer();
  b.writeUint8(ttcMsgTypeFunction);
  b.writeUint8(ttcAuthPhaseTwo);
  b.writeUint8(2); // sequence
  b.writeUint8(userBytes.isNotEmpty ? 1 : 0);
  b.writeUB4(userBytes.length);
  b.writeUB4(0x00000101);
  b.writeUint8(1);
  b.writeUB4(pairs.length);
  b.writeUint8(1);
  b.writeUint8(1);
  if (userBytes.isNotEmpty) b.writeBytesWithLength(userBytes);
  pairs.forEach((k, v) => _writeKv(b, k, v));
  return b.toBytes();
}

void _writeKv(WriteBuffer b, String key, String value) {
  final kb = Uint8List.fromList(utf8.encode(key));
  final vb = Uint8List.fromList(utf8.encode(value));
  b.writeUB4(kb.length);
  b.writeBytesWithLength(kb);
  b.writeUB4(vb.length);
  if (vb.isNotEmpty) b.writeBytesWithLength(vb);
  b.writeUB4(0);
}

/// Returns a ReadBuffer positioned past the 3-byte TTC function header
/// (message type, function code, sequence) — where the handlers start reading.
ReadBuffer _afterHeader(Uint8List request) => ReadBuffer(request)..skip(3);

/// Parses a PARAMETER (type 8) TTC response into a key -> value map.
Map<String, String> _parseParamResponse(Uint8List body) {
  final r = ReadBuffer(body);
  final msgType = r.readUint8();
  expect(msgType, ttcMsgTypeParameter);
  final n = r.readUB2();
  final out = <String, String>{};
  for (var i = 0; i < n; i++) {
    r.readUB4(); // key length
    final key = r.readStringWithLength();
    final valueLen = r.readUB4();
    final value = valueLen > 0 ? r.readStringWithLength() : '';
    r.readUB4(); // flags
    out[key] = value;
  }
  return out;
}

void main() {
  group('verifier (handler level)', () {
    test('accepts a correct O5LOGON proof', () {
      final users = OracleUserStore()..addUser('testuser', 'testpassword');
      final state = AuthPhaseState();

      final r1 =
          handleAuthPhaseOne(_afterHeader(_phaseOneRequest('testuser')),
              users, state);
      final params = _parseParamResponse(r1.bytes);
      final salt = hexDecode(params['AUTH_VFR_DATA']!);
      final serverKey = hexDecode(params['AUTH_SESSKEY']!);

      final proof = _clientProof(
        password: 'testpassword',
        salt: salt,
        serverKeyEncoded: serverKey,
      );
      final r2 = handleAuthPhaseTwo(
        _afterHeader(_phaseTwoRequest('testuser', {
          'AUTH_SESSKEY': proof.authSessKey,
          'AUTH_PASSWORD': proof.authPassword,
        })),
        state,
      );
      expect(r2.authenticated, isTrue);
      expect(r2.bytes.first, ttcMsgTypeStatus);
    });

    test('rejects a wrong password', () {
      final users = OracleUserStore()..addUser('testuser', 'testpassword');
      final state = AuthPhaseState();

      final r1 = handleAuthPhaseOne(
          _afterHeader(_phaseOneRequest('testuser')), users, state);
      final params = _parseParamResponse(r1.bytes);
      final salt = hexDecode(params['AUTH_VFR_DATA']!);
      final serverKey = hexDecode(params['AUTH_SESSKEY']!);

      final proof = _clientProof(
        password: 'WRONGpassword',
        salt: salt,
        serverKeyEncoded: serverKey,
      );
      final r2 = handleAuthPhaseTwo(
        _afterHeader(_phaseTwoRequest('testuser', {
          'AUTH_SESSKEY': proof.authSessKey,
          'AUTH_PASSWORD': proof.authPassword,
        })),
        state,
      );
      expect(r2.authenticated, isFalse);
      expect(r2.bytes.first, ttcMsgTypeError);
    });

    test('rejects an unknown user with a TTC ORA-01017 error', () {
      final users = OracleUserStore()..addUser('testuser', 'testpassword');
      final state = AuthPhaseState();
      final r1 = handleAuthPhaseOne(
          _afterHeader(_phaseOneRequest('nosuchuser')), users, state);
      expect(r1.authenticated, isFalse);
      expect(r1.bytes.first, ttcMsgTypeError);
    });
  });

  group('live end-to-end authentication', () {
    test('a correct proof authenticates over a socket', () async {
      final db = await Database.open(null);
      final server = OracleServer(db, port: 0, users: {
        'testuser': 'testpassword',
      });
      await server.start();
      addTearDown(() async => server.stop());

      final socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        server.boundPort,
      );
      addTearDown(() async => socket.close());
      final frames = _FrameReader(socket);

      // CONNECT -> ACCEPT
      socket.add(_buildConnect());
      expect((await frames.next())[4], tnsPacketAccept);

      // PROTOCOL + DATA-TYPES negotiation
      socket.add(_wrapData(_protocolRequest()));
      await frames.next();
      socket.add(_wrapData(_dataTypesRequest()));
      await frames.next();

      // AUTH_PHASE_ONE -> params
      socket.add(_wrapData(_phaseOneRequest('testuser')));
      final p1 = _ttcBody(await frames.next());
      final params = _parseParamResponse(p1);
      final salt = hexDecode(params['AUTH_VFR_DATA']!);
      final serverKey = hexDecode(params['AUTH_SESSKEY']!);

      // AUTH_PHASE_TWO -> STATUS success
      final proof = _clientProof(
        password: 'testpassword',
        salt: salt,
        serverKeyEncoded: serverKey,
      );
      socket.add(_wrapData(_phaseTwoRequest('testuser', {
        'AUTH_SESSKEY': proof.authSessKey,
        'AUTH_PASSWORD': proof.authPassword,
      })));
      final p2 = _ttcBody(await frames.next());
      expect(p2.first, ttcMsgTypeStatus);
      expect(ReadBuffer(p2)..readUint8(), isNotNull);
    });
  });
}

// --- transport test helpers (duplicated small; see oracle_wire_test.dart) ---

Uint8List _buildConnect() {
  const data = '(DESCRIPTION=(CONNECT_DATA=(SERVICE_NAME=DARTDB)))';
  final bytes = Uint8List.fromList(data.codeUnits);
  const bodyPrefix = 66;
  final body = ByteData(bodyPrefix + bytes.length);
  body.setUint16(0, 319);
  body.setUint16(2, 300);
  body.setUint16(4, 0x0001);
  body.setUint16(6, 8192);
  body.setUint16(8, 32767);
  body.setUint16(14, 1);
  body.setUint16(16, bytes.length);
  body.setUint16(18, tnsHeaderSize + bodyPrefix);
  for (var i = 0; i < bytes.length; i++) {
    body.setUint8(bodyPrefix + i, bytes[i]);
  }
  final bb = body.buffer.asUint8List();
  final out = BytesBuilder();
  final header = ByteData(tnsHeaderSize);
  header.setUint16(0, tnsHeaderSize + bb.length);
  header.setUint8(4, tnsPacketConnect);
  out.add(header.buffer.asUint8List());
  out.add(bb);
  return out.toBytes();
}

Uint8List _protocolRequest() {
  final b = BytesBuilder();
  b.addByte(ttcMsgProtocol);
  b.addByte(6);
  b.addByte(0);
  b.add('dart-oracledb'.codeUnits);
  b.addByte(0);
  return b.toBytes();
}

Uint8List _dataTypesRequest() {
  final b = BytesBuilder();
  b.addByte(ttcMsgDataTypes);
  b.add([0, 0]);
  return b.toBytes();
}

Uint8List _wrapData(Uint8List ttcBody) {
  final out = BytesBuilder();
  final header = ByteData(tnsHeaderSize);
  header.setUint32(0, tnsHeaderSize + 2 + ttcBody.length);
  header.setUint8(4, tnsPacketData);
  out.add(header.buffer.asUint8List());
  out.add([0, 0]);
  out.add(ttcBody);
  return out.toBytes();
}

Uint8List _ttcBody(Uint8List frame) =>
    Uint8List.sublistView(frame, tnsHeaderSize + 2);

class _FrameReader {
  _FrameReader(Stream<Uint8List> socket) {
    _sub = socket.listen((chunk) {
      _buf = _concat(_buf, chunk);
      _drain();
    });
  }

  late final StreamSubscription<Uint8List> _sub;
  Uint8List _buf = Uint8List(0);
  bool _largeSdu = false;
  final _queue = <Uint8List>[];
  final _waiters = <Completer<Uint8List>>[];

  void _drain() {
    while (_buf.length >= (_largeSdu ? 8 : 2)) {
      final len = _largeSdu
          ? (_buf[0] << 24) | (_buf[1] << 16) | (_buf[2] << 8) | _buf[3]
          : (_buf[0] << 8) | _buf[1];
      if (_buf.length < len) break;
      final frame = Uint8List.fromList(Uint8List.sublistView(_buf, 0, len));
      _buf = Uint8List.fromList(Uint8List.sublistView(_buf, len));
      _largeSdu = true; // the ACCEPT is the only 2-byte reply
      if (_waiters.isNotEmpty) {
        _waiters.removeAt(0).complete(frame);
      } else {
        _queue.add(frame);
      }
    }
  }

  Future<Uint8List> next() {
    if (_queue.isNotEmpty) return Future.value(_queue.removeAt(0));
    final c = Completer<Uint8List>();
    _waiters.add(c);
    return c.future.timeout(const Duration(seconds: 5), onTimeout: () {
      _sub.cancel();
      throw StateError('timed out waiting for a TNS frame');
    });
  }
}
