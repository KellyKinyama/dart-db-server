/// Tests for the cost-based query planner.
///
/// Correctness is already covered by the broader regression suite; this
/// file specifically asserts that the planner *picks the right plan* for
/// queries that should benefit from an index, exposed via
/// [Database.lastPlanTrace].
library;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  group('Planner: index selection', () {
    late Database db;

    setUp(() async {
      db = await Database.open();
      await db.execute(
          'CREATE TABLE t (id INTEGER PRIMARY KEY, k INTEGER, v TEXT)');
      // Insert 200 rows. k cycles 0..49 (4 rows per key on average) so an
      // equality probe on k should pick ~4 rows, much cheaper than a
      // 200-row scan.
      for (var i = 0; i < 200; i++) {
        await db.execute("INSERT INTO t VALUES ($i, ${i % 50}, 'row$i')");
      }
      await db.execute('CREATE INDEX ix_t_k ON t(k)');
      await db.execute('ANALYZE');
    });

    test('Equality on indexed column uses the index', () async {
      final r = await db.execute('SELECT id FROM t WHERE k = 7 ORDER BY id');
      expect(db.lastPlanTrace, isNotEmpty,
          reason: 'expected planner to pick an index plan, '
              'got full scan: ${db.lastPlanTrace}');
      expect(db.lastPlanTrace.first, contains('USING INDEX ix_t_k'));
      expect(db.lastPlanTrace.first, contains('k=?'));
      // Sanity: 200 rows / 50 distinct = 4 hits expected.
      expect(r.rows.length, 4);
    });

    test('Reversed equality (literal = column) is recognised', () async {
      await db.execute('SELECT id FROM t WHERE 7 = k');
      expect(db.lastPlanTrace, isNotEmpty);
      expect(db.lastPlanTrace.first, contains('USING INDEX ix_t_k'));
    });

    test('Range scan on indexed column uses the index', () async {
      final r = await db
          .execute('SELECT id FROM t WHERE k >= 10 AND k < 15 ORDER BY id');
      expect(db.lastPlanTrace, isNotEmpty);
      expect(db.lastPlanTrace.first, contains('USING INDEX ix_t_k'));
      // 5 keys × 4 rows = 20 rows
      expect(r.rows.length, 20);
    });

    test('BETWEEN on indexed column uses the index (closed range)', () async {
      final r = await db
          .execute('SELECT id FROM t WHERE k BETWEEN 10 AND 14 ORDER BY id');
      expect(db.lastPlanTrace, isNotEmpty);
      expect(db.lastPlanTrace.first, contains('USING INDEX ix_t_k'));
      expect(db.lastPlanTrace.first, contains('AND'));
      expect(r.rows.length, 20);
    });

    test('Equality wins over a less-selective range when both available',
        () async {
      // Both `k = 7` (4 rows) and `id < 100` (100 rows; PK index) are
      // indexable. Equality should win on cost.
      await db.execute('SELECT id FROM t WHERE k = 7 AND id < 100');
      expect(db.lastPlanTrace, isNotEmpty);
      expect(db.lastPlanTrace.first, contains('k=?'));
    });

    test('No index on a column => full scan (no plan trace)', () async {
      await db.execute("SELECT id FROM t WHERE v = 'row7'");
      expect(db.lastPlanTrace, isEmpty,
          reason: 'no index on v, expected full scan');
    });

    test('Range with no histogram still uses the index (50% heuristic)',
        () async {
      // We don't yet collect min/max histograms, so a range like `k >= 0`
      // is estimated at 50% of the table — under the 80% bail-out, so the
      // planner picks the index anyway. When we add histograms this test
      // should flip to expect a full scan.
      await db.execute('SELECT id FROM t WHERE k >= 0');
      expect(db.lastPlanTrace, isNotEmpty);
      expect(db.lastPlanTrace.first, contains('USING INDEX ix_t_k'));
    });

    test('Equality result set is correct (planner is just an optimisation)',
        () async {
      // Build a ground-truth set without going through the planner.
      final all = await db.execute('SELECT id, k FROM t ORDER BY id');
      final expected =
          all.rows.where((r) => r[1] == 7).map((r) => r[0]).toList();
      final got = await db.execute('SELECT id FROM t WHERE k = 7 ORDER BY id');
      expect(got.rows.map((r) => r[0]).toList(), expected);
    });
  });

  group('Planner: ANALYZE', () {
    test('ANALYZE populates sqlite_stat1 with per-table and per-index rows',
        () async {
      final db = await Database.open();
      await db.execute('CREATE TABLE t (id INTEGER, k INTEGER)');
      for (var i = 0; i < 50; i++) {
        await db.execute('INSERT INTO t VALUES ($i, ${i % 10})');
      }
      await db.execute('CREATE INDEX ix_t_k ON t(k)');
      await db.execute('ANALYZE');
      final r = await db.execute(
          'SELECT tbl, idx, stat FROM sqlite_stat1 ORDER BY idx NULLS FIRST');
      // Expect a (tbl=t, idx=NULL, stat='50') and (tbl=t, idx=ix_t_k, stat='50 5').
      expect(r.rows.length, greaterThanOrEqualTo(2));
      final tableRow = r.rows.firstWhere((row) => row[1] == null);
      expect(tableRow[0], 't');
      expect(tableRow[2], '50');
      final idxRow = r.rows.firstWhere((row) => row[1] == 'ix_t_k');
      // 50 rows / 10 distinct = 5 rows per key.
      expect(idxRow[2], '50 5');
    });
  });
}
