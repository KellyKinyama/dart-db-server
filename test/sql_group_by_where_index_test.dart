/// Phase-3.3 regression: GROUP BY indexed col now also restricts to
/// the WHERE-matched subrange of the index (=, BETWEEN, range AND,
/// IN-list, IS [NOT] NULL).
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

  test('GROUP BY v WHERE v = 3 → single group', () async {
    final db = await seed();
    try {
      final r = await db.execute(
          'SELECT v, COUNT(*) FROM t WHERE v = 3 GROUP BY v ORDER BY v');
      expect(r.rows, [
        [3, 3],
      ]);
    } finally {
      await db.close();
    }
  });

  test('GROUP BY v WHERE v BETWEEN 2 AND 4', () async {
    final db = await seed();
    try {
      final r = await db
          .execute('SELECT v, COUNT(*), SUM(v) FROM t WHERE v BETWEEN 2 AND 4 '
              'GROUP BY v ORDER BY v');
      expect(r.rows, [
        [2, 2, 4],
        [3, 3, 9],
        [4, 1, 4],
      ]);
    } finally {
      await db.close();
    }
  });

  test('GROUP BY v WHERE v >= 3 AND v < 5 (range AND)', () async {
    final db = await seed();
    try {
      final r =
          await db.execute('SELECT v, COUNT(*) FROM t WHERE v >= 3 AND v < 5 '
              'GROUP BY v ORDER BY v');
      expect(r.rows, [
        [3, 3],
        [4, 1],
      ]);
    } finally {
      await db.close();
    }
  });

  test('GROUP BY v WHERE v IN (1, 3, 5)', () async {
    final db = await seed();
    try {
      final r =
          await db.execute('SELECT v, COUNT(*) FROM t WHERE v IN (1, 3, 5) '
              'GROUP BY v ORDER BY v');
      expect(r.rows, [
        [1, 1],
        [3, 3],
        [5, 2],
      ]);
    } finally {
      await db.close();
    }
  });

  test('GROUP BY v WHERE v IS NOT NULL behaves like no WHERE', () async {
    final db = await seed();
    try {
      final r =
          await db.execute('SELECT v, COUNT(*) FROM t WHERE v IS NOT NULL '
              'GROUP BY v ORDER BY v');
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

  test('GROUP BY v WHERE v IS NULL → empty result', () async {
    final db = await seed();
    try {
      final r = await db
          .execute('SELECT v, COUNT(*) FROM t WHERE v IS NULL GROUP BY v');
      expect(r.rows, isEmpty);
    } finally {
      await db.close();
    }
  });

  test(
      'GROUP BY v with WHERE excluding NULLs works even when table '
      'has NULL rows', () async {
    final db = await Database.open();
    try {
      await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)');
      await db.execute('CREATE INDEX i_v ON t(v)');
      await db.execute('INSERT INTO t VALUES (1, 1)');
      await db.execute('INSERT INTO t VALUES (2, 2)');
      await db.execute('INSERT INTO t VALUES (3, 2)');
      await db.execute('INSERT INTO t VALUES (4, NULL)');
      await db.execute('INSERT INTO t VALUES (5, NULL)');
      // Without WHERE: bails (NULL group missing). With WHERE that
      // excludes NULLs: serves index-only.
      final r = await db.execute(
          'SELECT v, COUNT(*) FROM t WHERE v >= 1 GROUP BY v ORDER BY v');
      expect(r.rows, [
        [1, 1],
        [2, 2],
      ]);
    } finally {
      await db.close();
    }
  });

  test('GROUP BY v WHERE v BETWEEN 2 AND 4 ORDER BY v DESC', () async {
    final db = await seed();
    try {
      final r =
          await db.execute('SELECT v, COUNT(*) FROM t WHERE v BETWEEN 2 AND 4 '
              'GROUP BY v ORDER BY v DESC');
      expect(r.rows, [
        [4, 1],
        [3, 3],
        [2, 2],
      ]);
    } finally {
      await db.close();
    }
  });

  test('GROUP BY v WHERE v = 999 → empty result', () async {
    final db = await seed();
    try {
      final r = await db.execute(
          'SELECT v, COUNT(*), SUM(v) FROM t WHERE v = 999 GROUP BY v');
      expect(r.rows, isEmpty);
    } finally {
      await db.close();
    }
  });
}
