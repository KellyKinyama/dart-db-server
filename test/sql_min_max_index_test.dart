/// Phase-1.3 regression: bare `SELECT MIN(col) FROM t` / `MAX(col)`
/// short-circuits via the index's first / last entry. The path only
/// engages when the column has a single-column non-NOCASE index and
/// the SELECT carries no WHERE/GROUP BY/etc., otherwise the generic
/// aggregate path runs.
library;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  test('MIN(col) with index returns first index entry', () async {
    final db = await Database.open();
    try {
      await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)');
      await db.execute('CREATE INDEX i_v ON t(v)');
      // Insert in scrambled order so a scan would not naturally yield 1.
      var id = 1;
      for (final v in [50, 10, 30, 5, 90, 20, 40, 60, 70, 80]) {
        await db.execute('INSERT INTO t VALUES (${id++}, $v)');
      }
      final r = await db.execute('SELECT MIN(v) FROM t');
      expect(r.rows, [
        [5],
      ]);
    } finally {
      await db.close();
    }
  });

  test('MAX(col) with index returns last index entry', () async {
    final db = await Database.open();
    try {
      await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)');
      await db.execute('CREATE INDEX i_v ON t(v)');
      var id = 1;
      for (final v in [50, 10, 30, 5, 90, 20, 40, 60, 70, 80]) {
        await db.execute('INSERT INTO t VALUES (${id++}, $v)');
      }
      final r = await db.execute('SELECT MAX(v) FROM t');
      expect(r.rows, [
        [90],
      ]);
    } finally {
      await db.close();
    }
  });

  test('MIN/MAX on text-keyed index works', () async {
    final db = await Database.open();
    try {
      await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, k TEXT)');
      await db.execute('CREATE INDEX i_k ON t(k)');
      var id = 1;
      for (final k in ['delta', 'alpha', 'gamma', 'beta', 'epsilon']) {
        await db.execute("INSERT INTO t VALUES (${id++}, '$k')");
      }
      final lo = await db.execute('SELECT MIN(k) FROM t');
      final hi = await db.execute('SELECT MAX(k) FROM t');
      expect(lo.rows, [
        ['alpha'],
      ]);
      expect(hi.rows, [
        ['gamma'],
      ]);
    } finally {
      await db.close();
    }
  });

  test('MIN/MAX with NULLs ignores them (matches SQL semantics)', () async {
    final db = await Database.open();
    try {
      await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)');
      await db.execute('CREATE INDEX i_v ON t(v)');
      await db.execute('INSERT INTO t VALUES (1, 10)');
      await db.execute('INSERT INTO t VALUES (2, NULL)');
      await db.execute('INSERT INTO t VALUES (3, 5)');
      await db.execute('INSERT INTO t VALUES (4, NULL)');
      final lo = await db.execute('SELECT MIN(v) FROM t');
      final hi = await db.execute('SELECT MAX(v) FROM t');
      expect(lo.rows, [
        [5],
      ]);
      expect(hi.rows, [
        [10],
      ]);
    } finally {
      await db.close();
    }
  });

  test('MIN(col) on empty table returns NULL', () async {
    final db = await Database.open();
    try {
      await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)');
      await db.execute('CREATE INDEX i_v ON t(v)');
      final r = await db.execute('SELECT MIN(v) FROM t');
      expect(r.rows, [
        [null],
      ]);
    } finally {
      await db.close();
    }
  });

  test('MIN with alias preserves column name', () async {
    final db = await Database.open();
    try {
      await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)');
      await db.execute('CREATE INDEX i_v ON t(v)');
      for (var i = 1; i <= 10; i++) {
        await db.execute('INSERT INTO t VALUES ($i, $i)');
      }
      final r = await db.execute('SELECT MIN(v) AS lo FROM t');
      expect(r.columns, ['lo']);
      expect(r.rows, [
        [1],
      ]);
    } finally {
      await db.close();
    }
  });

  test('MIN on non-indexed column falls back to generic aggregate', () async {
    final db = await Database.open();
    try {
      await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)');
      // No index on v.
      var id = 1;
      for (final v in [50, 10, 30, 5, 90]) {
        await db.execute('INSERT INTO t VALUES (${id++}, $v)');
      }
      final r = await db.execute('SELECT MIN(v) FROM t');
      expect(r.rows, [
        [5],
      ]);
    } finally {
      await db.close();
    }
  });

  test('MIN with WHERE falls back to generic aggregate', () async {
    final db = await Database.open();
    try {
      await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)');
      await db.execute('CREATE INDEX i_v ON t(v)');
      for (var i = 1; i <= 10; i++) {
        await db.execute('INSERT INTO t VALUES ($i, $i)');
      }
      final r = await db.execute('SELECT MIN(v) FROM t WHERE v > 5');
      expect(r.rows, [
        [6],
      ]);
    } finally {
      await db.close();
    }
  });

  test('MIN(DISTINCT) falls back', () async {
    final db = await Database.open();
    try {
      await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)');
      await db.execute('CREATE INDEX i_v ON t(v)');
      var id = 1;
      for (final v in [3, 3, 1, 2, 1]) {
        await db.execute('INSERT INTO t VALUES (${id++}, $v)');
      }
      final r = await db.execute('SELECT MIN(DISTINCT v) FROM t');
      expect(r.rows, [
        [1],
      ]);
    } finally {
      await db.close();
    }
  });

  test('MIN with GROUP BY uses generic aggregate', () async {
    final db = await Database.open();
    try {
      await db.execute(
          'CREATE TABLE t (id INTEGER PRIMARY KEY, k INTEGER, v INTEGER)');
      await db.execute('CREATE INDEX i_v ON t(v)');
      var id = 1;
      for (final p in [
        [1, 10],
        [1, 20],
        [2, 5],
        [2, 100],
        [3, 50],
      ]) {
        await db.execute('INSERT INTO t VALUES (${id++}, ${p[0]}, ${p[1]})');
      }
      final r =
          await db.execute('SELECT k, MIN(v) FROM t GROUP BY k ORDER BY k');
      expect(r.rows, [
        [1, 10],
        [2, 5],
        [3, 50],
      ]);
    } finally {
      await db.close();
    }
  });
}
