/// Phase-2.9 regression: bare multi-projection aggregate fast path
/// (`_tryMinMaxFast`) now also handles `COUNT(col)` and DISTINCT on
/// COUNT/SUM/AVG/TOTAL by weighting each index key as 1.
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

  test('bare COUNT(v) on indexed col → posting-sum', () async {
    final db = await seed();
    try {
      final r = await db.execute('SELECT COUNT(v) FROM t');
      expect(r.rows, [
        [9],
      ]);
    } finally {
      await db.close();
    }
  });

  test('bare COUNT(DISTINCT v) on indexed col → key count', () async {
    final db = await seed();
    try {
      final r = await db.execute('SELECT COUNT(DISTINCT v) FROM t');
      expect(r.rows, [
        [5],
      ]);
    } finally {
      await db.close();
    }
  });

  test('SUM(DISTINCT v) bare → sum of unique keys', () async {
    final db = await seed();
    try {
      final r = await db.execute('SELECT SUM(DISTINCT v) FROM t');
      expect(r.rows, [
        [15], // 1+2+3+4+5
      ]);
    } finally {
      await db.close();
    }
  });

  test('AVG(DISTINCT v) bare', () async {
    final db = await seed();
    try {
      final r = await db.execute('SELECT AVG(DISTINCT v) FROM t');
      expect((r.rows.first.first as num).toDouble(), closeTo(3.0, 1e-9));
    } finally {
      await db.close();
    }
  });

  test('TOTAL(DISTINCT v) bare', () async {
    final db = await seed();
    try {
      final r = await db.execute('SELECT TOTAL(DISTINCT v) FROM t');
      expect((r.rows.first.first as num).toDouble(), closeTo(15.0, 1e-9));
    } finally {
      await db.close();
    }
  });

  test('combo: MIN, MAX, COUNT(*), COUNT(DISTINCT v), SUM(DISTINCT v)',
      () async {
    final db = await seed();
    try {
      final r = await db.execute(
          'SELECT MIN(v), MAX(v), COUNT(*), COUNT(DISTINCT v), SUM(DISTINCT v) FROM t');
      final row = r.rows.first;
      expect(row[0], 1);
      expect(row[1], 5);
      expect(row[2], 9);
      expect(row[3], 5);
      expect(row[4], 15);
    } finally {
      await db.close();
    }
  });

  test('SUM(DISTINCT) on empty indexed table → NULL', () async {
    final db = await Database.open();
    try {
      await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)');
      await db.execute('CREATE INDEX i_v ON t(v)');
      final r = await db.execute('SELECT SUM(DISTINCT v) FROM t');
      expect(r.rows, [
        [null],
      ]);
    } finally {
      await db.close();
    }
  });

  test('TOTAL(DISTINCT) on empty indexed table → 0.0', () async {
    final db = await Database.open();
    try {
      await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)');
      await db.execute('CREATE INDEX i_v ON t(v)');
      final r = await db.execute('SELECT TOTAL(DISTINCT v) FROM t');
      expect((r.rows.first.first as num).toDouble(), closeTo(0.0, 1e-9));
    } finally {
      await db.close();
    }
  });

  test('MIN(DISTINCT v) bails to generic path (still correct)', () async {
    final db = await seed();
    try {
      final r = await db.execute('SELECT MIN(DISTINCT v) FROM t');
      expect(r.rows.first.first, 1);
    } finally {
      await db.close();
    }
  });
}
