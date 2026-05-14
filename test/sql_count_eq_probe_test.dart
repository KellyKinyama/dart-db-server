/// Phase-1.7 regression: `SELECT COUNT(*) FROM t WHERE col = literal`
/// short-circuits to `indexMap[lit].length` when col has a
/// single-column non-NOCASE non-partial index. NULL literal returns 0
/// because `col = NULL` is UNKNOWN. Fallback path keeps semantics on
/// any unsupported shape.
library;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  test('COUNT(*) WHERE col = literal hits posting list directly', () async {
    final db = await Database.open();
    try {
      await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, k INTEGER)');
      await db.execute('CREATE INDEX i_k ON t(k)');
      var id = 1;
      for (final k in [1, 2, 2, 3, 3, 3, 4, 4, 4, 4]) {
        await db.execute('INSERT INTO t VALUES (${id++}, $k)');
      }
      final r = await db.execute('SELECT COUNT(*) FROM t WHERE k = 3');
      expect(r.rows, [
        [3],
      ]);
    } finally {
      await db.close();
    }
  });

  test('COUNT(*) with literal on left side (literal = col) also works',
      () async {
    final db = await Database.open();
    try {
      await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, k INTEGER)');
      await db.execute('CREATE INDEX i_k ON t(k)');
      var id = 1;
      for (final k in [5, 5, 5, 6, 7]) {
        await db.execute('INSERT INTO t VALUES (${id++}, $k)');
      }
      final r = await db.execute('SELECT COUNT(*) FROM t WHERE 5 = k');
      expect(r.rows, [
        [3],
      ]);
    } finally {
      await db.close();
    }
  });

  test('COUNT(*) WHERE col = NULL returns 0 (UNKNOWN)', () async {
    final db = await Database.open();
    try {
      await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, k INTEGER)');
      await db.execute('CREATE INDEX i_k ON t(k)');
      var id = 1;
      for (final v in [1, 2, 3]) {
        await db.execute('INSERT INTO t VALUES (${id++}, $v)');
      }
      await db.execute('INSERT INTO t VALUES (${id++}, NULL)');
      final r = await db.execute('SELECT COUNT(*) FROM t WHERE k = NULL');
      expect(r.rows, [
        [0],
      ]);
    } finally {
      await db.close();
    }
  });

  test('COUNT(*) WHERE TEXT col = literal', () async {
    final db = await Database.open();
    try {
      await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, s TEXT)');
      await db.execute('CREATE INDEX i_s ON t(s)');
      var id = 1;
      for (final s in ['a', 'b', 'b', 'c', 'b']) {
        await db.execute("INSERT INTO t VALUES (${id++}, '$s')");
      }
      final r = await db.execute("SELECT COUNT(*) FROM t WHERE s = 'b'");
      expect(r.rows, [
        [3],
      ]);
    } finally {
      await db.close();
    }
  });

  test('COUNT(*) WHERE col = literal on missing key returns 0', () async {
    final db = await Database.open();
    try {
      await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, k INTEGER)');
      await db.execute('CREATE INDEX i_k ON t(k)');
      for (var i = 1; i <= 5; i++) {
        await db.execute('INSERT INTO t VALUES ($i, $i)');
      }
      final r = await db.execute('SELECT COUNT(*) FROM t WHERE k = 99');
      expect(r.rows, [
        [0],
      ]);
    } finally {
      await db.close();
    }
  });

  test('COUNT(*) WHERE non-indexed col = literal still produces correct count',
      () async {
    final db = await Database.open();
    try {
      await db.execute(
          'CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)');
      // No index on v.
      var id = 1;
      for (final v in [1, 2, 2, 3, 3, 3]) {
        await db.execute('INSERT INTO t VALUES (${id++}, $v)');
      }
      final r = await db.execute('SELECT COUNT(*) FROM t WHERE v = 2');
      expect(r.rows, [
        [2],
      ]);
    } finally {
      await db.close();
    }
  });

  test('COUNT(*) WHERE col != literal stays correct via fallback',
      () async {
    final db = await Database.open();
    try {
      await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, k INTEGER)');
      await db.execute('CREATE INDEX i_k ON t(k)');
      var id = 1;
      for (final k in [1, 2, 2, 3]) {
        await db.execute('INSERT INTO t VALUES (${id++}, $k)');
      }
      final r = await db.execute('SELECT COUNT(*) FROM t WHERE k != 2');
      expect(r.rows, [
        [2],
      ]);
    } finally {
      await db.close();
    }
  });
}
