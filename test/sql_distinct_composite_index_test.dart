/// Phase-3.8 regression: SELECT DISTINCT c1, c2[,...] from a
/// composite-index-covered table is served by walking the index
/// keys and deduping adjacent prefix tuples.
library;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  Future<Database> seed() async {
    final db = await Database.open();
    await db.execute(
        'CREATE TABLE t (id INTEGER PRIMARY KEY, a INTEGER, b INTEGER)');
    await db.execute('CREATE INDEX i_ab ON t(a, b)');
    var id = 1;
    for (final pair in [
      [1, 10],
      [1, 10],
      [1, 20],
      [2, 10],
      [2, 20],
      [2, 20],
      [3, 30],
    ]) {
      await db
          .execute('INSERT INTO t VALUES (${id++}, ${pair[0]}, ${pair[1]})');
    }
    return db;
  }

  test('SELECT DISTINCT a, b uses composite index', () async {
    final db = await seed();
    try {
      final r = await db.execute('SELECT DISTINCT a, b FROM t ORDER BY a, b');
      expect(r.rows, [
        [1, 10],
        [1, 20],
        [2, 10],
        [2, 20],
        [3, 30],
      ]);
    } finally {
      await db.close();
    }
  });

  test('SELECT DISTINCT a, b ORDER BY a DESC, b DESC', () async {
    final db = await seed();
    try {
      final r = await db
          .execute('SELECT DISTINCT a, b FROM t ORDER BY a DESC, b DESC');
      expect(r.rows, [
        [3, 30],
        [2, 20],
        [2, 10],
        [1, 20],
        [1, 10],
      ]);
    } finally {
      await db.close();
    }
  });

  test('SELECT DISTINCT a, b LIMIT 3', () async {
    final db = await seed();
    try {
      final r =
          await db.execute('SELECT DISTINCT a, b FROM t ORDER BY a, b LIMIT 3');
      expect(r.rows, [
        [1, 10],
        [1, 20],
        [2, 10],
      ]);
    } finally {
      await db.close();
    }
  });

  test('SELECT DISTINCT a, b without ORDER BY', () async {
    final db = await seed();
    try {
      final r = await db.execute('SELECT DISTINCT a, b FROM t');
      // No ORDER BY: still walks the SplayTreeMap in sorted order
      // (deterministic but unspecified by SQL).
      expect(r.rows.length, 5);
      expect(r.rows, anyElement(equals([1, 10])));
      expect(r.rows, anyElement(equals([3, 30])));
    } finally {
      await db.close();
    }
  });

  test(
      'SELECT DISTINCT a (prefix of composite index) — falls to '
      'covering scan, dedupes via that path', () async {
    final db = await seed();
    try {
      final r = await db.execute('SELECT DISTINCT a FROM t ORDER BY a');
      // Even if served by a different path, the answer must be these
      // 3 distinct values.
      expect(r.rows, [
        [1],
        [2],
        [3],
      ]);
    } finally {
      await db.close();
    }
  });
}
