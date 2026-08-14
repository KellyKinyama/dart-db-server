/// Phase-1.6 regression: bare `SELECT MIN(col), MAX(col), COUNT(*)
/// FROM t` (any combination, in any order) is served entirely from
/// the index map plus `t.rows.length` — no row hydration. Falls back
/// to the generic aggregate path for unsupported aggregates.
library;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  test('MIN(col), MAX(col) on indexed col is index-only', () async {
    final db = await Database.open();
    try {
      await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)');
      await db.execute('CREATE INDEX i_v ON t(v)');
      var id = 1;
      for (final v in [50, 10, 30, 5, 90, 20, 40, 60, 70, 80]) {
        await db.execute('INSERT INTO t VALUES (${id++}, $v)');
      }
      final r = await db.execute('SELECT MIN(v), MAX(v) FROM t');
      expect(r.rows, [
        [5, 90],
      ]);
      expect(r.columns, ['min(v)', 'max(v)']);
    } finally {
      await db.close();
    }
  });

  test('MIN, MAX, COUNT(*) combined in one query', () async {
    final db = await Database.open();
    try {
      await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)');
      await db.execute('CREATE INDEX i_v ON t(v)');
      for (var i = 1; i <= 7; i++) {
        await db.execute('INSERT INTO t VALUES ($i, ${i * 3})');
      }
      final r = await db
          .execute('SELECT MIN(v) AS lo, MAX(v) AS hi, COUNT(*) AS n FROM t');
      expect(r.columns, ['lo', 'hi', 'n']);
      expect(r.rows, [
        [3, 21, 7],
      ]);
    } finally {
      await db.close();
    }
  });

  test('Empty table: MIN/MAX -> NULL, COUNT(*) -> 0', () async {
    final db = await Database.open();
    try {
      await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)');
      await db.execute('CREATE INDEX i_v ON t(v)');
      final r = await db.execute('SELECT MIN(v), MAX(v), COUNT(*) FROM t');
      expect(r.rows, [
        [null, null, 0],
      ]);
    } finally {
      await db.close();
    }
  });

  test('MIN of two different indexed columns', () async {
    final db = await Database.open();
    try {
      await db.execute(
          'CREATE TABLE t (id INTEGER PRIMARY KEY, a INTEGER, b INTEGER)');
      await db.execute('CREATE INDEX i_a ON t(a)');
      await db.execute('CREATE INDEX i_b ON t(b)');
      var id = 1;
      for (final p in [
        [10, 100],
        [3, 200],
        [50, 50],
        [7, 175],
      ]) {
        await db.execute('INSERT INTO t VALUES (${id++}, ${p[0]}, ${p[1]})');
      }
      final r = await db.execute('SELECT MIN(a), MAX(b) FROM t');
      expect(r.rows, [
        [3, 200],
      ]);
    } finally {
      await db.close();
    }
  });

  test('Mixing in a non-rewritable aggregate (SUM) falls through', () async {
    final db = await Database.open();
    try {
      await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)');
      await db.execute('CREATE INDEX i_v ON t(v)');
      for (var i = 1; i <= 5; i++) {
        await db.execute('INSERT INTO t VALUES ($i, $i)');
      }
      // Generic path; correctness only.
      final r = await db.execute('SELECT MIN(v), SUM(v) FROM t');
      expect(r.rows, [
        [1, 15],
      ]);
    } finally {
      await db.close();
    }
  });

  test('MIN(v) without index on v falls through to generic path', () async {
    final db = await Database.open();
    try {
      await db.execute(
          'CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER, w INTEGER)');
      await db.execute('CREATE INDEX i_w ON t(w)');
      var id = 1;
      for (final p in [
        [50, 1],
        [3, 2],
        [25, 3],
      ]) {
        await db.execute('INSERT INTO t VALUES (${id++}, ${p[0]}, ${p[1]})');
      }
      final r = await db.execute('SELECT MIN(v), MAX(w) FROM t');
      expect(r.rows, [
        [3, 3],
      ]);
    } finally {
      await db.close();
    }
  });
}
