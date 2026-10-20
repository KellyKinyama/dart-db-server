/// Real-client validation: the actual pure-Dart `oracledb` thin client
/// connects to `dart_db_server`'s Oracle wire front-end as if it were a real
/// Oracle database. Self-contained — no Docker / real Oracle required.
library;

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
}
