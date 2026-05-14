/// Phase-1.8 regression: `SELECT COUNT(*) FROM t WHERE col IN (lit,
/// lit, ...)` short-circuits to a sum of posting-list lengths when
/// col has a single-column non-NOCASE non-partial index. NULL list
/// elements are silently dropped (NULL never matches `=`); duplicate
/// list elements are de-duped so `IN (1, 1, 1)` doesn't triple-count.
/// Also exercises the OR-chain → IN rewrite (Phase 1.1) feeding into
/// this fast path.
library;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  test('COUNT(*) WHERE col IN (a, b, c) sums posting lists', () async {
    final db = await Database.open();
    try {
      await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, k INTEGER)');
      await db.execute('CREATE INDEX i_k ON t(k)');
      var id = 1;
      for (final k in [1, 2, 2, 3, 3, 3, 4, 4, 4, 4, 5]) {
        await db.execute('INSERT INTO t VALUES (${id++}, $k)');
      }
      final r = await db.execute('SELECT COUNT(*) FROM t WHERE k IN (2, 3)');
      // 2 of `2` + 3 of `3` = 5
      expect(r.rows, [
        [5],
      ]);
    } finally {
      await db.close();
    }
  });

  test('IN-list with NULL drops the NULL element', () async {
    final db = await Database.open();
    try {
      await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, k INTEGER)');
      await db.execute('CREATE INDEX i_k ON t(k)');
      var id = 1;
      for (final k in [1, 2, 2, 3]) {
        await db.execute('INSERT INTO t VALUES (${id++}, $k)');
      }
      final r =
          await db.execute('SELECT COUNT(*) FROM t WHERE k IN (1, NULL, 2)');
      // 1 of `1` + 2 of `2` = 3
      expect(r.rows, [
        [3],
      ]);
    } finally {
      await db.close();
    }
  });

  test('Duplicate list elements are de-duplicated', () async {
    final db = await Database.open();
    try {
      await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, k INTEGER)');
      await db.execute('CREATE INDEX i_k ON t(k)');
      var id = 1;
      for (final k in [1, 2, 2, 3]) {
        await db.execute('INSERT INTO t VALUES (${id++}, $k)');
      }
      final r =
          await db.execute('SELECT COUNT(*) FROM t WHERE k IN (2, 2, 2)');
      expect(r.rows, [
        [2],
      ]);
    } finally {
      await db.close();
    }
  });

  test('IN-list with all-missing keys returns 0', () async {
    final db = await Database.open();
    try {
      await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, k INTEGER)');
      await db.execute('CREATE INDEX i_k ON t(k)');
      for (var i = 1; i <= 5; i++) {
        await db.execute('INSERT INTO t VALUES ($i, $i)');
      }
      final r = await db
          .execute('SELECT COUNT(*) FROM t WHERE k IN (98, 99, 100)');
      expect(r.rows, [
        [0],
      ]);
    } finally {
      await db.close();
    }
  });

  test('TEXT IN-list', () async {
    final db = await Database.open();
    try {
      await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, s TEXT)');
      await db.execute('CREATE INDEX i_s ON t(s)');
      var id = 1;
      for (final s in ['a', 'b', 'b', 'c', 'd']) {
        await db.execute("INSERT INTO t VALUES (${id++}, '$s')");
      }
      final r =
          await db.execute("SELECT COUNT(*) FROM t WHERE s IN ('b', 'd')");
      // 2 + 1
      expect(r.rows, [
        [3],
      ]);
    } finally {
      await db.close();
    }
  });

  test('NOT IN falls back to generic path', () async {
    final db = await Database.open();
    try {
      await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, k INTEGER)');
      await db.execute('CREATE INDEX i_k ON t(k)');
      var id = 1;
      for (final k in [1, 2, 3, 4]) {
        await db.execute('INSERT INTO t VALUES (${id++}, $k)');
      }
      final r =
          await db.execute('SELECT COUNT(*) FROM t WHERE k NOT IN (2, 3)');
      expect(r.rows, [
        [2],
      ]);
    } finally {
      await db.close();
    }
  });

  test('OR-chain over indexed col reuses Phase 1.1 rewrite', () async {
    // Phase 1.1 turns `k = 2 OR k = 3 OR k = 5` into InExpr; the count
    // path then resolves it via the IN fast path.
    final db = await Database.open();
    try {
      await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, k INTEGER)');
      await db.execute('CREATE INDEX i_k ON t(k)');
      // ≥ 50 rows so the planner trace records the IN rewrite (per
      // memory note: planner has a 'too small' cutoff).
      var id = 1;
      for (var i = 0; i < 100; i++) {
        await db.execute('INSERT INTO t VALUES (${id++}, ${i % 7})');
      }
      // mod 2/3/5 each have 14 elements out of 100 (mods 0 and 1 each
      // have 15). 14 + 14 + 14 = 42.
      final r = await db
          .execute('SELECT COUNT(*) FROM t WHERE k = 2 OR k = 3 OR k = 5');
      expect(r.rows, [
        [42],
      ]);
    } finally {
      await db.close();
    }
  });
}
