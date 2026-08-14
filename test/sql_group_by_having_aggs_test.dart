/// Phase-3.5 regression: HAVING terms in the GROUP BY fast path now
/// also accept MIN/MAX/SUM/AVG/TOTAL of the group col.
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

  test('HAVING SUM(v) >= 9', () async {
    final db = await seed();
    try {
      final r = await db.execute(
          'SELECT v, SUM(v) FROM t GROUP BY v HAVING SUM(v) >= 9 ORDER BY v');
      expect(r.rows, [
        [3, 9],
        [5, 10],
      ]);
    } finally {
      await db.close();
    }
  });

  test('HAVING MIN(v) > 2', () async {
    final db = await seed();
    try {
      final r = await db.execute(
          'SELECT v, COUNT(*) FROM t GROUP BY v HAVING MIN(v) > 2 ORDER BY v');
      expect(r.rows, [
        [3, 3],
        [4, 1],
        [5, 2],
      ]);
    } finally {
      await db.close();
    }
  });

  test('HAVING MAX(v) <= 3', () async {
    final db = await seed();
    try {
      final r = await db.execute(
          'SELECT v, COUNT(*) FROM t GROUP BY v HAVING MAX(v) <= 3 ORDER BY v');
      expect(r.rows, [
        [1, 1],
        [2, 2],
        [3, 3],
      ]);
    } finally {
      await db.close();
    }
  });

  test('HAVING AVG(v) BETWEEN 2 AND 4', () async {
    final db = await seed();
    try {
      final r = await db.execute('SELECT v, COUNT(*) FROM t GROUP BY v '
          'HAVING AVG(v) BETWEEN 2 AND 4 ORDER BY v');
      expect(r.rows, [
        [2, 2],
        [3, 3],
        [4, 1],
      ]);
    } finally {
      await db.close();
    }
  });

  test('HAVING TOTAL(v) > 5.0', () async {
    final db = await seed();
    try {
      final r = await db.execute('SELECT v, COUNT(*) FROM t GROUP BY v '
          'HAVING TOTAL(v) > 5.0 ORDER BY v');
      // TOTAL(v) per group = key*cnt: 1,4,9,4,10. > 5 → keys 3 and 5.
      expect(r.rows, [
        [3, 3],
        [5, 2],
      ]);
    } finally {
      await db.close();
    }
  });

  test('HAVING SUM(v) IN (4, 9)', () async {
    final db = await seed();
    try {
      final r = await db.execute('SELECT v, SUM(v) FROM t GROUP BY v '
          'HAVING SUM(v) IN (4, 9) ORDER BY v');
      // SUM per group: 1,4,9,4,10 → matches 4 (v=2), 9 (v=3), 4 (v=4).
      expect(r.rows, [
        [2, 4],
        [3, 9],
        [4, 4],
      ]);
    } finally {
      await db.close();
    }
  });

  test('HAVING SUM(v) > 5 AND COUNT(*) > 1', () async {
    final db = await seed();
    try {
      final r = await db.execute('SELECT v, SUM(v), COUNT(*) FROM t GROUP BY v '
          'HAVING SUM(v) > 5 AND COUNT(*) > 1 ORDER BY v');
      expect(r.rows, [
        [3, 9, 3],
        [5, 10, 2],
      ]);
    } finally {
      await db.close();
    }
  });
}
