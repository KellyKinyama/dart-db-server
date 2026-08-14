// Test that exercises COM_STMT_PREPARE / EXECUTE / CLOSE round-trip
// over the raw MySQL wire protocol (no third-party driver).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  group('MySqlServer prepared statements', () {
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

      // Drain handshake + send empty-password handshake response.
      await r.next();
      w.send(_handshakeResponse(), seq: 1);
      final ok = await r.next();
      expect(ok.payload[0], 0x00);
    });

    tearDown(() async {
      await sock.close();
      await server.stop();
    });

    test('PREPARE INSERT with one parameter, EXECUTE inserts row', () async {
      // PREPARE: "INSERT INTO t VALUES (?, ?)"
      w.send(_stmtPrepare('INSERT INTO t VALUES (?, ?)'), seq: 0);
      final ok = await r.next();
      expect(ok.payload[0], 0x00);
      final stmtId =
          ok.payload[1] |
          (ok.payload[2] << 8) |
          (ok.payload[3] << 16) |
          (ok.payload[4] << 24);
      final numCols = ok.payload[5] | (ok.payload[6] << 8);
      final numParams = ok.payload[7] | (ok.payload[8] << 8);
      expect(numCols, 0);
      expect(numParams, 2);
      // Drain param defs.
      for (var i = 0; i < numParams; i++) {
        await r.next();
      }

      // EXECUTE with id=3, name='carol'.
      w.send(
        _stmtExecute(stmtId, [_Param.int64(3), _Param.text('carol')]),
        seq: 0,
      );
      final exec = await r.next();
      expect(exec.payload[0], 0x00, reason: 'OK packet after INSERT');

      final rows = await db.execute('SELECT id, name FROM t ORDER BY id');
      expect(rows.rows, [
        [1, 'alice'],
        [2, 'bob'],
        [3, 'carol'],
      ]);
    });

    test(
      'PREPARE SELECT with parameter, EXECUTE returns binary rows',
      () async {
        w.send(_stmtPrepare('SELECT id, name FROM t WHERE id = ?'), seq: 0);
        final ok = await r.next();
        final stmtId =
            ok.payload[1] |
            (ok.payload[2] << 8) |
            (ok.payload[3] << 16) |
            (ok.payload[4] << 24);
        final numParams = ok.payload[7] | (ok.payload[8] << 8);
        for (var i = 0; i < numParams; i++) {
          await r.next();
        }

        w.send(_stmtExecute(stmtId, [_Param.int64(2)]), seq: 0);

        // Binary result set: column count packet, then column defs, then
        // binary row packets, then EOF/OK terminator.
        final cc = await r.next();
        expect(cc.payload[0], 2);
        for (var i = 0; i < 2; i++) {
          await r.next();
        }
        final row = await r.next();
        expect(row.payload[0], 0x00, reason: 'binary row header');
        // Null bitmap is 1 byte for 2 cols.
        // Then LONGLONG(8 bytes) for id, then lenenc str for name.
        final pr = _PR(row.payload);
        pr.u8(); // header
        final bitmap = pr.bytes(1);
        expect(bitmap[0], 0); // no nulls
        var id = 0;
        for (var i = 0; i < 8; i++) {
          id |= pr.u8() << (8 * i);
        }
        expect(id, 2);
        final nameLen = pr.u8();
        final name = utf8.decode(pr.bytes(nameLen));
        expect(name, 'bob');

        final terminator = await r.next();
        expect(terminator.payload[0], 0xfe);
      },
    );

    test('CLOSE then EXECUTE on stale id returns ERR', () async {
      w.send(_stmtPrepare('SELECT 1'), seq: 0);
      final ok = await r.next();
      final stmtId =
          ok.payload[1] |
          (ok.payload[2] << 8) |
          (ok.payload[3] << 16) |
          (ok.payload[4] << 24);

      // CLOSE — no reply expected.
      w.send(_stmtClose(stmtId), seq: 0);

      // EXECUTE on the now-closed id should yield ERR.
      w.send(_stmtExecute(stmtId, const []), seq: 0);
      final err = await r.next();
      expect(err.payload[0], 0xff);
    });
  });
}

// ---------------------------------------------------------------------------
// Tiny client helpers (same shape as mysql_wire_test).
// ---------------------------------------------------------------------------

Uint8List _handshakeResponse() {
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
  out.addByte(0); // empty auth response
  out.add(utf8.encode('mysql_native_password'));
  out.addByte(0);
  return out.toBytes();
}

Uint8List _stmtPrepare(String sql) {
  final out = BytesBuilder();
  out.addByte(0x16); // COM_STMT_PREPARE
  out.add(utf8.encode(sql));
  return out.toBytes();
}

Uint8List _stmtClose(int id) {
  final out = BytesBuilder();
  out.addByte(0x19);
  for (var i = 0; i < 4; i++) {
    out.addByte((id >> (8 * i)) & 0xff);
  }
  return out.toBytes();
}

Uint8List _stmtExecute(int id, List<_Param> params) {
  final out = BytesBuilder();
  out.addByte(0x17); // COM_STMT_EXECUTE
  for (var i = 0; i < 4; i++) {
    out.addByte((id >> (8 * i)) & 0xff);
  }
  out.addByte(0); // flags
  for (var i = 0; i < 4; i++) {
    out.addByte((1 >> (8 * i)) & 0xff); // iteration_count = 1
  }
  if (params.isNotEmpty) {
    final n = params.length;
    final nullBitmap = Uint8List((n + 7) ~/ 8);
    for (var i = 0; i < n; i++) {
      if (params[i].isNull) {
        nullBitmap[i ~/ 8] |= 1 << (i % 8);
      }
    }
    out.add(nullBitmap);
    out.addByte(1); // new_params_bound_flag
    for (final p in params) {
      out.addByte(p.type);
      out.addByte(0); // unsigned flag
    }
    for (final p in params) {
      if (!p.isNull) out.add(p.encoded);
    }
  }
  return out.toBytes();
}

class _Param {
  final int type;
  final bool isNull;
  final Uint8List encoded;
  _Param(this.type, this.encoded, {this.isNull = false});

  factory _Param.int64(int v) {
    final b = Uint8List(8);
    for (var i = 0; i < 8; i++) {
      b[i] = (v >> (8 * i)) & 0xff;
    }
    return _Param(0x08, b);
  }

  factory _Param.text(String s) {
    final bytes = utf8.encode(s);
    final out = BytesBuilder();
    out.addByte(bytes.length); // assumes < 0xfb
    out.add(bytes);
    return _Param(0xfd, out.toBytes());
  }
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

class _PR {
  final Uint8List _b;
  int _i = 0;
  _PR(this._b);
  int u8() => _b[_i++];
  Uint8List bytes(int n) {
    final out = Uint8List.sublistView(_b, _i, _i + n);
    _i += n;
    return out;
  }
}
