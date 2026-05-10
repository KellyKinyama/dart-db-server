/// Tests for runtime use of multi-column indexes:
///   * UNIQUE enforcement on the full key (not just the leading column)
///   * Planner picks composite probes when every index column is bound
///   * Planner picks prefix scans when only a leading prefix is bound
///   * Cross-engine parity vs `package:sqlite3`
library;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:sqlite3/sqlite3.dart' as sq;
import 'package:test/test.dart';

import 'regression/sqlite_oracle.dart';

void main() {
  group('multi-column index runtime', () {
    test('UNIQUE multi-column rejects duplicates of the full key', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE t(a INT, b INT, v TEXT)');
        await db.execute('CREATE UNIQUE INDEX ux_ab ON t(a, b)');
        await db.execute("INSERT INTO t VALUES (1, 10, 'x')");
        // Same a, different b — must be allowed.
        await db.execute("INSERT INTO t VALUES (1, 20, 'y')");
        await db.execute("INSERT INTO t VALUES (2, 10, 'z')");
        // Exact (a, b) duplicate — must fail.
        expect(
          () => db.execute("INSERT INTO t VALUES (1, 10, 'dup')"),
          throwsA(isA<StateError>()),
        );
        final r = await db.execute('SELECT a, b, v FROM t ORDER BY a, b');
        expect(r.rows, [
          [1, 10, 'x'],
          [1, 20, 'y'],
          [2, 10, 'z'],
        ]);
      } finally {
        await db.close();
      }
    });

    test('full-key composite probe returns exactly the matching row', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE t(a INT, b INT, v TEXT)');
        await db.execute('CREATE INDEX ix_ab ON t(a, b)');
        for (var a = 0; a < 10; a++) {
          for (var b = 0; b < 10; b++) {
            await db.execute("INSERT INTO t VALUES ($a, $b, 'r${a}_$b')");
          }
        }
        final r = await db.execute('SELECT v FROM t WHERE a = 3 AND b = 7');
        expect(r.rows, [
          ['r3_7'],
        ]);
      } finally {
        await db.close();
      }
    });

    test('prefix-scan returns every row matching the leading column', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE t(g INT, n INT, v TEXT)');
        await db.execute('CREATE INDEX ix_gn ON t(g, n)');
        for (var g = 0; g < 5; g++) {
          for (var n = 0; n < 4; n++) {
            await db.execute("INSERT INTO t VALUES ($g, $n, 'r${g}_$n')");
          }
        }
        final r = await db.execute('SELECT g, n FROM t WHERE g = 2 ORDER BY n');
        expect(r.rows, [
          [2, 0],
          [2, 1],
          [2, 2],
          [2, 3],
        ]);
      } finally {
        await db.close();
      }
    });

    test('cross-engine parity vs sqlite3 on a 2k-row composite-index dataset',
        () async {
      final skip = sqliteSkipReason();
      if (skip != null) return;
      // Build identical datasets in both engines and confirm a few
      // composite-key queries return the same rows.
      final ours = await Database.open();
      final ref = sq.sqlite3.openInMemory();
      try {
        for (final db in [ours]) {
          await db.execute('CREATE TABLE t(a INT, b INT, v TEXT)');
          await db.execute('CREATE INDEX ix_ab ON t(a, b)');
        }
        ref.execute('CREATE TABLE t(a INT, b INT, v TEXT)');
        ref.execute('CREATE INDEX ix_ab ON t(a, b)');
        // 2000 rows: a in 0..49 (50 distinct), b in 0..39 (40 distinct).
        for (var i = 0; i < 2000; i++) {
          final a = i % 50;
          final b = (i ~/ 50) % 40;
          final v = 'row_$i';
          await ours.execute("INSERT INTO t VALUES ($a, $b, '$v')");
          ref.execute("INSERT INTO t VALUES ($a, $b, '$v')");
        }
        // Full-key probe.
        final ourFull =
            (await ours.execute('SELECT v FROM t WHERE a = 17 AND b = 23'))
                .rows
                .map((r) => r.first)
                .toSet();
        final refFull = ref
            .select('SELECT v FROM t WHERE a = 17 AND b = 23')
            .map((r) => r.values.first)
            .toSet();
        expect(ourFull, refFull);
        // Prefix-only probe.
        final ourPref =
            (await ours.execute('SELECT count(*) FROM t WHERE a = 5'))
                .rows
                .single
                .first;
        final refPref = ref
            .select('SELECT count(*) FROM t WHERE a = 5')
            .single
            .values
            .first;
        expect(ourPref, refPref);
      } finally {
        await ours.close();
        ref.dispose();
      }
    });

    test('plan trace mentions composite probe', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE t(a INT, b INT)');
        await db.execute('CREATE INDEX ix_ab ON t(a, b)');
        for (var i = 0; i < 100; i++) {
          await db.execute('INSERT INTO t VALUES (${i % 10}, ${i % 5})');
        }
        // Run a query that should hit the composite probe; check the
        // executor's plan trace via the public lastPlan getter.
        await db.execute('SELECT * FROM t WHERE a = 3 AND b = 2');
        final trace = db.lastPlanTrace;
        expect(trace, isNotEmpty);
        expect(trace.first, contains('ix_ab'));
      } finally {
        await db.close();
      }
    });
  });
}
