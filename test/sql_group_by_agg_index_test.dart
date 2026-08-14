/// Phase-3.2 regression: GROUP BY indexed col now also serves
/// MIN/MAX/SUM/AVG/TOTAL of the group col itself — within each
/// group the col is constant, so MIN=MAX=AVG=key, SUM=TOTAL=key*cnt.
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

  test('GROUP BY v with SUM(v) — key * count per group', () async {
    final db = await seed();
    try {
      final r =
          await db.execute('SELECT v, SUM(v) FROM t GROUP BY v ORDER BY v');
      expect(r.rows, [
        [1, 1], // 1*1
        [2, 4], // 2*2
        [3, 9], // 3*3
        [4, 4], // 4*1
        [5, 10], // 5*2
      ]);
    } finally {
      await db.close();
    }
  });

  test('GROUP BY v with MIN(v), MAX(v), AVG(v)', () async {
    final db = await seed();
    try {
      final r = await db.execute(
          'SELECT v, MIN(v), MAX(v), AVG(v) FROM t GROUP BY v ORDER BY v');
      expect(r.rows.length, 5);
      for (final row in r.rows) {
        final k = row[0] as int;
        expect(row[1], k);
        expect(row[2], k);
        expect((row[3] as num).toDouble(), closeTo(k.toDouble(), 1e-9));
      }
    } finally {
      await db.close();
    }
  });

  test('GROUP BY v with TOTAL(v) — REAL', () async {
    final db = await seed();
    try {
      final r =
          await db.execute('SELECT v, TOTAL(v) FROM t GROUP BY v ORDER BY v');
      final expectedTotals = [1.0, 4.0, 9.0, 4.0, 10.0];
      for (var i = 0; i < expectedTotals.length; i++) {
        expect(
            (r.rows[i][1] as num).toDouble(), closeTo(expectedTotals[i], 1e-9));
      }
    } finally {
      await db.close();
    }
  });

  test('GROUP BY v combo: COUNT(*), MIN(v), SUM(v) all in one row', () async {
    final db = await seed();
    try {
      final r = await db.execute(
          'SELECT v, COUNT(*), MIN(v), SUM(v) FROM t GROUP BY v ORDER BY v');
      expect(r.rows, [
        [1, 1, 1, 1],
        [2, 2, 2, 4],
        [3, 3, 3, 9],
        [4, 1, 4, 4],
        [5, 2, 5, 10],
      ]);
    } finally {
      await db.close();
    }
  });

  test('GROUP BY v on REAL col with SUM', () async {
    final db = await Database.open();
    try {
      await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, v REAL)');
      await db.execute('CREATE INDEX i_v ON t(v)');
      var id = 1;
      for (final v in [1.5, 1.5, 2.5, 2.5, 2.5]) {
        await db.execute('INSERT INTO t VALUES (${id++}, $v)');
      }
      final r =
          await db.execute('SELECT v, SUM(v) FROM t GROUP BY v ORDER BY v');
      expect(r.rows.length, 2);
      expect((r.rows[0][1] as num).toDouble(), closeTo(3.0, 1e-9));
      expect((r.rows[1][1] as num).toDouble(), closeTo(7.5, 1e-9));
    } finally {
      await db.close();
    }
  });

  test('GROUP BY v with SUM(other_col) bails (different col)', () async {
    final db = await Database.open();
    try {
      await db.execute(
          'CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER, w INTEGER)');
      await db.execute('CREATE INDEX i_v ON t(v)');
      var id = 1;
      for (final pair in [
        [1, 10],
        [1, 20],
        [2, 30],
      ]) {
        await db
            .execute('INSERT INTO t VALUES (${id++}, ${pair[0]}, ${pair[1]})');
      }
      // Generic path must still return correct sum across rows in group.
      final r =
          await db.execute('SELECT v, SUM(w) FROM t GROUP BY v ORDER BY v');
      expect(r.rows, [
        [1, 30],
        [2, 30],
      ]);
    } finally {
      await db.close();
    }
  });
}
