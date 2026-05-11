/// Planner honors `INDEXED BY name` (force a specific index) and
/// `NOT INDEXED` (force a full scan) hints in SELECT, UPDATE, DELETE.
library;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  group('INDEXED BY / NOT INDEXED hints', () {
    test('INDEXED BY forces the named index even on tiny tables', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE t (a INTEGER, b INTEGER)');
        await db.execute('CREATE INDEX ix_a ON t(a)');
        await db.execute('INSERT INTO t VALUES (1, 10), (2, 20), (3, 30)');
        // Without the hint the planner would scan (table is only 3 rows
        // and the 80% threshold rejects index plans). With the hint the
        // plan trace must show the named index.
        final r = await db
            .execute('SELECT b FROM t INDEXED BY ix_a WHERE a >= 2 ORDER BY a');
        expect(r.rows.map((r) => r.first).toList(), [20, 30]);
        expect(db.lastPlanTrace.join(' '), contains('ix_a'),
            reason: 'plan trace should reference ix_a, got '
                '${db.lastPlanTrace}');
      } finally {
        await db.close();
      }
    });

    test('INDEXED BY a missing/unusable index raises', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE t (a INTEGER, b INTEGER)');
        await db.execute('CREATE INDEX ix_b ON t(b)');
        await db.execute('INSERT INTO t VALUES (1, 10), (2, 20)');
        // ix_b is on b; the WHERE filters on a so the index cannot serve
        // the query.
        expect(
            () => db.execute('SELECT * FROM t INDEXED BY ix_b WHERE a = 1'),
            throwsA(isA<FormatException>()));
      } finally {
        await db.close();
      }
    });

    test('NOT INDEXED forces a full table scan on SELECT', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE t (a INTEGER, b INTEGER)');
        await db.execute('CREATE INDEX ix_a ON t(a)');
        for (var i = 0; i < 100; i++) {
          await db.execute('INSERT INTO t VALUES ($i, ${i * 10})');
        }
        // Without NOT INDEXED, a = 42 would probe ix_a. With NOT INDEXED
        // the planner must not record an index probe in the trace.
        final hinted = await db
            .execute('SELECT b FROM t NOT INDEXED WHERE a = 42');
        expect(hinted.rows.first.first, 420);
        expect(db.lastPlanTrace.join(' '), isNot(contains('ix_a')),
            reason: 'NOT INDEXED must suppress index usage, got '
                '${db.lastPlanTrace}');

        // Sanity: without the hint the planner *would* use ix_a.
        final unhinted = await db.execute('SELECT b FROM t WHERE a = 42');
        expect(unhinted.rows.first.first, 420);
        expect(db.lastPlanTrace.join(' '), contains('ix_a'));
      } finally {
        await db.close();
      }
    });

    test('UPDATE / DELETE NOT INDEXED still produce correct results',
        () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE t (a INTEGER)');
        await db.execute('CREATE INDEX ix_a ON t(a)');
        await db.execute('INSERT INTO t VALUES (1), (2), (3)');
        await db.execute('UPDATE t NOT INDEXED SET a = a + 10');
        await db.execute('DELETE FROM t NOT INDEXED WHERE a = 11');
        final r = await db.execute('SELECT a FROM t ORDER BY a');
        expect(r.rows.map((r) => r.first).toList(), [12, 13]);
      } finally {
        await db.close();
      }
    });
  });
}
