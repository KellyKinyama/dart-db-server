/// Phase-1.2 regression: bare `SELECT COUNT(*) FROM t [WHERE indexed]`
/// on in-memory tables short-circuits without hydrating row maps. We
/// can't easily probe "no hydration" directly, so we assert correctness
/// across a few representative shapes plus shape-mismatch fallthrough.
library;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  test('bare COUNT(*) with no WHERE returns t.rows.length', () async {
    final db = await Database.open();
    try {
      await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)');
      for (var i = 1; i <= 100; i++) {
        await db.execute('INSERT INTO t VALUES ($i, $i)');
      }
      final r = await db.execute('SELECT COUNT(*) FROM t');
      expect(r.rows, [
        [100],
      ]);
    } finally {
      await db.close();
    }
  });

  test('COUNT(*) with indexed equality WHERE counts via index', () async {
    final db = await Database.open();
    try {
      await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, k INTEGER)');
      await db.execute('CREATE INDEX i_k ON t(k)');
      for (var i = 1; i <= 100; i++) {
        await db.execute('INSERT INTO t VALUES ($i, ${i % 5})');
      }
      final r = await db.execute('SELECT COUNT(*) FROM t WHERE k = 2');
      expect(r.rows, [
        [20],
      ]);
    } finally {
      await db.close();
    }
  });

  test('COUNT(*) AS alias preserves the column name', () async {
    final db = await Database.open();
    try {
      await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY)');
      for (var i = 1; i <= 7; i++) {
        await db.execute('INSERT INTO t VALUES ($i)');
      }
      final r = await db.execute('SELECT COUNT(*) AS n FROM t');
      expect(r.columns, ['n']);
      expect(r.rows, [
        [7],
      ]);
    } finally {
      await db.close();
    }
  });

  test('COUNT(*) on empty table returns one row with 0', () async {
    final db = await Database.open();
    try {
      await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY)');
      final r = await db.execute('SELECT COUNT(*) FROM t');
      expect(r.rows, [
        [0],
      ]);
    } finally {
      await db.close();
    }
  });

  test('COUNT(*) with non-indexed WHERE still returns correct count',
      () async {
    final db = await Database.open();
    try {
      await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)');
      // No index on v → fast path declines, generic aggregate runs.
      for (var i = 1; i <= 30; i++) {
        await db.execute('INSERT INTO t VALUES ($i, $i)');
      }
      final r = await db.execute('SELECT COUNT(*) FROM t WHERE v > 20');
      expect(r.rows, [
        [10],
      ]);
    } finally {
      await db.close();
    }
  });

  test('COUNT(DISTINCT col) is not the bare fast path', () async {
    final db = await Database.open();
    try {
      await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)');
      var id = 1;
      for (final v in [1, 2, 2, 3, 3, 3]) {
        await db.execute('INSERT INTO t VALUES (${id++}, $v)');
      }
      // Generic aggregate path must still produce 3 distinct values.
      final r = await db.execute('SELECT COUNT(DISTINCT v) FROM t');
      expect(r.rows, [
        [3],
      ]);
    } finally {
      await db.close();
    }
  });

  test('COUNT(*) with GROUP BY uses generic aggregate path', () async {
    final db = await Database.open();
    try {
      await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)');
      var id = 1;
      for (final v in [1, 1, 2, 2, 2, 3]) {
        await db.execute('INSERT INTO t VALUES (${id++}, $v)');
      }
      final r =
          await db.execute('SELECT v, COUNT(*) FROM t GROUP BY v ORDER BY v');
      expect(r.rows, [
        [1, 2],
        [2, 3],
        [3, 1],
      ]);
    } finally {
      await db.close();
    }
  });
}
