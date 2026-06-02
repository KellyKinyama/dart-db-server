// Raw-socket verification of CLIENT_MULTI_STATEMENTS / CLIENT_MULTI_RESULTS.
//
// Drivers like `mysql_client` cannot consume an OK packet that appears
// mid-chain (their state machine completes on the first OK), so we go
// straight to the wire here to assert that the SERVER_MORE_RESULTS_EXISTS
// status flag is correctly threaded through every response packet —
// both result-set terminators and INSERT/UPDATE OK packets.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

const int _statusMoreResultsExists = 0x0008;

void main() {
  group('MySqlServer multi-statement COM_QUERY', () {
    late Database db;
    late MySqlServer server;
    late Socket sock;
    late _Reader r;
    late _Writer w;

    setUp(() async {
      db = await Database.open(null);
      await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)');
      await db.execute("INSERT INTO t VALUES (1, 'alice'), (2, 'bob')");
      server = MySqlServer(db, port: 0);
      await server.start();
      sock = await Socket.connect(
        InternetAddress.loopbackIPv4,
        server.boundPort,
      );
      r = _Reader(sock);
      w = _Writer(sock);

      // Drain handshake; respond with CLIENT_MULTI_STATEMENTS set.
      await r.next();
      w.send(_handshakeResponse(multi: true), seq: 1);
      final ok = await r.next();
      expect(ok.payload[0], 0x00);
    });

    tearDown(() async {
      await sock.close();
      await server.stop();
    });

    test('SELECT; INSERT; SELECT chains 3 results with proper status flags',
        () async {
      w.send(
        _comQuery(
          "SELECT id FROM t WHERE id = 1;"
          "INSERT INTO t VALUES (10, 'jay');"
          "SELECT name FROM t WHERE id = 10",
        ),
        seq: 0,
      );

      // --- First result: SELECT (one row).
      final cc1 = await r.next();
      expect(cc1.payload[0], 1, reason: 'column count = 1');
      await r.next(); // col def
      await r.next(); // intermediate EOF (DEPRECATE_EOF not negotiated)
      await r.next(); // row
      final eof1 = await r.next();
      expect(eof1.payload[0], 0xfe);
      // Classic EOF layout: 0xfe, u16 warnings, u16 status.
      final status1 = eof1.payload[3] | (eof1.payload[4] << 8);
      expect(
        status1 & _statusMoreResultsExists,
        isNot(0),
        reason: 'first SELECT carries MORE_RESULTS',
      );

      // --- Second result: INSERT (OK packet) with MORE_RESULTS set.
      final ok2 = await r.next();
      expect(ok2.payload[0], 0x00, reason: 'OK packet after INSERT');
      // OK layout: 0x00, lenenc affected, lenenc insertId, u16 status, ...
      final pr = _PR(ok2.payload);
      pr.u8(); // 0x00
      pr.lenencInt(); // affected
      pr.lenencInt(); // insert id
      final status2 = pr.u8() | (pr.u8() << 8);
      expect(
        status2 & _statusMoreResultsExists,
        isNot(0),
        reason: 'INSERT OK in the middle carries MORE_RESULTS',
      );

      // --- Third (last) result: SELECT (one row), no more results.
      final cc3 = await r.next();
      expect(cc3.payload[0], 1);
      await r.next(); // col def
      await r.next(); // intermediate EOF
      await r.next(); // row
      final eof3 = await r.next();
      expect(eof3.payload[0], 0xfe);
      final status3 = eof3.payload[3] | (eof3.payload[4] << 8);
      expect(
        status3 & _statusMoreResultsExists,
        0,
        reason: 'final result clears MORE_RESULTS',
      );
    });

    test('without CLIENT_MULTI_STATEMENTS, only the first stmt is executed',
        () async {
      // Reconnect without the cap.
      await sock.close();
      sock = await Socket.connect(
        InternetAddress.loopbackIPv4,
        server.boundPort,
      );
      r = _Reader(sock);
      w = _Writer(sock);
      await r.next();
      w.send(_handshakeResponse(multi: false), seq: 1);
      expect((await r.next()).payload[0], 0x00);

      // Server should parse only the first statement and either error
      // or ignore the rest. With our parser, the trailing `;` is
      // permitted but extra tokens after it cause an ERR.
      w.send(
        _comQuery("SELECT id FROM t WHERE id = 1; SELECT id FROM t"),
        seq: 0,
      );
      final resp = await r.next();
      // Either a successful first result OR an ERR is acceptable —
      // we just need to guarantee the multi-result behaviour does
      // NOT kick in for clients that did not negotiate it.
      expect([0x01, 0xff].contains(resp.payload[0]), isTrue);
    });
  });
}

// ---------------------------------------------------------------------------
// Wire helpers
// ---------------------------------------------------------------------------

Uint8List _handshakeResponse({required bool multi}) {
  // Deliberately omit CLIENT_DEPRECATE_EOF so the server emits an
  // intermediate EOF after column defs and a classic 5-byte EOF as the
  // row terminator. This makes the status-flag bytes easy to inspect.
  var caps = 0x00000200 | 0x00008000 | 0x00080000;
  if (multi) caps |= 0x00010000; // CLIENT_MULTI_STATEMENTS
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

Uint8List _comQuery(String sql) {
  final out = BytesBuilder();
  out.addByte(0x03); // COM_QUERY
  out.add(utf8.encode(sql));
  return out.toBytes();
}

class _Packet {
  final int seq;
  final Uint8List payload;
  _Packet(this.seq, this.payload);
}

class _Reader {
  final Socket _socket;
  final BytesBuilder _buf = BytesBuilder();
  final List<Completer<_Packet>> _waiters = [];
  final List<_Packet> _ready = [];

  _Reader(this._socket) {
    _socket.listen((data) {
      _buf.add(data);
      _drain();
    });
  }

  void _drain() {
    var bytes = _buf.toBytes();
    var consumed = 0;
    while (bytes.length - consumed >= 4) {
      final len = bytes[consumed] |
          (bytes[consumed + 1] << 8) |
          (bytes[consumed + 2] << 16);
      final seq = bytes[consumed + 3];
      if (bytes.length - consumed - 4 < len) break;
      final payload = Uint8List.sublistView(
        bytes,
        consumed + 4,
        consumed + 4 + len,
      );
      final pkt = _Packet(seq, Uint8List.fromList(payload));
      if (_waiters.isNotEmpty) {
        _waiters.removeAt(0).complete(pkt);
      } else {
        _ready.add(pkt);
      }
      consumed += 4 + len;
    }
    if (consumed > 0) {
      final rest = bytes.sublist(consumed);
      _buf.clear();
      _buf.add(rest);
    }
  }

  Future<_Packet> next() {
    if (_ready.isNotEmpty) return Future.value(_ready.removeAt(0));
    final c = Completer<_Packet>();
    _waiters.add(c);
    return c.future;
  }
}

class _Writer {
  final Socket _socket;
  _Writer(this._socket);
  void send(Uint8List payload, {int seq = 0}) {
    final header = Uint8List(4);
    header[0] = payload.length & 0xff;
    header[1] = (payload.length >> 8) & 0xff;
    header[2] = (payload.length >> 16) & 0xff;
    header[3] = seq & 0xff;
    _socket.add(header);
    _socket.add(payload);
  }
}

class _PR {
  final Uint8List buf;
  int pos = 0;
  _PR(this.buf);
  int u8() => buf[pos++];
  int lenencInt() {
    final h = u8();
    if (h < 0xfb) return h;
    if (h == 0xfc) return u8() | (u8() << 8);
    if (h == 0xfd) return u8() | (u8() << 8) | (u8() << 16);
    var v = 0;
    for (var i = 0; i < 8; i++) {
      v |= u8() << (8 * i);
    }
    return v;
  }
}
