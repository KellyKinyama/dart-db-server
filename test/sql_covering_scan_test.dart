/// Tests for index-only / covering-scan optimisation.
library;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  group('Planner: covering scan', () {
    late Database db;
    setUp(() async {
      db = await Database.open();
      await db.execute(
          'CREATE TABLE t (id INTEGER PRIMARY KEY, k INTEGER, v TEXT)');
      for (var i = 0; i < 50; i++) {
        await db.execute("INSERT INTO t VALUES ($i, ${i % 10}, 'row$i')");
      }
      await db.execute('CREATE INDEX ix_t_k ON t(k)');
    });

    test('SELECT k FROM t uses the covering index (no row hydration)',
        () async {
      db.resetCounters();
      final r = await db.execute('SELECT k FROM t');
      expect(db.coveringScansUsed, 1);
      expect(db.lastPlanTrace.first, contains('COVERING SCAN'));
      expect(db.lastPlanTrace.first, contains('ix_t_k'));
      // 50 rows total, one entry per source row.
      expect(r.rows.length, 50);
    });

    test('SELECT DISTINCT k FROM t returns distinct keys via the index',
        () async {
      db.resetCounters();
      final r = await db.execute('SELECT DISTINCT k FROM t');
      expect(db.coveringScansUsed, 1);
      // 10 distinct keys, sorted by index order.
      expect(r.rows.length, 10);
      expect(
          r.rows.map((row) => row[0]).toList(), [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]);
    });

    test('Covering scan honours ORDER BY on the same column', () async {
      db.resetCounters();
      final r =
          await db.execute('SELECT DISTINCT k FROM t ORDER BY k DESC LIMIT 3');
      expect(db.coveringScansUsed, 1);
      expect(r.rows, [
        [9],
        [8],
        [7]
      ]);
    });

    test('Adding a WHERE disables the covering path', () async {
      db.resetCounters();
      await db.execute('SELECT k FROM t WHERE k > 5');
      expect(db.coveringScansUsed, 0);
    });

    test('Selecting a non-indexed column disables the covering path', () async {
      db.resetCounters();
      await db.execute('SELECT v FROM t');
      expect(db.coveringScansUsed, 0);
    });

    test('SELECT * disables the covering path', () async {
      db.resetCounters();
      await db.execute('SELECT * FROM t');
      expect(db.coveringScansUsed, 0);
    });

    test('Covering scan result matches a normal scan result', () async {
      // Build ground truth without going through the index.
      final ref =
          await db.execute('SELECT k FROM t WHERE k = k ORDER BY k, id');
      final got = await db.execute('SELECT k FROM t ORDER BY k');
      // Multisets must match (order of rows within a key may differ).
      final refMs = (ref.rows.map((r) => r[0])).toList()..sort();
      final gotMs = (got.rows.map((r) => r[0])).toList()..sort();
      expect(gotMs, refMs);
    });
  });
}
