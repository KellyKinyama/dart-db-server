/// Phase-3.4 regression: GROUP BY indexed col now also handles
/// HAVING on the group col / COUNT(*) (=, !=, <, <=, >, >=, BETWEEN,
/// IN, AND-combinations).
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

  test('HAVING COUNT(*) > 1', () async {
    final db = await seed();
    try {
      final r = await db.execute(
          'SELECT v, COUNT(*) FROM t GROUP BY v HAVING COUNT(*) > 1 '
          'ORDER BY v');
      expect(r.rows, [
        [2, 2],
        [3, 3],
        [5, 2],
      ]);
    } finally {
      await db.close();
    }
  });

  test('HAVING COUNT(*) = 1', () async {
    final db = await seed();
    try {
      final r = await db.execute(
          'SELECT v, COUNT(*) FROM t GROUP BY v HAVING COUNT(*) = 1 '
          'ORDER BY v');
      expect(r.rows, [
        [1, 1],
        [4, 1],
      ]);
    } finally {
      await db.close();
    }
  });

  test('HAVING v >= 3', () async {
    final db = await seed();
    try {
      final r = await db.execute(
          'SELECT v, COUNT(*) FROM t GROUP BY v HAVING v >= 3 ORDER BY v');
      expect(r.rows, [
        [3, 3],
        [4, 1],
        [5, 2],
      ]);
    } finally {
      await db.close();
    }
  });

  test('HAVING v BETWEEN 2 AND 4', () async {
    final db = await seed();
    try {
      final r = await db.execute(
          'SELECT v, COUNT(*) FROM t GROUP BY v HAVING v BETWEEN 2 AND 4 '
          'ORDER BY v');
      expect(r.rows, [
        [2, 2],
        [3, 3],
        [4, 1],
      ]);
    } finally {
      await db.close();
    }
  });

  test('HAVING v IN (1, 3, 5)', () async {
    final db = await seed();
    try {
      final r = await db.execute(
          'SELECT v, COUNT(*) FROM t GROUP BY v HAVING v IN (1, 3, 5) '
          'ORDER BY v');
      expect(r.rows, [
        [1, 1],
        [3, 3],
        [5, 2],
      ]);
    } finally {
      await db.close();
    }
  });

  test('HAVING COUNT(*) >= 2 AND v < 5', () async {
    final db = await seed();
    try {
      final r = await db.execute(
          'SELECT v, COUNT(*) FROM t GROUP BY v '
          'HAVING COUNT(*) >= 2 AND v < 5 ORDER BY v');
      expect(r.rows, [
        [2, 2],
        [3, 3],
      ]);
    } finally {
      await db.close();
    }
  });

  test('WHERE + HAVING composes', () async {
    final db = await seed();
    try {
      final r = await db.execute(
          'SELECT v, COUNT(*) FROM t WHERE v >= 2 GROUP BY v '
          'HAVING COUNT(*) > 1 ORDER BY v DESC');
      expect(r.rows, [
        [5, 2],
        [3, 3],
        [2, 2],
      ]);
    } finally {
      await db.close();
    }
  });

  test('HAVING that filters everything → empty', () async {
    final db = await seed();
    try {
      final r = await db.execute(
          'SELECT v, COUNT(*) FROM t GROUP BY v HAVING COUNT(*) > 999');
      expect(r.rows, isEmpty);
    } finally {
      await db.close();
    }
  });

  test('HAVING SUM(v) >= 9 — SUM(v) of group col supported', () async {
    // SUM(v) here is the group col aggregate (= key * cnt). HAVING
    // currently only inspects key & cnt directly; SUM as a HAVING
    // term isn't recognised → must fall through to generic path and
    // still produce the correct answer.
    final db = await seed();
    try {
      final r = await db.execute(
          'SELECT v, SUM(v) FROM t GROUP BY v HAVING SUM(v) >= 9 '
          'ORDER BY v');
      expect(r.rows, [
        [3, 9],
        [5, 10],
      ]);
    } finally {
      await db.close();
    }
  });
}
