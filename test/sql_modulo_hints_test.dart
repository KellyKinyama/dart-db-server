/// Coverage for: `%` modulo operator, `INDEXED BY` on UPDATE/DELETE,
/// and `MATERIALIZED` / `NOT MATERIALIZED` CTE hints observable via
/// `Database.lastCteHints`.
library;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  group('% modulo operator', () {
    test('integer modulo', () async {
      final db = await Database.open();
      try {
        final r = await db.execute('SELECT 10 % 3, -7 % 3, 0 % 5');
        expect(r.rows.first, [1, -1, 0]);
      } finally {
        await db.close();
      }
    });

    test('% binds at multiplicative precedence', () async {
      final db = await Database.open();
      try {
        // 1 + 10 % 3 == 1 + 1 == 2
        final r = await db.execute('SELECT 1 + 10 % 3');
        expect(r.rows.first.first, 2);
      } finally {
        await db.close();
      }
    });

    test('% inside GROUP BY and ORDER BY', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE t (x INTEGER)');
        await db.execute('INSERT INTO t VALUES (1),(2),(3),(4),(5),(6)');
        final r = await db.execute(
            'SELECT x % 3 AS k, COUNT(*) FROM t GROUP BY x % 3 ORDER BY k');
        expect(r.rows, [
          [0, 2],
          [1, 2],
          [2, 2],
        ]);
      } finally {
        await db.close();
      }
    });

    test('% with NULL propagates null', () async {
      final db = await Database.open();
      try {
        final r = await db.execute('SELECT NULL % 3, 5 % NULL');
        expect(r.rows.first, [null, null]);
      } finally {
        await db.close();
      }
    });
  });

  group('INDEXED BY on UPDATE/DELETE', () {
    test('UPDATE INDEXED BY narrows rows touched (correctness)', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE t (a INTEGER, b INTEGER)');
        await db.execute('CREATE INDEX ix_a ON t(a)');
        for (var i = 0; i < 100; i++) {
          await db.execute('INSERT INTO t VALUES ($i, ${i * 10})');
        }
        await db.execute('UPDATE t INDEXED BY ix_a SET b = 9999 WHERE a = 42');
        final r = await db.execute('SELECT b FROM t WHERE a = 42');
        expect(r.rows.first.first, 9999);
        // Other rows unchanged.
        final other = await db.execute('SELECT b FROM t WHERE a = 1');
        expect(other.rows.first.first, 10);
      } finally {
        await db.close();
      }
    });

    test('UPDATE INDEXED BY unknown index raises', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE t (a INTEGER, b INTEGER)');
        await db.execute('INSERT INTO t VALUES (1, 10)');
        expect(
            () => db
                .execute('UPDATE t INDEXED BY ix_nope SET b = 99 WHERE a = 1'),
            throwsA(isA<FormatException>()));
      } finally {
        await db.close();
      }
    });

    test('DELETE INDEXED BY only deletes matching rows', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE t (a INTEGER, b INTEGER)');
        await db.execute('CREATE INDEX ix_a ON t(a)');
        for (var i = 0; i < 20; i++) {
          await db.execute('INSERT INTO t VALUES ($i, ${i * 10})');
        }
        await db.execute('DELETE FROM t INDEXED BY ix_a WHERE a = 5');
        final r = await db.execute('SELECT COUNT(*) FROM t');
        expect(r.rows.first.first, 19);
        final missing = await db.execute('SELECT * FROM t WHERE a = 5');
        expect(missing.rows, isEmpty);
        // Surrounding rows preserved.
        final r4 = await db.execute('SELECT b FROM t WHERE a = 4');
        expect(r4.rows.first.first, 40);
        final r6 = await db.execute('SELECT b FROM t WHERE a = 6');
        expect(r6.rows.first.first, 60);
      } finally {
        await db.close();
      }
    });

    test('DELETE NOT INDEXED still works (full scan path)', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE t (a INTEGER)');
        await db.execute('CREATE INDEX ix_a ON t(a)');
        await db.execute('INSERT INTO t VALUES (1),(2),(3)');
        await db.execute('DELETE FROM t NOT INDEXED WHERE a = 2');
        final r = await db.execute('SELECT a FROM t ORDER BY a');
        expect(r.rows.map((r) => r.first).toList(), [1, 3]);
      } finally {
        await db.close();
      }
    });
  });

  group('CTE MATERIALIZED / NOT MATERIALIZED hints', () {
    test('MATERIALIZED hint is recorded and query still works', () async {
      final db = await Database.open();
      try {
        final r = await db.execute(
            'WITH c AS MATERIALIZED (SELECT 1 AS v UNION ALL SELECT 2) '
            'SELECT SUM(v) FROM c');
        expect(r.rows.first.first, 3);
        expect(db.lastCteHints, {'c': true});
      } finally {
        await db.close();
      }
    });

    test('NOT MATERIALIZED hint is recorded and query still works', () async {
      final db = await Database.open();
      try {
        final r = await db.execute(
            'WITH c AS NOT MATERIALIZED (SELECT 1 AS v UNION ALL SELECT 2) '
            'SELECT SUM(v) FROM c');
        expect(r.rows.first.first, 3);
        expect(db.lastCteHints, {'c': false});
      } finally {
        await db.close();
      }
    });

    test('No hint means lastCteHints is empty', () async {
      final db = await Database.open();
      try {
        final r =
            await db.execute('WITH c AS (SELECT 1 AS v UNION ALL SELECT 2) '
                'SELECT SUM(v) FROM c');
        expect(r.rows.first.first, 3);
        expect(db.lastCteHints, isEmpty);
      } finally {
        await db.close();
      }
    });

    test('Mixed hints across multiple CTEs are recorded', () async {
      final db = await Database.open();
      try {
        final r = await db.execute('WITH a AS MATERIALIZED (SELECT 1 AS v), '
            '     b AS NOT MATERIALIZED (SELECT 2 AS v), '
            '     c AS (SELECT 3 AS v) '
            'SELECT (SELECT v FROM a) + (SELECT v FROM b) + (SELECT v FROM c)');
        expect(r.rows.first.first, 6);
        expect(db.lastCteHints, {'a': true, 'b': false});
      } finally {
        await db.close();
      }
    });
  });
}
