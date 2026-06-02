// Test caching_sha2_password fast-auth in the MySQL wire scaffold.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  group('MySqlServer caching_sha2_password', () {
    late Database db;
    late MySqlServer server;

    setUp(() async {
      db = await Database.open(null);
    });

    tearDown(() async {
      await server.stop();
    });

    Future<_Pkt> _connectAndHandshake({
      required String? password,
      required String? clientPassword,
    }) async {
      server = MySqlServer(db, port: 0, password: password);
      await server.start();
      final sock = await Socket.connect(
        InternetAddress.loopbackIPv4,
        server.boundPort,
      );
      final r = _Reader(sock);
      final w = _Writer(sock);

      final hs = await r.next();
      // Skip to scramble: payload layout = u8 ver, cstr version, u32 thread,
      // bytes(8) scramble part 1, u8 filler, u16 caps_lo, u8 charset,
      // u16 status, u16 caps_hi, u8 plugin_data_len, bytes(10) reserved,
      // bytes(13) scramble part 2 (last byte NUL), cstr plugin.
      final p = hs.payload;
      var i = 0;
      i++; // proto ver
      while (p[i] != 0) {
        i++;
      }
      i++; // skip cstr version + NUL
      i += 4; // thread id
      final scrambleLo = p.sublist(i, i + 8);
      i += 8;
      i++; // filler
      i += 2 + 1 + 2; // caps_lo + charset + status
      i += 2; // caps_hi
      i++; // plugin data len
      i += 10; // reserved
      final scrambleHi = p.sublist(i, i + 12);
      final scramble20 = Uint8List(20)
        ..setRange(0, 8, scrambleLo)
        ..setRange(8, 20, scrambleHi);

      final authResp = clientPassword == null || clientPassword.isEmpty
          ? Uint8List(0)
          : _sha2Scramble(clientPassword, scramble20);

      w.send(_handshakeResponse(authResp), seq: 1);
      // Expect either AuthMoreData(0x01 0x03) then OK, or ERR.
      final first = await r.next();
      if (first.payload[0] == 0xff) {
        await sock.close();
        return first;
      }
      // Fast-auth-success
      expect(first.payload[0], 0x01);
      expect(first.payload[1], 0x03);
      final ok = await r.next();
      await sock.close();
      return ok;
    }

    test('empty password connects', () async {
      final ok = await _connectAndHandshake(
        password: null,
        clientPassword: null,
      );
      expect(ok.payload[0], 0x00);
    });

    test('correct password connects', () async {
      final ok = await _connectAndHandshake(
        password: 'hunter2',
        clientPassword: 'hunter2',
      );
      expect(ok.payload[0], 0x00);
    });

    test('wrong password rejected', () async {
      final err = await _connectAndHandshake(
        password: 'hunter2',
        clientPassword: 'wrong',
      );
      expect(err.payload[0], 0xff);
    });
  });
}

Uint8List _sha2Scramble(String pwd, Uint8List scramble) {
  final h1 = sha256.convert(utf8.encode(pwd)).bytes;
  final h2 = sha256.convert(h1).bytes;
  final mix = sha256.convert([...h2, ...scramble]).bytes;
  final out = Uint8List(32);
  for (var i = 0; i < 32; i++) {
    out[i] = h1[i] ^ mix[i];
  }
  return out;
}

Uint8List _handshakeResponse(Uint8List authResp) {
  const caps = 0x00000200 | 0x00008000 | 0x00080000 | 0x01000000;
  final out = BytesBuilder();
  void u32(int v) {
    for (var i = 0; i < 4; i++) {
      out.addByte((v >> (8 * i)) & 0xff);
    }
  }

  u32(caps);
  u32(1 << 24);
  out.addByte(255);
  out.add(Uint8List(23));
  out.add(utf8.encode('root'));
  out.addByte(0);
  out.addByte(authResp.length);
  out.add(authResp);
  out.add(utf8.encode('caching_sha2_password'));
  out.addByte(0);
  return out.toBytes();
}

class _Pkt {
  final Uint8List payload;
  final int seq;
  _Pkt(this.payload, this.seq);
}

class _Reader {
  final Stream<Uint8List> _stream;
  final List<int> _buf = [];
  late final StreamSubscription<List<int>> _sub;
  final _queue = <_Pkt>[];
  final _waiters = <Completer<_Pkt>>[];

  _Reader(Socket s) : _stream = s.cast<Uint8List>() {
    _sub = _stream.listen(_onData);
  }

  void _onData(List<int> chunk) {
    _buf.addAll(chunk);
    while (_buf.length >= 4) {
      final len = _buf[0] | (_buf[1] << 8) | (_buf[2] << 16);
      if (_buf.length < 4 + len) return;
      final seq = _buf[3];
      final payload = Uint8List.fromList(_buf.sublist(4, 4 + len));
      _buf.removeRange(0, 4 + len);
      final pkt = _Pkt(payload, seq);
      if (_waiters.isNotEmpty) {
        _waiters.removeAt(0).complete(pkt);
      } else {
        _queue.add(pkt);
      }
    }
  }

  Future<_Pkt> next() {
    if (_queue.isNotEmpty) return Future.value(_queue.removeAt(0));
    final c = Completer<_Pkt>();
    _waiters.add(c);
    return c.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () => throw StateError('no packet within 5s'),
    );
  }

  // ignore: unused_element
  Future<void> close() => _sub.cancel();
}

class _Writer {
  final Socket sock;
  _Writer(this.sock);
  void send(Uint8List payload, {required int seq}) {
    final hdr = Uint8List(4);
    final n = payload.length;
    hdr[0] = n & 0xff;
    hdr[1] = (n >> 8) & 0xff;
    hdr[2] = (n >> 16) & 0xff;
    hdr[3] = seq & 0xff;
    sock.add(hdr);
    sock.add(payload);
  }
}
