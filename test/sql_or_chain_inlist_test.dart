/// Phase-1.1 regression: a `WHERE col=a OR col=b OR ...` chain on a
/// single column with constant RHSes is normalised to `col IN (a,b,...)`
/// for index planning, so the planner picks the IN-list probe instead
/// of falling back to a full scan. The original WHERE is still
/// re-evaluated as a residual, so semantics are unchanged.
library;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  test('OR chain on indexed column uses index plan', () async {
    final db = await Database.open();
    try {
      await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)');
      await db.execute('CREATE INDEX i_v ON t(v)');
      for (var i = 1; i <= 100; i++) {
        await db.execute('INSERT INTO t VALUES ($i, $i)');
      }
      final r = await db.execute(
          'SELECT id FROM t WHERE v = 5 OR v = 50 OR v = 95 ORDER BY id');
      expect(r.rows, [
        [5],
        [50],
        [95],
      ]);
      // Plan trace should reference the index.
      expect(db.lastPlanTrace.first, contains('i_v'));
    } finally {
      await db.close();
    }
  });

  test('OR chain matches IN-list semantics for missing keys', () async {
    final db = await Database.open();
    try {
      await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)');
      await db.execute('CREATE INDEX i_v ON t(v)');
      for (var i = 1; i <= 10; i++) {
        await db.execute('INSERT INTO t VALUES ($i, ${i * 10})');
      }
      // 999 doesn't exist; the IN/OR rewrite must just skip it.
      final r = await db.execute(
          'SELECT id FROM t WHERE v = 30 OR v = 999 OR v = 70 ORDER BY id');
      expect(r.rows, [
        [3],
        [7],
      ]);
    } finally {
      await db.close();
    }
  });

  test('OR chain on different columns falls back (no rewrite)', () async {
    final db = await Database.open();
    try {
      await db.execute(
          'CREATE TABLE t (id INTEGER PRIMARY KEY, a INTEGER, b INTEGER)');
      await db.execute('CREATE INDEX i_a ON t(a)');
      await db.execute('CREATE INDEX i_b ON t(b)');
      for (var i = 1; i <= 20; i++) {
        await db.execute('INSERT INTO t VALUES ($i, $i, ${100 - i})');
      }
      // Mixed columns → not eligible for OR-to-IN. Result must still
      // be correct (the executor falls back to a full scan).
      final r = await db.execute(
          'SELECT id FROM t WHERE a = 3 OR b = 95 ORDER BY id');
      expect(r.rows, [
        [3],
        [5],
      ]);
    } finally {
      await db.close();
    }
  });

  test('OR chain combined with AND is preserved correctly', () async {
    final db = await Database.open();
    try {
      await db.execute(
          'CREATE TABLE t (id INTEGER PRIMARY KEY, a INTEGER, b INTEGER)');
      await db.execute('CREATE INDEX i_a ON t(a)');
      for (var i = 1; i <= 20; i++) {
        await db.execute('INSERT INTO t VALUES ($i, ${i % 5}, $i)');
      }
      // (a=1 OR a=2) AND b > 10 — only the OR-chain is rewritten; the
      // AND with `b > 10` is still applied (as either residual or
      // separate conjunct).
      final r = await db.execute(
          'SELECT id FROM t WHERE (a = 1 OR a = 2) AND b > 10 ORDER BY id');
      final expected = <List<Object?>>[
        for (var i = 1; i <= 20; i++)
          if ((i % 5 == 1 || i % 5 == 2) && i > 10) [i],
      ];
      expect(r.rows, expected);
    } finally {
      await db.close();
    }
  });

  test('OR chain on text-keyed indexed column uses index', () async {
    final db = await Database.open();
    try {
      await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, k TEXT)');
      await db.execute('CREATE INDEX i_k ON t(k)');
      // Insert lots of rows so the IN-list (3 keys) easily beats the
      // 80%-of-table fallback threshold.
      for (var i = 1; i <= 100; i++) {
        await db.execute("INSERT INTO t VALUES ($i, 'k$i')");
      }
      final r = await db.execute(
          "SELECT id FROM t WHERE k = 'k5' OR k = 'k50' OR k = 'k95' "
          "ORDER BY id");
      expect(r.rows, [
        [5],
        [50],
        [95],
      ]);
      expect(db.lastPlanTrace.isNotEmpty, isTrue);
      expect(db.lastPlanTrace.first, contains('i_k'));
    } finally {
      await db.close();
    }
  });
}
