import 'dart:io';

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  group('Database (in-memory)', () {
    late Database db;
    setUp(() async {
      db = await Database.open();
    });

    test('CREATE TABLE / INSERT / SELECT *', () async {
      await db.execute(
          'CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, age INTEGER)');
      await db.execute(
          "INSERT INTO users (id, name, age) VALUES (1, 'Alice', 30), (2, 'Bob', 25)");
      final r = await db.execute('SELECT * FROM users ORDER BY id');
      expect(r.columns, ['id', 'name', 'age']);
      expect(r.rows, [
        [1, 'Alice', 30],
        [2, 'Bob', 25],
      ]);
    });

    test('SELECT with WHERE expression (AND/OR/comparisons)', () async {
      await db.execute('CREATE TABLE t (id INTEGER, x INTEGER)');
      for (final v in [1, 2, 3, 4, 5]) {
        await db.execute('INSERT INTO t VALUES ($v, ${v * 10})');
      }
      final r = await db.execute('SELECT id FROM t WHERE x > 20 AND x < 50');
      expect(r.rows.map((r) => r[0]).toList(), [3, 4]);
    });

    test('UPDATE and DELETE with WHERE', () async {
      await db.execute('CREATE TABLE t (id INTEGER, name TEXT)');
      await db.execute("INSERT INTO t VALUES (1, 'a'), (2, 'b'), (3, 'c')");
      final u = await db.execute("UPDATE t SET name = 'X' WHERE id >= 2");
      expect(u.affected, 2);
      final d = await db.execute('DELETE FROM t WHERE id = 1');
      expect(d.affected, 1);
      final r = await db.execute('SELECT * FROM t ORDER BY id');
      expect(r.rows, [
        [2, 'X'],
        [3, 'X']
      ]);
    });

    test('IS NULL, IN, BETWEEN, LIKE', () async {
      await db.execute('CREATE TABLE t (name TEXT, score INTEGER)');
      await db.execute(
          "INSERT INTO t VALUES ('alice', 90), ('bob', 75), ('carol', NULL)");
      expect(
          (await db.execute("SELECT name FROM t WHERE score IS NULL")).rows, [
        ['carol']
      ]);
      expect(
          (await db.execute(
                  "SELECT name FROM t WHERE score IN (90, 75) ORDER BY name"))
              .rows,
          [
            ['alice'],
            ['bob']
          ]);
      expect(
          (await db
                  .execute("SELECT name FROM t WHERE score BETWEEN 80 AND 100"))
              .rows,
          [
            ['alice']
          ]);
      expect(
          (await db.execute("SELECT name FROM t WHERE name LIKE 'a%'")).rows, [
        ['alice']
      ]);
    });

    test('PRIMARY KEY UNIQUE constraint enforcement', () async {
      await db.execute('CREATE TABLE u (id INTEGER PRIMARY KEY, n TEXT)');
      await db.execute("INSERT INTO u VALUES (1, 'a')");
      expect(() => db.execute("INSERT INTO u VALUES (1, 'b')"),
          throwsA(isA<StateError>()));
    });

    test('NOT NULL enforcement', () async {
      await db.execute('CREATE TABLE u (id INTEGER NOT NULL, n TEXT)');
      expect(() => db.execute("INSERT INTO u VALUES (NULL, 'a')"),
          throwsA(isA<FormatException>()));
    });

    test('ORDER BY DESC, LIMIT, OFFSET', () async {
      await db.execute('CREATE TABLE t (n INTEGER)');
      for (var i = 1; i <= 5; i++) {
        await db.execute('INSERT INTO t VALUES ($i)');
      }
      final r =
          await db.execute('SELECT n FROM t ORDER BY n DESC LIMIT 2 OFFSET 1');
      expect(r.rows, [
        [4],
        [3]
      ]);
    });

    test('INNER JOIN', () async {
      await db.execute('CREATE TABLE a (id INTEGER, name TEXT)');
      await db.execute('CREATE TABLE b (aid INTEGER, val INTEGER)');
      await db.execute("INSERT INTO a VALUES (1,'x'), (2,'y')");
      await db.execute("INSERT INTO b VALUES (1, 100), (1, 200), (2, 300)");
      final r = await db.execute(
          'SELECT a.name, b.val FROM a INNER JOIN b ON a.id = b.aid ORDER BY b.val');
      expect(r.rows, [
        ['x', 100],
        ['x', 200],
        ['y', 300]
      ]);
    });

    test('LEFT JOIN with no matches', () async {
      await db.execute('CREATE TABLE a (id INTEGER)');
      await db.execute('CREATE TABLE b (aid INTEGER, v INTEGER)');
      await db.execute('INSERT INTO a VALUES (1), (2)');
      await db.execute('INSERT INTO b VALUES (1, 10)');
      final r = await db.execute(
          'SELECT a.id, b.v FROM a LEFT JOIN b ON a.id = b.aid ORDER BY a.id');
      expect(r.rows, [
        [1, 10],
        [2, null]
      ]);
    });

    test('Transaction commit and rollback', () async {
      await db.execute('CREATE TABLE t (n INTEGER)');
      await db.execute('INSERT INTO t VALUES (1)');
      await db.execute('BEGIN');
      await db.execute('INSERT INTO t VALUES (2)');
      await db.execute('ROLLBACK');
      expect((await db.execute('SELECT n FROM t')).rows, [
        [1]
      ]);
      await db.execute('BEGIN');
      await db.execute('INSERT INTO t VALUES (3)');
      await db.execute('COMMIT');
      expect((await db.execute('SELECT n FROM t ORDER BY n')).rows, [
        [1],
        [3]
      ]);
    });

    test('CREATE INDEX / DROP INDEX', () async {
      await db.execute('CREATE TABLE t (n INTEGER)');
      await db.execute('INSERT INTO t VALUES (1), (2), (3)');
      await db.execute('CREATE INDEX idx_n ON t(n)');
      await db.execute('DROP INDEX idx_n');
    });

    test('ALTER TABLE ADD COLUMN with DEFAULT', () async {
      await db.execute('CREATE TABLE t (id INTEGER)');
      await db.execute('INSERT INTO t VALUES (1)');
      await db.execute("ALTER TABLE t ADD COLUMN status TEXT DEFAULT 'new'");
      final r = await db.execute('SELECT * FROM t');
      expect(r.columns, ['id', 'status']);
      expect(r.rows, [
        [1, 'new']
      ]);
    });

    test('SHOW TABLES', () async {
      await db.execute('CREATE TABLE foo (n INTEGER)');
      await db.execute('CREATE TABLE bar (n INTEGER)');
      final r = await db.execute('SHOW TABLES');
      expect(r.rows.map((r) => r[0]).toSet(), {'foo', 'bar'});
    });
  });

  group('Persistence', () {
    test('round-trips through JSON file', () async {
      final tmp = File(
          '${Directory.systemTemp.path}/dart_db_test_${DateTime.now().microsecondsSinceEpoch}.json');
      addTearDown(() async {
        if (await tmp.exists()) await tmp.delete();
      });
      var db = await Database.open(tmp.path);
      await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)');
      await db.execute("INSERT INTO t VALUES (1, 'a'), (2, 'b')");
      await db.flush();
      await db.close();
      db = await Database.open(tmp.path);
      final r = await db.execute('SELECT * FROM t ORDER BY id');
      expect(r.rows, [
        [1, 'a'],
        [2, 'b']
      ]);
      await db.close();
    });
  });

  group('TCP server', () {
    test('client/server round-trip', () async {
      final db = await Database.open();
      final server = DbServer(db, port: 0); // ephemeral port chosen by OS
      // We need a known port; instead bind to 0 and re-create with the chosen port.
      // Simpler: pick a high arbitrary port and retry on conflict.
      const port = 45550;
      final s2 = DbServer(db, port: port);
      await s2.start();
      addTearDown(() async {
        await s2.stop();
      });
      final client = await DbClient.connect(port: port);
      addTearDown(() => client.close());
      await client.exec('CREATE TABLE t (n INTEGER)');
      await client.exec('INSERT INTO t VALUES (42)');
      final reply = await client.exec('SELECT n FROM t');
      expect(reply['columns'], ['n']);
      expect(reply['rows'], [
        [42]
      ]);
      // Avoid analyzer "unused" warning on `server`.
      expect(server.port, 0);
    });
  });
}
