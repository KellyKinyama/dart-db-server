/// Real-client validation: the actual pure-Dart `oracledb` thin client
/// connects to `dart_db_server`'s Oracle wire front-end as if it were a real
/// Oracle database. Self-contained — no Docker / real Oracle required.
library;

import 'dart:typed_data';

import 'package:dart_db_server/dart_db_server.dart';
import 'package:oracledb/oracledb.dart';
import 'package:test/test.dart';

Future<OracleServer> _startServer(Database db) async {
  final server = OracleServer(db, port: 0, users: {
    'testuser': 'testpassword',
  });
  await server.start();
  return server;
}

void main() {
  test('client connects, authenticates, and round-trips CRUD', () async {
    final db = await Database.open(null);
    final server = await _startServer(db);
    addTearDown(() async => server.stop());

    final conn = await OracleConnection.connect(
      '127.0.0.1:${server.boundPort}/DARTDB',
      user: 'testuser',
      password: 'testpassword',
    );
    addTearDown(() async => conn.close());

    await conn.execute(
        'CREATE TABLE people (id INTEGER PRIMARY KEY, name TEXT)');

    final ins = await conn.execute("INSERT INTO people VALUES (1, 'alice')");
    expect(ins.rowsAffected, 1);
    await conn.execute("INSERT INTO people VALUES (2, 'bob')");

    final sel = await conn.execute('SELECT id, name FROM people ORDER BY id');
    expect(sel.rows.length, 2);
    // id comes back as a native int (Oracle NUMBER), name as a String.
    expect(sel.rows[0][0], 1);
    expect(sel.rows[0][0], isA<int>());
    expect(sel.rows[0][1], 'alice');
    expect(sel.rows[1][0], 2);
    expect(sel.rows[1][1], 'bob');
  });

  test('a wrong password is rejected', () async {
    final db = await Database.open(null);
    final server = await _startServer(db);
    addTearDown(() async => server.stop());

    await expectLater(
      OracleConnection.connect(
        '127.0.0.1:${server.boundPort}/DARTDB',
        user: 'testuser',
        password: 'WRONG',
      ),
      throwsA(isA<Object>()),
    );
  });

  test('numeric columns round-trip as native int/double', () async {
    final db = await Database.open(null);
    final server = await _startServer(db);
    addTearDown(() async => server.stop());

    final conn = await OracleConnection.connect(
      '127.0.0.1:${server.boundPort}/DARTDB',
      user: 'testuser',
      password: 'testpassword',
    );
    addTearDown(() async => conn.close());

    await conn.execute('CREATE TABLE nums (k TEXT, n REAL)');
    await conn.execute("INSERT INTO nums VALUES ('pi', 3.14)");
    await conn.execute("INSERT INTO nums VALUES ('neg', -42)");

    final r = await conn.execute('SELECT n FROM nums ORDER BY k');
    expect(r.rows[0][0], -42); // 'neg'
    expect(r.rows[1][0], closeTo(3.14, 1e-9)); // 'pi'
  });

  test('positional and named bind variables work', () async {
    final db = await Database.open(null);
    final server = await _startServer(db);
    addTearDown(() async => server.stop());

    final conn = await OracleConnection.connect(
      '127.0.0.1:${server.boundPort}/DARTDB',
      user: 'testuser',
      password: 'testpassword',
    );
    addTearDown(() async => conn.close());

    await conn.execute(
        'CREATE TABLE emp (id INTEGER PRIMARY KEY, name TEXT, dept INTEGER)');

    // Positional binds (a List -> :1, :2, :3).
    final ins = await conn.execute(
      'INSERT INTO emp VALUES (:1, :2, :3)',
      [1, 'alice', 10],
    );
    expect(ins.rowsAffected, 1);
    await conn.execute('INSERT INTO emp VALUES (:1, :2, :3)', [2, 'bob', 20]);
    await conn.execute('INSERT INTO emp VALUES (:1, :2, :3)', [3, 'carol', 10]);

    // Named bind in a WHERE clause.
    final sel = await conn.execute(
      'SELECT id, name FROM emp WHERE dept = :dept ORDER BY id',
      {'dept': 10},
    );
    expect(sel.rows.length, 2);
    expect(sel.rows[0][0], 1);
    expect(sel.rows[0][1], 'alice');
    expect(sel.rows[1][0], 3);
    expect(sel.rows[1][1], 'carol');

    // A repeated named placeholder binds once.
    final rep = await conn.execute(
      'SELECT name FROM emp WHERE id = :x OR dept = :x ORDER BY id',
      {'x': 10},
    );
    expect(rep.rows.map((r) => r[0]).toList(), ['alice', 'carol']);
  });

  test('a large result set spans multiple packets', () async {
    final db = await Database.open(null);
    final server = await _startServer(db);
    addTearDown(() async => server.stop());

    final conn = await OracleConnection.connect(
      '127.0.0.1:${server.boundPort}/DARTDB',
      user: 'testuser',
      password: 'testpassword',
    );
    addTearDown(() async => conn.close());

    await conn.execute('CREATE TABLE big (id INTEGER PRIMARY KEY, pad TEXT)');
    const rows = 800; // ~40 KB of result >> the 8 KB SDU -> multi-packet
    final pad = 'x' * 40;
    for (var i = 0; i < rows; i++) {
      await conn.execute('INSERT INTO big VALUES (:1, :2)', [i, pad]);
    }

    final sel = await conn.execute('SELECT id, pad FROM big ORDER BY id');
    expect(sel.rows.length, rows);
    expect(sel.rows.first[0], 0);
    expect(sel.rows.last[0], rows - 1);
    expect(sel.rows[123][1], pad);
  });

  test('a DateTime bind round-trips as an ISO-8601 value', () async {
    final db = await Database.open(null);
    final server = await _startServer(db);
    addTearDown(() async => server.stop());

    final conn = await OracleConnection.connect(
      '127.0.0.1:${server.boundPort}/DARTDB',
      user: 'testuser',
      password: 'testpassword',
    );
    addTearDown(() async => conn.close());

    await conn.execute('CREATE TABLE events (id INTEGER, at TEXT)');
    final at = DateTime(2025, 3, 14, 9, 26, 53);
    await conn.execute('INSERT INTO events VALUES (:1, :2)', [1, at]);

    // The engine stores dates as ISO-8601 text; the bind decoded correctly.
    final r = await conn.execute('SELECT at FROM events');
    expect(r.rows[0][0], '2025-03-14 09:26:53');
  });

  test('INTERVAL binds round-trip as signed literal values', () async {
    final db = await Database.open(null);
    final server = await _startServer(db);
    addTearDown(() async => server.stop());

    final conn = await OracleConnection.connect(
      '127.0.0.1:${server.boundPort}/DARTDB',
      user: 'testuser',
      password: 'testpassword',
    );
    addTearDown(() async => conn.close());

    await conn.execute(
        'CREATE TABLE spans (id INTEGER PRIMARY KEY, ym TEXT, ds TEXT)');

    // The client infers INTERVAL YEAR TO MONTH / DAY TO SECOND from the
    // wrapper value; the server decodes each to a signed literal string.
    await conn.execute('INSERT INTO spans VALUES (:1, :2, :3)', [
      1,
      OracleIntervalYM(years: 2, months: 6),
      OracleIntervalDS(days: 3, hours: 4, minutes: 5, seconds: 6, fseconds: 123456789),
    ]);
    await conn.execute('INSERT INTO spans VALUES (:1, :2, :3)', [
      2,
      OracleIntervalYM(years: -1, months: -3),
      OracleIntervalDS(days: -2, hours: -1, minutes: -2, seconds: -3, fseconds: -500000000),
    ]);

    final r = await conn.execute('SELECT ym, ds FROM spans ORDER BY id');
    expect(r.rows.length, 2);
    expect(r.rows[0][0], '+2-06');
    expect(r.rows[0][1], '+3 04:05:06.123456789');
    expect(r.rows[1][0], '-1-03');
    expect(r.rows[1][1], '-2 01:02:03.500000000');
  });

  test('a VECTOR bind and column round-trip (dense FLOAT32)', () async {
    final db = await Database.open(null);
    final server = await _startServer(db);
    addTearDown(() async => server.stop());

    final conn = await OracleConnection.connect(
      '127.0.0.1:${server.boundPort}/DARTDB',
      user: 'testuser',
      password: 'testpassword',
    );
    addTearDown(() async => conn.close());

    await conn.execute(
        'CREATE TABLE embeds (id INTEGER PRIMARY KEY, emb VECTOR)');

    // A Float32List binds as a dense FLOAT32 VECTOR; the engine stores it
    // natively and returns it on fetch.
    await conn.execute('INSERT INTO embeds VALUES (:1, :2)',
        [1, Float32List.fromList([1.5, -2.5, 3.25])]);

    final r = await conn.execute('SELECT emb FROM embeds ORDER BY id');
    expect(r.rows.length, 1);
    final back = r.rows[0][0] as Float32List;
    expect(back, [1.5, -2.5, 3.25]);
  });

  test('a JSON document binds and reads back as OSON', () async {
    final db = await Database.open(null);
    final server = await _startServer(db);
    addTearDown(() async => server.stop());

    final conn = await OracleConnection.connect(
      '127.0.0.1:${server.boundPort}/DARTDB',
      user: 'testuser',
      password: 'testpassword',
    );
    addTearDown(() async => conn.close());

    await conn.execute('CREATE TABLE docs (id INTEGER PRIMARY KEY, doc JSON)');

    // A Map binds as a native JSON (OSON) value; the engine stores it and
    // the server returns OSON the client decodes back to a Map.
    final doc = {
      'name': 'alice',
      'age': 30,
      'tags': ['x', 'y', 'z'],
      'nested': {'k': 1, 'active': true, 'note': null},
    };
    await conn.execute('INSERT INTO docs VALUES (:1, :2)', [1, doc]);

    final r = await conn.execute('SELECT doc FROM docs ORDER BY id');
    expect(r.rows.length, 1);
    expect(r.rows[0][0], doc);
  });

  test('a JSON document with DateTime and byte-array members round-trips',
      () async {
    final db = await Database.open(null);
    final server = await _startServer(db);
    addTearDown(() async => server.stop());

    final conn = await OracleConnection.connect(
      '127.0.0.1:${server.boundPort}/DARTDB',
      user: 'testuser',
      password: 'testpassword',
    );
    addTearDown(() async => conn.close());

    await conn.execute('CREATE TABLE docs (id INTEGER PRIMARY KEY, doc JSON)');

    // A JSON document with Oracle-specific OSON scalars: a local DateTime
    // (TIMESTAMP7 / TIMESTAMP nodes) and a Uint8List (binary node).
    final when = DateTime(2025, 3, 14, 9, 26, 53);
    final precise = DateTime(2025, 1, 1, 0, 0, 0, 123, 456);
    final doc = {
      'when': when,
      'precise': precise,
      'blob': Uint8List.fromList([1, 2, 3, 250, 255]),
      'nested': {'ts': when, 'bytes': Uint8List.fromList([0, 128, 255])},
    };
    await conn.execute('INSERT INTO docs VALUES (:1, :2)', [1, doc]);

    final r = await conn.execute('SELECT doc FROM docs ORDER BY id');
    final back = r.rows[0][0] as Map;
    expect(back['when'], when);
    expect(back['precise'], precise);
    expect(back['blob'], [1, 2, 3, 250, 255]);
    expect((back['nested'] as Map)['ts'], when);
    expect((back['nested'] as Map)['bytes'], [0, 128, 255]);
  });

  test('a JSON document with a field name over 255 bytes round-trips (OSON v3)',
      () async {
    final db = await Database.open(null);
    final server = await _startServer(db);
    addTearDown(() async => server.stop());

    final conn = await OracleConnection.connect(
      '127.0.0.1:${server.boundPort}/DARTDB',
      user: 'testuser',
      password: 'testpassword',
    );
    addTearDown(() async => conn.close());

    await conn.execute('CREATE TABLE docs (id INTEGER PRIMARY KEY, doc JSON)');

    final longKey = 'k' * 300; // > 255 UTF-8 bytes → OSON version 3
    final doc = {longKey: 'long', 'short': 7};
    await conn.execute('INSERT INTO docs VALUES (:1, :2)', [1, doc]);

    final r = await conn.execute('SELECT doc FROM docs ORDER BY id');
    final back = r.rows[0][0] as Map;
    expect(back[longKey], 'long');
    expect(back['short'], 7);
  });

  test('a 12c PBKDF2-verifier user authenticates', () async {
    final db = await Database.open(null);
    final server = await _startServer(db);
    server.userStore.addPbkdf2User('pbkdfuser', 'pbkdfpass');
    addTearDown(() async => server.stop());

    final conn = await OracleConnection.connect(
      '127.0.0.1:${server.boundPort}/DARTDB',
      user: 'pbkdfuser',
      password: 'pbkdfpass',
    );
    addTearDown(() async => conn.close());

    await conn.execute('CREATE TABLE p (id INTEGER PRIMARY KEY, v TEXT)');
    await conn.execute("INSERT INTO p VALUES (1, 'ok')");
    final r = await conn.execute('SELECT v FROM p');
    expect(r.rows[0][0], 'ok');
  });

  test('a 12c PBKDF2-verifier user with a wrong password is rejected',
      () async {
    final db = await Database.open(null);
    final server = await _startServer(db);
    server.userStore.addPbkdf2User('pbkdfuser', 'pbkdfpass');
    addTearDown(() async => server.stop());

    await expectLater(
      OracleConnection.connect(
        '127.0.0.1:${server.boundPort}/DARTDB',
        user: 'pbkdfuser',
        password: 'WRONG',
      ),
      throwsA(isA<Object>()),
    );
  });

  test('a temporary BLOB round-trips through write/read and a bound insert',
      () async {
    final db = await Database.open(null);
    final server = await _startServer(db);
    addTearDown(() async => server.stop());

    final conn = await OracleConnection.connect(
      '127.0.0.1:${server.boundPort}/DARTDB',
      user: 'testuser',
      password: 'testpassword',
    );
    addTearDown(() async => conn.close());

    // Temp BLOB: create (CREATE_TEMP + GET_CHUNK_SIZE), write (WRITE), read
    // back (GET_LENGTH + READ).
    final blob = await conn.createTemporaryBlob();
    await blob.write(1, Uint8List.fromList([10, 20, 30, 40, 50]));
    expect(await blob.read(), [10, 20, 30, 40, 50]);

    // Bind the temp BLOB into a BLOB column; the server resolves the locator to
    // its bytes and the column reads back.
    await conn.execute('CREATE TABLE b (id INTEGER PRIMARY KEY, data BLOB)');
    await conn.execute('INSERT INTO b VALUES (:1, :2)', [1, blob]);
    final r = await conn.execute('SELECT data FROM b');
    expect(r.rows[0][0], [10, 20, 30, 40, 50]);
  });

  test('a temporary CLOB round-trips through write/read and a bound insert',
      () async {
    final db = await Database.open(null);
    final server = await _startServer(db);
    addTearDown(() async => server.stop());

    final conn = await OracleConnection.connect(
      '127.0.0.1:${server.boundPort}/DARTDB',
      user: 'testuser',
      password: 'testpassword',
    );
    addTearDown(() async => conn.close());

    final clob = await conn.createTemporaryClob();
    await clob.write(1, 'hello lob world');
    expect(await clob.read(), 'hello lob world');

    await conn.execute('CREATE TABLE c (id INTEGER PRIMARY KEY, txt CLOB)');
    await conn.execute('INSERT INTO c VALUES (:1, :2)', [1, clob]);
    final r = await conn.execute('SELECT txt FROM c');
    expect(r.rows[0][0], 'hello lob world');
  });

  // NOTE: TLS (TCPS) is implemented and validated server-side by the
  // self-contained test/oracle_tls_test.dart (a standard SecureSocket client).
  // A real-`oracledb`-client TLS test is intentionally omitted: the client's
  // `OracleSocket.upgradeToTls` cancels its raw-socket subscription before
  // `SecureSocket.secure`, which closes the socket's read side and fails the
  // handshake against any Dart `SecureSocket` server (reproduced against a
  // vanilla `SecureServerSocket`) — a client-side limitation on this SDK, not a
  // server defect.
}
