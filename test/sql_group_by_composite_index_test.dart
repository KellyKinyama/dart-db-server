/// Phase-3.7 regression: GROUP BY fast path now also serves the
/// LEADING column of a composite index.
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
      [1, 20],
      [2, 10],
      [2, 20],
      [2, 30],
      [3, 10],
      [4, 10],
      [4, 40],
    ]) {
      await db.execute(
          'INSERT INTO t VALUES (${id++}, ${pair[0]}, ${pair[1]})');
    }
    return db;
  }

  test('GROUP BY a uses composite index on (a,b) — COUNT(*)', () async {
    final db = await seed();
    try {
      final r = await db
          .execute('SELECT a, COUNT(*) FROM t GROUP BY a ORDER BY a');
      expect(r.rows, [
        [1, 2],
        [2, 3],
        [3, 1],
        [4, 2],
      ]);
    } finally {
      await db.close();
    }
  });

  test('GROUP BY a with SUM(a) on composite index', () async {
    final db = await seed();
    try {
      final r =
          await db.execute('SELECT a, SUM(a) FROM t GROUP BY a ORDER BY a');
      expect(r.rows, [
        [1, 2],
        [2, 6],
        [3, 3],
        [4, 8],
      ]);
    } finally {
      await db.close();
    }
  });

  test('GROUP BY a ORDER BY a DESC on composite index', () async {
    final db = await seed();
    try {
      final r = await db.execute(
          'SELECT a, COUNT(*) FROM t GROUP BY a ORDER BY a DESC');
      expect(r.rows, [
        [4, 2],
        [3, 1],
        [2, 3],
        [1, 2],
      ]);
    } finally {
      await db.close();
    }
  });

  test('GROUP BY a with MIN(a), MAX(a), AVG(a) on composite index',
      () async {
    final db = await seed();
    try {
      final r = await db.execute(
          'SELECT a, MIN(a), MAX(a), AVG(a) FROM t GROUP BY a ORDER BY a');
      expect(r.rows.length, 4);
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

  test('GROUP BY a with WHERE on composite-leading col → bails to '
      'generic path (still correct)', () async {
    final db = await seed();
    try {
      final r = await db.execute(
          'SELECT a, COUNT(*) FROM t WHERE a = 2 GROUP BY a');
      expect(r.rows, [
        [2, 3],
      ]);
    } finally {
      await db.close();
    }
  });
}
