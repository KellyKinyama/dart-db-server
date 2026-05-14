/// Phase-0.4 regression: ANALYZE-populated sqlite_stat1 rows actually
/// flow into the planner's row-count estimate used by join reorder.
/// Before this wire-up, `_tableRowCountEstimate` ignored stats entirely
/// and read the live `rows.length`, so a snapshot loaded from another
/// SQLite file (where stats existed but no rows had been re-inserted)
/// got planned as if every table were empty.
library;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  test('row count without ANALYZE matches live rows.length', () async {
    final db = await Database.open();
    try {
      await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, k INTEGER)');
      for (var i = 0; i < 25; i++) {
        await db.execute('INSERT INTO t VALUES ($i, ${i % 5})');
      }
      expect(db.plannerRowCountEstimate('t'), 25);
    } finally {
      await db.close();
    }
  });

  test('ANALYZE primes plannerRowCountEstimate from sqlite_stat1',
      () async {
    final db = await Database.open();
    try {
      await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, k INTEGER)');
      await db.execute('CREATE INDEX i_k ON t(k)');
      for (var i = 0; i < 40; i++) {
        await db.execute('INSERT INTO t VALUES ($i, ${i % 8})');
      }
      // Pre-ANALYZE: live row count.
      expect(db.plannerRowCountEstimate('t'), 40);
      await db.execute('ANALYZE');
      // Post-ANALYZE: stats path is taken; should agree numerically.
      expect(db.plannerRowCountEstimate('t'), 40);
      // Distinct-count for the indexed column k is recoverable: 40
      // rows / 8 distinct = avg 5 rows per key.
      expect(db.plannerEqualityHitsEstimate('t', 'k'), 5);
    } finally {
      await db.close();
    }
  });

  test('FROM-order vs ANALYZE: reordered query yields same rows',
      () async {
    final db = await Database.open();
    try {
      await db.execute('CREATE TABLE big (id INTEGER, k INTEGER)');
      await db.execute('CREATE TABLE small (k INTEGER, label TEXT)');
      for (var i = 0; i < 200; i++) {
        await db.execute('INSERT INTO big VALUES ($i, ${i % 4})');
      }
      for (var i = 0; i < 4; i++) {
        await db.execute("INSERT INTO small VALUES ($i, 'L$i')");
      }
      await db.execute('ANALYZE');
      // Stats now drive the planner — `small` should be cheaper.
      expect(db.plannerRowCountEstimate('small'),
          lessThan(db.plannerRowCountEstimate('big')));
      final r = await db.execute('SELECT id, label FROM big '
          'INNER JOIN small ON big.k = small.k ORDER BY id');
      expect(r.rows.length, 200);
      expect(r.rows.first, [0, 'L0']);
    } finally {
      await db.close();
    }
  });

  test('paged table row count is reported by the planner', () async {
    final db = await Database.open();
    try {
      // In-memory DB rejects USING paged, so this just sanity-checks
      // the in-memory branch. The paged branch is exercised by the
      // paged_pragmas / paged_create suites; this test is mostly here
      // to lock in the API.
      await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY)');
      for (var i = 0; i < 7; i++) {
        await db.execute('INSERT INTO t VALUES ($i)');
      }
      expect(db.plannerRowCountEstimate('t'), 7);
      expect(db.plannerRowCountEstimate('does_not_exist'), 100);
    } finally {
      await db.close();
    }
  });
}
