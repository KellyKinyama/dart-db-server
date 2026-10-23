/// Phase-3.1 regression: `SELECT col, COUNT(*) FROM t GROUP BY col`
/// on a single-column non-NOCASE non-partial index is served from
/// the index — one row per key with `posting.length`. ASC/DESC ORDER
/// BY on the same col is satisfied by the SplayTreeMap walk.
library;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  Future<Database> seed() async {
    final db = await Database.open();
    await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)');
    await db.execute('CREATE INDEX i_v ON t(v)');
    var id = 1;
    for (final v in [1, 2, 2, 3, 3, 3, 4, 5, 5]) {
      await db.execute('INSERT INTO t VALUES (${id++}, $v)');
    }
    return db;
  }

  test('SELECT v, COUNT(*) FROM t GROUP BY v', () async {
    final db = await seed();
    try {
      final r = await db.execute('SELECT v, COUNT(*) FROM t GROUP BY v');
      expect(r.rows, [
        [1, 1],
        [2, 2],
        [3, 3],
        [4, 1],
        [5, 2],
      ]);
    } finally {
      await db.close();
    }
  });

  test('SELECT v, COUNT(*) FROM t GROUP BY v ORDER BY v DESC', () async {
    final db = await seed();
    try {
      final r = await db
          .execute('SELECT v, COUNT(*) FROM t GROUP BY v ORDER BY v DESC');
      expect(r.rows, [
        [5, 2],
        [4, 1],
        [3, 3],
        [2, 2],
        [1, 1],
      ]);
      expect(db.lastPlanSortSkipped, isTrue);
    } finally {
      await db.close();
    }
  });

  test('GROUP BY single col, only COUNT(*) projection', () async {
    final db = await seed();
    try {
      final r = await db.execute('SELECT COUNT(*) FROM t GROUP BY v');
      expect(r.rows, [
        [1],
        [2],
        [3],
        [1],
        [2],
      ]);
    } finally {
      await db.close();
    }
  });

  test('GROUP BY with COUNT(v) (same col) is equivalent to COUNT(*)', () async {
    final db = await seed();
    try {
      final r =
          await db.execute('SELECT v, COUNT(v) FROM t GROUP BY v ORDER BY v');
      expect(r.rows, [
        [1, 1],
        [2, 2],
        [3, 3],
        [4, 1],
        [5, 2],
      ]);
    } finally {
      await db.close();
    }
  });

  test('GROUP BY with NULLs in col bails (generic path produces NULL group)',
      () async {
    final db = await Database.open();
    try {
      await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)');
      await db.execute('CREATE INDEX i_v ON t(v)');
      var id = 1;
      for (final v in [1, null, 1, 2, null]) {
        await db.execute('INSERT INTO t VALUES (${id++}, ${v ?? 'NULL'})');
      }
      final r =
          await db.execute('SELECT v, COUNT(*) FROM t GROUP BY v ORDER BY v');
      // Generic path emits a NULL group with count=2.
      expect(r.rows.length, 3);
      // SQLite groups NULLs together.
      expect(r.rows.first.first, isNull);
      expect(r.rows.first[1], 2);
    } finally {
      await db.close();
    }
  });

  test('GROUP BY + WHERE bails (predicate restricts groups)', () async {
    final db = await seed();
    try {
      final r = await db.execute(
          'SELECT v, COUNT(*) FROM t WHERE v >= 3 GROUP BY v ORDER BY v');
      expect(r.rows, [
        [3, 3],
        [4, 1],
        [5, 2],
      ]);
    } finally {
      await db.close();
    }
  });

  test('GROUP BY + LIMIT/OFFSET', () async {
    final db = await seed();
    try {
      final r = await db.execute(
          'SELECT v, COUNT(*) FROM t GROUP BY v ORDER BY v LIMIT 2 OFFSET 1');
      expect(r.rows, [
        [2, 2],
        [3, 3],
      ]);
    } finally {
      await db.close();
    }
  });

  test('GROUP BY non-indexed col bails (correct via generic)', () async {
    final db = await Database.open();
    try {
      await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)');
      // No index on v.
      var id = 1;
      for (final v in [1, 2, 2, 3]) {
        await db.execute('INSERT INTO t VALUES (${id++}, $v)');
      }
      final r =
          await db.execute('SELECT v, COUNT(*) FROM t GROUP BY v ORDER BY v');
      expect(r.rows, [
        [1, 1],
        [2, 2],
        [3, 1],
      ]);
    } finally {
      await db.close();
    }
  });
}
