/// Phase-0.9 regression: when ORDER BY is satisfied by index order and
/// LIMIT is set, the executor truncates the working row set BEFORE the
/// projection / window pass so we don't evaluate expressions on rows
/// that LIMIT would discard. Verified through correctness +
/// `lastPlanLimitPushed` introspection.
library;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  test('LIMIT pushdown on indexed ASC ORDER BY', () async {
    final db = await Database.open();
    try {
      await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)');
      await db.execute('CREATE INDEX i_v ON t(v)');
      // Insert in scrambled order.
      var id = 1;
      for (final v in [50, 10, 30, 5, 90, 20, 40, 60, 70, 80]) {
        await db.execute('INSERT INTO t VALUES (${id++}, $v)');
      }
      final r = await db.execute(
          'SELECT v FROM t WHERE v >= 1 ORDER BY v LIMIT 3');
      expect(r.rows.map((row) => row[0]).toList(), [5, 10, 20]);
      expect(db.lastPlanSortSkipped, isTrue);
      expect(db.lastPlanLimitPushed, isTrue);
    } finally {
      await db.close();
    }
  });

  test('LIMIT pushdown on indexed DESC ORDER BY', () async {
    final db = await Database.open();
    try {
      await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)');
      await db.execute('CREATE INDEX i_v ON t(v)');
      var id = 1;
      for (final v in [50, 10, 30, 5, 90, 20, 40, 60, 70, 80]) {
        await db.execute('INSERT INTO t VALUES (${id++}, $v)');
      }
      final r = await db.execute(
          'SELECT v FROM t WHERE v >= 1 ORDER BY v DESC LIMIT 3');
      expect(r.rows.map((row) => row[0]).toList(), [90, 80, 70]);
      expect(db.lastPlanSortSkipped, isTrue);
      expect(db.lastPlanLimitPushed, isTrue);
    } finally {
      await db.close();
    }
  });

  test('LIMIT pushdown honours OFFSET', () async {
    final db = await Database.open();
    try {
      await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)');
      await db.execute('CREATE INDEX i_v ON t(v)');
      var id = 1;
      for (final v in [50, 10, 30, 5, 90, 20, 40, 60, 70, 80]) {
        await db.execute('INSERT INTO t VALUES (${id++}, $v)');
      }
      final r = await db.execute(
          'SELECT v FROM t WHERE v >= 1 ORDER BY v LIMIT 3 OFFSET 4');
      expect(r.rows.map((row) => row[0]).toList(), [40, 50, 60]);
      expect(db.lastPlanLimitPushed, isTrue);
    } finally {
      await db.close();
    }
  });

  test('LIMIT pushdown skipped when ORDER BY not satisfied by index',
      () async {
    final db = await Database.open();
    try {
      await db.execute(
          'CREATE TABLE t (id INTEGER PRIMARY KEY, a INTEGER, b INTEGER)');
      await db.execute('CREATE INDEX i_a ON t(a)');
      for (var i = 0; i < 10; i++) {
        await db.execute('INSERT INTO t VALUES (${i + 1}, ${i % 3}, ${9 - i})');
      }
      // Index is on a, ORDER BY is on b → no pushdown.
      final r = await db.execute(
          'SELECT b FROM t WHERE a = 1 ORDER BY b LIMIT 2');
      expect(r.rows.length, 2);
      expect(db.lastPlanLimitPushed, isFalse);
    } finally {
      await db.close();
    }
  });

  test('LIMIT pushdown skipped under DISTINCT', () async {
    final db = await Database.open();
    try {
      await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)');
      await db.execute('CREATE INDEX i_v ON t(v)');
      var id = 1;
      for (final v in [1, 1, 2, 2, 3, 3, 4]) {
        await db.execute('INSERT INTO t VALUES (${id++}, $v)');
      }
      final r = await db.execute(
          'SELECT DISTINCT v FROM t WHERE v >= 1 ORDER BY v LIMIT 2');
      expect(r.rows.map((row) => row[0]).toList(), [1, 2]);
      expect(db.lastPlanLimitPushed, isFalse);
    } finally {
      await db.close();
    }
  });

  test('LIMIT pushdown skipped under window functions', () async {
    final db = await Database.open();
    try {
      await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)');
      await db.execute('CREATE INDEX i_v ON t(v)');
      var id = 1;
      for (final v in [10, 20, 30, 40, 50]) {
        await db.execute('INSERT INTO t VALUES (${id++}, $v)');
      }
      // ROW_NUMBER over the whole partition needs every row first.
      final r = await db.execute(
          'SELECT v, ROW_NUMBER() OVER (ORDER BY v) AS rn '
          'FROM t WHERE v >= 1 ORDER BY v LIMIT 2');
      expect(r.rows, [
        [10, 1],
        [20, 2],
      ]);
      expect(db.lastPlanLimitPushed, isFalse);
    } finally {
      await db.close();
    }
  });
}
