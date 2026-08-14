/// Phase-2.5 regression: extend `_tryAggregateWithWhereFast` to handle
/// `WHERE col IS [NOT] NULL` on the SAME indexed column. Indexes
/// don't store NULL keys, so:
///   * `IS NULL`     → empty input (NULL/0/0.0 per aggregate)
///   * `IS NOT NULL` → walk every entry of the SplayTreeMap
library;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  Future<Database> seed() async {
    final db = await Database.open();
    await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)');
    await db.execute('CREATE INDEX i_v ON t(v)');
    var id = 1;
    for (final v in [1, null, 2, null, 3, null, 4, 5]) {
      await db.execute('INSERT INTO t VALUES (${id++}, ${v ?? 'NULL'})');
    }
    return db;
  }

  test('SUM(v) WHERE v IS NOT NULL → walks all entries', () async {
    final db = await seed();
    try {
      final r = await db.execute('SELECT SUM(v) FROM t WHERE v IS NOT NULL');
      expect(r.rows.first.first, 15); // 1+2+3+4+5
    } finally {
      await db.close();
    }
  });

  test('AVG(v) WHERE v IS NOT NULL', () async {
    final db = await seed();
    try {
      final r = await db.execute('SELECT AVG(v) FROM t WHERE v IS NOT NULL');
      expect((r.rows.first.first as num).toDouble(), closeTo(3.0, 1e-9));
    } finally {
      await db.close();
    }
  });

  test('TOTAL(v) WHERE v IS NOT NULL', () async {
    final db = await seed();
    try {
      final r = await db.execute('SELECT TOTAL(v) FROM t WHERE v IS NOT NULL');
      expect((r.rows.first.first as num).toDouble(), closeTo(15.0, 1e-9));
    } finally {
      await db.close();
    }
  });

  test('MIN/MAX/COUNT(v) WHERE v IS NOT NULL', () async {
    final db = await seed();
    try {
      final r1 = await db.execute('SELECT MIN(v) FROM t WHERE v IS NOT NULL');
      expect(r1.rows.first.first, 1);
      final r2 = await db.execute('SELECT MAX(v) FROM t WHERE v IS NOT NULL');
      expect(r2.rows.first.first, 5);
      final r3 = await db.execute('SELECT COUNT(v) FROM t WHERE v IS NOT NULL');
      expect(r3.rows.first.first, 5);
    } finally {
      await db.close();
    }
  });

  test('SUM(v) WHERE v IS NULL → NULL (empty input)', () async {
    final db = await seed();
    try {
      final r = await db.execute('SELECT SUM(v) FROM t WHERE v IS NULL');
      expect(r.rows.first.first, isNull);
    } finally {
      await db.close();
    }
  });

  test('TOTAL(v) WHERE v IS NULL → 0.0', () async {
    final db = await seed();
    try {
      final r = await db.execute('SELECT TOTAL(v) FROM t WHERE v IS NULL');
      expect((r.rows.first.first as num).toDouble(), closeTo(0.0, 1e-9));
    } finally {
      await db.close();
    }
  });

  test('COUNT(v) WHERE v IS NULL → 0', () async {
    final db = await seed();
    try {
      final r = await db.execute('SELECT COUNT(v) FROM t WHERE v IS NULL');
      expect(r.rows.first.first, 0);
    } finally {
      await db.close();
    }
  });

  test(
      'IS NOT NULL on different column → not handled by fast path '
      '(falls through, still correct)', () async {
    final db = await Database.open();
    try {
      await db.execute(
          'CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER, w INTEGER)');
      await db.execute('CREATE INDEX i_v ON t(v)');
      var id = 1;
      for (final pair in [
        [1, 10],
        [2, null],
        [3, 30],
      ]) {
        await db.execute(
            'INSERT INTO t VALUES (${id++}, ${pair[0]}, ${pair[1] ?? 'NULL'})');
      }
      final r = await db.execute('SELECT SUM(v) FROM t WHERE w IS NOT NULL');
      expect(r.rows.first.first, 4); // rows 1,3 → v=1+3
    } finally {
      await db.close();
    }
  });
}
