/// Tests for partial-index planner narrowing.
library;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  group('partial index narrowing', () {
    test('planner uses a partial index when WHERE matches its predicate',
        () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, '
            'status TEXT, val INTEGER)');
        for (var i = 0; i < 200; i++) {
          await db.execute(
              "INSERT INTO t VALUES ($i, '${i % 5 == 0 ? 'open' : 'done'}', $i)");
        }
        await db.execute(
            "CREATE INDEX t_open ON t(val) WHERE status = 'open'");

        // Query whose conjunct exactly matches the partial-index WHERE.
        final r = await db.execute(
            "SELECT id FROM t WHERE status = 'open' AND val = 100");
        expect(r.rows, [
          [100]
        ]);
        // The plan trace should mention the partial index.
        expect(db.lastPlanTrace.join(' '), contains('t_open'),
            reason: 'expected planner to choose t_open partial index, '
                'got: ${db.lastPlanTrace}');
      } finally {
        await db.close();
      }
    });

    test('planner skips a partial index when WHERE is broader', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, '
            'status TEXT, val INTEGER)');
        for (var i = 0; i < 200; i++) {
          await db.execute(
              "INSERT INTO t VALUES ($i, '${i % 5 == 0 ? 'open' : 'done'}', $i)");
        }
        await db.execute(
            "CREATE INDEX t_open ON t(val) WHERE status = 'open'");

        // No status filter — partial index cannot be used.
        final r = await db.execute('SELECT id FROM t WHERE val = 100');
        expect(r.rows, [
          [100]
        ]);
        // The chosen plan must not be the partial index.
        expect(db.lastPlanTrace.join(' '), isNot(contains('t_open')),
            reason: 'partial index incorrectly chosen for query without '
                'matching predicate: ${db.lastPlanTrace}');
      } finally {
        await db.close();
      }
    });

    test('partial index reflects rows inserted after CREATE INDEX',
        () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, '
            'flag INTEGER, val INTEGER)');
        await db.execute('CREATE INDEX t_flag ON t(val) WHERE flag = 1');
        await db.execute('INSERT INTO t VALUES (1, 1, 100)');
        await db.execute('INSERT INTO t VALUES (2, 0, 200)');
        await db.execute('INSERT INTO t VALUES (3, 1, 300)');
        final r = await db
            .execute('SELECT id, val FROM t WHERE flag = 1 ORDER BY id');
        expect(r.rows, [
          [1, 100],
          [3, 300]
        ]);
      } finally {
        await db.close();
      }
    });

    test('partial index drops rows on DELETE', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, '
            'flag INTEGER, val INTEGER)');
        await db.execute('CREATE INDEX t_flag ON t(val) WHERE flag = 1');
        await db.execute('INSERT INTO t VALUES (1, 1, 100)');
        await db.execute('INSERT INTO t VALUES (2, 1, 200)');
        await db.execute('DELETE FROM t WHERE id = 1');
        final r = await db
            .execute('SELECT id FROM t WHERE flag = 1 ORDER BY id');
        expect(r.rows, [
          [2]
        ]);
      } finally {
        await db.close();
      }
    });

    test('partial index handles row exit on UPDATE that violates WHERE',
        () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, '
            'flag INTEGER, val INTEGER)');
        await db.execute('CREATE INDEX t_flag ON t(val) WHERE flag = 1');
        await db.execute('INSERT INTO t VALUES (1, 1, 100)');
        await db.execute('INSERT INTO t VALUES (2, 1, 200)');
        // Row 1 now no longer matches the partial WHERE.
        await db.execute('UPDATE t SET flag = 0 WHERE id = 1');
        final r =
            await db.execute('SELECT id FROM t WHERE flag = 1 ORDER BY id');
        expect(r.rows, [
          [2]
        ]);
      } finally {
        await db.close();
      }
    });
  });
}
