/// Phase-2.0 regression: `SELECT COUNT(*) FROM t WHERE col IS [NOT]
/// NULL` short-circuits via the index. Indexes don't store NULL keys
/// so `IS NOT NULL` is the sum of every posting list; `IS NULL` is
/// `t.rows.length - that`.
library;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  test('COUNT(*) WHERE col IS NULL via index complement', () async {
    final db = await Database.open();
    try {
      await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, k INTEGER)');
      await db.execute('CREATE INDEX i_k ON t(k)');
      var id = 1;
      for (final v in [1, 2, null, 3, null, null, 4]) {
        await db.execute('INSERT INTO t VALUES (${id++}, '
            '${v ?? 'NULL'})');
      }
      final r = await db.execute('SELECT COUNT(*) FROM t WHERE k IS NULL');
      expect(r.rows, [
        [3],
      ]);
    } finally {
      await db.close();
    }
  });

  test('COUNT(*) WHERE col IS NOT NULL via posting-sum', () async {
    final db = await Database.open();
    try {
      await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, k INTEGER)');
      await db.execute('CREATE INDEX i_k ON t(k)');
      var id = 1;
      for (final v in [10, null, 20, 30, null]) {
        await db.execute('INSERT INTO t VALUES (${id++}, '
            '${v ?? 'NULL'})');
      }
      final r =
          await db.execute('SELECT COUNT(*) FROM t WHERE k IS NOT NULL');
      expect(r.rows, [
        [3],
      ]);
    } finally {
      await db.close();
    }
  });

  test('COUNT(*) WHERE col IS NULL on no-NULL table is 0', () async {
    final db = await Database.open();
    try {
      await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, k INTEGER)');
      await db.execute('CREATE INDEX i_k ON t(k)');
      for (var i = 1; i <= 5; i++) {
        await db.execute('INSERT INTO t VALUES ($i, $i)');
      }
      final r = await db.execute('SELECT COUNT(*) FROM t WHERE k IS NULL');
      expect(r.rows, [
        [0],
      ]);
    } finally {
      await db.close();
    }
  });

  test('COUNT(*) WHERE col IS NULL on all-NULL table equals row count',
      () async {
    final db = await Database.open();
    try {
      await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, k INTEGER)');
      await db.execute('CREATE INDEX i_k ON t(k)');
      for (var i = 1; i <= 4; i++) {
        await db.execute('INSERT INTO t VALUES ($i, NULL)');
      }
      final r = await db.execute('SELECT COUNT(*) FROM t WHERE k IS NULL');
      expect(r.rows, [
        [4],
      ]);
      final r2 =
          await db.execute('SELECT COUNT(*) FROM t WHERE k IS NOT NULL');
      expect(r2.rows, [
        [0],
      ]);
    } finally {
      await db.close();
    }
  });

  test('IS NULL on non-indexed col falls through to generic path',
      () async {
    final db = await Database.open();
    try {
      await db.execute(
          'CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)');
      var id = 1;
      for (final v in [1, null, 2, null]) {
        await db.execute('INSERT INTO t VALUES (${id++}, '
            '${v ?? 'NULL'})');
      }
      final r = await db.execute('SELECT COUNT(*) FROM t WHERE v IS NULL');
      expect(r.rows, [
        [2],
      ]);
    } finally {
      await db.close();
    }
  });
}
