/// TOTAL, GROUP_CONCAT, STRING_AGG aggregates and CONCAT_WS scalar.
library;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  group('TOTAL aggregate', () {
    test('returns 0.0 on empty set', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE t (x INTEGER)');
        final r = await db.execute('SELECT TOTAL(x) FROM t');
        expect(r.rows.first.first, 0.0);
      } finally {
        await db.close();
      }
    });

    test('always returns float', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE t (x INTEGER)');
        await db.execute('INSERT INTO t VALUES (1),(2),(3)');
        final r = await db.execute('SELECT TOTAL(x) FROM t');
        expect(r.rows.first.first, 6.0);
        expect(r.rows.first.first, isA<double>());
      } finally {
        await db.close();
      }
    });
  });

  group('GROUP_CONCAT / STRING_AGG', () {
    test('default comma separator', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE t (s TEXT)');
        await db.execute("INSERT INTO t VALUES ('a'),('b'),('c')");
        final r = await db.execute('SELECT GROUP_CONCAT(s) FROM t');
        expect(r.rows.first.first, 'a,b,c');
      } finally {
        await db.close();
      }
    });

    test('custom separator', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE t (s TEXT)');
        await db.execute("INSERT INTO t VALUES ('a'),('b'),('c')");
        final r = await db.execute("SELECT GROUP_CONCAT(s, ' | ') FROM t");
        expect(r.rows.first.first, 'a | b | c');
      } finally {
        await db.close();
      }
    });

    test('STRING_AGG alias', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE t (s TEXT)');
        await db.execute("INSERT INTO t VALUES ('x'),('y'),('z')");
        final r = await db.execute("SELECT STRING_AGG(s, '-') FROM t");
        expect(r.rows.first.first, 'x-y-z');
      } finally {
        await db.close();
      }
    });

    test('NULL values skipped, all-NULL returns NULL', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE t (s TEXT)');
        await db.execute("INSERT INTO t VALUES ('a'), (NULL), ('b')");
        final r = await db.execute('SELECT GROUP_CONCAT(s) FROM t');
        expect(r.rows.first.first, 'a,b');

        await db.execute('DELETE FROM t');
        await db.execute('INSERT INTO t VALUES (NULL), (NULL)');
        final r2 = await db.execute('SELECT GROUP_CONCAT(s) FROM t');
        expect(r2.rows.first.first, null);
      } finally {
        await db.close();
      }
    });

    test('DISTINCT eliminates duplicates', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE t (s TEXT)');
        await db.execute("INSERT INTO t VALUES ('a'),('b'),('a'),('c'),('b')");
        final r = await db.execute("SELECT GROUP_CONCAT(DISTINCT s) FROM t");
        expect(r.rows.first.first, 'a,b,c');
      } finally {
        await db.close();
      }
    });

    test('per-group aggregation', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE t (g TEXT, v TEXT)');
        await db.execute("INSERT INTO t VALUES ('A','1'),('A','2'),('B','3')");
        final r = await db.execute(
            "SELECT g, GROUP_CONCAT(v, ';') FROM t GROUP BY g ORDER BY g");
        expect(r.rows, [
          ['A', '1;2'],
          ['B', '3'],
        ]);
      } finally {
        await db.close();
      }
    });
  });

  group('CONCAT_WS', () {
    test('skips NULLs, joins with separator', () async {
      final db = await Database.open();
      try {
        final r =
            await db.execute("SELECT CONCAT_WS('-', 'a', NULL, 'b', 'c')");
        expect(r.rows.first.first, 'a-b-c');
      } finally {
        await db.close();
      }
    });

    test('NULL separator returns NULL', () async {
      final db = await Database.open();
      try {
        final r = await db.execute("SELECT CONCAT_WS(NULL, 'a', 'b')");
        expect(r.rows.first.first, null);
      } finally {
        await db.close();
      }
    });

    test('all-NULL args returns empty string', () async {
      final db = await Database.open();
      try {
        final r = await db.execute("SELECT CONCAT_WS(',', NULL, NULL)");
        expect(r.rows.first.first, '');
      } finally {
        await db.close();
      }
    });
  });
}
