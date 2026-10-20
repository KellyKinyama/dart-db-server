// End-to-end test for the MySQL X Protocol front-end (G11). Drives the
// protobuf-framed protocol with a raw socket (no X-protocol driver dependency):
// capabilities, MYSQL41 + PLAIN auth, and Sql.StmtExecute result sets.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

// Server message types.
const _sError = 1;
const _sCapabilities = 2;
const _sAuthContinue = 3;
const _sAuthOk = 4;
const _sNotice = 11;
const _sColumnMeta = 12;
const _sRow = 13;
const _sFetchDone = 14;
const _sStmtOk = 17;

// Client message types.
const _cCapabilitiesGet = 1;
const _cAuthStart = 4;
const _cAuthContinue = 5;
const _cStmtExecute = 12;
const _cCrudFind = 17;
const _cCrudInsert = 18;
const _cCrudUpdate = 19;
const _cCrudDelete = 20;

// ---------------------------------------------------------------------------
// CRUD protobuf builders (Mysqlx.Crud / Mysqlx.Expr)
// ---------------------------------------------------------------------------

Uint8List _scInt(int n) => (_PbW()..vint(1, 1)..zig(2, n)).build();
Uint8List _scStr(String s) =>
    (_PbW()..vint(1, 8)..msg(8, (_PbW()..bytes(1, utf8.encode(s))).build()))
        .build();

Uint8List _eIdent(String col) =>
    (_PbW()..vint(1, 1)..msg(2, (_PbW()..str(2, col)).build())).build();
Uint8List _eLit(Uint8List scalar) => (_PbW()..vint(1, 2)..msg(4, scalar)).build();
Uint8List _eOp(String name, List<Uint8List> params) {
  final op = _PbW()..str(1, name);
  for (final p in params) {
    op.msg(2, p);
  }
  return (_PbW()..vint(1, 5)..msg(6, op.build())).build();
}

Uint8List _collection(String table) => (_PbW()..str(1, table)).build();

Uint8List _find({
  required String table,
  List<String> cols = const [],
  Uint8List? criteria,
  String? orderBy,
  bool orderDesc = false,
  int? limit,
}) {
  final b = _PbW()..msg(2, _collection(table));
  for (final c in cols) {
    b.msg(4, (_PbW()..msg(1, _eIdent(c))).build()); // Projection{source=1}
  }
  if (criteria != null) b.msg(5, criteria);
  if (limit != null) b.msg(6, (_PbW()..vint(1, limit)).build());
  if (orderBy != null) {
    final o = _PbW()..msg(1, _eIdent(orderBy));
    if (orderDesc) o.vint(2, 2);
    b.msg(7, o.build());
  }
  return b.build();
}

Uint8List _insert({
  required String table,
  required List<String> cols,
  required List<List<Uint8List>> rows,
}) {
  final b = _PbW()..msg(1, _collection(table));
  for (final c in cols) {
    b.msg(3, (_PbW()..str(1, c)).build()); // Column{name=1}
  }
  for (final row in rows) {
    final tr = _PbW();
    for (final field in row) {
      tr.msg(1, field); // TypedRow{field=1}
    }
    b.msg(4, tr.build());
  }
  return b.build();
}

Uint8List _delete({required String table, Uint8List? criteria}) {
  final b = _PbW()..msg(1, _collection(table));
  if (criteria != null) b.msg(3, criteria);
  return b.build();
}

Uint8List _update({
  required String table,
  required List<Uint8List> ops,
  Uint8List? criteria,
}) {
  final b = _PbW()..msg(2, _collection(table));
  if (criteria != null) b.msg(4, criteria);
  for (final op in ops) {
    b.msg(7, op);
  }
  return b.build();
}

Uint8List _setOp(String col, Uint8List valueExpr) => (_PbW()
      ..msg(1, (_PbW()..str(2, col)).build()) // ColumnIdentifier{name=2}
      ..vint(2, 1) // UpdateType.SET
      ..msg(3, valueExpr))
    .build();


void main() {
  group('MysqlxServer', () {
    late Database db;
    late MysqlxServer server;
    late Socket sock;
    late _XClient x;

    Future<void> connect({String? password}) async {
      db = await Database.open(null);
      server = MysqlxServer(db, port: 0, password: password);
      await server.start();
      sock = await Socket.connect(
        InternetAddress.loopbackIPv4,
        server.boundPort,
      );
      x = _XClient(sock);
    }

    tearDown(() async {
      await x.close();
      await sock.close();
      await server.stop();
    });

    Future<void> authMysql41(String user, {String? password}) async {
      x.send(_cAuthStart, (_PbW()..str(1, 'MYSQL41')).build());
      final cont = await x.next();
      expect(cont.type, _sAuthContinue);
      final salt = _PbR(cont.payload).readBytesField(1)!;
      final resp = password == null || password.isEmpty
          ? ''
          : _mysql41Response(password, salt);
      final authData = <int>[
        0, // schema (empty) + NUL
        ...utf8.encode(user), 0,
        ...utf8.encode(resp),
      ];
      x.send(_cAuthContinue, (_PbW()..bytes(1, authData)).build());
      final ok = await x.next();
      expect(ok.type, _sAuthOk, reason: 'authentication should succeed');
    }

    Future<List<List<Object?>>> query(String sql) async {
      x.send(_cStmtExecute, (_PbW()..bytes(1, utf8.encode(sql))).build());
      final cols = <int>[];
      final rows = <List<Object?>>[];
      while (true) {
        final m = await x.next();
        if (m.type == _sColumnMeta) {
          cols.add(_PbR(m.payload).readVarintField(1)!); // FieldType
        } else if (m.type == _sRow) {
          rows.add(_decodeRow(m.payload, cols));
        } else if (m.type == _sFetchDone || m.type == _sNotice) {
          // keep reading until StmtExecuteOk
        } else if (m.type == _sStmtOk) {
          break;
        } else if (m.type == _sError) {
          throw StateError('X error: ${_decodeError(m.payload)}');
        }
      }
      return rows;
    }

    // Send a CRUD message and collect any result rows up to StmtExecuteOk.
    Future<List<List<Object?>>> crud(int type, Uint8List payload) async {
      x.send(type, payload);
      final cols = <int>[];
      final rows = <List<Object?>>[];
      while (true) {
        final m = await x.next();
        if (m.type == _sColumnMeta) {
          cols.add(_PbR(m.payload).readVarintField(1)!);
        } else if (m.type == _sRow) {
          rows.add(_decodeRow(m.payload, cols));
        } else if (m.type == _sFetchDone || m.type == _sNotice) {
          // keep reading
        } else if (m.type == _sStmtOk) {
          break;
        } else if (m.type == _sError) {
          throw StateError('X error: ${_decodeError(m.payload)}');
        }
      }
      return rows;
    }

    test('CapabilitiesGet advertises auth mechanisms', () async {
      await connect();
      x.send(_cCapabilitiesGet, Uint8List(0));
      final caps = await x.next();
      expect(caps.type, _sCapabilities);
      // The payload should mention our mechanisms somewhere.
      final text = utf8.decode(caps.payload, allowMalformed: true);
      expect(text, contains('authentication.mechanisms'));
      expect(text, contains('MYSQL41'));
    });

    test('MYSQL41 auth (no password) + SQL round-trip', () async {
      await connect();
      await authMysql41('root');

      await query('CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT, score REAL)');
      await query("INSERT INTO t VALUES (1, 'Alice', 9.5), (2, 'Bob', 7.25)");
      final rows = await query('SELECT id, name, score FROM t ORDER BY id');
      expect(rows, [
        [1, 'Alice', 9.5],
        [2, 'Bob', 7.25],
      ]);
    });

    test('MYSQL41 auth with correct password', () async {
      await connect(password: 'secret');
      await authMysql41('root', password: 'secret');
      final rows = await query('SELECT 42');
      expect(rows, [
        [42],
      ]);
    });

    test('MYSQL41 auth with wrong password is rejected', () async {
      await connect(password: 'secret');
      x.send(_cAuthStart, (_PbW()..str(1, 'MYSQL41')).build());
      final cont = await x.next();
      final salt = _PbR(cont.payload).readBytesField(1)!;
      final resp = _mysql41Response('wrong', salt);
      final authData = <int>[0, ...utf8.encode('root'), 0, ...utf8.encode(resp)];
      x.send(_cAuthContinue, (_PbW()..bytes(1, authData)).build());
      final m = await x.next();
      expect(m.type, _sError, reason: 'wrong password should error');
    });

    test('PLAIN auth', () async {
      await connect(password: 'secret');
      final authData = <int>[
        0, // schema
        ...utf8.encode('root'), 0,
        ...utf8.encode('secret'),
      ];
      x.send(
        _cAuthStart,
        (_PbW()..str(1, 'PLAIN')..bytes(3, authData)).build(),
      );
      final m = await x.next();
      expect(m.type, _sAuthOk);
    });

    test('SHA256_MEMORY auth with correct password', () async {
      await connect(password: 'secret');
      x.send(_cAuthStart, (_PbW()..str(1, 'SHA256_MEMORY')).build());
      final cont = await x.next();
      expect(cont.type, _sAuthContinue);
      final salt = _PbR(cont.payload).readBytesField(1)!;
      final resp = _sha256MemoryResponse('secret', salt);
      final authData = <int>[0, ...utf8.encode('root'), 0, ...utf8.encode(resp)];
      x.send(_cAuthContinue, (_PbW()..bytes(1, authData)).build());
      final m = await x.next();
      expect(m.type, _sAuthOk);
    });

    test('SHA256_MEMORY auth with wrong password is rejected', () async {
      await connect(password: 'secret');
      x.send(_cAuthStart, (_PbW()..str(1, 'SHA256_MEMORY')).build());
      final cont = await x.next();
      final salt = _PbR(cont.payload).readBytesField(1)!;
      final resp = _sha256MemoryResponse('nope', salt);
      final authData = <int>[0, ...utf8.encode('root'), 0, ...utf8.encode(resp)];
      x.send(_cAuthContinue, (_PbW()..bytes(1, authData)).build());
      final m = await x.next();
      expect(m.type, _sError);
    });

    test('NULL and string values decode correctly', () async {
      await connect();
      await authMysql41('root');
      await query('CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)');
      await query("INSERT INTO t VALUES (1, 'x'), (2, NULL)");
      final rows = await query('SELECT id, name FROM t ORDER BY id');
      expect(rows, [
        [1, 'x'],
        [2, null],
      ]);
    });

    test('CRUD Insert then Find round-trips', () async {
      await connect();
      await authMysql41('root');
      await query('CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)');
      await crud(
        _cCrudInsert,
        _insert(table: 't', cols: [
          'id',
          'name'
        ], rows: [
          [_eLit(_scInt(1)), _eLit(_scStr('alice'))],
          [_eLit(_scInt(2)), _eLit(_scStr('bob'))],
        ]),
      );
      final rows = await crud(
        _cCrudFind,
        _find(table: 't', cols: ['id', 'name'], orderBy: 'id'),
      );
      expect(rows, [
        [1, 'alice'],
        [2, 'bob'],
      ]);
    });

    test('CRUD Find with criteria, order and limit', () async {
      await connect();
      await authMysql41('root');
      await query('CREATE TABLE t (id INTEGER PRIMARY KEY, n INTEGER)');
      await query('INSERT INTO t VALUES (1,10),(2,20),(3,30),(4,40)');
      final rows = await crud(
        _cCrudFind,
        _find(
          table: 't',
          cols: ['id'],
          criteria: _eOp('>', [_eIdent('n'), _eLit(_scInt(15))]),
          orderBy: 'id',
          orderDesc: true,
          limit: 2,
        ),
      );
      expect(rows.map((r) => r.first).toList(), [4, 3]);
    });

    test('CRUD Update with criteria', () async {
      await connect();
      await authMysql41('root');
      await query('CREATE TABLE t (id INTEGER PRIMARY KEY, n INTEGER)');
      await query('INSERT INTO t VALUES (1,10),(2,20)');
      await crud(
        _cCrudUpdate,
        _update(
          table: 't',
          ops: [_setOp('n', _eLit(_scInt(99)))],
          criteria: _eOp('==', [_eIdent('id'), _eLit(_scInt(2))]),
        ),
      );
      final rows = await crud(
        _cCrudFind,
        _find(table: 't', cols: ['id', 'n'], orderBy: 'id'),
      );
      expect(rows, [
        [1, 10],
        [2, 99],
      ]);
    });

    test('CRUD Delete with criteria', () async {
      await connect();
      await authMysql41('root');
      await query('CREATE TABLE t (id INTEGER PRIMARY KEY)');
      await query('INSERT INTO t VALUES (1),(2),(3)');
      await crud(
        _cCrudDelete,
        _delete(
          table: 't',
          criteria: _eOp('<', [_eIdent('id'), _eLit(_scInt(3))]),
        ),
      );
      final rows = await crud(
        _cCrudFind,
        _find(table: 't', cols: ['id'], orderBy: 'id'),
      );
      expect(rows.map((r) => r.first).toList(), [3]);
    });

    test('StmtExecute before auth is rejected', () async {
      await connect();
      x.send(_cStmtExecute, (_PbW()..bytes(1, utf8.encode('SELECT 1'))).build());
      final m = await x.next();
      expect(m.type, _sError);
    });
  });
}

// ---------------------------------------------------------------------------
// MYSQL41 client-side hash
// ---------------------------------------------------------------------------

String _mysql41Response(String password, Uint8List salt) {
  final h1 = sha1.convert(utf8.encode(password)).bytes;
  final h2 = sha1.convert(h1).bytes;
  final t = sha1.convert([...salt, ...h2]).bytes;
  final token = <int>[for (var i = 0; i < 20; i++) h1[i] ^ t[i]];
  return '*${token.map((b) => b.toRadixString(16).padLeft(2, '0')).join().toUpperCase()}';
}

String _sha256MemoryResponse(String password, Uint8List salt) {
  final h1 = sha256.convert(utf8.encode(password)).bytes;
  final h2 = sha256.convert(h1).bytes;
  final t = sha256.convert([...h2, ...salt]).bytes;
  final token = <int>[for (var i = 0; i < 32; i++) h1[i] ^ t[i]];
  return token
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join()
      .toUpperCase();
}

// ---------------------------------------------------------------------------
// Row / error decoding
// ---------------------------------------------------------------------------

List<Object?> _decodeRow(Uint8List payload, List<int> colTypes) {
  final fields = _PbR(payload).readAllBytesField(1);
  final out = <Object?>[];
  for (var i = 0; i < fields.length; i++) {
    final f = fields[i];
    if (f.isEmpty) {
      out.add(null);
      continue;
    }
    final type = i < colTypes.length ? colTypes[i] : 7;
    switch (type) {
      case 1: // SINT
        out.add(_decodeZigzag(f));
      case 2: // UINT
        out.add(_decodeVarint(f));
      case 5: // DOUBLE
        out.add(ByteData.sublistView(f).getFloat64(0, Endian.little));
      default: // BYTES (trailing NUL)
        out.add(utf8.decode(f.sublist(0, f.length - 1)));
    }
  }
  return out;
}

int _decodeVarint(Uint8List b) {
  var shift = 0;
  var result = 0;
  var p = 0;
  while (true) {
    final x = b[p++];
    result |= (x & 0x7f) << shift;
    if ((x & 0x80) == 0) break;
    shift += 7;
  }
  return result;
}

int _decodeZigzag(Uint8List b) {
  final v = _decodeVarint(b);
  return (v >>> 1) ^ -(v & 1);
}

String _decodeError(Uint8List payload) {
  final r = _PbR(payload);
  return r.readStringField(3) ?? 'unknown';
}

// ---------------------------------------------------------------------------
// Raw X-protocol client (framing + minimal protobuf)
// ---------------------------------------------------------------------------

class _Msg {
  final int type;
  final Uint8List payload;
  _Msg(this.type, this.payload);
}

class _XClient {
  final Socket sock;
  final List<int> _buf = [];
  late final StreamSubscription<List<int>> _sub;
  final _queue = <_Msg>[];
  final _waiters = <Completer<_Msg>>[];

  _XClient(this.sock) {
    _sub = sock.cast<Uint8List>().listen(_onData);
  }

  void _onData(List<int> chunk) {
    _buf.addAll(chunk);
    while (_buf.length >= 4) {
      final len =
          _buf[0] | (_buf[1] << 8) | (_buf[2] << 16) | (_buf[3] << 24);
      if (_buf.length < 4 + len) return;
      final type = _buf[4];
      final payload = Uint8List.fromList(_buf.sublist(5, 4 + len));
      _buf.removeRange(0, 4 + len);
      final m = _Msg(type, payload);
      if (_waiters.isNotEmpty) {
        _waiters.removeAt(0).complete(m);
      } else {
        _queue.add(m);
      }
    }
  }

  void send(int type, Uint8List payload) {
    final len = payload.length + 1;
    final header = Uint8List(5);
    header[0] = len & 0xff;
    header[1] = (len >> 8) & 0xff;
    header[2] = (len >> 16) & 0xff;
    header[3] = (len >> 24) & 0xff;
    header[4] = type & 0xff;
    sock.add(header);
    sock.add(payload);
  }

  Future<_Msg> next() {
    if (_queue.isNotEmpty) return Future.value(_queue.removeAt(0));
    final c = Completer<_Msg>();
    _waiters.add(c);
    return c.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () => throw StateError('no X message within 5s'),
    );
  }

  Future<void> close() => _sub.cancel();
}

class _PbW {
  final BytesBuilder _b = BytesBuilder();
  void _tag(int field, int wire) => _rawVarint((field << 3) | wire);
  void _rawVarint(int value) {
    var x = value;
    while (true) {
      final part = x & 0x7f;
      x = x >>> 7;
      if (x != 0) {
        _b.addByte(part | 0x80);
      } else {
        _b.addByte(part);
        break;
      }
    }
  }

  _PbW str(int field, String s) => bytes(field, utf8.encode(s));
  _PbW bytes(int field, List<int> data) {
    _tag(field, 2);
    _rawVarint(data.length);
    _b.add(data);
    return this;
  }

  _PbW vint(int field, int value) {
    _tag(field, 0);
    _rawVarint(value);
    return this;
  }

  _PbW zig(int field, int value) {
    _tag(field, 0);
    _rawVarint((value << 1) ^ (value >> 63));
    return this;
  }

  _PbW msg(int field, Uint8List m) => bytes(field, m);

  Uint8List build() => _b.toBytes();
}

class _PbR {
  final Uint8List data;
  int _p = 0;
  _PbR(this.data);
  bool get _hasMore => _p < data.length;

  int _rawVarint() {
    var shift = 0;
    var result = 0;
    while (true) {
      final b = data[_p++];
      result |= (b & 0x7f) << shift;
      if ((b & 0x80) == 0) break;
      shift += 7;
    }
    return result;
  }

  Uint8List _readLenDelim() {
    final len = _rawVarint();
    final out = Uint8List.sublistView(data, _p, _p + len);
    _p += len;
    return out;
  }

  void _skip(int wire) {
    switch (wire) {
      case 0:
        _rawVarint();
      case 1:
        _p += 8;
      case 2:
        _p += _rawVarint();
      case 5:
        _p += 4;
    }
  }

  int? readVarintField(int field) {
    while (_hasMore) {
      final key = _rawVarint();
      final f = key >> 3;
      final w = key & 7;
      if (f == field && w == 0) return _rawVarint();
      _skip(w);
    }
    return null;
  }

  Uint8List? readBytesField(int field) {
    while (_hasMore) {
      final key = _rawVarint();
      final f = key >> 3;
      final w = key & 7;
      if (f == field && w == 2) return Uint8List.fromList(_readLenDelim());
      _skip(w);
    }
    return null;
  }

  String? readStringField(int field) {
    final b = readBytesField(field);
    return b == null ? null : utf8.decode(b);
  }

  List<Uint8List> readAllBytesField(int field) {
    final out = <Uint8List>[];
    while (_hasMore) {
      final key = _rawVarint();
      final f = key >> 3;
      final w = key & 7;
      if (f == field && w == 2) {
        out.add(Uint8List.fromList(_readLenDelim()));
      } else {
        _skip(w);
      }
    }
    return out;
  }
}
