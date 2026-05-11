/// Combined coverage for SQLite-parity additions: GROUP BY / ORDER BY
/// positional column references, HEX / UNHEX / UNICODE / CHAR builtins,
/// and PRAGMA defer_checks (deferred CHECK constraint evaluation).
library;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  group('GROUP BY positional', () {
    test('GROUP BY 1 groups by the first projected column', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE t (cat TEXT, n INTEGER)');
        await db.execute(
            "INSERT INTO t VALUES ('a',1),('a',2),('b',3),('a',4),('b',5)");
        final r = await db
            .execute('SELECT cat, SUM(n) FROM t GROUP BY 1 ORDER BY cat');
        expect(r.rows, [
          ['a', 7],
          ['b', 8],
        ]);
      } finally {
        await db.close();
      }
    });

    test('GROUP BY 1 with aliased expression', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE t (x INTEGER)');
        await db.execute('INSERT INTO t VALUES (1),(2),(3),(4),(5),(6)');
        final r = await db.execute(
            'SELECT MOD(x, 2) AS bucket, COUNT(*) FROM t GROUP BY 1 ORDER BY 1');
        expect(r.rows, [
          [0, 3],
          [1, 3],
        ]);
      } finally {
        await db.close();
      }
    });

    test('GROUP BY position out of range raises', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE t (a INTEGER)');
        await db.execute('INSERT INTO t VALUES (1)');
        expect(() => db.execute('SELECT a FROM t GROUP BY 2'),
            throwsA(isA<StateError>()));
      } finally {
        await db.close();
      }
    });
  });

  group('ORDER BY positional', () {
    test('ORDER BY 2 DESC sorts by the second projected column', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE t (a INTEGER, b INTEGER)');
        await db.execute('INSERT INTO t VALUES (1,30),(2,10),(3,20)');
        final r = await db.execute('SELECT a, b FROM t ORDER BY 2 DESC');
        expect(r.rows, [
          [1, 30],
          [3, 20],
          [2, 10],
        ]);
      } finally {
        await db.close();
      }
    });
  });

  group('Encoding builtins', () {
    test('HEX of an ASCII string returns uppercase hex bytes', () async {
      final db = await Database.open();
      try {
        final r = await db.execute("SELECT HEX('abc')");
        expect(r.rows.first.first, '616263');
      } finally {
        await db.close();
      }
    });

    test('UNHEX round-trips HEX', () async {
      final db = await Database.open();
      try {
        final r = await db.execute("SELECT UNHEX(HEX('hello'))");
        final v = r.rows.first.first;
        // UNHEX returns bytes; convert for comparison.
        expect(v, isA<List<int>>());
        expect(String.fromCharCodes(v as List<int>), 'hello');
      } finally {
        await db.close();
      }
    });

    test('UNHEX returns NULL on malformed input', () async {
      final db = await Database.open();
      try {
        final r = await db.execute("SELECT UNHEX('zz')");
        expect(r.rows.first.first, isNull);
      } finally {
        await db.close();
      }
    });

    test('UNICODE returns first codepoint', () async {
      final db = await Database.open();
      try {
        final r = await db.execute("SELECT UNICODE('A'), UNICODE('abc')");
        expect(r.rows.first, [65, 97]);
      } finally {
        await db.close();
      }
    });

    test('CHAR builds a string from codepoints', () async {
      final db = await Database.open();
      try {
        final r = await db.execute('SELECT CHAR(65, 66, 67)');
        expect(r.rows.first.first, 'ABC');
      } finally {
        await db.close();
      }
    });
  });

  group('PRAGMA defer_checks', () {
    test('Deferred CHECK passes when final row satisfies the constraint',
        () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE t (a INTEGER CHECK (a > 0))');
        await db.execute('INSERT INTO t VALUES (5)');
        await db.execute('PRAGMA defer_checks = 1');
        await db.execute('BEGIN');
        // Transiently sets a to -1 (would normally fail immediately),
        // then back to 10. Without deferral the first UPDATE throws.
        await db.execute('UPDATE t SET a = -1');
        await db.execute('UPDATE t SET a = 10');
        await db.execute('COMMIT');
        final r = await db.execute('SELECT a FROM t');
        expect(r.rows.first.first, 10);
      } finally {
        await db.close();
      }
    });

    test('Deferred CHECK reports failure at COMMIT and rolls back', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE t (a INTEGER CHECK (a > 0))');
        await db.execute('INSERT INTO t VALUES (5)');
        await db.execute('PRAGMA defer_checks = 1');
        await db.execute('BEGIN');
        await db.execute('UPDATE t SET a = -1');
        expect(
            () => db.execute('COMMIT'),
            throwsA(isA<StateError>().having(
                (e) => e.message, 'message', contains('DEFERRED CHECK'))));
        // After rollback the original value survives.
        final r = await db.execute('SELECT a FROM t');
        expect(r.rows.first.first, 5);
      } finally {
        await db.close();
      }
    });

    test('Non-deferred CHECK still fires immediately', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE t (a INTEGER CHECK (a > 0))');
        expect(() => db.execute('INSERT INTO t VALUES (-1)'),
            throwsA(isA<StateError>()));
      } finally {
        await db.close();
      }
    });
  });
}
