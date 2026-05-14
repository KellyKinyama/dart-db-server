/// Phase-2.8 regression: `_tryAggregateWithWhereFast` now also serves
/// `COUNT/SUM/AVG/TOTAL(DISTINCT col)` with WHERE on the same indexed
/// col by weighting each matching key as 1 instead of its posting-list
/// length. MIN/MAX(DISTINCT) is unchanged.
library;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  Future<Database> seed() async {
    final db = await Database.open();
    await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)');
    await db.execute('CREATE INDEX i_v ON t(v)');
    var id = 1;
    // Distinct values in [1..7]: 1,2,3,4,5,6,7 with various dup counts.
    for (final v in [1, 2, 2, 3, 3, 3, 4, 4, 5, 6, 7, 7]) {
      await db.execute('INSERT INTO t VALUES (${id++}, $v)');
    }
    return db;
  }

  test('COUNT(DISTINCT v) WHERE v BETWEEN — counts unique keys', () async {
    final db = await seed();
    try {
      final r = await db
          .execute('SELECT COUNT(DISTINCT v) FROM t WHERE v BETWEEN 2 AND 5');
      expect(r.rows, [
        [4], // 2,3,4,5
      ]);
    } finally {
      await db.close();
    }
  });

  test('SUM(DISTINCT v) WHERE v BETWEEN — sum of unique keys', () async {
    final db = await seed();
    try {
      final r = await db
          .execute('SELECT SUM(DISTINCT v) FROM t WHERE v BETWEEN 2 AND 5');
      expect(r.rows, [
        [14], // 2+3+4+5
      ]);
    } finally {
      await db.close();
    }
  });

  test('AVG(DISTINCT v) WHERE v BETWEEN — avg of unique keys', () async {
    final db = await seed();
    try {
      final r = await db
          .execute('SELECT AVG(DISTINCT v) FROM t WHERE v BETWEEN 2 AND 5');
      expect((r.rows.first.first as num).toDouble(), closeTo(3.5, 1e-9));
    } finally {
      await db.close();
    }
  });

  test('TOTAL(DISTINCT v) WHERE v IS NOT NULL → all unique', () async {
    final db = await seed();
    try {
      final r = await db.execute(
          'SELECT TOTAL(DISTINCT v) FROM t WHERE v IS NOT NULL');
      // 1+2+3+4+5+6+7 = 28
      expect((r.rows.first.first as num).toDouble(), closeTo(28.0, 1e-9));
    } finally {
      await db.close();
    }
  });

  test('COUNT(DISTINCT v) WHERE v IN (lits) — dedupes posting weights',
      () async {
    final db = await seed();
    try {
      final r = await db
          .execute('SELECT COUNT(DISTINCT v) FROM t WHERE v IN (3, 3, 5, 7)');
      expect(r.rows, [
        [3],
      ]);
    } finally {
      await db.close();
    }
  });

  test('SUM(DISTINCT v) WHERE v = lit — single key', () async {
    final db = await seed();
    try {
      final r = await db
          .execute('SELECT SUM(DISTINCT v) FROM t WHERE v = 3');
      expect(r.rows, [
        [3],
      ]);
    } finally {
      await db.close();
    }
  });

  test('AVG(DISTINCT v) WHERE no match → NULL', () async {
    final db = await seed();
    try {
      final r = await db
          .execute('SELECT AVG(DISTINCT v) FROM t WHERE v BETWEEN 100 AND 200');
      expect(r.rows.first.first, isNull);
    } finally {
      await db.close();
    }
  });

  test('TOTAL(DISTINCT v) WHERE no match → 0.0', () async {
    final db = await seed();
    try {
      final r = await db
          .execute('SELECT TOTAL(DISTINCT v) FROM t WHERE v BETWEEN 100 AND 200');
      expect((r.rows.first.first as num).toDouble(), closeTo(0.0, 1e-9));
    } finally {
      await db.close();
    }
  });

  test('MIN(DISTINCT v) WHERE — bails (DISTINCT not supported for MIN); '
      'generic path still correct', () async {
    final db = await seed();
    try {
      final r = await db
          .execute('SELECT MIN(DISTINCT v) FROM t WHERE v BETWEEN 3 AND 6');
      expect(r.rows.first.first, 3);
    } finally {
      await db.close();
    }
  });
}
