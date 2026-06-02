// Smoke test for TLS upgrade in the MySQL wire scaffold.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  group('MySqlServer TLS upgrade', () {
    late Database db;
    late MySqlServer server;
    late Socket sock;

    setUp(() async {
      db = await Database.open(null);
      final ctx = SecurityContext()
        ..useCertificateChain('test/fixtures/mysql_test_cert.pem')
        ..usePrivateKey('test/fixtures/mysql_test_key.pem');
      server = MySqlServer(db, port: 0, tlsContext: ctx);
      await server.start();
      sock = await Socket.connect(
        InternetAddress.loopbackIPv4,
        server.boundPort,
      );
    });

    tearDown(() async {
      await sock.close();
      await server.stop();
    });

    test('handshake advertises CLIENT_SSL when context is set', () async {
      final r = _Reader(sock);
      final hs = await r.next();
      final caps = _parseServerCaps(hs.payload);
      expect(caps & 0x0800, isNot(0), reason: 'CLIENT_SSL bit set');
    });

    test('SSLRequest upgrades the connection and a query round-trips',
        () async {
      final r = _Reader(sock);
      final w = _Writer(sock);

      final hs = await r.next();
      final caps = _parseServerCaps(hs.payload);
      expect(caps & 0x0800, isNot(0));

      // Send a 32-byte SSLRequest with CLIENT_SSL bit set, seq=1.
      const clientCaps = 0x00000200 | // PROTOCOL_41
          0x00000800 | // SSL
          0x00008000 | // SECURE_CONNECTION
          0x00080000 | // PLUGIN_AUTH
          0x01000000; // DEPRECATE_EOF
      w.send(_sslRequest(clientCaps), seq: 1);

      // Pause (do not cancel) the existing subscription so the underlying
      // socket stays alive while SecureSocket.secure detaches its raw end.
      r.pause();
      final secure = await SecureSocket.secure(
        sock,
        host: 'localhost',
        onBadCertificate: (_) => true,
      );
      sock = secure;
      final rr = _Reader(secure);
      final ww = _Writer(secure);

      // Send the real handshake response over TLS, seq=2.
      ww.send(_handshakeResponse(clientCaps), seq: 2);
      final ok = await rr.next();
      expect(ok.payload[0], 0x00, reason: 'OK after TLS handshake');

      // Run a simple query.
      ww.send(_query('SELECT 1'), seq: 0);
      final cc = await rr.next();
      expect(cc.payload[0], 1);
      await rr.next(); // column def
      final row = await rr.next();
      expect(row.payload[0], 1); // lenenc len=1
      expect(utf8.decode(row.payload.sublist(1, 2)), '1');
      await rr.next(); // EOF/OK terminator
    });
  });
}

int _parseServerCaps(Uint8List p) {
  // Skip proto ver + cstr version + thread + scramble(8) + filler.
  var i = 1;
  while (p[i] != 0) {
    i++;
  }
  i++;
  i += 4 + 8 + 1;
  final capsLo = p[i] | (p[i + 1] << 8);
  i += 2;
  i += 1 + 2; // charset + status
  final capsHi = p[i] | (p[i + 1] << 8);
  return (capsHi << 16) | capsLo;
}

Uint8List _sslRequest(int caps) {
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
  return out.toBytes(); // exactly 32 bytes
}

Uint8List _handshakeResponse(int caps) {
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
  out.addByte(0); // empty auth response
  out.add(utf8.encode('mysql_native_password'));
  out.addByte(0);
  return out.toBytes();
}

Uint8List _query(String sql) {
  final out = BytesBuilder();
  out.addByte(0x03);
  out.add(utf8.encode(sql));
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

  Future<void> close() => _sub.cancel();
  void pause() => _sub.pause();
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
