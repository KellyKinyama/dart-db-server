// Smoke test for the MySQL wire scaffold: drives the protocol with a raw
// socket (no real MySQL driver dependency) to verify handshake, login, and
// a COM_QUERY round-trip with both DDL/DML (OK packet) and SELECT
// (column defs + text rows + EOF).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  group('MySqlServer wire', () {
    late Database db;
    late MySqlServer server;
    late Socket sock;
    late _Reader r;
    late _Writer w;

    setUp(() async {
      db = await Database.open(null);
      server = MySqlServer(db, port: 0); // ephemeral port
      await server.start();
      sock = await Socket.connect(
        InternetAddress.loopbackIPv4,
        server.boundPort,
      );
      r = _Reader(sock);
      w = _Writer(sock);
    });

    tearDown(() async {
      await sock.close();
      await server.stop();
    });

    test('handshake + COM_QUERY round-trip', () async {
      // 1) Server sends handshake (seq 0).
      final hs = await r.next();
      expect(hs.payload[0], 10, reason: 'protocol version v10');

      // 2) Client sends a handshake response with no password.
      w.send(_buildHandshakeResponse(user: 'root'), seq: 1);

      // 3) Expect OK.
      final ok = await r.next();
      expect(ok.payload[0], 0x00, reason: 'OK header');

      // 4) COM_QUERY: CREATE TABLE.
      w.send(
        _query('CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)'),
        seq: 0,
      );
      var pkt = await r.next();
      expect(pkt.payload[0], 0x00, reason: 'DDL returns OK');

      // 5) COM_QUERY: INSERT.
      w.send(_query("INSERT INTO t VALUES (1, 'Alice'), (2, 'Bob')"), seq: 0);
      pkt = await r.next();
      expect(pkt.payload[0], 0x00);

      // 6) COM_QUERY: SELECT.
      w.send(_query('SELECT id, name FROM t ORDER BY id'), seq: 0);

      // column count
      pkt = await r.next();
      expect(pkt.payload[0], 2);

      // column defs
      for (var i = 0; i < 2; i++) {
        pkt = await r.next();
        expect(pkt.payload.isNotEmpty, isTrue);
      }

      // rows
      final rows = <List<String>>[];
      while (true) {
        pkt = await r.next();
        if (pkt.payload[0] == 0xfe && pkt.payload.length < 9) break; // EOF/OK
        rows.add(_decodeTextRow(pkt.payload, 2));
      }
      expect(rows, [
        ['1', 'Alice'],
        ['2', 'Bob'],
      ]);
    });

    test('rejects bad password', () async {
      await sock.close();
      await server.stop();
      server = MySqlServer(db, port: 0, password: 'secret');
      await server.start();
      sock = await Socket.connect(
        InternetAddress.loopbackIPv4,
        server.boundPort,
      );
      r = _Reader(sock);
      w = _Writer(sock);

      await r.next(); // handshake
      // Send empty auth response — should fail.
      w.send(_buildHandshakeResponse(user: 'root'), seq: 1);
      final err = await r.next();
      expect(err.payload[0], 0xff, reason: 'ERR packet');
    });
  });
}

// ---------------------------------------------------------------------------
// Minimal client helpers (no third-party driver).
// ---------------------------------------------------------------------------

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
      final seq = _buf[3];
      if (_buf.length < 4 + len) return;
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

Uint8List _buildHandshakeResponse({required String user}) {
  // Capabilities: PROTOCOL_41 | SECURE_CONNECTION | PLUGIN_AUTH | DEPRECATE_EOF
  const caps = 0x00000200 | 0x00008000 | 0x00080000 | 0x01000000;
  final out = BytesBuilder();
  void u32(int v) {
    for (var i = 0; i < 4; i++) {
      out.addByte((v >> (8 * i)) & 0xff);
    }
  }

  u32(caps);
  u32(1 << 24); // max packet
  out.addByte(255); // charset utf8mb4
  out.add(Uint8List(23)); // reserved
  out.add(utf8.encode(user));
  out.addByte(0);
  out.addByte(0); // auth response length = 0
  out.add(utf8.encode('mysql_native_password'));
  out.addByte(0);
  return out.toBytes();
}

Uint8List _query(String sql) {
  final out = BytesBuilder();
  out.addByte(0x03); // COM_QUERY
  out.add(utf8.encode(sql));
  return out.toBytes();
}

List<String> _decodeTextRow(Uint8List payload, int colCount) {
  var i = 0;
  final cols = <String>[];
  for (var c = 0; c < colCount; c++) {
    final h = payload[i];
    if (h == 0xfb) {
      cols.add('NULL');
      i++;
      continue;
    }
    int len;
    if (h < 0xfb) {
      len = h;
      i += 1;
    } else if (h == 0xfc) {
      len = payload[i + 1] | (payload[i + 2] << 8);
      i += 3;
    } else if (h == 0xfd) {
      len = payload[i + 1] | (payload[i + 2] << 8) | (payload[i + 3] << 16);
      i += 4;
    } else {
      throw StateError('unexpected lenenc int header');
    }
    cols.add(utf8.decode(payload.sublist(i, i + len)));
    i += len;
  }
  return cols;
}
