/// Phase-2.7 regression: bare `COUNT(DISTINCT col)` on a single-column
/// non-NOCASE non-partial index is `indexMap.length` — keys ARE the
/// distinct non-NULL values.
library;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  test('COUNT(DISTINCT v) on indexed col → index size', () async {
    final db = await Database.open();
    try {
      await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)');
      await db.execute('CREATE INDEX i_v ON t(v)');
      var id = 1;
      for (final v in [1, 2, 2, 3, 3, 3, 4]) {
        await db.execute('INSERT INTO t VALUES (${id++}, $v)');
      }
      final r = await db.execute('SELECT COUNT(DISTINCT v) FROM t');
      expect(r.rows, [
        [4],
      ]);
    } finally {
      await db.close();
    }
  });

  test('COUNT(DISTINCT v) skips NULLs', () async {
    final db = await Database.open();
    try {
      await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)');
      await db.execute('CREATE INDEX i_v ON t(v)');
      var id = 1;
      for (final v in [1, null, 2, null, 2, 3]) {
        await db.execute('INSERT INTO t VALUES (${id++}, ${v ?? 'NULL'})');
      }
      final r = await db.execute('SELECT COUNT(DISTINCT v) FROM t');
      expect(r.rows, [
        [3],
      ]);
    } finally {
      await db.close();
    }
  });

  test('COUNT(DISTINCT v) on empty table → 0', () async {
    final db = await Database.open();
    try {
      await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)');
      await db.execute('CREATE INDEX i_v ON t(v)');
      final r = await db.execute('SELECT COUNT(DISTINCT v) FROM t');
      expect(r.rows, [
        [0],
      ]);
    } finally {
      await db.close();
    }
  });

  test('COUNT(DISTINCT v) on non-indexed col falls through (correctness)',
      () async {
    final db = await Database.open();
    try {
      await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)');
      // No index on v.
      var id = 1;
      for (final v in [1, 2, 2, 3, 3, 3, 4]) {
        await db.execute('INSERT INTO t VALUES (${id++}, $v)');
      }
      final r = await db.execute('SELECT COUNT(DISTINCT v) FROM t');
      expect(r.rows, [
        [4],
      ]);
    } finally {
      await db.close();
    }
  });

  test('COUNT(DISTINCT) with WHERE bails to generic path', () async {
    final db = await Database.open();
    try {
      await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)');
      await db.execute('CREATE INDEX i_v ON t(v)');
      var id = 1;
      for (final v in [1, 2, 2, 3, 3, 3, 4]) {
        await db.execute('INSERT INTO t VALUES (${id++}, $v)');
      }
      final r =
          await db.execute('SELECT COUNT(DISTINCT v) FROM t WHERE v >= 2');
      expect(r.rows, [
        [3],
      ]);
    } finally {
      await db.close();
    }
  });
}
